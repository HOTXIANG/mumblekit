//
//  MKConnection.m
//  MumbleKit
//
//  Fixed: Deprecated SSL properties and selector typos.
//

#import <MumbleKit/MKConnection.h>
#import <MumbleKit/MKUser.h>
#import <MumbleKit/MKVersion.h>
#import <MumbleKit/MKCertificate.h>
#import "MKUtils.h"
#import "MKAudioOutput.h"
#import "MKCryptState.h"
#import "MKPacketDataStream.h"
#import "MKAudio.h"
#import "MKAudioOutput.h"

#include <dispatch/dispatch.h>

#include  <Security/SecureTransport.h>

#if TARGET_OS_IPHONE == 1
# import <UIKit/UIKit.h>
# import <CFNetwork/CFNetwork.h>
# import <CoreFoundation/CoreFoundation.h>
#endif

#include <sys/socket.h>
#include <sys/types.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <netinet/tcp.h>

#import "Mumble.pb.h"

// The bitstream we should send to the server.
// It's currently hard-coded.
#define MUMBLEKIT_CELT_BITSTREAM 0x8000000bUL

@interface MKConnection () {
    MKCryptState   *_crypt;

    MKMessageType  packetType;
    int            packetLength;
    int            packetBufferOffset;
    NSMutableData  *packetBuffer;
    NSString       *_hostname;
    NSUInteger     _port;
    BOOL           _keepRunning;
    BOOL           _reconnect;

    BOOL           _forceTCP;
    BOOL           _udpAvailable;
    unsigned long  _connTime;
    NSTimer        *_pingTimer;
    NSOutputStream *_outputStream;
    NSInputStream  *_inputStream;
    BOOL           _connectionEstablished;
    BOOL           _ignoreSSLVerification;
    BOOL           _readyVoice;
    id             _msgHandler;
    id             _delegate;
    int            _socket;
    CFSocketRef    _udpSock;
    NSArray        *_certificateChain;
    NSError        *_connError;
    BOOL           _rejected;

    // Codec info
    NSUInteger     _alphaCodec;
    NSUInteger     _betaCodec;
    BOOL           _preferAlpha;
    BOOL           _shouldUseOpus;
    
    // Server info.
    NSString       *_serverVersion;
    NSString       *_serverRelease;
    NSString       *_serverOSName;
    NSString       *_serverOSVersion;
    NSMutableArray *_peerCertificates;
    BOOL           _trustedChain;
}

- (void) _setupSsl;
- (void) _updateTLSTrustedStatus;
- (void) _pingTimerFired:(NSTimer *)timer;
- (void) _pingResponseFromServer:(MPPing *)pingMessage;
- (void) _versionMessageReceived:(MPVersion *)msg;
- (void) _doCryptSetup:(MPCryptSetup *)cryptSetup;
- (void) _connectionRejected:(MPReject *)rejectMessage;
- (void) _codecChange:(MPCodecVersion *)codecVersion;
- (uint64_t) _currentTimeStamp;

// TCP
- (void) _sendMessageHelper:(NSDictionary *)dict;
- (void) _dataReady;
- (void) _messageRecieved:(NSData *)data;

// UDP
- (void) _setupUdpSock;
- (void) _teardownUdpSock;
- (void) _udpDataReady:(NSData *)data;
- (void) _udpMessageReceived:(NSData *)data;
- (void) _sendUDPMessage:(NSData *)data;
- (void) _sendVoiceDataOnConnectionThread:(NSData *)data;

// Error handling
- (void) _handleError:(NSError *)streamError;
- (BOOL) _tryHandleSslError:(NSError *)streamError;

// Thread handling
- (void) startConnectionThread;
- (void) stopConnectionThread;
@end

// CFSocket UDP callback.
static void MKConnectionUDPCallback(CFSocketRef sock, CFSocketCallBackType type,
                                    CFDataRef addr, const void *data, void *udata) {
    MKConnection *conn = (MKConnection *)udata;

    if (conn == NULL) {
        NSLog(@"MKConnection: MKConnectionUDPCallback called with udata == NULL");
        return;
    }

    if (type != kCFSocketDataCallBack) {
        NSLog(@"MKConnection: MKConnectionUDPCallback called with type=%lu", type);
        return;
    }

    if (data == NULL) {
        NSLog(@"MKConnection: MKConnectionUDPCallback called with data == NULL");
        return;
    }

    [conn _udpDataReady:(NSData *)data];
}

@implementation MKConnection

- (MKAudioOutput *) audioOutput {
    return [[MKAudio sharedAudio] output];
}

- (id) init {
    self = [super init];
    if (self == nil)
        return nil;

    _ignoreSSLVerification = NO;
    _shouldUseOpus = [[MKVersion sharedVersion] isOpusEnabled];

    return self;
}

