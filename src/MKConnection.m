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
#import "../../Source/Classes/SwiftUI/Core/MumbleLogger.h"

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
#include <math.h>

#import "Mumble.pb.h"

// The bitstream we should send to the server.
// It's currently hard-coded.
#define MUMBLEKIT_CELT_BITSTREAM 0x8000000bUL
static const NSUInteger MKUDPRebuildFailureThreshold = 3;
static const uint64_t MKUDPRebuildCooldownUsec = 2ULL * 1000ULL * 1000ULL;
static const uint64_t MKUDPReceiveStallThresholdUsec = 8ULL * 1000ULL * 1000ULL;
static const uint64_t MKUDPProbeIntervalUsec = 15ULL * 1000ULL * 1000ULL;
static const uint64_t MKTCPTunnelKeepaliveIntervalUsec = 5ULL * 1000ULL * 1000ULL;

@interface MKConnection () {
    MKCryptState   *_crypt;

    MKMessageType  packetType;
    int            packetLength;
    int            packetBufferOffset;
    NSMutableData  *packetBuffer;
    unsigned char  _headerBuf[6];
    int            _headerBufLen;
    NSString       *_hostname;
    NSUInteger     _port;
    BOOL           _keepRunning;
    BOOL           _reconnect;

    BOOL           _forceTCP;
    BOOL           _udpAvailable;
    MKUDPTransportState _udpTransportState;
    NSUInteger     _udpConsecutiveSendFailures;
    uint64_t       _lastUdpRebuildAttemptUsec;
    uint64_t       _lastUdpReceiveUsec;
    uint64_t       _lastUdpProbeUsec;
    uint64_t       _lastTcpTunnelKeepaliveUsec;
    uint64_t       _lastTcpTunnelReceiveUsec;
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

