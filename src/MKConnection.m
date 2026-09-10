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
#import "MKConnectionTransport.h"
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
#include <time.h>
#include <stdatomic.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <math.h>

#import "Mumble.pb.h"

// The bitstream we should send to the server.
// It's currently hard-coded.
#define MUMBLEKIT_CELT_BITSTREAM 0x8000000bUL
static const uint64_t MKConnectionHandshakeTimeoutUsec = 20ULL * 1000000ULL;
static const uint64_t MKConnectionServerSyncTimeoutUsec = 30ULL * 1000000ULL;
static const uint64_t MKConnectionTCPTimeoutUsec = 30ULL * 1000000ULL;
static const uint64_t MKConnectionWriteTimeoutUsec = 15ULL * 1000000ULL;
static const uint64_t MKConnectionCryptResyncIntervalUsec = 5ULL * 1000000ULL;
static const NSUInteger MKUDPRebuildFailureThreshold = 3;
static const uint64_t MKUDPRebuildCooldownUsec = 2ULL * 1000ULL * 1000ULL;
static const uint64_t MKUDPReceiveStallThresholdUsec = 8ULL * 1000ULL * 1000ULL;
static const uint64_t MKUDPProbeIntervalUsec = 15ULL * 1000ULL * 1000ULL;
static const uint64_t MKTCPTunnelKeepaliveIntervalUsec = 5ULL * 1000ULL * 1000ULL;
static const int MKConnectionVoiceDSCPTrafficClass = 46 << 2;

static int MKConnectionSocketFamily(CFSocketNativeHandle nativeSocket) {
    struct sockaddr_storage address;
    socklen_t addressLength = sizeof(address);
    memset(&address, 0, sizeof(address));
    if (getsockname(nativeSocket, (struct sockaddr *)&address, &addressLength) == 0) {
        return address.ss_family;
    }
    return AF_UNSPEC;
}

@interface MKConnection () {
    MKCryptState   *_crypt;

    MKMessageType  packetType;
    MKConnectionReadState _readState;
    MKConnectionWriteQueue _writeQueue;
    CFRunLoopRef   _connectionRunLoop;
    NSTimer        *_watchdogTimer;
    uint64_t       _attemptStartUsec;
    uint64_t       _handshakeCompleteUsec;
    MKConnectionPingState _tcpPingState;
    MKConnectionPingState _udpPingState;
    uint64_t       _lastTcpWriteProgressUsec;
    uint64_t       _lastCryptResyncRequestUsec;
    uint64_t       _lastCryptSetupUsec;
    BOOL           _waitingForTrust;
    atomic_uint_fast64_t _connectionGeneration;
    NSString       *_hostname;
    NSUInteger     _port;
    atomic_bool    _keepRunning;
    atomic_bool    _reconnect;

    BOOL           _forceTCP;
    BOOL           _enableQoS;
    BOOL           _udpAvailable;
    MKUDPTransportState _udpTransportState;
    NSUInteger     _udpConsecutiveSendFailures;
    uint64_t       _lastUdpRebuildAttemptUsec;
    uint64_t       _lastUdpReceiveUsec;
    uint64_t       _lastUdpProbeUsec;
    uint64_t       _lastTcpTunnelKeepaliveUsec;
    uint64_t       _lastTcpTunnelReceiveUsec;
    uint64_t       _connTime;
    NSTimer        *_pingTimer;
    NSOutputStream *_outputStream;
    NSInputStream  *_inputStream;
    atomic_bool    _connectionEstablished;
    atomic_bool    _ignoreSSLVerification;
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
- (void) _flushTCPWrites;
- (void) _watchdogTimerFired:(NSTimer *)timer;
- (void) _performOnConnectionThread:(SEL)selector object:(id)object;
- (void) _dataReady;
- (void) _messageRecieved:(NSData *)data;

// UDP
- (void) _setupUdpSock;
- (void) _teardownUdpSock;
- (void) _applyForceTCPOnConnectionThread:(NSNumber *)flagNumber;
- (void) _applyQoSOnConnectionThread:(NSNumber *)flagNumber;
- (void) _applyQoSToNativeSocket:(CFSocketNativeHandle)nativeSocket name:(NSString *)socketName;
- (void) _applyQoSToTCPSocketIfAvailable;
- (void) _applyQoSToUDPSocketIfAvailable;
- (void) _udpDataReady:(NSData *)data;
- (void) _udpMessageReceived:(NSData *)data viaUDP:(BOOL)viaUDP;
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
    _enableQoS = YES;
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
    