- (void) dealloc {
    [self disconnect];

    [_peerCertificates release];
    [_certificateChain release];

    [super dealloc];
}

- (void) main {
    NSRunLoop *runLoop = [NSRunLoop currentRunLoop];

    do {
        if (_reconnect) {
            _reconnect = NO;
            _readyVoice = NO;
        }

        [_crypt release];
        _crypt = [[MKCryptState alloc] init];

        CFStreamCreatePairWithSocketToHost(kCFAllocatorDefault,
                                           (CFStringRef)_hostname, (UInt32) _port,
                                           (CFReadStreamRef *) &_inputStream,
                                           (CFWriteStreamRef *) &_outputStream);

        if (_inputStream == nil || _outputStream == nil) {
            NSLog(@"MKConnection: Unable to create stream pair.");
            return;
        }

        [_inputStream setDelegate:self];
        [_outputStream setDelegate:self];

        [_inputStream scheduleInRunLoop:runLoop forMode:NSDefaultRunLoopMode];
        [_outputStream scheduleInRunLoop:runLoop forMode:NSDefaultRunLoopMode];

        [self _setupSsl];

        [_inputStream open];
        [_outputStream open];

        while (_keepRunning) {
            if (_reconnect)
                break;
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
        }

        if (_udpSock) {
            [self _teardownUdpSock];
        }

        if (_inputStream) {
            [_inputStream close];
            [_inputStream release];
            _inputStream = nil;
        }

        if (_outputStream) {
            [_outputStream close];
            [_outputStream release];
            _outputStream = nil;
        }

        [_pingTimer invalidate];
        _pingTimer = nil;
    
        if (_connectionEstablished && !_rejected) {
            if ([_delegate respondsToSelector:@selector(connection:closedWithError:)]) {
                NSError *err = [_connError retain];
                _connectionEstablished = NO;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [_delegate connection:self closedWithError:err];
                    [err release];
                });
            }

        } else if (_connError != nil) {
            if ([_delegate respondsToSelector:@selector(connection:unableToConnectWithError:)]) {
                NSError *err = [_connError retain];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [_delegate connection:self unableToConnectWithError:err];
                    [err release];
                });
            }
        }

        _connectionEstablished = NO;
        _rejected = NO;

        // Remove the connection as the main connection for audio.
        [[MKAudio sharedAudio] setMainConnectionForAudio:nil];

    } while (_reconnect);
    
    [_crypt release];

    [NSThread exit];
}

- (void) _wakeRunLoopHelper:(id)noObject {
    CFRunLoopRef runLoop = [[NSRunLoop currentRunLoop] getCFRunLoop];
    CFRunLoopWakeUp(runLoop);
}

- (void) _wakeRunLoop {
    [self performSelector:@selector(_wakeRunLoopHelper:) onThread:self withObject:nil waitUntilDone:NO];
}

- (void) connectToHost:(NSString *)hostName port:(NSUInteger)portNumber {
    [_hostname release];
    _hostname = [hostName copy];
    _port = portNumber;

    [self startConnectionThread];
}

- (void) startConnectionThread {
    NSAssert(![self isExecuting], @"Thread is currently executing. Can't start another one.");

    _socket = -1;
    packetLength = -1;
    _connectionEstablished = NO;
    _keepRunning = YES;
    _readyVoice = NO;
    _rejected = NO;

    [self start];
}

- (void) stopConnectionThread {
    if (![self isExecuting])
        return;
    _keepRunning = NO;
    [self _wakeRunLoop];
}

- (void) disconnect {
    [self stopConnectionThread];
    while ([self isExecuting] && ![self isFinished]) {
    }
}

- (void) reconnect {
    _reconnect = YES;
    [self _wakeRunLoop];
}

- (BOOL) connected {
    return _connectionEstablished;
}

- (NSString *) hostname {
    return _hostname;
}

- (NSUInteger) port {
    return _port;
}

- (void) setCertificateChain:(NSArray *)chain {
    [_certificateChain release];
    _certificateChain = [chain retain];
}

- (NSArray *) certificateChain {
    return _certificateChain;
}

#pragma mark Server Information

- (NSString *) serverVersion { return _serverVersion; }
- (NSString *) serverRelease { return _serverRelease; }
- (NSString *) serverOSName { return _serverOSName; }
- (NSString *) serverOSVersion { return _serverOSVersion; }

#pragma mark -