    // Local network stats sent to server in PingMessage.
    double         _udpPingMeanMs;
    double         _udpPingM2Ms;
    uint32_t       _udpPingSamples;
    double         _tcpPingMeanMs;
    double         _tcpPingM2Ms;
    uint32_t       _tcpPingSamples;
    uint32_t       _udpPacketsSent;
    uint32_t       _tcpPacketsSent;
    uint32_t       _lastGood;
    uint32_t       _lastLate;
    uint32_t       _lastLost;
    uint32_t       _lastResync;
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
- (void) _applyForceTCPOnConnectionThread:(NSNumber *)flagNumber;
- (void) _udpDataReady:(NSData *)data;
- (void) _udpMessageReceived:(NSData *)data;
- (BOOL) _sendUDPMessage:(NSData *)data;
- (BOOL) _sendUDPPingWithTimestamp:(uint64_t)timeStamp;
- (BOOL) _shouldProbeUDPAtTime:(uint64_t)now;
- (void) _sendTcpTunnelKeepaliveWithTimestamp:(uint64_t)timeStamp;
- (void) _attemptUdpSocketRecoveryIfNeeded;
- (void) _checkUdpLivenessAndRecoverIfNeeded;
- (void) _notifyUDPTransportStateIfChanged:(MKUDPTransportState)newState;
- (void) _sendVoiceDataOnConnectionThread:(NSData *)data;

// Error handling
- (void) _handleError:(NSError *)streamError;
- (BOOL) _tryHandleSslError:(NSError *)streamError;

// Thread handling
- (void) startConnectionThread;
- (void) stopConnectionThread;
@end

static void MKConnectionResetRunningStats(double *mean, double *m2, uint32_t *samples) {
    *mean = 0.0;
    *m2 = 0.0;
    *samples = 0;
}

static void MKConnectionAddSample(double sampleMs, double *mean, double *m2, uint32_t *samples) {
    if (!isfinite(sampleMs) || sampleMs < 0.0) {
        return;
    }

    if (*samples == UINT32_MAX) {
        // Keep estimator stable if samples overflow in very long sessions.
        *samples = UINT32_MAX - 1;
    }

    *samples += 1;
    double n = (double)(*samples);
    double delta = sampleMs - *mean;
    *mean += delta / n;
    double delta2 = sampleMs - *mean;
    *m2 += delta * delta2;
}

static Float32 MKConnectionVarianceFromM2(double m2, uint32_t samples) {
    if (samples < 2 || !isfinite(m2) || m2 < 0.0) {
        return 0.0f;
    }
    return (Float32)(m2 / (double)(samples - 1));
}

// CFSocket UDP callback.
static void MKConnectionUDPCallback(CFSocketRef sock, CFSocketCallBackType type,
                                    CFDataRef addr, const void *data, void *udata) {
    MKConnection *conn = (MKConnection *)udata;

    if (conn == NULL) {
        MKLogWarning(Connection, @"MKConnection: MKConnectionUDPCallback called with udata == NULL");
        return;
    }

    if (type != kCFSocketDataCallBack) {
        MKLogWarning(Connection, @"MKConnection: MKConnectionUDPCallback called with type=%lu", type);
        return;
    }

    if (data == NULL) {
        MKLogWarning(Connection, @"MKConnection: MKConnectionUDPCallback called with data == NULL");
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
    // 确保连接已断开
    [self disconnect];

    // 释放 Core Foundation 和 Objective-C 对象
    // 注意：_peerCertificates 和 _certificateChain 可能包含 SecCertificateRef 等 CF 对象
    if (_peerCertificates) {
        [_peerCertificates release];
        _peerCertificates = nil;
    }
    
    if (_certificateChain) {
        [_certificateChain release];
        _certificateChain = nil;
    }
    
    // 释放其他实例变量
    if (_hostname) {
        [_hostname release];
        _hostname = nil;
    }
    
    if (packetBuffer) {
        [packetBuffer release];
        packetBuffer = nil;
    }
    
    if (_crypt) {
        [_crypt release];
        _crypt = nil;
    }
    
    if (_serverVersion) {
        [_serverVersion release];
        _serverVersion = nil;
    }
    
    if (_serverRelease) {
        [_serverRelease release];
        _serverRelease = nil;
    }
    
    if (_serverOSName) {
        [_serverOSName release];
        _serverOSName = nil;
    }
    
    if (_serverOSVersion) {
        [_serverOSVersion release];
        _serverOSVersion = nil;
    }
    
    if (_connError) {
        [_connError release];
        _connError = nil;
    }

    [super dealloc];
}

- (void) main {
    NSRunLoop *runLoop = [NSRunLoop currentRunLoop];

    do {
        if (_reconnect) {
            _reconnect = NO;
            _readyVoice = NO;
            _udpAvailable = NO;
            _udpTransportState = MKUDPTransportStateUnknown;
            _udpConsecutiveSendFailures = 0;
            _lastUdpRebuildAttemptUsec = 0;
            _lastUdpReceiveUsec = 0;
            _lastUdpProbeUsec = 0;
            _lastTcpTunnelKeepaliveUsec = 0;
            _lastTcpTunnelReceiveUsec = 0;
            MKConnectionResetRunningStats(&_udpPingMeanMs, &_udpPingM2Ms, &_udpPingSamples);
            MKConnectionResetRunningStats(&_tcpPingMeanMs, &_tcpPingM2Ms, &_tcpPingSamples);
            _udpPacketsSent = 0;
            _tcpPacketsSent = 0;
            _lastGood = 0;
            _lastLate = 0;
            _lastLost = 0;
            _lastResync = 0;
        }

        [_crypt release];
        _crypt = [[MKCryptState alloc] init];

        CFStreamCreatePairWithSocketToHost(kCFAllocatorDefault,
                                           (CFStringRef)_hostname, (UInt32) _port,
                                           (CFReadStreamRef *) &_inputStream,
                                           (CFWriteStreamRef *) &_outputStream);

        if (_inputStream == nil || _outputStream == nil) {
            MKLogError(Connection, @"MKConnection: Unable to create stream pair.");
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
    _crypt = nil;

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
    _headerBufLen = 0;
    _connectionEstablished = NO;
    _keepRunning = YES;
    _readyVoice = NO;
    _udpAvailable = NO;
    _udpTransportState = MKUDPTransportStateUnknown;
    _udpConsecutiveSendFailures = 0;
    _lastUdpRebuildAttemptUsec = 0;
    _lastUdpReceiveUsec = 0;
    _lastUdpProbeUsec = 0;
    _lastTcpTunnelKeepaliveUsec = 0;
    _lastTcpTunnelReceiveUsec = 0;
    _rejected = NO;
    MKConnectionResetRunningStats(&_udpPingMeanMs, &_udpPingM2Ms, &_udpPingSamples);
    MKConnectionResetRunningStats(&_tcpPingMeanMs, &_tcpPingM2Ms, &_tcpPingSamples);
    _udpPacketsSent = 0;
    _tcpPacketsSent = 0;
    _lastGood = 0;
    _lastLate = 0;
    _lastLost = 0;
    _lastResync = 0;

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
    int attempts = 0;
    BOOL warned = NO;
    while ([self isExecuting] && ![self isFinished]) {
        if (!warned && ++attempts > 300) {
            MKLogWarning(Connection, @"MKConnection: disconnect still waiting for thread after 3s.");
            warned = YES;
        }
        usleep(10000);
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
    NSProcessInfo *processInfo = [NSProcessInfo processInfo];
    NSOperatingSystemVersion osv = [processInfo operatingSystemVersion];
    [version setOs:@"macOS"];
    [version setOsVersion:[NSString stringWithFormat:@"%ld.%ld.%ld",
                           (long)osv.majorVersion,
                           (long)osv.minorVersion,
                           (long)osv.patchVersion]];
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

            if (_forceTCP) {
                [self _teardownUdpSock];
            } else {
                [self _setupUdpSock];
            }
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
            MKLogWarning(Connection, @"MKConnection: Unknown event (%lu)", (unsigned long)eventCode);
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
    if (_forceTCP) {
        return;
    }

    _udpAvailable = NO;
    _udpConsecutiveSendFailures = 0;
    _lastUdpReceiveUsec = [self _currentTimeStamp];
    struct sockaddr_storage sa;

    socklen_t sl = sizeof(sa);
    if (getpeername(_socket, (struct sockaddr *) &sa, &sl) == -1) {
        MKLogError(Connection, @"MKConnection: Unable to query TCP socket for address.");
        return;
    }

    CFSocketContext udpctx;
    memset(&udpctx, 0, sizeof(CFSocketContext));
    udpctx.info = self;

    _udpSock = CFSocketCreate(NULL, sa.ss_family, SOCK_DGRAM, IPPROTO_UDP,
                                  kCFSocketDataCallBack, MKConnectionUDPCallback,
                                  &udpctx);
    if (! _udpSock) {
        MKLogError(Connection, @"MKConnection: Failed to create UDP socket.");
        return;
    }

    CFRunLoopSourceRef src = CFSocketCreateRunLoopSource(NULL, _udpSock, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, kCFRunLoopDefaultMode);
    CFRelease(src);

    NSData *_udpAddr = [[[NSData alloc] initWithBytes:&sa length:(NSUInteger)sl] autorelease];
    CFSocketError err = CFSocketConnectToAddress(_udpSock, (CFDataRef)_udpAddr, -1);
    if (err == kCFSocketError) {
        MKLogError(Connection, @"MKConnection: Unable to CFSocketConnectToAddress()");
        [self _teardownUdpSock];
        return;
    }
}

- (void) _teardownUdpSock {
    _udpAvailable = NO;
    _udpConsecutiveSendFailures = 0;
    _lastUdpReceiveUsec = 0;
    if (_udpSock) {
        CFSocketInvalidate(_udpSock);
        CFRelease(_udpSock);
        _udpSock = NULL;
    }
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
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            SecCertificateRef cert = SecTrustGetCertificateAtIndex(trust, i);
#pragma clang diagnostic pop
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
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    OSStatus err = SecTrustEvaluate(trust, &trustRes);
#pragma clang diagnostic pop
    
    if (err == noErr) {
        switch (trustRes) {
            case kSecTrustResultProceed:
            case kSecTrustResultUnspecified:
                trusted = YES;
                break;
            default:
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
    if ([NSThread currentThread] != self) {
        [self performSelector:@selector(_applyForceTCPOnConnectionThread:) onThread:self withObject:@(flag) waitUntilDone:NO];
        return;
    }

    [self _applyForceTCPOnConnectionThread:@(flag)];
}

- (void) _applyForceTCPOnConnectionThread:(NSNumber *)flagNumber {
    BOOL flag = [flagNumber boolValue];

    _forceTCP = flag;
    if (_forceTCP) {
        [self _teardownUdpSock];
    } else if (_connectionEstablished && _socket != -1 && !_udpSock) {
        [self _setupUdpSock];
    }
}

- (BOOL) forceTCP {
    return _forceTCP;
}

- (BOOL) _sendUDPMessage:(NSData *)data {
    if (_forceTCP) {
        return NO;
    }

    if (![_crypt valid] || _udpSock == NULL || !CFSocketIsValid(_udpSock)) {
        MKLogWarning(Connection, @"MKConnection: Invalid CryptState or CFSocket.");
        _udpAvailable = NO;
        [self _notifyUDPTransportStateIfChanged:MKUDPTransportStateUnavailable];
        _udpConsecutiveSendFailures += 1;
        [self _attemptUdpSocketRecoveryIfNeeded];
        return NO;
    }

    NSData *crypted = [_crypt encryptData:data];
    if (crypted == nil) {
        MKLogWarning(Connection, @"MKConnection: unable to encrypt UDP message");
        _udpAvailable = NO;
        [self _notifyUDPTransportStateIfChanged:MKUDPTransportStateUnavailable];
        _udpConsecutiveSendFailures += 1;
        [self _attemptUdpSocketRecoveryIfNeeded];
        return NO;
    }

    CFSocketError err = CFSocketSendData(_udpSock, NULL, (CFDataRef)crypted, -1.0f);
    if (err != kCFSocketSuccess) {
        MKLogWarning(Connection, @"MKConnection: CFSocketSendData failed with err=%i", (int)err);
        _udpAvailable = NO;
        [self _notifyUDPTransportStateIfChanged:MKUDPTransportStateUnavailable];
        _udpConsecutiveSendFailures += 1;
        [self _attemptUdpSocketRecoveryIfNeeded];
        return NO;
    }
    _udpConsecutiveSendFailures = 0;
    if (_udpPacketsSent < UINT32_MAX) {
        _udpPacketsSent += 1;
    }
    return YES;
}

- (BOOL) _sendUDPPingWithTimestamp:(uint64_t)timeStamp {
    unsigned char buf[16];
    MKPacketDataStream *pds = [[MKPacketDataStream alloc] initWithBuffer:buf+1 length:16];
    buf[0] = UDPPingMessage << 5;
    [pds addVarint:timeStamp];

    BOOL sent = NO;
    if ([pds valid]) {
        NSData *data = [[NSData alloc] initWithBytesNoCopy:buf length:[pds size]+1 freeWhenDone:NO];
        sent = [self _sendUDPMessage:data];
        [data release];
    }

    [pds release];
    return sent;
}

- (BOOL) _shouldProbeUDPAtTime:(uint64_t)now {
    if (_forceTCP || _udpAvailable || _udpSock == NULL) {
        return NO;
    }

    if (_lastUdpProbeUsec == 0) {
        return YES;
    }

    return now - _lastUdpProbeUsec >= MKUDPProbeIntervalUsec;
}

- (void) _sendTcpTunnelKeepaliveWithTimestamp:(uint64_t)timeStamp {
    if (!_connectionEstablished || !_readyVoice) {
        return;
    }

    uint64_t now = [self _currentTimeStamp];
    if (_lastTcpTunnelKeepaliveUsec != 0 &&
        now - _lastTcpTunnelKeepaliveUsec < MKTCPTunnelKeepaliveIntervalUsec) {
        return;
    }

    unsigned char buf[16];
    MKPacketDataStream *pds = [[MKPacketDataStream alloc] initWithBuffer:buf+1 length:16];
    buf[0] = UDPPingMessage << 5;
    [pds addVarint:timeStamp];

    if ([pds valid]) {
        NSData *data = [[NSData alloc] initWithBytesNoCopy:buf length:[pds size]+1 freeWhenDone:NO];
        _lastTcpTunnelKeepaliveUsec = now;
        [self sendMessageWithType:UDPTunnelMessage data:data];
        [data release];
        MKLogDebug(Connection, @"MKConnection: Sent TCP tunnel keepalive while UDP is unavailable.");
    }

    [pds release];
}

- (void) _attemptUdpSocketRecoveryIfNeeded {
    if (_forceTCP || !_connectionEstablished || _socket == -1) {
        return;
    }
    if (_udpConsecutiveSendFailures < MKUDPRebuildFailureThreshold) {
        return;
    }

    uint64_t now = [self _currentTimeStamp];
    if (_lastUdpRebuildAttemptUsec != 0 &&
        now - _lastUdpRebuildAttemptUsec < MKUDPRebuildCooldownUsec) {
        return;
    }

    _lastUdpRebuildAttemptUsec = now;
    BOOL shouldSurfaceRecovery = (_udpTransportState == MKUDPTransportStateAvailable ||
                                  _udpTransportState == MKUDPTransportStateStalled);
    if (shouldSurfaceRecovery) {
        [self _notifyUDPTransportStateIfChanged:MKUDPTransportStateRecovering];
    }
    MKLogWarning(Connection, @"MKConnection: Rebuilding UDP socket after %lu consecutive failures.",
          (unsigned long)_udpConsecutiveSendFailures);
    [self _teardownUdpSock];
    [self _setupUdpSock];
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
        MKLogError(Connection, @"MKConnection: write error, wrote %li, expected %lu", (long int)nwritten, (unsigned long)expectedLength);
    } else if (_tcpPacketsSent < UINT32_MAX) {
        _tcpPacketsSent += 1;
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
    [self _checkUdpLivenessAndRecoverIfNeeded];
    if (!_forceTCP && _udpAvailable) {
        if ([self _sendUDPMessage:data]) {
            return;
        }
    } else if (!_forceTCP) {
        [self _attemptUdpSocketRecoveryIfNeeded];
    }
    [self sendMessageWithType:UDPTunnelMessage data:data];
}

- (void) _notifyUDPTransportStateIfChanged:(MKUDPTransportState)newState {
    if (_udpTransportState == newState) {
        return;
    }
    _udpTransportState = newState;

    if ([_delegate respondsToSelector:@selector(connection:udpTransportStateChanged:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [_delegate connection:self udpTransportStateChanged:newState];
        });
    }
}

- (void) _udpDataReady:(NSData *)crypted {
    if (! _udpAvailable) {
        _udpAvailable = true;
        [self _notifyUDPTransportStateIfChanged:MKUDPTransportStateAvailable];
        MKLogInfo(Connection, @"MKConnection: UDP is now available!");
    }
    _udpConsecutiveSendFailures = 0;
    _lastUdpReceiveUsec = [self _currentTimeStamp];
    _lastUdpProbeUsec = 0;

    if ([crypted length] > 4) {
        NSData *plain = [_crypt decryptData:crypted];
        if (plain) {
            [self _udpMessageReceived:plain];
        }
    }
}

- (void) _dataReady {
    if (!packetBuffer) {
        packetBuffer = [[NSMutableData alloc] initWithLength:0];
    }

    if (packetLength == -1) {
        NSInteger need = 6 - _headerBufLen;
        NSInteger got = [_inputStream read:&_headerBuf[_headerBufLen] maxLength:need];
        if (got <= 0) {
            return;
        }
        _headerBufLen += got;
        if (_headerBufLen < 6) {
            return;
        }

        packetType = (MKMessageType) CFSwapInt16BigToHost(*(UInt16 *)(&_headerBuf[0]));
        UInt32 rawLen = CFSwapInt32BigToHost(*(UInt32 *)(&_headerBuf[2]));
        _headerBufLen = 0;

        if (rawLen > 8 * 1024 * 1024) {
            MKLogError(Connection, @"MKConnection: Received absurd packet length (%u). Dropping connection.", (unsigned)rawLen);
            _keepRunning = NO;
            return;
        }

        packetLength = (int)rawLen;
        packetBufferOffset = 0;
        [packetBuffer setLength:packetLength];
    }

    if (packetLength > 0) {
        UInt8 *packetBytes = [packetBuffer mutableBytes];
        if (!packetBytes) {
            MKLogWarning(Connection, @"MKConnection: NSMutableData is stubborn.");
            return;
        }

        NSInteger availableBytes = [_inputStream read:packetBytes + packetBufferOffset maxLength:packetLength];
        if (availableBytes <= 0) {
            return;
        }
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
    NSData *data;
    uint64_t now = [self _currentTimeStamp];
    uint64_t timeStamp = now - _connTime;
    Float32 udpVar = MKConnectionVarianceFromM2(_udpPingM2Ms, _udpPingSamples);
    Float32 tcpVar = MKConnectionVarianceFromM2(_tcpPingM2Ms, _tcpPingSamples);

    [self _checkUdpLivenessAndRecoverIfNeeded];

    // UDP is only trusted after a bidirectional ping reply. While it is down,
    // keep the voice path pinned to TCP tunnel and probe UDP sparingly.
    if (!_forceTCP) {
        if (_udpAvailable) {
            [self _sendUDPPingWithTimestamp:timeStamp];
        } else {
            if ([self _shouldProbeUDPAtTime:now]) {
                _lastUdpProbeUsec = now;
                [self _sendUDPPingWithTimestamp:timeStamp];
            }
            [self _sendTcpTunnelKeepaliveWithTimestamp:timeStamp];
        }
    } else {
        [self _sendTcpTunnelKeepaliveWithTimestamp:timeStamp];
    }
        
    // TCP Ping
    MPPing_Builder *ping = [MPPing builder];
    [ping setTimestamp:timeStamp];
    [ping setGood:_lastGood];
    [ping setLate:_lastLate];
    [ping setLost:_lastLost];
    [ping setResync:_lastResync];
    [ping setUdpPingAvg:(Float32)_udpPingMeanMs];
    [ping setUdpPingVar:udpVar];
    [ping setUdpPackets:_udpPacketsSent];
    [ping setTcpPingAvg:(Float32)_tcpPingMeanMs];
    [ping setTcpPingVar:tcpVar];
    [ping setTcpPackets:_tcpPacketsSent];

    data = [[ping build] data];
    [self sendMessageWithType:PingMessage data:data];

    MKLogDebug(Connection, @"MKConnection: Sent ping message (udpAvg=%.2fms, tcpAvg=%.2fms, udpPackets=%u, tcpPackets=%u).",
          _udpPingMeanMs, _tcpPingMeanMs, _udpPacketsSent, _tcpPacketsSent);
}

- (void) _checkUdpLivenessAndRecoverIfNeeded {
    if (_forceTCP || !_connectionEstablished || _socket == -1) {
        return;
    }

    uint64_t now = [self _currentTimeStamp];
    if (_lastUdpReceiveUsec == 0) {
        _lastUdpReceiveUsec = now;
        return;
    }

    uint64_t idleUsec = now - _lastUdpReceiveUsec;
    if (_udpAvailable && idleUsec >= MKUDPReceiveStallThresholdUsec) {
        MKLogWarning(Connection, @"MKConnection: UDP stalled for %.2fs, forcing TCP fallback and rebuilding UDP socket.",
              (double)idleUsec / 1000000.0);
        _udpAvailable = NO;
        [self _notifyUDPTransportStateIfChanged:MKUDPTransportStateStalled];
        [self _sendTcpTunnelKeepaliveWithTimestamp:(now - _connTime)];
        _udpConsecutiveSendFailures = MKUDPRebuildFailureThreshold;
        _lastUdpRebuildAttemptUsec = 0;
        [self _attemptUdpSocketRecoveryIfNeeded];
        return;
    }

    if (!_udpAvailable && idleUsec >= MKUDPReceiveStallThresholdUsec) {
        [self _notifyUDPTransportStateIfChanged:MKUDPTransportStateUnavailable];
        [self _sendTcpTunnelKeepaliveWithTimestamp:(now - _connTime)];
        _udpConsecutiveSendFailures = MKUDPRebuildFailureThreshold;
        [self _attemptUdpSocketRecoveryIfNeeded];
    }
}

- (void) _pingResponseFromServer:(MPPing *)pingMessage {
    uint64_t nowUsec = [self _currentTimeStamp] - _connTime;

    if ([pingMessage hasTimestamp]) {
        uint64_t sentUsec = [pingMessage timestamp];
        if (nowUsec >= sentUsec) {
            uint64_t rttUsec = nowUsec - sentUsec;
            // Guard against obviously stale/invalid timestamps.
            if (rttUsec <= 5ULL * 60ULL * 1000000ULL) {
                MKConnectionAddSample((double)rttUsec / 1000.0, &_tcpPingMeanMs, &_tcpPingM2Ms, &_tcpPingSamples);
            }
        }
    }

    if ([pingMessage hasGood]) {
        _lastGood = [pingMessage good];
    }
    if ([pingMessage hasLate]) {
        _lastLate = [pingMessage late];
    }
    if ([pingMessage hasLost]) {
        _lastLost = [pingMessage lost];
    }
    if ([pingMessage hasResync]) {
        _lastResync = [pingMessage resync];
    }
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
    MKLogInfo(Connection, @"MKConnection: Got CryptSetup from server.");

    if ([cryptSetup hasKey] && [cryptSetup hasClientNonce] && [cryptSetup hasServerNonce]) {
        [_crypt setKey:[cryptSetup key] eiv:[cryptSetup clientNonce] div:[cryptSetup serverNonce]];
        MKLogInfo(Connection, @"MKConnection: CryptState initialized.");
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
        MKLogError(Connection, @"MKConnection: Server does not support Opus codec. CELT is not supported. Please upgrade your Mumble server.");
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
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if (SecTrustEvaluate(trust, &trustResult) != noErr) {
#pragma clang diagnostic pop
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
            MKLogWarning(Connection, @"MKConnection: Dropping unsupported CELT voice packet type=%d", (int)messageType);
            break;
        case UDPVoiceSpeexMessage:
        case UDPVoiceOpusMessage: {
            if (messageType == UDPVoiceOpusMessage && ![[MKVersion sharedVersion] isOpusEnabled]) {
                MKLogWarning(Connection, @"MKConnection: Received Opus voice packet in no-Opus mode. Discarding.");
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
            if (!_udpAvailable) {
                MKLogVerbose(Connection, @"TCP tunnel ping response received while UDP is unavailable.");
                break;
            }
            if (now >= timeStamp) {
                uint64_t rttUsec = now - timeStamp;
                if (rttUsec <= 5ULL * 60ULL * 1000000ULL) {
                    MKConnectionAddSample((double)rttUsec / 1000.0, &_udpPingMeanMs, &_udpPingM2Ms, &_udpPingSamples);
                }
                MKLogVerbose(Connection, @"UDP ping = %llu usec", rttUsec);
            }
            break;
        }

        default:
            MKLogWarning(Connection, @"MKConnection: Unknown UDPTunnel packet (%i) received. Discarding...", (int)messageType);
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
            _lastTcpTunnelReceiveUsec = [self _currentTimeStamp];
            [self _udpMessageReceived:data];
            break;
        }
        case ServerSyncMessage: {
            _readyVoice = YES;
            if (_forceTCP || !_udpAvailable) {
                MKLogDebug(Connection, @"MKConnection: Priming TCP tunnel until UDP is confirmed.");
                [self _sendTcpTunnelKeepaliveWithTimestamp:([self _currentTimeStamp] - _connTime)];
            }
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
        case ServerConfigMessage: {
            MPServerConfig *serverConfig = [MPServerConfig parseFromData:data];
            if ([_msgHandler respondsToSelector:@selector(connection:handleServerConfigMessage:)]) {
                dispatch_async(main_queue, ^{
                    [_msgHandler connection:self handleServerConfigMessage:serverConfig];
                });
            }
            break;
        }
        case UserStatsMessage: {
            MPUserStats *userStats = [MPUserStats parseFromData:data];
            if ([_msgHandler respondsToSelector:@selector(connection:handleUserStatsMessage:)]) {
                dispatch_async(main_queue, ^{
                    [_msgHandler connection:self handleUserStatsMessage:userStats];
                });
            }
            break;
        }
        case SuggestConfigMessage: {
            MPSuggestConfig *suggestConfig = [MPSuggestConfig parseFromData:data];
            if ([_msgHandler respondsToSelector:@selector(connection:handleSuggestConfigMessage:)]) {
                dispatch_async(main_queue, ^{
                    [_msgHandler connection:self handleSuggestConfigMessage:suggestConfig];
                });
            }
            break;
        }

        default: {
            MKLogWarning(Connection, @"MKConnection: Unknown packet type recieved. Discarding. (type=%u)", packetType);
            break;
        }
    }
}

- (NSUInteger) alphaCodec { return _alphaCodec; }
- (NSUInteger) betaCodec { return _betaCodec; }
- (BOOL) preferAlphaCodec { return _preferAlpha; }
- (BOOL) shouldUseOpus { return _shouldUseOpus; }
- (double) udpPingMeanMs { return _udpPingMeanMs; }
- (double) udpPingVarianceMs { return (double)MKConnectionVarianceFromM2(_udpPingM2Ms, _udpPingSamples); }
- (uint32_t) udpPingSamples { return _udpPingSamples; }
- (uint32_t) lastGood { return _lastGood; }
- (uint32_t) lastLate { return _lastLate; }
- (uint32_t) lastLost { return _lastLost; }
- (MKUDPTransportState) udpTransportState { return _udpTransportState; }

@end