    MKConnectionResetReadState(&_readState);
    MKConnectionResetWriteQueue(&_writeQueue);
    
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
    @autoreleasepool {
        NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
        @synchronized(self) {
            _connectionRunLoop = (CFRunLoopRef)CFRetain([runLoop getCFRunLoop]);
        }
        do {
            @autoreleasepool {
                _reconnect = NO;
                if (!_keepRunning) break;
                _connectionGeneration += 1;
                _connectionEstablished = NO;
                _readyVoice = NO;
                _waitingForTrust = NO;
                _trustedChain = NO;
                _rejected = NO;
                _socket = -1;
                _udpAvailable = NO;
                _udpTransportState = MKUDPTransportStateUnknown;
                _udpConsecutiveSendFailures = 0;
                _lastUdpRebuildAttemptUsec = 0;
                _lastUdpReceiveUsec = 0;
                _lastUdpProbeUsec = 0;
                _lastTcpTunnelKeepaliveUsec = 0;
                _lastTcpTunnelReceiveUsec = 0;
                memset(&_tcpPingState, 0, sizeof(_tcpPingState));
                memset(&_udpPingState, 0, sizeof(_udpPingState));
                _lastTcpWriteProgressUsec = 0;
                _lastCryptResyncRequestUsec = 0;
                _lastCryptSetupUsec = 0;
                _handshakeCompleteUsec = 0;
                _attemptStartUsec = [self _currentTimeStamp];
                _connTime = _attemptStartUsec;
                MKConnectionResetReadState(&_readState);
                MKConnectionResetWriteQueue(&_writeQueue);
                MKConnectionResetRunningStats(&_udpPingMeanMs, &_udpPingM2Ms, &_udpPingSamples);
                MKConnectionResetRunningStats(&_tcpPingMeanMs, &_tcpPingM2Ms, &_tcpPingSamples);
                _udpPacketsSent = _tcpPacketsSent = 0;
                _lastGood = _lastLate = _lastLost = _lastResync = 0;
                [_connError release]; _connError = nil;
                [_peerCertificates release]; _peerCertificates = nil;
                [_serverVersion release]; _serverVersion = nil;
                [_serverRelease release]; _serverRelease = nil;
                [_serverOSName release]; _serverOSName = nil;
                [_serverOSVersion release]; _serverOSVersion = nil;
                [_crypt release];
                _crypt = [[MKCryptState alloc] init];

                CFStreamCreatePairWithSocketToHost(kCFAllocatorDefault,
                    (CFStringRef)_hostname, (UInt32)_port,
                    (CFReadStreamRef *)&_inputStream, (CFWriteStreamRef *)&_outputStream);
                if (!_inputStream || !_outputStream) {
                    [self _handleError:[NSError errorWithDomain:NSPOSIXErrorDomain code:ENOMEM
                        userInfo:@{NSLocalizedDescriptionKey: @"Unable to create connection streams."}]];
                } else {
                    [_inputStream setDelegate:self];
                    [_outputStream setDelegate:self];
                    [_inputStream scheduleInRunLoop:runLoop forMode:NSDefaultRunLoopMode];
                    [_outputStream scheduleInRunLoop:runLoop forMode:NSDefaultRunLoopMode];
                    [self _setupSsl];
                    _watchdogTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self
                        selector:@selector(_watchdogTimerFired:) userInfo:nil repeats:YES];
                    [_inputStream open];
                    [_outputStream open];
                    while (_keepRunning && !_reconnect) {
                        @autoreleasepool {
                            // A bounded run prevents a lost wake during startup from trapping shutdown.
                            [runLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
                        }
                    }
                }

                [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_dataReady) object:nil];
                [self _teardownUdpSock];
                [_watchdogTimer invalidate]; _watchdogTimer = nil;
                [_pingTimer invalidate]; _pingTimer = nil;
                for (NSStream *stream in @[_inputStream ?: (id)[NSNull null], _outputStream ?: (id)[NSNull null]]) {
                    if ((id)stream == [NSNull null]) continue;
                    [stream setDelegate:nil];
                    [stream removeFromRunLoop:runLoop forMode:NSDefaultRunLoopMode];
                    [stream close];
                }
                [_inputStream release]; _inputStream = nil;
                [_outputStream release]; _outputStream = nil;
                _socket = -1;
                MKConnectionResetReadState(&_readState);
                MKConnectionResetWriteQueue(&_writeQueue);
                BOOL wasEstablished = _connectionEstablished;
                _connectionEstablished = NO;
                _readyVoice = NO;
                [[MKAudio sharedAudio] clearMainConnectionForAudioIfMatches:self];

                if (!_reconnect && !_rejected) {
                    NSError *error = [[_connError retain] autorelease];
                    if (wasEstablished) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            id delegate = [self delegate];
                            if ([delegate respondsToSelector:@selector(connection:closedWithError:)])
                                [delegate connection:self closedWithError:error];
                        });
                    } else if (error) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            id delegate = [self delegate];
                            if ([delegate respondsToSelector:@selector(connection:unableToConnectWithError:)])
                                [delegate connection:self unableToConnectWithError:error];
                        });
                    }
                }
            }
        } while (_keepRunning && _reconnect);
        @synchronized(self) {
            CFRelease(_connectionRunLoop);
            _connectionRunLoop = NULL;
        }
        [_crypt release]; _crypt = nil;
    }
}

- (void) _wakeRunLoop {
    @synchronized(self) {
        if (_connectionRunLoop) CFRunLoopWakeUp(_connectionRunLoop);
    }
}

// Run-loop blocks have the lifetime of this attempt; sending to a finished NSThread
// with performSelector:onThread: can race shutdown and raise an exception.
- (void) _performOnConnectionThread:(SEL)selector object:(id)object {
    if ([NSThread currentThread] == self) {
        if (_keepRunning && !_reconnect) [self performSelector:selector withObject:object];
        return;
    }
    @synchronized(self) {
        if (!_connectionRunLoop || !_keepRunning || _reconnect) return;
        uint64_t generation = _connectionGeneration;
        CFRunLoopPerformBlock(_connectionRunLoop, kCFRunLoopDefaultMode, ^{
            if (_keepRunning && !_reconnect && generation == _connectionGeneration)
                [self performSelector:selector withObject:object];
        });
        CFRunLoopWakeUp(_connectionRunLoop);
    }
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
    MKConnectionResetReadState(&_readState);
    MKConnectionResetWriteQueue(&_writeQueue);
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
    // Also cancels the small window after start but before main begins executing.
    _keepRunning = NO;
    _reconnect = NO;
    [self _wakeRunLoop];
}

- (void) disconnect {
    // NSThread retains its target until main returns. Cleanup is performed there;
    // callers (including the connection thread itself) must never join by spinning.
    [self stopConnectionThread];
}