- (void) authenticateWithUsername:(NSString *)userName password:(NSString *)password accessTokens:(NSArray *)tokens {
     NSData *data;
     MPVersion_Builder *version = [MPVersion builder];

#if TARGET_OS_IPHONE == 1
    UIDevice *dev = [UIDevice currentDevice];
    [version setOs: [dev systemName]];
    [version setOsVersion: [dev systemVersion]];
#elif TARGET_OS_MAC == 1
    [version setOs:@"Mac OS X"];
    [version setOsVersion:@"10.6"];
#endif

    MKVersion *vers = [MKVersion sharedVersion];
    [version setVersion:(uint32_t)[vers hexVersion]];
    [version setRelease:[vers releaseString]];
    data = [[version build] data];
    [self sendMessageWithType:VersionMessage data:data];

    MPAuthenticate_Builder *authenticate = [MPAuthenticate builder];
    [authenticate setUsername:userName];
    if (password) {
        [authenticate setPassword:password];
    }
    if (tokens) {
        [authenticate setTokensArray:tokens];
    }

    if ([[MKVersion sharedVersion] isOpusEnabled])
        [authenticate setOpus:YES];

    data = [[authenticate build] data];
    [self sendMessageWithType:AuthenticateMessage data:data];
}

#pragma mark NSStream event handlers

- (void) stream:(NSStream *)stream handleEvent:(NSStreamEvent)eventCode {
    if (stream == _inputStream) {
        if (eventCode == NSStreamEventHasBytesAvailable)
            [self _dataReady];
        return;
    }

    switch (eventCode) {
        case NSStreamEventOpenCompleted: {
            CFDataRef nativeHandle = CFWriteStreamCopyProperty((CFWriteStreamRef) _outputStream, kCFStreamPropertySocketNativeHandle);
            if (nativeHandle) {
                _socket = *(int *)CFDataGetBytePtr(nativeHandle);
                CFRelease(nativeHandle);
            }

            _connTime = [self _currentTimeStamp];

            if (_socket != -1) {
                int val = 1;
                setsockopt(_socket, IPPROTO_TCP, TCP_NODELAY, &val, sizeof(val));
            }

            [self _setupUdpSock];
            break;
        }

        case NSStreamEventHasSpaceAvailable: {
            if (! _connectionEstablished) {
                _connectionEstablished = YES;
                [self _updateTLSTrustedStatus];
                [[MKAudio sharedAudio] setMainConnectionForAudio:self];
                
                _pingTimer = [NSTimer timerWithTimeInterval:MKConnectionPingInterval target:self selector:@selector(_pingTimerFired:) userInfo:nil repeats:YES];
                [[NSRunLoop currentRunLoop] addTimer:_pingTimer forMode:NSRunLoopCommonModes];

                if ([_delegate respondsToSelector:@selector(connectionOpened:)]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [_delegate connectionOpened:self];
                    });
                }
            }
            break;
        }

        case NSStreamEventErrorOccurred: {
            NSError *err = [_outputStream streamError];
            [self _handleError:err];
            break;
        }

        case NSStreamEventEndEncountered: {
            NSError *err = [NSError errorWithDomain:@"MKConnection" code:0 userInfo:nil];
            [self _handleError:err];
            break;
        }

        default:
            NSLog(@"MKConnection: Unknown event (%lu)", (unsigned long)eventCode);
            break;
    }
}

#pragma mark -

- (void) setDelegate:(id<MKConnectionDelegate>)delegate { _delegate = delegate; }
- (id<MKConnectionDelegate>) delegate { return _delegate; }
- (void) setMessageHandler:(id<MKMessageHandler>)messageHandler { _msgHandler = messageHandler; }
- (id<MKMessageHandler>) messageHandler { return _msgHandler; }

#pragma mark -

- (void) _setupSsl {
    CFMutableDictionaryRef sslDictionary = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
                                                                     &kCFTypeDictionaryKeyCallBacks,
                                                                     &kCFTypeDictionaryValueCallBacks);
    if (sslDictionary) {
        CFDictionaryAddValue(sslDictionary, kCFStreamSSLLevel, kCFStreamSocketSecurityLevelNegotiatedSSL);
        CFDictionaryAddValue(sslDictionary, kCFStreamSSLValidatesCertificateChain, _ignoreSSLVerification ? kCFBooleanFalse : kCFBooleanTrue);
        
        if (_certificateChain) {
            CFDictionaryAddValue(sslDictionary, kCFStreamSSLCertificates, _certificateChain);
        }

        CFWriteStreamSetProperty((CFWriteStreamRef) _outputStream, kCFStreamPropertySSLSettings, sslDictionary);
        CFReadStreamSetProperty((CFReadStreamRef) _inputStream, kCFStreamPropertySSLSettings, sslDictionary);
        CFRelease(sslDictionary);
    }
}

- (void) _setupUdpSock {
    struct sockaddr_storage sa;

    socklen_t sl = sizeof(sa);
    if (getpeername(_socket, (struct sockaddr *) &sa, &sl) == -1) {
        NSLog(@"MKConnection: Unable to query TCP socket for address.");
        return;
    }

    CFSocketContext udpctx;
    memset(&udpctx, 0, sizeof(CFSocketContext));
    udpctx.info = self;

    _udpSock = CFSocketCreate(NULL, sa.ss_family, SOCK_DGRAM, IPPROTO_UDP,
                                  kCFSocketDataCallBack, MKConnectionUDPCallback,
                                  &udpctx);
    if (! _udpSock) {
        NSLog(@"MKConnection: Failed to create UDP socket.");
        return;
    }

    CFRunLoopSourceRef src = CFSocketCreateRunLoopSource(NULL, _udpSock, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, kCFRunLoopDefaultMode);
    CFRelease(src);

    NSData *_udpAddr = [[[NSData alloc] initWithBytes:&sa length:(NSUInteger)sl] autorelease];
    CFSocketError err = CFSocketConnectToAddress(_udpSock, (CFDataRef)_udpAddr, -1);
    if (err == kCFSocketError) {
        NSLog(@"MKConnection: Unable to CFSocketConnectToAddress()");
        return;
    }
}

- (void) _teardownUdpSock {
    CFSocketInvalidate(_udpSock);
    CFRelease(_udpSock);
}

- (void) setIgnoreSSLVerification:(BOOL)flag {
    _ignoreSSLVerification = flag;
}

// ✅ FIXED: Use kCFStreamPropertySSLPeerTrust instead of kCFStreamPropertySSLPeerCertificates
- (NSArray *) peerCertificates {
    if (_peerCertificates != nil) {
        return _peerCertificates;
    }

    // Modern replacement: Get the SecTrustRef directly
    SecTrustRef trust = (SecTrustRef)CFWriteStreamCopyProperty((CFWriteStreamRef)_outputStream, kCFStreamPropertySSLPeerTrust);
    
    if (trust) {
        CFIndex count = SecTrustGetCertificateCount(trust);
        _peerCertificates = [[NSMutableArray alloc] initWithCapacity:count];
        
        for (CFIndex i = 0; i < count; i++) {
            SecCertificateRef cert = SecTrustGetCertificateAtIndex(trust, i);
            NSData *data = (NSData *)SecCertificateCopyData(cert);
            if (data) {
                [_peerCertificates addObject:[MKCertificate certificateWithCertificate:data privateKey:nil]];
                [data release];
            }
        }
        CFRelease(trust);
    } else {
        _peerCertificates = [[NSMutableArray alloc] init];
    }

    return _peerCertificates;
}

// ✅ FIXED: Use kCFStreamPropertySSLPeerTrust and handle all switch cases
- (void) _updateTLSTrustedStatus {
    BOOL trusted = NO;

    // Get the trust object directly from the stream
    SecTrustRef trust = (SecTrustRef) CFWriteStreamCopyProperty((CFWriteStreamRef) _outputStream, kCFStreamPropertySSLPeerTrust);
    
    if (!trust) {
        _trustedChain = NO;
        return;
    }

    SecTrustResultType trustRes;
    OSStatus err = SecTrustEvaluate(trust, &trustRes);
    
    if (err == noErr) {
        switch (trustRes) {
            case kSecTrustResultProceed:
            case kSecTrustResultUnspecified: // System trusts it.
                trusted = YES;
                break;
            default:
                // kSecTrustResultInvalid, kSecTrustResultDeny, etc.
                trusted = NO;
                break;
        }
    }
    
    _trustedChain = trusted;
    CFRelease(trust);
}

- (BOOL) peerCertificateChainTrusted {
    return _trustedChain;
}

- (void) setForceTCP:(BOOL)flag {
    _forceTCP = flag;
}

- (BOOL) forceTCP {
    return _forceTCP;
}

- (void) _sendUDPMessage:(NSData *)data {
    if (![_crypt valid] || !CFSocketIsValid(_udpSock)) {
        NSLog(@"MKConnection: Invalid CryptState or CFSocket.");
        return;
    }

    NSData *crypted = [_crypt encryptData:data];
    if (crypted == nil) {
        NSLog(@"MKConnection: unable to encrypt UDP message");
        return;
    }

    CFSocketError err = CFSocketSendData(_udpSock, NULL, (CFDataRef)crypted, -1.0f);
    if (err != kCFSocketSuccess) {
        NSLog(@"MKConnection: CFSocketSendData failed with err=%i", (int)err);
    }
}

- (void) sendMessageWithType:(MKMessageType)messageType data:(NSData *)data {
    NSDictionary *dict = [[NSDictionary alloc] initWithObjectsAndKeys:
                            data, @"data",
                            [NSNumber numberWithInt:(int)messageType], @"messageType",
                            nil];

    if ([NSThread currentThread] != self) {
        [self performSelector:@selector(_sendMessageHelper:) onThread:self withObject:dict waitUntilDone:NO];
    } else {
        [self _sendMessageHelper:dict];
    }

    [dict release];
}