- (void) reconnect {
    if (!_keepRunning || [self isFinished]) return;
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
    if (!_keepRunning || _reconnect || (stream != _inputStream && stream != _outputStream)) return;
    if (eventCode == NSStreamEventErrorOccurred) {
        [self _handleError:[stream streamError]];
        return;
    }
    if (eventCode == NSStreamEventEndEncountered) {
        [self _handleError:[NSError errorWithDomain:NSPOSIXErrorDomain code:ECONNRESET
            userInfo:@{NSLocalizedDescriptionKey: @"The server closed the connection."}]];
        return;
    }
    if (stream == _inputStream) {
        if (eventCode == NSStreamEventHasBytesAvailable) [self _dataReady];
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
                setsockopt(_socket, SOL_SOCKET, SO_KEEPALIVE, &val, sizeof(val));
#ifdef SO_NOSIGPIPE
                setsockopt(_socket, SOL_SOCKET, SO_NOSIGPIPE, &val, sizeof(val));
#endif
                [self _applyQoSToTCPSocketIfAvailable];
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
                if (_waitingForTrust) break;
                _connectionEstablished = YES;
                _handshakeCompleteUsec = [self _currentTimeStamp];
                [self _updateTLSTrustedStatus];
                [self peerCertificates];
                [[MKAudio sharedAudio] setMainConnectionForAudio:self];
                
                _pingTimer = [NSTimer timerWithTimeInterval:MKConnectionPingInterval target:self selector:@selector(_pingTimerFired:) userInfo:nil repeats:YES];
                [[NSRunLoop currentRunLoop] addTimer:_pingTimer forMode:NSRunLoopCommonModes];

                uint64_t generation = _connectionGeneration;
                dispatch_async(dispatch_get_main_queue(), ^{
                    id delegate = [self delegate];
                    if (generation == _connectionGeneration && _keepRunning && !_reconnect &&
                        [delegate respondsToSelector:@selector(connectionOpened:)])
                        [delegate connectionOpened:self];
                });
            }
            [self _flushTCPWrites];
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

- (void) setDelegate:(id<MKConnectionDelegate>)delegate { @synchronized(self) { _delegate = delegate; } }
- (id<MKConnectionDelegate>) delegate { @synchronized(self) { return [[_delegate retain] autorelease]; } }
- (void) setMessageHandler:(id<MKMessageHandler>)messageHandler { @synchronized(self) { _msgHandler = messageHandler; } }
- (id<MKMessageHandler>) messageHandler { @synchronized(self) { return [[_msgHandler retain] autorelease]; } }

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
    _lastUdpReceiveUsec = 0;
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

    [self _applyQoSToUDPSocketIfAvailable];

    CFRunLoopSourceRef src = CFSocketCreateRunLoopSource(NULL, _udpSock, 0);
    if (!src) {
        [self _teardownUdpSock];
        return;
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, kCFRunLoopDefaultMode);
    CFRelease(src);

    NSData *_udpAddr = [[[NSData alloc] initWithBytes:&sa length:(NSUInteger)sl] autorelease];
    CFSocketError err = CFSocketConnectToAddress(_udpSock, (CFDataRef)_udpAddr, -1);
    if (err != kCFSocketSuccess) {
        MKLogError(Connection, @"MKConnection: Unable to CFSocketConnectToAddress()");
        [self _teardownUdpSock];
        return;
    }
}