- (void) _sendMessageHelper:(NSDictionary *)dict {
    if (!_connectionEstablished)
        return;

    NSData *data = [dict objectForKey:@"data"];
    MKMessageType messageType = (MKMessageType)[[dict objectForKey:@"messageType"] intValue];
    
    UInt16 type = CFSwapInt16HostToBig((UInt16)messageType);
    UInt32 length = CFSwapInt32HostToBig((UInt32)[data length]);

    NSUInteger expectedLength = sizeof(UInt16) + sizeof(UInt32) + [data length];
    NSMutableData *msg = [[NSMutableData alloc] initWithCapacity:expectedLength];
    [msg appendBytes:&type length:sizeof(UInt16)];
    [msg appendBytes:&length length:sizeof(UInt32)];
    [msg appendData:data];

    NSInteger nwritten = [_outputStream write:[msg bytes] maxLength:[msg length]];
    if (nwritten != expectedLength) {
        NSLog(@"MKConnection: write error, wrote %li, expected %lu", (long int)nwritten, (unsigned long)expectedLength);
    }
    [msg release];
}

- (void) sendVoiceData:(NSData *)data {
    if ([NSThread currentThread] == self) {
        [self _sendVoiceDataOnConnectionThread:data];
    } else {
        [self performSelector:@selector(_sendVoiceDataOnConnectionThread:) onThread:self withObject:data waitUntilDone:NO];
    }
}

- (void) _sendVoiceDataOnConnectionThread:(NSData *)data {
    if (!_readyVoice || !_connectionEstablished)
        return;
    if (!_forceTCP && _udpAvailable) {
        [self _sendUDPMessage:data];
    } else {
        [self sendMessageWithType:UDPTunnelMessage data:data];
    }
}

- (void) _udpDataReady:(NSData *)crypted {
    if (! _udpAvailable) {
        _udpAvailable = true;
        NSLog(@"MKConnection: UDP is now available!");
    }

    if ([crypted length] > 4) {
        NSData *plain = [_crypt decryptData:crypted];
        if (plain) {
            [self _udpMessageReceived:plain];
        }
    }
}

- (void) _dataReady {
    unsigned char buffer[6];

    if (! packetBuffer) {
        packetBuffer = [[NSMutableData alloc] initWithLength:0];
    }

    if (packetLength == -1) {
        NSInteger availableBytes = [_inputStream read:&buffer[0] maxLength:6];
        if (availableBytes < 6) {
            return;
        }

        packetType = (MKMessageType) CFSwapInt16BigToHost(*(UInt16 *)(&buffer[0]));
        packetLength = (int) CFSwapInt32BigToHost(*(UInt32 *)(&buffer[2]));

        packetBufferOffset = 0;
        [packetBuffer setLength:packetLength];
    }

    if (packetLength > 0) {
        UInt8 *packetBytes = [packetBuffer mutableBytes];
        if (! packetBytes) {
            NSLog(@"MKConnection: NSMutableData is stubborn.");
            return;
        }

        NSInteger availableBytes = [_inputStream read:packetBytes + packetBufferOffset maxLength:packetLength];
        packetLength -= availableBytes;
        packetBufferOffset += availableBytes;
    }

    if (packetLength == 0) {
        [self _messageRecieved:packetBuffer];
        [packetBuffer setLength:0];
        packetLength = -1;
    }
}

- (uint64_t) _currentTimeStamp {
    struct timeval tv;
    gettimeofday(&tv, NULL);

    uint64_t ret = tv.tv_sec * 1000000ULL;
    ret += tv.tv_usec;

    return ret;
}

- (void) _pingTimerFired:(NSTimer *)timer {
    unsigned char buf[16];
    NSData *data;
    uint64_t timeStamp = [self _currentTimeStamp] - _connTime;

    // UDP Ping
    MKPacketDataStream *pds = [[MKPacketDataStream alloc] initWithBuffer:buf+1 length:16];
    buf[0] = UDPPingMessage << 5;
    [pds addVarint:timeStamp];
    if ([pds valid]) {
        data = [[NSData alloc] initWithBytesNoCopy:buf length:[pds size]+1 freeWhenDone:NO];
        [self _sendUDPMessage:data];
        [data release];
    }
    [pds release];
        
    // TCP Ping
    MPPing_Builder *ping = [MPPing builder];
    [ping setTimestamp:timeStamp];
    [ping setGood:0];
    [ping setLate:0];
    [ping setLost:0];
    [ping setResync:0];
    [ping setUdpPingAvg:0.0f];
    [ping setUdpPingVar:0.0f];
    [ping setUdpPackets:0];
    [ping setTcpPingAvg:0.0f];
    [ping setTcpPingVar:0.0f];
    [ping setTcpPackets:0];

    data = [[ping build] data];
    [self sendMessageWithType:PingMessage data:data];

    NSLog(@"MKConnection: Sent ping message.");
}

- (void) _pingResponseFromServer:(MPPing *)pingMessage {
    NSLog(@"MKConnection: pingResponseFromServer");
}

- (void) _connectionRejected:(MPReject *)rejectMessage {
    MKRejectReason reason = MKRejectReasonNone;
    NSString *explanationString = nil;

    if ([rejectMessage hasType])
        reason = (MKRejectReason) [rejectMessage type];
    if ([rejectMessage hasReason])
        explanationString = [rejectMessage reason];

    if ([_delegate respondsToSelector:@selector(connection:rejectedWithReason:explanation:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [_delegate connection:self rejectedWithReason:reason explanation:explanationString];
        });
    }

    _rejected = YES;
    [self stopConnectionThread];
}

- (void) _doCryptSetup:(MPCryptSetup *)cryptSetup {
    NSLog(@"MKConnection: Got CryptSetup from server.");

    if ([cryptSetup hasKey] && [cryptSetup hasClientNonce] && [cryptSetup hasServerNonce]) {
        [_crypt setKey:[cryptSetup key] eiv:[cryptSetup clientNonce] div:[cryptSetup serverNonce]];
        NSLog(@"MKConnection: CryptState initialized.");
    }
}

- (void) _versionMessageReceived:(MPVersion *)msg {
    if ([msg hasVersion]) {
        int32_t version = [msg version];
        _serverVersion = [[NSString alloc] initWithFormat:@"%i.%i.%i", (version >> 8) & 0xff, (version >> 4) & 0xff, version & 0xff, nil];
    }
    if ([msg hasRelease])
        _serverRelease = [[msg release] copy];
    if ([msg hasOs])
        _serverOSName = [[msg os] copy];
    if ([msg hasOsVersion])
        _serverOSVersion = [[msg osVersion] copy];
}

- (void) _codecChange:(MPCodecVersion *)codec {
    NSUInteger alpha = ([codec hasAlpha] ? (NSUInteger) [codec alpha] : 0) & 0xffffffff;
    NSUInteger beta = ([codec hasBeta] ? (NSUInteger) [codec beta] : 0) & 0xffffffff;
    BOOL pref = [codec hasPreferAlpha] ? [codec preferAlpha] : NO;

    if ((alpha != -1) && (alpha != _alphaCodec)) {
        if (pref && alpha != MUMBLEKIT_CELT_BITSTREAM)
            pref = ! pref;
    }
    if ((beta != -1) && (beta != _betaCodec)) {
        if (! pref && beta != MUMBLEKIT_CELT_BITSTREAM)
            pref = ! pref;
    }

    _alphaCodec = alpha;
    _betaCodec = beta;
    _preferAlpha = pref;

    if ([[MKVersion sharedVersion] isOpusEnabled] && [codec hasOpus]) {
        _shouldUseOpus = [codec opus];
    } else {
        _shouldUseOpus = NO;
    }

    if (_shouldUseOpus == NO) {
        NSLog(@"MKConnection: Server does not support Opus codec. CELT is not supported. Please upgrade your Mumble server.");
        // Gracefully disconnect instead of crashing
        NSDictionary *userInfo = @{
            NSLocalizedDescriptionKey: @"Codec Unsupported",
            NSLocalizedFailureReasonErrorKey: @"The server does not support the Opus codec. Please ask the server administrator to upgrade to a newer version of Mumble server."
        };
        NSError *codecError = [NSError errorWithDomain:@"MKConnection" code:-1 userInfo:userInfo];
        [_connError release];
        _connError = [codecError retain];
        [self stopConnectionThread];
        return;
    }
}

- (void) _handleError:(NSError *)streamError {
    NSInteger errorCode = [streamError code];

    if (errorCode <= errSSLProtocol && errorCode > errSSLLast) {
        BOOL didHandle = [self _tryHandleSslError:streamError];
        if (didHandle) {
            return;
        }
    }

    [_connError release];
    _connError = [streamError retain];
    [self stopConnectionThread];
}

- (BOOL) _tryHandleSslError:(NSError *)streamError {
    if ([streamError code] == errSSLXCertChainInvalid
        || [streamError code] == errSSLUnknownRootCert) {
        
        SecTrustRef trust = (SecTrustRef) CFWriteStreamCopyProperty((CFWriteStreamRef) _outputStream, kCFStreamPropertySSLPeerTrust);
        if (!trust) return NO;

        SecTrustResultType trustResult;
        if (SecTrustEvaluate(trust, &trustResult) != noErr) {
            CFRelease(trust);
            return NO;
        }

        BOOL handled = NO;
        switch (trustResult) {
            case kSecTrustResultInvalid:
            case kSecTrustResultProceed:
            case kSecTrustResultDeny:
            case kSecTrustResultUnspecified:
            case kSecTrustResultFatalTrustFailure:
            case kSecTrustResultOtherError:
                break;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            case kSecTrustResultConfirm:
                break;
#pragma clang diagnostic pop

            case kSecTrustResultRecoverableTrustFailure: {
                if ([_delegate respondsToSelector:@selector(connection:trustFailureInCertificateChain:)]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [_delegate connection:self trustFailureInCertificateChain:[self peerCertificates]];
                    });
                }
                handled = YES;
                break;
            }
        }

        CFRelease(trust);
        return handled;
    }

    return NO;
}