- (void) _teardownUdpSock {
    memset(&_udpPingState, 0, sizeof(_udpPingState));
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
    if (_peerCertificates != nil || !_outputStream) {
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

- (void) setQoSEnabled:(BOOL)flag {
    if (![self isExecuting]) { _enableQoS = flag; return; }
    if ([NSThread currentThread] != self) {
        [self _performOnConnectionThread:@selector(_applyQoSOnConnectionThread:) object:@(flag)];
        return;
    }

    [self _applyQoSOnConnectionThread:@(flag)];
}

- (BOOL) qosEnabled {
    return _enableQoS;
}

- (void) _applyQoSOnConnectionThread:(NSNumber *)flagNumber {
    _enableQoS = [flagNumber boolValue];
    [self _applyQoSToTCPSocketIfAvailable];
    [self _applyQoSToUDPSocketIfAvailable];
}

- (void) _applyQoSToNativeSocket:(CFSocketNativeHandle)nativeSocket name:(NSString *)socketName {
    if (nativeSocket == -1) {
        return;
    }

#if defined(SO_NET_SERVICE_TYPE) && defined(NET_SERVICE_TYPE_VO)
    int serviceType = _enableQoS ? NET_SERVICE_TYPE_VO : 0;
# if defined(NET_SERVICE_TYPE_BE)
    if (!_enableQoS) {
        serviceType = NET_SERVICE_TYPE_BE;
    }
# endif
    if (setsockopt(nativeSocket, SOL_SOCKET, SO_NET_SERVICE_TYPE, &serviceType, sizeof(serviceType)) != 0) {
        MKLogWarning(Connection, @"MKConnection: failed to apply %@ SO_NET_SERVICE_TYPE=%d", socketName, serviceType);
    }
#endif

    int trafficClass = _enableQoS ? MKConnectionVoiceDSCPTrafficClass : 0;
    int family = MKConnectionSocketFamily(nativeSocket);
    if (family == AF_INET || family == AF_UNSPEC) {
        if (setsockopt(nativeSocket, IPPROTO_IP, IP_TOS, &trafficClass, sizeof(trafficClass)) != 0 && family == AF_INET) {
            MKLogWarning(Connection, @"MKConnection: failed to apply %@ IPv4 DSCP=%d", socketName, trafficClass);
        }
    }
    if (family == AF_INET6 || family == AF_UNSPEC) {
        if (setsockopt(nativeSocket, IPPROTO_IPV6, IPV6_TCLASS, &trafficClass, sizeof(trafficClass)) != 0 && family == AF_INET6) {
            MKLogWarning(Connection, @"MKConnection: failed to apply %@ IPv6 DSCP=%d", socketName, trafficClass);
        }
    }
}

- (void) _applyQoSToTCPSocketIfAvailable {
    if (_socket != -1) {
        [self _applyQoSToNativeSocket:_socket name:@"TCP"];
    }
}

- (void) _applyQoSToUDPSocketIfAvailable {
    if (_udpSock != NULL && CFSocketIsValid(_udpSock)) {
        [self _applyQoSToNativeSocket:CFSocketGetNative(_udpSock) name:@"UDP"];
    }
}

- (void) setForceTCP:(BOOL)flag {
    if (![self isExecuting]) { _forceTCP = flag; return; }
    if ([NSThread currentThread] != self) {
        [self _performOnConnectionThread:@selector(_applyForceTCPOnConnectionThread:) object:@(flag)];
        return;
    }

    [self _applyForceTCPOnConnectionThread:@(flag)];
}

- (void) _applyForceTCPOnConnectionThread:(NSNumber *)flagNumber {
    BOOL flag = [flagNumber boolValue];

    _forceTCP = flag;
    if (_forceTCP) {
        [self _teardownUdpSock];
        [self _notifyUDPTransportStateIfChanged:MKUDPTransportStateUnavailable];
    } else if (_connectionEstablished && _socket != -1 && !_udpSock) {
        [self _setupUdpSock];
        _lastUdpProbeUsec = 0;
        if ([_crypt valid]) [self _sendUDPPingWithTimestamp:([self _currentTimeStamp] - _connTime)];
    }
}

- (BOOL) forceTCP {
    return _forceTCP;
}

- (BOOL) _sendUDPMessage:(NSData *)data {
    if (_forceTCP) {
        return NO;
    }

    if (![_crypt valid]) return NO;
    if (_udpSock == NULL || !CFSocketIsValid(_udpSock)) {
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

    // UDP must never wait on a full kernel send buffer on the connection thread.
    ssize_t sent = send(CFSocketGetNative(_udpSock), [crypted bytes], [crypted length], MSG_DONTWAIT);
    if (sent < 0 || (NSUInteger)sent != [crypted length]) {
        MKLogWarning(Connection, @"MKConnection: UDP send failed with errno=%d", errno);
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
    MKPacketDataStream *pds = [[MKPacketDataStream alloc] initWithBuffer:buf+1 length:sizeof(buf)-1];
    buf[0] = UDPPingMessage << 5;
    [pds addVarint:timeStamp];

    BOOL sent = NO;
    if ([pds valid]) {
        NSData *data = [[NSData alloc] initWithBytesNoCopy:buf length:[pds size]+1 freeWhenDone:NO];
        sent = [self _sendUDPMessage:data];
        if (sent) MKConnectionRecordPing(&_udpPingState, timeStamp, [self _currentTimeStamp]);
        [data release];
    }

    [pds release];
    return sent;
}

- (BOOL) _shouldProbeUDPAtTime:(uint64_t)now {
    if (_forceTCP || _udpAvailable || ![_crypt valid]) {
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
    MKPacketDataStream *pds = [[MKPacketDataStream alloc] initWithBuffer:buf+1 length:sizeof(buf)-1];
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
    _lastUdpProbeUsec = 0;
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
    if (!data || !_keepRunning || !_connectionEstablished) return;
    NSDictionary *dict = [[NSDictionary alloc] initWithObjectsAndKeys:
                            data, @"data",
                            [NSNumber numberWithInt:(int)messageType], @"messageType",
                            nil];

    if ([NSThread currentThread] != self) {
        [self _performOnConnectionThread:@selector(_sendMessageHelper:) object:dict];
    } else {
        [self _sendMessageHelper:dict];
    }

    [dict release];
}

- (void) _sendMessageHelper:(NSDictionary *)dict {
    if (!_keepRunning || _reconnect || !_connectionEstablished) return;
    NSData *data = [dict objectForKey:@"data"];
    MKMessageType messageType = (MKMessageType)[[dict objectForKey:@"messageType"] intValue];
    // New live voice may be shed under backpressure. Never drop part of a frame
    // already queued, and never silently discard reliable control messages.
    if (messageType == UDPTunnelMessage && _writeQueue.pendingBytes >= MKConnectionVoiceBacklogLimit) return;
    BOOL wasEmpty = _writeQueue.pendingBytes == 0;
    if (!MKConnectionEnqueueFrame(&_writeQueue, (uint16_t)messageType, data)) {
        [self _handleError:[NSError errorWithDomain:NSPOSIXErrorDomain code:ENOBUFS
            userInfo:@{NSLocalizedDescriptionKey: @"The connection send queue is full."}]];
        return;
    }
    if (wasEmpty) _lastTcpWriteProgressUsec = [self _currentTimeStamp];
    [self _flushTCPWrites];
}

- (void) _flushTCPWrites {
    if (!_keepRunning || _reconnect || !_connectionEstablished) return;
    NSUInteger written = 0;
    uint32_t frames = 0;
    if (!MKConnectionFlushFrames(&_writeQueue, _outputStream, &written, &frames)) {
        [self _handleError:[_outputStream streamError]];
        return;
    }
    if (written) _lastTcpWriteProgressUsec = [self _currentTimeStamp];
    _tcpPacketsSent += MIN(frames, UINT32_MAX - _tcpPacketsSent);
}

- (void) sendVoiceData:(NSData *)data {
    if (!data || !_keepRunning || !_connectionEstablished) return;
    if ([NSThread currentThread] == self) {
        [self _sendVoiceDataOnConnectionThread:data];
    } else {
        [self _performOnConnectionThread:@selector(_sendVoiceDataOnConnectionThread:) object:data];
    }
}

- (void) _sendVoiceDataOnConnectionThread:(NSData *)data {
    if (!_keepRunning || _reconnect || !_readyVoice || !_connectionEstablished)
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

    uint64_t generation = _connectionGeneration;
    dispatch_async(dispatch_get_main_queue(), ^{
        id delegate = [self delegate];
        if (generation == _connectionGeneration && _keepRunning && !_reconnect &&
            [delegate respondsToSelector:@selector(connection:udpTransportStateChanged:)])
            [delegate connection:self udpTransportStateChanged:newState];
    });
}

- (void) _udpDataReady:(NSData *)crypted {
    if (!_keepRunning || _reconnect || _forceTCP || ![_crypt valid] || [crypted length] <= 4) return;
    NSData *plain = [_crypt decryptData:crypted];
    if (!plain) {
        uint64_t now = [self _currentTimeStamp];
        uint64_t lastGood = _lastUdpReceiveUsec ?: _lastCryptSetupUsec;
        if (MKConnectionDeadlineExpired(now, lastGood, MKConnectionCryptResyncIntervalUsec) &&
            (_lastCryptResyncRequestUsec == 0 || MKConnectionDeadlineExpired(now, _lastCryptResyncRequestUsec, MKConnectionCryptResyncIntervalUsec))) {
            _lastCryptResyncRequestUsec = now;
            [self sendMessageWithType:CryptSetupMessage data:[[[MPCryptSetup builder] build] data]];
            MKLogWarning(Connection, @"MKConnection: Requesting UDP nonce resynchronization.");
        }
        return;
    }
    // Voice proves only the receive path. Only an echoed UDP probe may restore
    // the send route; continuous downlink voice can otherwise mask uplink loss.
    _lastUdpReceiveUsec = [self _currentTimeStamp];
    [self _udpMessageReceived:plain viaUDP:YES];
}

- (void) _dataReady {
    if (!_keepRunning || _reconnect || _waitingForTrust) return;
    @try {
        MKConnectionReadResult result = MKConnectionReadFrames(&_readState, _inputStream, ^BOOL(uint16_t type, NSData *data) {
            packetType = (MKMessageType)type;
            [self _messageRecieved:data];
            return _keepRunning && !_reconnect;
        });
        switch (result) {
            case MKConnectionReadContinue:
                [self performSelector:@selector(_dataReady) withObject:nil afterDelay:0];
                break;
            case MKConnectionReadError:
                [self _handleError:[_inputStream streamError]];
                break;
            case MKConnectionReadEOF:
            case MKConnectionReadOversized:
                [self _handleError:[NSError errorWithDomain:NSPOSIXErrorDomain
                    code:result == MKConnectionReadEOF ? ECONNRESET : EMSGSIZE
                    userInfo:@{NSLocalizedDescriptionKey: result == MKConnectionReadEOF ?
                        @"The server closed the connection." : @"The server sent an oversized protocol message."}]];
                break;
            case MKConnectionReadDrained: break;
        }
    } @catch (NSException *exception) {
        MKLogError(Connection, @"MKConnection: Invalid protocol message (%@).", [exception name]);
        [self _handleError:[NSError errorWithDomain:NSPOSIXErrorDomain code:EPROTO
            userInfo:@{NSLocalizedDescriptionKey: @"The server sent an invalid protocol message."}]];
    }
}

- (uint64_t) _currentTimeStamp {
    // Includes sleep but is unaffected by wall-clock corrections.
    return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1000ULL;
}

- (void) _watchdogTimerFired:(NSTimer *)timer {
    if (!_keepRunning || _reconnect || _waitingForTrust) return;
    uint64_t now = [self _currentTimeStamp];
    NSString *reason = nil;
    if (!_connectionEstablished && MKConnectionDeadlineExpired(now, _attemptStartUsec, MKConnectionHandshakeTimeoutUsec))
        reason = @"The TCP/TLS connection timed out.";
    else if (_connectionEstablished && !_readyVoice && MKConnectionDeadlineExpired(now, _handshakeCompleteUsec, MKConnectionServerSyncTimeoutUsec))
        reason = @"The server did not complete authentication in time.";
    else if (_connectionEstablished && MKConnectionDeadlineExpired(now, _tcpPingState.lastReplyUsec ?: _handshakeCompleteUsec, MKConnectionTCPTimeoutUsec))
        reason = @"The server stopped responding to connection heartbeats.";
    else if (_writeQueue.pendingBytes && MKConnectionDeadlineExpired(now, _lastTcpWriteProgressUsec, MKConnectionWriteTimeoutUsec))
        reason = @"The connection stopped accepting outgoing data.";
    if (reason) {
        MKLogWarning(Connection, @"MKConnection: %@", reason);
        [self _handleError:[NSError errorWithDomain:NSPOSIXErrorDomain code:ETIMEDOUT
            userInfo:@{NSLocalizedDescriptionKey: reason}]];
    } else {
        [self _flushTCPWrites];
        [self _checkUdpLivenessAndRecoverIfNeeded];
    }
}

- (void) _pingTimerFired:(NSTimer *)timer {
    if (!_keepRunning || _reconnect || !_connectionEstablished) return;
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
    MKConnectionRecordPing(&_tcpPingState, timeStamp, now);
    [self sendMessageWithType:PingMessage data:data];

    MKLogDebug(Connection, @"MKConnection: Sent ping message (udpAvg=%.2fms, tcpAvg=%.2fms, udpPackets=%u, tcpPackets=%u).",
          _udpPingMeanMs, _tcpPingMeanMs, _udpPacketsSent, _tcpPacketsSent);
}

- (void) _checkUdpLivenessAndRecoverIfNeeded {
    if (_forceTCP || !_connectionEstablished || _socket == -1 || ![_crypt valid]) return;
    uint64_t now = [self _currentTimeStamp];
    uint64_t baseline = _udpPingState.lastReplyUsec ?: _lastCryptSetupUsec;
    if (baseline == 0) return;
    uint64_t idleUsec = now >= baseline ? now - baseline : 0;
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

    if (!_udpAvailable && idleUsec >= MKUDPProbeIntervalUsec &&
        (_lastUdpRebuildAttemptUsec == 0 || MKConnectionDeadlineExpired(now, _lastUdpRebuildAttemptUsec, MKUDPProbeIntervalUsec))) {
        [self _notifyUDPTransportStateIfChanged:MKUDPTransportStateUnavailable];
        [self _sendTcpTunnelKeepaliveWithTimestamp:(now - _connTime)];
        _udpConsecutiveSendFailures = MKUDPRebuildFailureThreshold;
        [self _attemptUdpSocketRecoveryIfNeeded];
    }
}

- (void) _pingResponseFromServer:(MPPing *)pingMessage {
    uint64_t now = [self _currentTimeStamp];
    if ([pingMessage hasTimestamp] &&
        MKConnectionAcceptPingReply(&_tcpPingState, [pingMessage timestamp], now, MKConnectionTCPTimeoutUsec)) {
        uint64_t elapsed = now - _connTime;
        uint64_t timestamp = [pingMessage timestamp];
        if (elapsed >= timestamp)
            MKConnectionAddSample((double)(elapsed - timestamp) / 1000.0, &_tcpPingMeanMs, &_tcpPingM2Ms, &_tcpPingSamples);
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

    dispatch_async(dispatch_get_main_queue(), ^{
        id delegate = [self delegate];
        if ([delegate respondsToSelector:@selector(connection:rejectedWithReason:explanation:)])
            [delegate connection:self rejectedWithReason:reason explanation:explanationString];
    });

    _rejected = YES;
    [self stopConnectionThread];
}

- (void) _doCryptSetup:(MPCryptSetup *)cryptSetup {
    // Mumble supports full setup, server nonce resync, and an empty request
    // asking the client to report its current encryption nonce.
    if ([cryptSetup hasKey] && [cryptSetup hasClientNonce] && [cryptSetup hasServerNonce]) {
        if ([[cryptSetup key] length] != 16 || [[cryptSetup clientNonce] length] != 16 ||
            [[cryptSetup serverNonce] length] != 16) {
            [self _handleError:[NSError errorWithDomain:NSPOSIXErrorDomain code:EPROTO
                userInfo:@{NSLocalizedDescriptionKey: @"The server sent invalid voice encryption parameters."}]];
            return;
        }
        [_crypt setKey:[cryptSetup key] eiv:[cryptSetup clientNonce] div:[cryptSetup serverNonce]];
        _lastCryptSetupUsec = [self _currentTimeStamp];
        _udpAvailable = NO;
        _lastUdpReceiveUsec = 0;
        memset(&_udpPingState, 0, sizeof(_udpPingState));
        MKLogInfo(Connection, @"MKConnection: CryptState initialized.");
    } else if ([cryptSetup hasServerNonce] && ![cryptSetup hasKey] && ![cryptSetup hasClientNonce] && [_crypt valid]) {
        if ([[cryptSetup serverNonce] length] != 16) {
            [self _handleError:[NSError errorWithDomain:NSPOSIXErrorDomain code:EPROTO
                userInfo:@{NSLocalizedDescriptionKey: @"The server sent an invalid voice encryption nonce."}]];
            return;
        }
        [_crypt setDecryptIV:[cryptSetup serverNonce]];
        MKLogInfo(Connection, @"MKConnection: UDP decrypt nonce resynchronized.");
    } else if (![cryptSetup hasKey] && ![cryptSetup hasClientNonce] && ![cryptSetup hasServerNonce] && [_crypt valid]) {
        MPCryptSetup_Builder *response = [MPCryptSetup builder];
        [response setClientNonce:[_crypt encryptIV]];
        [self sendMessageWithType:CryptSetupMessage data:[[response build] data]];
        return;
    } else {
        [self _handleError:[NSError errorWithDomain:NSPOSIXErrorDomain code:EPROTO
            userInfo:@{NSLocalizedDescriptionKey: @"The server sent incomplete voice encryption parameters."}]];
        return;
    }
    if (!_forceTCP) {
        _lastUdpProbeUsec = [self _currentTimeStamp];
        [self _sendUDPPingWithTimestamp:(_lastUdpProbeUsec - _connTime)];
    }
}

- (void) _versionMessageReceived:(MPVersion *)msg {
    if ([msg hasVersion]) {
        int32_t version = [msg version];
        [_serverVersion release];
        _serverVersion = [[NSString alloc] initWithFormat:@"%i.%i.%i", (version >> 16) & 0xffff, (version >> 8) & 0xff, version & 0xff];
    }
    if ([msg hasRelease]) { [_serverRelease release]; _serverRelease = [[msg release] copy]; }
    if ([msg hasOs]) { [_serverOSName release]; _serverOSName = [[msg os] copy]; }
    if ([msg hasOsVersion]) { [_serverOSVersion release]; _serverOSVersion = [[msg osVersion] copy]; }
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
    if (!_keepRunning || _waitingForTrust) return;
    NSInteger errorCode = [streamError code];

    if (errorCode <= errSSLProtocol && errorCode > errSSLLast) {
        BOOL didHandle = [self _tryHandleSslError:streamError];
        if (didHandle) {
            return;
        }
    }

    if (!_keepRunning || _waitingForTrust) return;
    [_connError release];
    _connError = [(streamError ?: [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO
        userInfo:@{NSLocalizedDescriptionKey: @"The connection stream failed."}]) retain];
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
                id delegate = [self delegate];
                if ([delegate respondsToSelector:@selector(connection:trustFailureInCertificateChain:)]) {
                    _waitingForTrust = YES;
                    NSArray *chain = [self peerCertificates];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if ([self delegate] == delegate)
                            [delegate connection:self trustFailureInCertificateChain:chain];
                    });
                    handled = YES;
                }
                break;
            }
        }

        CFRelease(trust);
        return handled;
    }

    return NO;
}

- (void) _udpMessageReceived:(NSData *)data viaUDP:(BOOL)viaUDP {
    if ([data length] == 0) return;
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
            if (![pds valid] || [pds left] == 0) break;
            NSMutableData *voicePacketData = [[NSMutableData alloc] initWithCapacity:[pds left]+1];
            [voicePacketData setLength:[pds left]+1];
            unsigned char *bytes = [voicePacketData mutableBytes];
            bytes[0] = (unsigned char)messageFlags;
            memcpy(bytes+1, [pds dataPtr], [pds left]);
            [[MKAudio sharedAudio] addFrameToBufferWithSession:session data:voicePacketData sequence:seq type:messageType connection:self];
            [voicePacketData release];
            break;
        }

        case UDPPingMessage: {
            uint64_t timeStamp = [pds getVarint];
            if (![pds valid] || [pds left] != 0 || !viaUDP) break;
            uint64_t now = [self _currentTimeStamp];
            if (!MKConnectionAcceptPingReply(&_udpPingState, timeStamp, now, MKUDPReceiveStallThresholdUsec)) break;
            if (!_udpAvailable) {
                _udpAvailable = YES;
                [self _notifyUDPTransportStateIfChanged:MKUDPTransportStateAvailable];
                MKLogInfo(Connection, @"MKConnection: Bidirectional UDP probe confirmed.");
            }
            _udpConsecutiveSendFailures = 0;
            _lastUdpProbeUsec = 0;
            uint64_t elapsed = now - _connTime;
            if (elapsed >= timeStamp)
                MKConnectionAddSample((double)(elapsed - timeStamp) / 1000.0, &_udpPingMeanMs, &_udpPingM2Ms, &_udpPingSamples);
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

    id messageHandler = [self messageHandler];
    uint64_t generation = _connectionGeneration;
    switch (packetType) {
        case UDPTunnelMessage: {
            _lastTcpTunnelReceiveUsec = [self _currentTimeStamp];
            [self _udpMessageReceived:data viaUDP:NO];
            break;
        }
        case ServerSyncMessage: {
            _readyVoice = YES;
            if (_forceTCP || !_udpAvailable) {
                MKLogDebug(Connection, @"MKConnection: Priming TCP tunnel until UDP is confirmed.");
                [self _sendTcpTunnelKeepaliveWithTimestamp:([self _currentTimeStamp] - _connTime)];
            }
            MPServerSync *serverSync = [MPServerSync parseFromData:data];
            if ([messageHandler respondsToSelector:@selector(connection:handleServerSyncMessage:)]) {
                dispatch_async(main_queue, ^{
                    if (generation != _connectionGeneration || [self messageHandler] != messageHandler) return;
                    [messageHandler connection:self handleServerSyncMessage:serverSync];
                });
            }
            break;
        }
        case ChannelRemoveMessage: {
            MPChannelRemove *channelRemove = [MPChannelRemove parseFromData:data];
            if ([messageHandler respondsToSelector:@selector(connection:handleChannelRemoveMessage:)]) {
                dispatch_async(main_queue, ^{
                    if (generation != _connectionGeneration || [self messageHandler] != messageHandler) return;
                    [messageHandler connection:self handleChannelRemoveMessage:channelRemove];
                });
            }
            break;
        }
        case ChannelStateMessage: {
            MPChannelState *channelState = [MPChannelState parseFromData:data];
            if ([messageHandler respondsToSelector:@selector(connection:handleChannelStateMessage:)]) {
                dispatch_async(main_queue, ^{
                    if (generation != _connectionGeneration || [self messageHandler] != messageHandler) return;
                    [messageHandler connection:self handleChannelStateMessage:channelState];
                });
            }
            break;
        }
        case UserRemoveMessage: {
            MPUserRemove *userRemove = [MPUserRemove parseFromData:data];
            if ([messageHandler respondsToSelector:@selector(connection:handleUserRemoveMessage:)]) {
                dispatch_async(main_queue, ^{
                    if (generation != _connectionGeneration || [self messageHandler] != messageHandler) return;
                    [messageHandler connection:self handleUserRemoveMessage:userRemove];
                });
            }
            break;
        }
        case UserStateMessage: {
            MPUserState *userState = [MPUserState parseFromData:data];
            if ([messageHandler respondsToSelector:@selector(connection:handleUserStateMessage:)]) {
                dispatch_async(main_queue, ^{
                    if (generation != _connectionGeneration || [self messageHandler] != messageHandler) return;
                    [messageHandler connection:self handleUserStateMessage:userState];
                });
            }
            break;
        }
        case BanListMessage: {
            MPBanList *banList = [MPBanList parseFromData:data];
            if ([messageHandler respondsToSelector:@selector(connection:handleBanListMessage:)]) {
                dispatch_async(main_queue, ^{
                    if (generation != _connectionGeneration || [self messageHandler] != messageHandler) return;
                    [messageHandler connection:self handleBanListMessage:banList];
                 });
            }
            break;
        }
        case TextMessageMessage: {
            MPTextMessage *textMessage = [MPTextMessage parseFromData:data];
            if ([messageHandler respondsToSelector:@selector(connection:handleTextMessageMessage:)]) {
                dispatch_async(main_queue, ^{
                    if (generation != _connectionGeneration || [self messageHandler] != messageHandler) return;
                    [messageHandler connection:self handleTextMessageMessage:textMessage];
                });
            }
            break;
        }
        case PermissionDeniedMessage: {
            MPPermissionDenied *permissionDenied = [MPPermissionDenied parseFromData:data];
            if ([messageHandler respondsToSelector:@selector(connection:handlePermissionDeniedMessage:)]) {
                dispatch_async(main_queue, ^{
                    if (generation != _connectionGeneration || [self messageHandler] != messageHandler) return;
                    [messageHandler connection:self handlePermissionDeniedMessage:permissionDenied];
                });
            }
            break;
        }
        case ACLMessage: {
            MPACL *aclMessage = [MPACL parseFromData:data];
            if ([messageHandler respondsToSelector:@selector(connection:handleACLMessage:)]) {
                dispatch_async(main_queue, ^{
                    if (generation != _connectionGeneration || [self messageHandler] != messageHandler) return;
                    [messageHandler connection:self handleACLMessage:aclMessage];
                });
            }
            break;
        }
        case QueryUsersMessage: {
            MPQueryUsers *queryUsers = [MPQueryUsers parseFromData:data];
            if ([messageHandler respondsToSelector:@selector(connection:handleQueryUsersMessage:)]) {
                dispatch_async(main_queue, ^{
                    if (generation != _connectionGeneration || [self messageHandler] != messageHandler) return;
                    [messageHandler connection:self handleQueryUsersMessage:queryUsers];
                });
            }
            break;
        }
        case ContextActionModifyMessage: {
            MPContextActionModify *contextActionModify = [MPContextActionModify parseFromData:data];
            if ([messageHandler respondsToSelector:@selector(connection:handleContextActionModifyMessage:)]) {
                dispatch_async(main_queue, ^{
                    if (generation != _connectionGeneration || [self messageHandler] != messageHandler) return;
                    [messageHandler connection:self handleContextActionModifyMessage:contextActionModify];
                });
            }
            break;
        }
        case ContextActionMessage: {
            MPContextAction *contextAction = [MPContextAction parseFromData:data];
            if ([messageHandler respondsToSelector:@selector(connection:handleContextActionMessage:)]) {
                dispatch_async(main_queue, ^{
                    if (generation != _connectionGeneration || [self messageHandler] != messageHandler) return;
                    [messageHandler connection:self handleContextActionMessage:contextAction];
                });
            }
            break;
        }
        case UserListMessage: {
            MPUserList *userList = [MPUserList parseFromData:data];
            if ([messageHandler respondsToSelector:@selector(connection:handleUserListMessage:)]) {
                dispatch_async(main_queue, ^{
                    if (generation != _connectionGeneration || [self messageHandler] != messageHandler) return;
                    [messageHandler connection:self handleUserListMessage:userList];
                });
            }
            break;
        }
        case VoiceTargetMessage: {
            MPVoiceTarget *voiceTarget = [MPVoiceTarget parseFromData:data];
            // ✅ FIXED: Correct selector name
            if ([messageHandler respondsToSelector:@selector(connection:handleVoiceTargetMessage:)]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation != _connectionGeneration || [self messageHandler] != messageHandler) return;
                    [messageHandler connection:self handleVoiceTargetMessage:voiceTarget];
                });
            }
            break;
        }
        case PermissionQueryMessage: {
            MPPermissionQuery *permissionQuery = [MPPermissionQuery parseFromData:data];
            if ([messageHandler respondsToSelector:@selector(connection:handlePermissionQueryMessage:)]) {
                dispatch_async(main_queue, ^{
                    if (generation != _connectionGeneration || [self messageHandler] != messageHandler) return;
                    [messageHandler connection:self handlePermissionQueryMessage:permissionQuery];
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
            if ([messageHandler respondsToSelector:@selector(connection:handleServerConfigMessage:)]) {
                dispatch_async(main_queue, ^{
                    if (generation != _connectionGeneration || [self messageHandler] != messageHandler) return;
                    [messageHandler connection:self handleServerConfigMessage:serverConfig];
                });
            }
            break;
        }
        case UserStatsMessage: {
            MPUserStats *userStats = [MPUserStats parseFromData:data];
            if ([messageHandler respondsToSelector:@selector(connection:handleUserStatsMessage:)]) {
                dispatch_async(main_queue, ^{
                    if (generation != _connectionGeneration || [self messageHandler] != messageHandler) return;
                    [messageHandler connection:self handleUserStatsMessage:userStats];
                });
            }
            break;
        }
        case SuggestConfigMessage: {
            MPSuggestConfig *suggestConfig = [MPSuggestConfig parseFromData:data];
            if ([messageHandler respondsToSelector:@selector(connection:handleSuggestConfigMessage:)]) {
                dispatch_async(main_queue, ^{
                    if (generation != _connectionGeneration || [self messageHandler] != messageHandler) return;
                    [messageHandler connection:self handleSuggestConfigMessage:suggestConfig];
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