- (void) _udpMessageReceived:(NSData *)data {
    unsigned char *buf = (unsigned char *)[data bytes];
    MKUDPMessageType messageType = ((buf[0] >> 5) & 0x7);
    unsigned int messageFlags = buf[0] & 0x1f;
    MKPacketDataStream *pds = [[MKPacketDataStream alloc] initWithBuffer:buf+1 length:[data length]-1];

    switch (messageType) {
        case UDPVoiceCELTAlphaMessage:
        case UDPVoiceCELTBetaMessage:
            NSLog(@"MKConnection: Dropping unsupported CELT voice packet type=%d", (int)messageType);
            break;
        case UDPVoiceSpeexMessage:
        case UDPVoiceOpusMessage: {
            if (messageType == UDPVoiceOpusMessage && ![[MKVersion sharedVersion] isOpusEnabled]) {
                NSLog(@"MKConnection: Received Opus voice packet in no-Opus mode. Discarding.");
                break;
            }
            NSUInteger session = [pds getUnsignedInt];
            NSUInteger seq = [pds getUnsignedInt];
            NSMutableData *voicePacketData = [[NSMutableData alloc] initWithCapacity:[pds left]+1];
            [voicePacketData setLength:[pds left]+1];
            unsigned char *bytes = [voicePacketData mutableBytes];
            bytes[0] = (unsigned char)messageFlags;
            memcpy(bytes+1, [pds dataPtr], [pds left]);
            [[MKAudio sharedAudio] addFrameToBufferWithSession:session data:voicePacketData sequence:seq type:messageType];
            [voicePacketData release];
            break;
        }

        case UDPPingMessage: {
            uint64_t timeStamp = [pds getVarint];
            uint64_t now = [self _currentTimeStamp] - _connTime;
            NSLog(@"UDP ping = %llu usec", now - timeStamp);
            break;
        }

        default:
            NSLog(@"MKConnection: Unknown UDPTunnel packet (%i) received. Discarding...", (int)messageType);
            break;
    }

    [pds release];
}

- (void) _messageRecieved:(NSData *)data {
    dispatch_queue_t main_queue = dispatch_get_main_queue();

    if (! _msgHandler)
        return;

    switch (packetType) {
        case UDPTunnelMessage: {
            [self _udpMessageReceived:data];
            break;
        }
        case ServerSyncMessage: {
            if (_forceTCP) {
                NSLog(@"MKConnection: Sending dummy UDPTunnel message.");
                NSMutableData *msg = [[NSMutableData alloc] initWithLength:3];
                char *buf = [msg mutableBytes];
                memset(buf, 0, 3);
                [self sendMessageWithType:UDPTunnelMessage data:msg];
                [msg release];
            }
            _readyVoice = YES;
            MPServerSync *serverSync = [MPServerSync parseFromData:data];
            if ([_msgHandler respondsToSelector:@selector(connection:handleServerSyncMessage:)]) {
                dispatch_async(main_queue, ^{
                    [_msgHandler connection:self handleServerSyncMessage:serverSync];
                });
            }
            break;
        }
        case ChannelRemoveMessage: {
            MPChannelRemove *channelRemove = [MPChannelRemove parseFromData:data];
            if ([_msgHandler respondsToSelector:@selector(connection:handleChannelRemoveMessage:)]) {
                dispatch_async(main_queue, ^{
                    [_msgHandler connection:self handleChannelRemoveMessage:channelRemove];
                });
            }
            break;
        }
        case ChannelStateMessage: {
            MPChannelState *channelState = [MPChannelState parseFromData:data];
            if ([_msgHandler respondsToSelector:@selector(connection:handleChannelStateMessage:)]) {
                dispatch_async(main_queue, ^{
                    [_msgHandler connection:self handleChannelStateMessage:channelState];
                });
            }
            break;
        }
        case UserRemoveMessage: {
            MPUserRemove *userRemove = [MPUserRemove parseFromData:data];
            if ([_msgHandler respondsToSelector:@selector(connection:handleUserRemoveMessage:)]) {
                dispatch_async(main_queue, ^{
                    [_msgHandler connection:self handleUserRemoveMessage:userRemove];
                });
            }
            break;
        }
        case UserStateMessage: {
            MPUserState *userState = [MPUserState parseFromData:data];
            if ([_msgHandler respondsToSelector:@selector(connection:handleUserStateMessage:)]) {
                dispatch_async(main_queue, ^{
                    [_msgHandler connection:self handleUserStateMessage:userState];
                });
            }
            break;
        }
        case BanListMessage: {
            MPBanList *banList = [MPBanList parseFromData:data];
            if ([_msgHandler respondsToSelector:@selector(connection:handleBanListMessage:)]) {
                dispatch_async(main_queue, ^{
                    [_msgHandler connection:self handleBanListMessage:banList];
                 });
            }
            break;
        }
        case TextMessageMessage: {
            MPTextMessage *textMessage = [MPTextMessage parseFromData:data];
            if ([_msgHandler respondsToSelector:@selector(connection:handleTextMessageMessage:)]) {
                dispatch_async(main_queue, ^{
                    [_msgHandler connection:self handleTextMessageMessage:textMessage];
                });
            }
            break;
        }
        case PermissionDeniedMessage: {
            MPPermissionDenied *permissionDenied = [MPPermissionDenied parseFromData:data];
            if ([_msgHandler respondsToSelector:@selector(connection:handlePermissionDeniedMessage:)]) {
                dispatch_async(main_queue, ^{
                    [_msgHandler connection:self handlePermissionDeniedMessage:permissionDenied];
                });
            }
            break;
        }
        case ACLMessage: {
            MPACL *aclMessage = [MPACL parseFromData:data];
            if ([_msgHandler respondsToSelector:@selector(connection:handleACLMessage:)]) {
                dispatch_async(main_queue, ^{
                    [_msgHandler connection:self handleACLMessage:aclMessage];
                });
            }
            break;
        }
        case QueryUsersMessage: {
            MPQueryUsers *queryUsers = [MPQueryUsers parseFromData:data];
            if ([_msgHandler respondsToSelector:@selector(connection:handleQueryUsersMessage:)]) {
                dispatch_async(main_queue, ^{
                    [_msgHandler connection:self handleQueryUsersMessage:queryUsers];
                });
            }
            break;
        }
        case ContextActionModifyMessage: {
            MPContextActionModify *contextActionModify = [MPContextActionModify parseFromData:data];
            if ([_msgHandler respondsToSelector:@selector(connection:handleContextActionModifyMessage:)]) {
                dispatch_async(main_queue, ^{
                    [_msgHandler connection:self handleContextActionModifyMessage:contextActionModify];
                });
            }
            break;
        }
        case ContextActionMessage: {
            MPContextAction *contextAction = [MPContextAction parseFromData:data];
            if ([_msgHandler respondsToSelector:@selector(connection:handleContextActionMessage:)]) {
                dispatch_async(main_queue, ^{
                    [_msgHandler connection:self handleContextActionMessage:contextAction];
                });
            }
            break;
        }
        case UserListMessage: {
            MPUserList *userList = [MPUserList parseFromData:data];
            if ([_msgHandler respondsToSelector:@selector(connection:handleUserListMessage:)]) {
                dispatch_async(main_queue, ^{
                    [_msgHandler connection:self handleUserListMessage:userList];
                });
            }
            break;
        }
        case VoiceTargetMessage: {
            MPVoiceTarget *voiceTarget = [MPVoiceTarget parseFromData:data];
            // ✅ FIXED: Correct selector name
            if ([_msgHandler respondsToSelector:@selector(connection:handleVoiceTargetMessage:)]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [_msgHandler connection:self handleVoiceTargetMessage:voiceTarget];
                });
            }
            break;
        }
        case PermissionQueryMessage: {
            MPPermissionQuery *permissionQuery = [MPPermissionQuery parseFromData:data];
            if ([_msgHandler respondsToSelector:@selector(connection:handlePermissionQueryMessage:)]) {
                dispatch_async(main_queue, ^{
                    [_msgHandler connection:self handlePermissionQueryMessage:permissionQuery];
                });
            }
            break;
        }

        case VersionMessage: {
            MPVersion *v = [MPVersion parseFromData:data];
            [self _versionMessageReceived:v];
            break;
        }
        case PingMessage: {
            MPPing *p = [MPPing parseFromData:data];
            [self _pingResponseFromServer:p];
            break;
        }
        case RejectMessage: {
            MPReject *r = [MPReject parseFromData:data];
            [self _connectionRejected:r];
            break;
        }
        case CryptSetupMessage: {
            MPCryptSetup *cs = [MPCryptSetup parseFromData:data];
            [self _doCryptSetup:cs];
            break;
        }
        case CodecVersionMessage: {
            MPCodecVersion *codecVersion = [MPCodecVersion parseFromData:data];
            [self _codecChange:codecVersion];
            break;
        }

        default: {
            NSLog(@"MKConnection: Unknown packet type recieved. Discarding. (type=%u)", packetType);
            break;
        }
    }
}

- (NSUInteger) alphaCodec { return _alphaCodec; }
- (NSUInteger) betaCodec { return _betaCodec; }
- (BOOL) preferAlphaCodec { return _preferAlpha; }
- (BOOL) shouldUseOpus { return _shouldUseOpus; }

@end
