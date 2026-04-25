//
//  MKAudio.m
//  MumbleKit
//
//  Modernized to use AVAudioSession (Removing all deprecated AudioSession C-APIs)
//

#import <MumbleKit/MKAudio.h>
#import "MKUtils.h"
#import "MKAudioDevice.h"
#import "MKAudioInput.h"
#import "MKAudioInputRackBridge.h"
#import "MKAudioOutput.h"
#import "MKAudioOutputSidetone.h"
#import "MKAudioRemoteBusRackBridge.h"
#import "MKAudioRemoteTrackRackBridge.h"
#import <MumbleKit/MKConnection.h>
#import "../../Source/Classes/SwiftUI/Core/MumbleLogger.h"

#import <AVFoundation/AVFoundation.h> // ✅ 必须引入

#if TARGET_OS_IPHONE == 1
# import "MKVoiceProcessingDevice.h"
# import "MKiOSAudioDevice.h"
#elif TARGET_OS_OSX == 1
# import "MKVoiceProcessingDevice.h"
# import "MKMacAudioDevice.h"
#endif

#if TARGET_OS_OSX == 1
#import <CoreAudio/CoreAudio.h>
#import <libkern/OSAtomic.h>
#elif TARGET_OS_IPHONE
#import <libkern/OSAtomic.h>
#endif
#import <os/lock.h>

#if TARGET_OS_IPHONE || TARGET_IPHONE_SIMULATOR
#import <UIKit/UIKit.h>
#endif

NSString *MKAudioDidRestartNotification = @"MKAudioDidRestartNotification";
NSString *MKAudioErrorNotification = @"MKAudioErrorNotification";
#if TARGET_OS_OSX == 1
static NSString *const MUMacAudioInputDevicesChangedNotification = @"MUMacAudioInputDevicesChanged";
static NSString *const MUMacAudioVPIOToHALTransitionNotification = @"MUMacAudioVPIOToHALTransition";
#endif

typedef struct _MKAudioPreviewGainProcessorState {
    float gain;
    BOOL enabled;
} MKAudioPreviewGainProcessorState;

@interface MKAudio () {
    id<MKAudioDelegate>      _delegate;
    MKAudioDevice            *_audioDevice;
    MKAudioInput             *_audioInput;
    MKAudioOutput            *_audioOutput;
    MKAudioOutputSidetone    *_sidetoneOutput;
    MKConnection             *_connection;
    MKAudioSettings          _audioSettings;
    BOOL                     _running;

    // 保存闭麦/不听状态，在 audio restart 后恢复
    BOOL                     _cachedSelfMuted;
    BOOL                     _cachedSuppressed;
    BOOL                     _cachedMuted;
    MKAudioPreviewGainProcessorState _inputTrackPreviewState;
    MKAudioPreviewGainProcessorState _remoteBusPreviewState;
    MKAudioInputRackBridge *_inputTrackRackBridge;
    MKAudioInputRackBridge *_sidetoneRackBridge;
    MKAudioRemoteBusRackBridge *_remoteBusRackBridge;
    MKAudioRemoteBusRackBridge *_remoteBusRackBridge2;
    MKAudioPreviewGainProcessorState _remoteBus2PreviewState;
    NSMutableDictionary      *_remoteTrackPreviewStates;
    NSMutableDictionary      *_remoteTrackRackBridges;
    NSUInteger               _pluginHostBufferFrames;
#if TARGET_OS_OSX == 1
    BOOL                     _isObservingDefaultInputDevice;
    CFAbsoluteTime           _lastDefaultInputSwitchTime;
    CFAbsoluteTime           _lastDefaultOutputSwitchTime;
    BOOL                     _isRestartingForDeviceChange;
    BOOL                     _lastDeviceWasVPIO;
#endif
    
    // P0 修复：使用串行队列替代 @synchronized，提升性能
    dispatch_queue_t         _accessQueue;

    // Input track sidechain FIFO (written by input thread, consumed in render-aligned blocks)
    os_unfair_lock _sidechainInputLock;
    float    *_sidechainInputRingBuffer;
    float    *_sidechainInputReadBuffer;
    NSUInteger _sidechainInputRingCapacityFrames;
    NSUInteger _sidechainInputReadPos;
    NSUInteger _sidechainInputWritePos;
    NSUInteger _sidechainInputBufferedFrames;
    NSUInteger _sidechainInputPPChannels;
    NSUInteger _sidechainInputPPSampleRate;

    // Sidetone track sidechain FIFO (written by input thread, consumed in render-aligned blocks)
    os_unfair_lock _sidechainSidetoneLock;
    float    *_sidechainSidetoneRingBuffer;
    float    *_sidechainSidetoneReadBuffer;
    NSUInteger _sidechainSidetoneRingCapacityFrames;
    NSUInteger _sidechainSidetoneReadPos;
    NSUInteger _sidechainSidetoneWritePos;
    NSUInteger _sidechainSidetoneBufferedFrames;
    NSUInteger _sidechainSidetonePPChannels;
    NSUInteger _sidechainSidetonePPSampleRate;

    // Input monitor FIFO (post-sidetone-track DSP, consumed continuously by output)
    os_unfair_lock _inputMonitorLock;
    float    *_inputMonitorRingBuffer;
    float    *_inputMonitorReadBuffer;
    NSUInteger _inputMonitorRingCapacityFrames;
    NSUInteger _inputMonitorReadPos;
    NSUInteger _inputMonitorWritePos;
    NSUInteger _inputMonitorBufferedFrames;
    NSUInteger _inputMonitorPPChannels;
    NSUInteger _inputMonitorPPSampleRate;

}
#if TARGET_OS_OSX == 1
- (void)startObservingDefaultInputDeviceChanges;
- (void)stopObservingDefaultInputDeviceChanges;
- (void)handleDefaultInputDeviceChanged;
- (void)handleDefaultOutputDeviceChanged;
#endif
- (void)rebindRemoteTrackProcessorsToOutputLocked;
- (NSUInteger)currentOutputProcessingSampleRateLocked;
- (MKAudioRemoteTrackRackBridge *)remoteTrackRackBridgeForSessionLocked:(NSUInteger)session createIfNeeded:(BOOL)create;
@end

#if TARGET_OS_OSX == 1
static OSStatus MKAudioDefaultInputDeviceChangedCallback(AudioObjectID inObjectID,
                                                          UInt32 inNumberAddresses,
                                                          const AudioObjectPropertyAddress inAddresses[],
                                                          void *inClientData) {
    MKAudio *audio = (MKAudio *)inClientData;
    if (!audio) return noErr;
    [audio handleDefaultInputDeviceChanged];
    return noErr;
}

static OSStatus MKAudioDefaultOutputDeviceChangedCallback(AudioObjectID inObjectID,
                                                           UInt32 inNumberAddresses,
                                                           const AudioObjectPropertyAddress inAddresses[],
                                                           void *inClientData) {
    MKAudio *audio = (MKAudio *)inClientData;
    if (!audio) return noErr;
    [audio handleDefaultOutputDeviceChanged];
    return noErr;
}

static BOOL MKAudioDeviceHasInputStreams(AudioDeviceID devId) {
    AudioObjectPropertyAddress addr;
    addr.mSelector = kAudioDevicePropertyStreams;
    addr.mScope = kAudioDevicePropertyScopeInput;
    addr.mElement = kAudioObjectPropertyElementMain;
    
    UInt32 size = 0;
    OSStatus err = AudioObjectGetPropertyDataSize(devId, &addr, 0, NULL, &size);
    return (err == noErr && size > 0);
}

static NSString *MKAudioCopyDeviceUID(AudioDeviceID devId) {
    AudioObjectPropertyAddress addr;
    addr.mSelector = kAudioDevicePropertyDeviceUID;
    addr.mScope = kAudioObjectPropertyScopeGlobal;
    addr.mElement = kAudioObjectPropertyElementMain;
    
    CFStringRef uidRef = NULL;
    UInt32 size = sizeof(CFStringRef);
    OSStatus err = AudioObjectGetPropertyData(devId, &addr, 0, NULL, &size, &uidRef);
    if (err != noErr || uidRef == NULL) {
        return nil;
    }
    NSString *uid = [(__bridge NSString *)uidRef copy];
    CFRelease(uidRef);
    return [uid autorelease];
}

static BOOL MKAudioInputDeviceExistsForUID(NSString *uid) {
    if (uid == nil || [uid length] == 0) return NO;
    
    AudioObjectPropertyAddress addr;
    addr.mSelector = kAudioHardwarePropertyDevices;
    addr.mScope = kAudioObjectPropertyScopeGlobal;
    addr.mElement = kAudioObjectPropertyElementMain;
    
    UInt32 size = 0;
    OSStatus err = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &size);
    if (err != noErr || size < sizeof(AudioDeviceID)) {
        return NO;
    }
    
    UInt32 count = size / sizeof(AudioDeviceID);
    AudioDeviceID *devIds = (AudioDeviceID *)calloc(count, sizeof(AudioDeviceID));
    if (devIds == NULL) return NO;
    
    err = AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, devIds);
    if (err != noErr) {
        free(devIds);
        return NO;
    }
    
    BOOL found = NO;
    for (UInt32 i = 0; i < count; i++) {
        AudioDeviceID candidate = devIds[i];
        if (!MKAudioDeviceHasInputStreams(candidate)) continue;
        NSString *candidateUID = MKAudioCopyDeviceUID(candidate);
        if (candidateUID && [candidateUID isEqualToString:uid]) {
            found = YES;
            break;
        }
    }
    
    free(devIds);
    return found;
}

static BOOL MKAudioSystemDefaultInputIsBuiltInOrBluetooth(void) {
    AudioDeviceID devId = kAudioObjectUnknown;
    AudioObjectPropertyAddress addr;
    addr.mSelector = kAudioHardwarePropertyDefaultInputDevice;
    addr.mScope = kAudioObjectPropertyScopeGlobal;
    addr.mElement = kAudioObjectPropertyElementMain;
    UInt32 size = sizeof(AudioDeviceID);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, &devId) != noErr) {
        return NO;
    }
    addr.mSelector = kAudioDevicePropertyTransportType;
    UInt32 transportType = 0;
    size = sizeof(UInt32);
    if (AudioObjectGetPropertyData(devId, &addr, 0, NULL, &size, &transportType) != noErr) {
        return NO;
    }
    return (transportType == kAudioDeviceTransportTypeBuiltIn ||
            transportType == kAudioDeviceTransportTypeBluetooth ||
            transportType == kAudioDeviceTransportTypeBluetoothLE);
}
#endif

static void MKAudioNormalizeSettings(MKAudioSettings *settings) {
    if (settings == NULL) return;
    
    if (settings->codec != MKCodecFormatSpeex
        && settings->codec != MKCodecFormatCELT
        && settings->codec != MKCodecFormatOpus) {
        settings->codec = MKCodecFormatOpus;
    }
    if (settings->transmitType != MKTransmitTypeVAD
        && settings->transmitType != MKTransmitTypeToggle
        && settings->transmitType != MKTransmitTypeContinuous) {
        settings->transmitType = MKTransmitTypeVAD;
    }
    if (settings->vadKind != MKVADKindSignalToNoise
        && settings->vadKind != MKVADKindAmplitude) {
        settings->vadKind = MKVADKindAmplitude;
    }
    if (settings->quality <= 0) {
        settings->quality = 100000;
    }
    if (settings->audioPerPacket <= 0 || settings->audioPerPacket > 8) {
        settings->audioPerPacket = 2;
    }
    if (settings->volume < 0.0f) {
        settings->volume = 0.0f;
    }
    if (settings->micBoost <= 0.0f) {
        settings->micBoost = 1.0f;
    }
    if (settings->vadMin < 0.0f) {
        settings->vadMin = 0.0f;
    }
    if (settings->vadMax < 0.0f) {
        settings->vadMax = 0.0f;
    }
    if (settings->vadMax < settings->vadMin) {
        float t = settings->vadMax;
        settings->vadMax = settings->vadMin;
        settings->vadMin = t;
    }
}

static NSUInteger MKAudioInputProcessingSampleRateForSettings(const MKAudioSettings *settings) {
    if (settings != NULL && settings->codec == MKCodecFormatSpeex) {
        return 32000;
    }
    return SAMPLE_RATE;
}

@implementation MKAudio

#pragma mark - Singleton & Init

+ (MKAudio *) sharedAudio {
    static dispatch_once_t pred;
    static MKAudio *audio;

    dispatch_once(&pred, ^{
        audio = [[MKAudio alloc] init];
    });

    return audio;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // P0 修复：创建串行队列用于线程安全访问，替代 @synchronized
        NSString *queueName = [NSString stringWithFormat:@"com.mumble.audio.%p", self];
        _accessQueue = dispatch_queue_create([queueName UTF8String], DISPATCH_QUEUE_SERIAL);
        
        // 安全默认值：避免首个设置更新尚未应用时读取到未定义配置。
        memset(&_audioSettings, 0, sizeof(MKAudioSettings));
        _audioSettings.codec = MKCodecFormatOpus;
        _audioSettings.transmitType = MKTransmitTypeVAD;
        _audioSettings.vadKind = MKVADKindAmplitude;
        _audioSettings.vadMin = 0.3f;
        _audioSettings.vadMax = 0.6f;
        _audioSettings.quality = 100000;
        _audioSettings.audioPerPacket = 2;
        _audioSettings.volume = 1.0f;
        _audioSettings.micBoost = 1.0f;
        _audioSettings.enableStereoOutput = YES;
        _audioSettings.enableVadGate = YES;
        _audioSettings.vadGateTimeSeconds = 0.1;
        MKAudioNormalizeSettings(&_audioSettings);

        _inputTrackPreviewState.gain = 1.0f;
        _inputTrackPreviewState.enabled = NO;
        _remoteBusPreviewState.gain = 1.0f;
        _remoteBusPreviewState.enabled = NO;
        _pluginHostBufferFrames = 256;
        _inputTrackRackBridge = [[MKAudioInputRackBridge alloc] init];
        _sidetoneRackBridge = [[MKAudioInputRackBridge alloc] init];
        _remoteBusRackBridge = [[MKAudioRemoteBusRackBridge alloc] init];
        _remoteBusRackBridge2 = [[MKAudioRemoteBusRackBridge alloc] init];
        _remoteBus2PreviewState.gain = 1.0f;
        _remoteBus2PreviewState.enabled = NO;
        _remoteTrackPreviewStates = [[NSMutableDictionary alloc] init];
        _remoteTrackRackBridges = [[NSMutableDictionary alloc] init];

        _sidechainInputLock = OS_UNFAIR_LOCK_INIT;
        _sidechainInputRingCapacityFrames = MK_SIDECHAIN_MAX_FRAMES * 8;
        _sidechainInputRingBuffer = calloc(_sidechainInputRingCapacityFrames * 2, sizeof(float));
        _sidechainInputReadBuffer = calloc(MK_SIDECHAIN_MAX_FRAMES * 2, sizeof(float));
        _sidechainInputReadPos = 0;
        _sidechainInputWritePos = 0;
        _sidechainInputBufferedFrames = 0;
        _sidechainInputPPChannels = 0;
        _sidechainInputPPSampleRate = 0;
        _sidechainSidetoneLock = OS_UNFAIR_LOCK_INIT;
        _sidechainSidetoneRingCapacityFrames = MK_SIDECHAIN_MAX_FRAMES * 8;
        _sidechainSidetoneRingBuffer = calloc(_sidechainSidetoneRingCapacityFrames * 2, sizeof(float));
        _sidechainSidetoneReadBuffer = calloc(MK_SIDECHAIN_MAX_FRAMES * 2, sizeof(float));
        _sidechainSidetoneReadPos = 0;
        _sidechainSidetoneWritePos = 0;
        _sidechainSidetoneBufferedFrames = 0;
        _sidechainSidetonePPChannels = 0;
        _sidechainSidetonePPSampleRate = 0;
        _inputMonitorLock = OS_UNFAIR_LOCK_INIT;
        _inputMonitorRingCapacityFrames = MK_SIDECHAIN_MAX_FRAMES * 8;
        _inputMonitorRingBuffer = calloc(_inputMonitorRingCapacityFrames * 2, sizeof(float));
        _inputMonitorReadBuffer = calloc(MK_SIDECHAIN_MAX_FRAMES * 2, sizeof(float));
        _inputMonitorReadPos = 0;
        _inputMonitorWritePos = 0;
        _inputMonitorBufferedFrames = 0;
        _inputMonitorPPChannels = 0;
        _inputMonitorPPSampleRate = 0;

#if TARGET_OS_IOS
        // 注册通知监听 (替代旧的 C 回调)
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleInterruption:)
                                                     name:AVAudioSessionInterruptionNotification
                                                   object:nil];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleRouteChange:)
                                                     name:AVAudioSessionRouteChangeNotification
                                                   object:nil];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleMediaServicesReset:)
                                                     name:AVAudioSessionMediaServicesWereResetNotification
                                                   object:nil];
#elif TARGET_OS_OSX == 1
        _lastDefaultInputSwitchTime = 0;
        _lastDefaultOutputSwitchTime = 0;
        [self startObservingDefaultInputDeviceChanges];
#endif
    }
    return self;
}

- (void)dealloc {
#if TARGET_OS_OSX == 1
    [self stopObservingDefaultInputDeviceChanges];
#endif
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    // P0 修复：清理访问队列
    if (_accessQueue) {
        dispatch_release(_accessQueue);
        _accessQueue = NULL;
    }
    for (NSValue *value in [_remoteTrackPreviewStates allValues]) {
        MKAudioPreviewGainProcessorState *state = (MKAudioPreviewGainProcessorState *)[value pointerValue];
        if (state != NULL) {
            free(state);
        }
    }
    [_remoteTrackPreviewStates release];
    _remoteTrackPreviewStates = nil;
    
    [_inputTrackRackBridge release];
    _inputTrackRackBridge = nil;
    [_sidetoneRackBridge release];
    _sidetoneRackBridge = nil;
    [_remoteBusRackBridge release];
    _remoteBusRackBridge = nil;
    [_remoteBusRackBridge2 release];
    _remoteBusRackBridge2 = nil;
    [_remoteTrackRackBridges release];
    _remoteTrackRackBridges = nil;

    free(_sidechainInputRingBuffer);
    free(_sidechainInputReadBuffer);
    free(_sidechainSidetoneRingBuffer);
    free(_sidechainSidetoneReadBuffer);
    free(_inputMonitorRingBuffer);
    free(_inputMonitorReadBuffer);

    [super dealloc];
}

#pragma mark - AVAudioSession Configuration (Modern)

- (void)setupAudioSession {
#if TARGET_OS_IPHONE == 1
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    
    // 1. 确定 Category Options
    // 默认允许蓝牙 (A2DP/HFP) 和 与其他应用混音 (MixWithOthers)
    AVAudioSessionCategoryOptions options = AVAudioSessionCategoryOptionAllowBluetoothHFP |
                                            AVAudioSessionCategoryOptionAllowBluetoothA2DP | // ✅ 增加 A2DP 支持
                                            AVAudioSessionCategoryOptionMixWithOthers; // 混音

    // 处理扬声器/听筒逻辑
    // 如果用户没有偏好听筒 (Receiver)，则默认走扬声器 (Speaker)
    // 注意：在 VoiceChat 模式下，如果不加 DefaultToSpeaker，默认会走听筒
    MKAudioSettings settings;
    [self readAudioSettings:&settings];
    
    if (!settings.preferReceiverOverSpeaker) {
        options |= AVAudioSessionCategoryOptionDefaultToSpeaker;
    }

    // 2. 设置 Category 和 Mode
    // ✅ Category: PlayAndRecord (录音+播放)
    // ✅ Mode: VoiceChat — 必须使用此模式以确保系统硬件层面的 AEC 正常工作。
    //    Default 模式下虽然 VPIO AudioUnit 有 AEC，但系统不会对硬件路径做回声消除优化，
    //    导致对方说话被麦克风重新采集回去。
    //    系统麦克风模式选择器（标准/语音突显/宽谱）在 VoiceChat + VPIO 下仍然可用。
    BOOL success = [session setCategory:AVAudioSessionCategoryPlayAndRecord
                                   mode:AVAudioSessionModeVoiceChat
                                options:options
                                  error:&error];
    
    if (!success) {
        MKLogError(Audio, @"MKAudio: Failed to set session category: %@", error.localizedDescription);
    }

    // 3. 设置硬件采样率 (推荐 48kHz)
    [session setPreferredSampleRate:48000.0 error:nil];
    
    // 4. 设置 I/O Buffer
    // iPad VPIO + MixWithOthers 组合 CPU 开销很大，使用更长的缓冲区（40ms）减轻负载
    // iPhone 保持低延迟（20ms）
    NSTimeInterval bufferDuration = 0.02;
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
        bufferDuration = 0.04;
    }
    [session setPreferredIOBufferDuration:bufferDuration error:nil];
#endif
}

- (void)resetAudioSessionToIdle {
#if TARGET_OS_IPHONE == 1
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;

    [session setActive:NO
           withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                 error:&error];
    if (error) {
        MKLogWarning(Audio, @"MKAudio: Failed to deactivate session while resetting idle category: %@", error.localizedDescription);
        error = nil;
    }

    BOOL success = [session setCategory:AVAudioSessionCategoryAmbient
                                   mode:AVAudioSessionModeDefault
                                options:AVAudioSessionCategoryOptionMixWithOthers
                                  error:&error];
    if (!success) {
        MKLogWarning(Audio, @"MKAudio: Failed to reset idle audio session category: %@", error.localizedDescription);
    } else {
        MKLogDebug(Audio, @"MKAudio: Reset audio session to idle Ambient/Default");
    }
#endif
}

- (void)updateAudioSessionSettings {
    // 只有音频正在运行时才重新应用录音会话，避免未连接时进入 VoiceChat/通话模式。
    if (_running) {
        [self setupAudioSession];
    }
}

#pragma mark - Notification Handlers

#if TARGET_OS_IOS
- (void)handleInterruption:(NSNotification *)notification {
    NSDictionary *userInfo = notification.userInfo;
    AVAudioSessionInterruptionType type = [userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];

    if (type == AVAudioSessionInterruptionTypeBegan) {
        MKLogInfo(Audio, @"MKAudio: Interruption BEGAN (Phone call etc.)");
        [self stop];
    } else if (type == AVAudioSessionInterruptionTypeEnded) {
        MKLogInfo(Audio, @"MKAudio: Interruption ENDED. Restarting audio engine...");
        // 不再依赖 ShouldResume 标志位。电话挂断后该标志经常不被设置，
        // 导致音频引擎永远无法恢复。只要中断结束且连接仍然活跃，就无条件重启。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (![self _audioShouldBeRunning]) {
                MKLogInfo(Audio, @"MKAudio: Interruption ended but audio should stay idle.");
                [self resetAudioSessionToIdle];
                return;
            }

            [self restart];
        });
    }
}

- (void)handleRouteChange:(NSNotification *)notification {
    NSDictionary *userInfo = notification.userInfo;
    AVAudioSessionRouteChangeReason reason = [userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];
    
    MKLogInfo(Audio, @"MKAudio: Route Changed. Reason: %lu", (unsigned long)reason);
    
    // 以下情况通常不需要重启：
    // kAudioSessionRouteChangeReasonOverride (我们自己代码改的)
    // kAudioSessionRouteChangeReasonCategoryChange (Category 改变)
    
    switch (reason) {
        case AVAudioSessionRouteChangeReasonNewDeviceAvailable: // 插入耳机
        case AVAudioSessionRouteChangeReasonOldDeviceUnavailable: // 拔出耳机
            // 只有音频引擎已经在运行时才重启，避免在未连接服务器时激活麦克风
            if (_running) {
                MKLogInfo(Audio, @"MKAudio: Restarting audio due to device change.");
                [self restart];
            }
            break;
        default:
            break;
    }
}

- (void)handleMediaServicesReset:(NSNotification *)notification {
    MKLogWarning(Audio, @"MKAudio: Media Services Reset (Audio daemon crashed). Re-initializing.");
    // 彻底重置
    [self stop];
    if ([self _audioShouldBeRunning]) {
        [self start];
    }
}
#endif // TARGET_OS_IOS

#if TARGET_OS_OSX == 1
- (void)startObservingDefaultInputDeviceChanges {
    if (_isObservingDefaultInputDevice) return;
    
    AudioObjectPropertyAddress defaultInputAddr;
    defaultInputAddr.mSelector = kAudioHardwarePropertyDefaultInputDevice;
    defaultInputAddr.mScope = kAudioObjectPropertyScopeGlobal;
    defaultInputAddr.mElement = kAudioObjectPropertyElementMain;
    
    OSStatus err = AudioObjectAddPropertyListener(kAudioObjectSystemObject,
                                                  &defaultInputAddr,
                                                  MKAudioDefaultInputDeviceChangedCallback,
                                                  self);
    if (err != noErr) {
        MKLogWarning(Audio, @"MKAudio: Failed to observe default input device changes (%d).", (int)err);
        return;
    }
    
    AudioObjectPropertyAddress devicesAddr;
    devicesAddr.mSelector = kAudioHardwarePropertyDevices;
    devicesAddr.mScope = kAudioObjectPropertyScopeGlobal;
    devicesAddr.mElement = kAudioObjectPropertyElementMain;
    
    OSStatus devicesErr = AudioObjectAddPropertyListener(kAudioObjectSystemObject,
                                                         &devicesAddr,
                                                         MKAudioDefaultInputDeviceChangedCallback,
                                                         self);
    if (devicesErr != noErr) {
        AudioObjectRemovePropertyListener(kAudioObjectSystemObject,
                                          &defaultInputAddr,
                                          MKAudioDefaultInputDeviceChangedCallback,
                                          self);
        MKLogWarning(Audio, @"MKAudio: Failed to observe device list changes (%d).", (int)devicesErr);
        return;
    }
    
    AudioObjectPropertyAddress defaultOutputAddr;
    defaultOutputAddr.mSelector = kAudioHardwarePropertyDefaultOutputDevice;
    defaultOutputAddr.mScope = kAudioObjectPropertyScopeGlobal;
    defaultOutputAddr.mElement = kAudioObjectPropertyElementMain;
    
    OSStatus outputErr = AudioObjectAddPropertyListener(kAudioObjectSystemObject,
                                                        &defaultOutputAddr,
                                                        MKAudioDefaultOutputDeviceChangedCallback,
                                                        self);
    if (outputErr != noErr) {
        AudioObjectRemovePropertyListener(kAudioObjectSystemObject,
                                          &defaultInputAddr,
                                          MKAudioDefaultInputDeviceChangedCallback,
                                          self);
        AudioObjectRemovePropertyListener(kAudioObjectSystemObject,
                                          &devicesAddr,
                                          MKAudioDefaultInputDeviceChangedCallback,
                                          self);
        MKLogWarning(Audio, @"MKAudio: Failed to observe default output device changes (%d).", (int)outputErr);
        return;
    }
    
    _isObservingDefaultInputDevice = YES;
    MKLogInfo(Audio, @"MKAudio: Observing default input/output and device list changes.");
}

- (void)stopObservingDefaultInputDeviceChanges {
    if (!_isObservingDefaultInputDevice) return;
    
    AudioObjectPropertyAddress defaultInputAddr;
    defaultInputAddr.mSelector = kAudioHardwarePropertyDefaultInputDevice;
    defaultInputAddr.mScope = kAudioObjectPropertyScopeGlobal;
    defaultInputAddr.mElement = kAudioObjectPropertyElementMain;
    
    OSStatus err = AudioObjectRemovePropertyListener(kAudioObjectSystemObject,
                                                     &defaultInputAddr,
                                                     MKAudioDefaultInputDeviceChangedCallback,
                                                     self);
    if (err != noErr) {
        MKLogWarning(Audio, @"MKAudio: Failed to remove default input device observer (%d).", (int)err);
    }
    
    AudioObjectPropertyAddress devicesAddr;
    devicesAddr.mSelector = kAudioHardwarePropertyDevices;
    devicesAddr.mScope = kAudioObjectPropertyScopeGlobal;
    devicesAddr.mElement = kAudioObjectPropertyElementMain;
    
    OSStatus devicesErr = AudioObjectRemovePropertyListener(kAudioObjectSystemObject,
                                                            &devicesAddr,
                                                            MKAudioDefaultInputDeviceChangedCallback,
                                                            self);
    if (devicesErr != noErr) {
        MKLogWarning(Audio, @"MKAudio: Failed to remove device list observer (%d).", (int)devicesErr);
    }
    
    AudioObjectPropertyAddress defaultOutputAddr;
    defaultOutputAddr.mSelector = kAudioHardwarePropertyDefaultOutputDevice;
    defaultOutputAddr.mScope = kAudioObjectPropertyScopeGlobal;
    defaultOutputAddr.mElement = kAudioObjectPropertyElementMain;
    
    OSStatus outputErr = AudioObjectRemovePropertyListener(kAudioObjectSystemObject,
                                                           &defaultOutputAddr,
                                                           MKAudioDefaultOutputDeviceChangedCallback,
                                                           self);
    if (outputErr != noErr) {
        MKLogWarning(Audio, @"MKAudio: Failed to remove default output device observer (%d).", (int)outputErr);
    }
    
    _isObservingDefaultInputDevice = NO;
}

- (void)handleDefaultInputDeviceChanged {
    // 节流：避免系统在切换过程中短时间多次回调导致重复 restart
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - _lastDefaultInputSwitchTime < 0.8) {
        return;
    }
    _lastDefaultInputSwitchTime = now;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:MUMacAudioInputDevicesChangedNotification object:nil];
        
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        BOOL followSystemInput = YES;
        if ([defaults objectForKey:@"AudioFollowSystemInputDevice"] != nil) {
            followSystemInput = [defaults boolForKey:@"AudioFollowSystemInputDevice"];
        }
        
        if (!followSystemInput) {
            NSString *preferredUID = [[defaults stringForKey:@"AudioPreferredInputDeviceUID"]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([preferredUID length] > 0 && MKAudioInputDeviceExistsForUID(preferredUID)) {
                // 固定设备仍存在时，忽略系统默认设备变化
                return;
            }
            
            // 固定设备已经不存在，自动回退到“跟随系统”
            [defaults setBool:YES forKey:@"AudioFollowSystemInputDevice"];
            [defaults setObject:@"" forKey:@"AudioPreferredInputDeviceUID"];
            MKLogInfo(Audio, @"MKAudio: Preferred input device missing. Auto-fallback to follow system default.");
        }
        
        if (!self->_running) {
            return;
        }
        if (self->_isRestartingForDeviceChange) {
            return;
        }
        self->_isRestartingForDeviceChange = YES;
        BOOL wasVPIO = [self->_audioDevice isKindOfClass:[MKVoiceProcessingDevice class]];
        BOOL nowExternal = !MKAudioSystemDefaultInputIsBuiltInOrBluetooth();
        MKLogInfo(Audio, @"MKAudio: Default input device changed. Restarting audio to apply new microphone.");
        [self restart];
        if (wasVPIO && nowExternal) {
            [[NSNotificationCenter defaultCenter] postNotificationName:MUMacAudioVPIOToHALTransitionNotification object:self];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self->_isRestartingForDeviceChange = NO;
        });
    });
}

- (void)handleDefaultOutputDeviceChanged {
    // 节流：避免切换输出设备时系统短时间多次回调导致重复 restart
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - _lastDefaultOutputSwitchTime < 0.6) {
        return;
    }
    _lastDefaultOutputSwitchTime = now;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self->_running) {
            return;
        }
        if (self->_isRestartingForDeviceChange) {
            return;
        }
        self->_isRestartingForDeviceChange = YES;
        MKLogInfo(Audio, @"MKAudio: Default output device changed. Restarting audio to apply new speaker/output.");
        [self restart];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self->_isRestartingForDeviceChange = NO;
        });
    });
}
#endif // TARGET_OS_OSX

#pragma mark - Control Methods

// Should audio be running?
- (BOOL) _audioShouldBeRunning {
    __block id<MKAudioDelegate> delegate;
    dispatch_sync(_accessQueue, ^{
        delegate = _delegate;
    });
    
    if ([(id)delegate respondsToSelector:@selector(audioShouldBeRunning:)]) {
        return [delegate audioShouldBeRunning:self];
    }
    
#if TARGET_OS_IPHONE == 1
    return NO;
#else
    return YES;
#endif
}

- (BOOL) isRunning {
    return _running;
}

- (void) stop {
    dispatch_sync(_accessQueue, ^{
        for (NSValue *value in [_remoteTrackPreviewStates allValues]) {
            MKAudioPreviewGainProcessorState *state = (MKAudioPreviewGainProcessorState *)[value pointerValue];
            if (state != NULL) {
                free(state);
            }
        }
        [_remoteTrackPreviewStates removeAllObjects];
    });

    @synchronized(self) {
#if TARGET_OS_OSX == 1
        _lastDeviceWasVPIO = [_audioDevice isKindOfClass:[MKVoiceProcessingDevice class]];
#endif
        // Clear sidechain references before tearing down audio output
        [_inputTrackRackBridge setSidechainAudioOutput:nil];
        [_sidetoneRackBridge setSidechainAudioOutput:nil];
        [_remoteBusRackBridge setSidechainAudioOutput:nil];
        [_remoteBusRackBridge2 setSidechainAudioOutput:nil];
        for (NSNumber *sessionKey in _remoteTrackRackBridges) {
            MKAudioRemoteTrackRackBridge *bridge = [_remoteTrackRackBridges objectForKey:sessionKey];
            [bridge setSidechainAudioOutput:nil];
        }

        [_audioDevice setupInput:NULL];
        [_audioDevice setupOutput:NULL];
        [_audioInput release];
        _audioInput = nil;
        [_audioOutput release];
        _audioOutput = nil;
        [_audioDevice teardownDevice];
        [_audioDevice release];
        _audioDevice = nil;
        [_sidetoneOutput release];
        _sidetoneOutput = nil;
        os_unfair_lock_lock(&_sidechainInputLock);
        _sidechainInputReadPos = 0;
        _sidechainInputWritePos = 0;
        _sidechainInputBufferedFrames = 0;
        _sidechainInputPPChannels = 0;
        _sidechainInputPPSampleRate = 0;
        os_unfair_lock_unlock(&_sidechainInputLock);
        os_unfair_lock_lock(&_sidechainSidetoneLock);
        _sidechainSidetoneReadPos = 0;
        _sidechainSidetoneWritePos = 0;
        _sidechainSidetoneBufferedFrames = 0;
        _sidechainSidetonePPChannels = 0;
        _sidechainSidetonePPSampleRate = 0;
        os_unfair_lock_unlock(&_sidechainSidetoneLock);
        os_unfair_lock_lock(&_inputMonitorLock);
        _inputMonitorReadPos = 0;
        _inputMonitorWritePos = 0;
        _inputMonitorBufferedFrames = 0;
        _inputMonitorPPChannels = 0;
        _inputMonitorPPSampleRate = 0;
        os_unfair_lock_unlock(&_inputMonitorLock);
        _running = NO;
    }
    
#if TARGET_OS_IPHONE == 1
    [self resetAudioSessionToIdle];
#endif
}

- (void) start {
#if TARGET_OS_IPHONE == 1
    // ✅ 现代 API 激活 Session
    // 每次开始前，重新应用一次设置以确保 Option 正确（如扬声器设置）
    [self setupAudioSession];
    
    NSError *error = nil;
    [[AVAudioSession sharedInstance] setActive:YES error:&error];
    if (error) {
        MKLogError(Audio, @"MKAudio: Failed to activate AVAudioSession: %@", error);
        NSDictionary *info = @{@"message": [NSString stringWithFormat:@"Audio session activation failed: %@", error.localizedDescription]};
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:MKAudioErrorNotification object:nil userInfo:info];
        });
        return;
    }
#endif
    
    __block MKAudioSettings settingsSnapshot;
    __block MKConnection *connSnapshot = nil;
    dispatch_sync(_accessQueue, ^{
        memcpy(&settingsSnapshot, &_audioSettings, sizeof(MKAudioSettings));
        connSnapshot = [_connection retain];
    });
    MKAudioNormalizeSettings(&settingsSnapshot);
    
    @synchronized(self) {
        if (_running) {
#if TARGET_OS_OSX == 1
            _lastDeviceWasVPIO = [_audioDevice isKindOfClass:[MKVoiceProcessingDevice class]];
#endif
            [_audioDevice setupInput:NULL];
            [_audioDevice setupOutput:NULL];
            [_audioInput release];
            _audioInput = nil;
            [_audioOutput release];
            _audioOutput = nil;
            [_audioDevice teardownDevice];
            [_audioDevice release];
            _audioDevice = nil;
        }

#if TARGET_OS_IPHONE == 1
        if (settingsSnapshot.enableStereoInput) {
            _audioDevice = [[MKiOSAudioDevice alloc] initWithSettings:&settingsSnapshot];
        } else {
            _audioDevice = [[MKVoiceProcessingDevice alloc] initWithSettings:&settingsSnapshot];
        }
#elif TARGET_OS_OSX == 1
        {
            NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
            BOOL followSystem = YES;
            if ([defaults objectForKey:@"AudioFollowSystemInputDevice"] != nil) {
                followSystem = [defaults boolForKey:@"AudioFollowSystemInputDevice"];
            }
            BOOL useVPIO = followSystem
                        && !settingsSnapshot.enableStereoInput
                        && MKAudioSystemDefaultInputIsBuiltInOrBluetooth();
            if (useVPIO) {
                MKLogInfo(Audio, @"MKAudio: macOS using VPIO (follow-system, built-in/Bluetooth).");
                _audioDevice = [[MKVoiceProcessingDevice alloc] initWithSettings:&settingsSnapshot];
            } else {
                MKLogInfo(Audio, @"MKAudio: macOS using HALOutput.");
                _audioDevice = [[MKMacAudioDevice alloc] initWithSettings:&settingsSnapshot];
            }
        }
#else
# error Missing MKAudioDevice
#endif
        
        BOOL setupSuccess = [_audioDevice setupDevice];
#if TARGET_OS_OSX == 1
        if (!setupSuccess && ![_audioDevice isKindOfClass:[MKMacAudioDevice class]]) {
            MKLogWarning(Audio, @"MKAudio: VPIO setup failed on macOS, falling back to HALOutput.");
            [_audioDevice release];
            _audioDevice = [[MKMacAudioDevice alloc] initWithSettings:&settingsSnapshot];
            setupSuccess = [_audioDevice setupDevice];
        }
#endif
        if (!setupSuccess) {
            MKLogError(Audio, @"MKAudio: Failed to setup audio device.");
            [_audioDevice release];
            _audioDevice = nil;
            [connSnapshot release];
            NSDictionary *info = @{@"message": @"Failed to initialize audio device. Check microphone permissions."};
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:MKAudioErrorNotification object:nil userInfo:info];
            });
            return;
        }

        _audioInput = [[MKAudioInput alloc] initWithDevice:_audioDevice andSettings:&settingsSnapshot];
        [_audioInput setMainConnectionForAudio:connSnapshot];
        [_inputTrackRackBridge updateHostBufferFrames:_pluginHostBufferFrames];
        [_inputTrackRackBridge updatePreviewGain:_inputTrackPreviewState.gain enabled:_inputTrackPreviewState.enabled];
        [_inputTrackRackBridge updateSampleRate:MKAudioInputProcessingSampleRateForSettings(&settingsSnapshot)];
        [_audioInput setInputTrackProcessor:MKAudioInputRackBridgeProcess context:_inputTrackRackBridge];
        [_sidetoneRackBridge updateHostBufferFrames:_pluginHostBufferFrames];
        [_sidetoneRackBridge updatePreviewGain:1.0f enabled:NO];
        [_sidetoneRackBridge updateSampleRate:MKAudioInputProcessingSampleRateForSettings(&settingsSnapshot)];
        [_audioInput setSidetoneTrackProcessor:MKAudioInputRackBridgeProcess context:_sidetoneRackBridge];
        
        [_audioInput setSelfMuted:_cachedSelfMuted];
        [_audioInput setSuppressed:_cachedSuppressed];
        [_audioInput setMuted:_cachedMuted];
        
        _audioOutput = [[MKAudioOutput alloc] initWithDevice:_audioDevice andSettings:&settingsSnapshot];
        [_remoteBusRackBridge updateHostBufferFrames:_pluginHostBufferFrames];
        [_remoteBusRackBridge updatePreviewGain:_remoteBusPreviewState.gain enabled:_remoteBusPreviewState.enabled];
        [_remoteBusRackBridge updateSampleRate:[_audioOutput outputSampleRate]];
        [_audioOutput setRemoteBusProcessor:MKAudioRemoteBusRackBridgeProcess context:_remoteBusRackBridge];
        [_remoteBusRackBridge2 updateHostBufferFrames:_pluginHostBufferFrames];
        [_remoteBusRackBridge2 updatePreviewGain:_remoteBus2PreviewState.gain enabled:_remoteBus2PreviewState.enabled];
        [_remoteBusRackBridge2 updateSampleRate:[_audioOutput outputSampleRate]];
        [_audioOutput setRemoteBus2Processor:MKAudioRemoteBusRackBridgeProcess context:_remoteBusRackBridge2];

        // Wire sidechain buffer pool to all rack bridges
        [_inputTrackRackBridge setSidechainAudioOutput:_audioOutput];
        [_sidetoneRackBridge setSidechainAudioOutput:_audioOutput];
        [_remoteBusRackBridge setSidechainAudioOutput:_audioOutput];
        [_remoteBusRackBridge2 setSidechainAudioOutput:_audioOutput];

        [self rebindRemoteTrackProcessorsToOutputLocked];

        if (![_audioDevice startDevice]) {
            MKLogError(Audio, @"MKAudio: Failed to start audio device.");
            [_audioDevice setupInput:NULL];
            [_audioDevice setupOutput:NULL];
            [_audioOutput release];
            _audioOutput = nil;
            [_audioInput release];
            _audioInput = nil;
            [_audioDevice teardownDevice];
            [_audioDevice release];
            _audioDevice = nil;
            [connSnapshot release];
            NSDictionary *info = @{@"message": @"Failed to start audio device. Check microphone permissions."};
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:MKAudioErrorNotification object:nil userInfo:info];
            });
            return;
        }
        
        _running = YES;
    }
    
    [connSnapshot release];
}

- (void) restart {
    [self stop];
#if TARGET_OS_OSX == 1
    if (_lastDeviceWasVPIO) {
        _lastDeviceWasVPIO = NO;
        MKLogInfo(Audio, @"MKAudio: VPIO teardown detected, delaying start for pipeline release...");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(500 * NSEC_PER_MSEC)),
                       dispatch_get_main_queue(), ^{
            [self start];
            [[NSNotificationCenter defaultCenter] postNotificationName:MKAudioDidRestartNotification object:self];
        });
        return;
    }
#endif
    [self start];
    [[NSNotificationCenter defaultCenter] postNotificationName:MKAudioDidRestartNotification object:self];
}

#pragma mark - Properties & Accessors

- (MKAudioOutput *) output {
    __block MKAudioOutput *result;
    dispatch_sync(_accessQueue, ^{
        result = _audioOutput;
    });
    return result;
}

// P0 修复：使用 dispatch_async/sync 替代 @synchronized，提升性能
- (void) setDelegate:(id<MKAudioDelegate>)delegate {
    dispatch_async(_accessQueue, ^{
        _delegate = delegate;
    });
}

- (id<MKAudioDelegate>) delegate {
    __block id<MKAudioDelegate> delegate;
    dispatch_sync(_accessQueue, ^{
        delegate = _delegate;
    });
    return delegate;
}

- (void) readAudioSettings:(MKAudioSettings *)settings {
    if (settings == NULL) return;
    dispatch_sync(_accessQueue, ^{
        memcpy(settings, &_audioSettings, sizeof(MKAudioSettings));
    });
}

- (void) updateAudioSettings:(MKAudioSettings *)settings {
    if (settings == NULL) return;
    
    // 关键修复：避免异步 block 捕获调用方栈指针，导致设置结构体损坏。
    MKAudioSettings settingsCopy;
    memcpy(&settingsCopy, settings, sizeof(MKAudioSettings));
    MKAudioNormalizeSettings(&settingsCopy);
    
    dispatch_async(_accessQueue, ^{
        memcpy(&_audioSettings, &settingsCopy, sizeof(MKAudioSettings));
        [_audioInput setInputMonitorEnabled:settingsCopy.enableSideTone];
        if (_audioOutput != nil) {
            [_audioOutput setMasterVolume:settingsCopy.volume];
            [_audioOutput setInputMonitorEnabled:settingsCopy.enableSideTone gain:settingsCopy.sidetoneVolume];
        }
        if (!settingsCopy.enableSideTone) {
            [self writeInputMonitorSamples:NULL frameCount:0 channels:0 sampleRate:0];
        }
    });
    // 如果设置改变（如切换扬声器），可能需要刷新 Session 配置
    // 注意：这里没有自动 restart，调用者通常会在更新设置后手动 restart
}

- (void) setMainConnectionForAudio:(MKConnection *)conn {
    MKConnection *retainedConn = [conn retain];
    dispatch_async(_accessQueue, ^{
        [_audioInput setMainConnectionForAudio:retainedConn];
        [_connection release];
        _connection = retainedConn;
    });
}

- (void) addFrameToBufferWithSession:(NSUInteger)session data:(NSData *)data sequence:(NSUInteger)seq type:(MKUDPMessageType)msgType {
    dispatch_async(_accessQueue, ^{
        [_audioOutput addFrameToBufferWithSession:session data:data sequence:seq type:msgType];
    });
}

- (MKAudioOutputSidetone *) sidetoneOutput {
    __block MKAudioOutputSidetone *result;
    dispatch_sync(_accessQueue, ^{
        result = _sidetoneOutput;
    });
    return result;
}

- (MKTransmitType) transmitType {
    __block MKTransmitType result;
    dispatch_sync(_accessQueue, ^{
        result = _audioSettings.transmitType;
    });
    return result;
}

- (BOOL) forceTransmit {
    __block BOOL result;
    dispatch_sync(_accessQueue, ^{
        result = [_audioInput forceTransmit];
    });
    return result;
}

- (void) setForceTransmit:(BOOL)flag {
    dispatch_async(_accessQueue, ^{
        [_audioInput setForceTransmit:flag];
    });
}

- (float) speechProbablity {
    __block float result;
    dispatch_sync(_accessQueue, ^{
        result = [_audioInput speechProbability];
    });
    return result;
}

- (float) peakCleanMic {
    __block float result;
    dispatch_sync(_accessQueue, ^{
        result = [_audioInput peakCleanMic];
    });
    return result;
}

- (void) setSelfMuted:(BOOL)selfMuted {
    dispatch_async(_accessQueue, ^{
        _cachedSelfMuted = selfMuted;
        [_audioInput setSelfMuted:selfMuted];
    });
}

- (void) setSuppressed:(BOOL)suppressed {
    dispatch_async(_accessQueue, ^{
        _cachedSuppressed = suppressed;
        [_audioInput setSuppressed:suppressed];
    });
}

- (void) setMuted:(BOOL)muted {
    dispatch_async(_accessQueue, ^{
        _cachedMuted = muted;
        [_audioInput setMuted:muted];
    });
}

- (BOOL) echoCancellationAvailable {
#if TARGET_OS_IPHONE
    return YES;
#else
    {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        BOOL followSystem = YES;
        if ([defaults objectForKey:@"AudioFollowSystemInputDevice"] != nil) {
            followSystem = [defaults boolForKey:@"AudioFollowSystemInputDevice"];
        }
        return followSystem && MKAudioSystemDefaultInputIsBuiltInOrBluetooth();
    }
#endif
}

- (NSDictionary *) copyAudioOutputMixerDebugInfo {
    return [_audioOutput copyMixerInfo];
}

- (void)setPluginHostBufferFrames:(NSUInteger)frames {
    NSUInteger normalized = frames;
    switch (normalized) {
        case 64:
        case 128:
        case 256:
        case 512:
        case 1024:
        case 2048:
            break;
        default:
            normalized = 256;
            break;
    }

    dispatch_async(_accessQueue, ^{
        _pluginHostBufferFrames = normalized;
        [_inputTrackRackBridge updateHostBufferFrames:normalized];
        [_sidetoneRackBridge updateHostBufferFrames:normalized];
        [_remoteBusRackBridge updateHostBufferFrames:normalized];
        [_remoteBusRackBridge2 updateHostBufferFrames:normalized];
        for (MKAudioRemoteTrackRackBridge *bridge in [_remoteTrackRackBridges allValues]) {
            [bridge updateHostBufferFrames:normalized];
        }
    });
}

- (NSUInteger)pluginHostBufferFrames {
    __block NSUInteger result = 256;
    dispatch_sync(_accessQueue, ^{
        result = _pluginHostBufferFrames > 0 ? _pluginHostBufferFrames : 256;
    });
    return result;
}

- (NSUInteger)pluginSampleRateForTrackKey:(NSString *)trackKey {
    if (trackKey == nil) {
        trackKey = @"";
    }

    __block NSUInteger result = SAMPLE_RATE;
    dispatch_sync(_accessQueue, ^{
        if ([trackKey isEqualToString:@"input"]) {
            result = MKAudioInputProcessingSampleRateForSettings(&_audioSettings);
            return;
        }
        if ([trackKey isEqualToString:@"sidetone"]) {
            result = MKAudioInputProcessingSampleRateForSettings(&_audioSettings);
            return;
        }

        if (_audioOutput != nil) {
            NSUInteger outputSampleRate = [_audioOutput outputSampleRate];
            if (outputSampleRate > 0) {
                result = outputSampleRate;
                return;
            }
        }

        if (_audioDevice != nil) {
            int outputSampleRate = [_audioDevice outputSampleRate];
            if (outputSampleRate <= 0) {
                outputSampleRate = [_audioDevice inputSampleRate];
            }
            if (outputSampleRate > 0) {
                result = (NSUInteger)outputSampleRate;
            }
        }
    });
    return result;
}

- (NSDictionary *)copyInputTrackDSPStatus {
    __block NSDictionary *result = nil;
    dispatch_sync(_accessQueue, ^{
        result = [_inputTrackRackBridge copyStatus];
    });
    return result;
}

- (NSDictionary *)copyRemoteBusDSPStatus {
    __block NSDictionary *result = nil;
    dispatch_sync(_accessQueue, ^{
        result = [_remoteBusRackBridge copyStatus];
    });
    return result;
}

- (NSUInteger)currentOutputProcessingSampleRateLocked {
    NSUInteger sampleRate = SAMPLE_RATE;
    if (_audioOutput != nil) {
        NSUInteger outputSampleRate = [_audioOutput outputSampleRate];
        if (outputSampleRate > 0) {
            return outputSampleRate;
        }
    }

    if (_audioDevice != nil) {
        int outputSampleRate = [_audioDevice outputSampleRate];
        if (outputSampleRate <= 0) {
            outputSampleRate = [_audioDevice inputSampleRate];
        }
        if (outputSampleRate > 0) {
            sampleRate = (NSUInteger)outputSampleRate;
        }
    }
    return sampleRate;
}

- (MKAudioRemoteTrackRackBridge *)remoteTrackRackBridgeForSessionLocked:(NSUInteger)session createIfNeeded:(BOOL)create {
    NSNumber *sessionKey = [NSNumber numberWithUnsignedInteger:session];
    MKAudioRemoteTrackRackBridge *bridge = [_remoteTrackRackBridges objectForKey:sessionKey];
    if (bridge == nil && create) {
        bridge = [[MKAudioRemoteTrackRackBridge alloc] init];
        if (bridge == nil) {
            return nil;
        }
        [_remoteTrackRackBridges setObject:bridge forKey:sessionKey];
        [bridge release];
        bridge = [_remoteTrackRackBridges objectForKey:sessionKey];
        [bridge updateHostBufferFrames:_pluginHostBufferFrames];
        [bridge updateSampleRate:[self currentOutputProcessingSampleRateLocked]];

        NSValue *previewValue = [_remoteTrackPreviewStates objectForKey:sessionKey];
        if (previewValue != nil) {
            MKAudioPreviewGainProcessorState *previewState = (MKAudioPreviewGainProcessorState *)[previewValue pointerValue];
            if (previewState != NULL) {
                [bridge updatePreviewGain:previewState->gain enabled:previewState->enabled];
            }
        }
    }
    return bridge;
}

- (void)rebindRemoteTrackProcessorsToOutputLocked {
    if (_audioOutput == nil) {
        return;
    }

    [_audioOutput clearAllRemoteTrackProcessors];
    NSUInteger sampleRate = [self currentOutputProcessingSampleRateLocked];
    for (NSNumber *sessionKey in _remoteTrackRackBridges) {
        MKAudioRemoteTrackRackBridge *bridge = [_remoteTrackRackBridges objectForKey:sessionKey];
        if (bridge == nil) {
            continue;
        }
        [bridge updateHostBufferFrames:_pluginHostBufferFrames];
        [bridge updateSampleRate:sampleRate];
        [bridge setSidechainAudioOutput:_audioOutput];
        [_audioOutput setRemoteTrackProcessor:MKAudioRemoteTrackRackBridgeProcess
                                      context:bridge
                                   forSession:[sessionKey unsignedIntegerValue]];
    }
}

- (void) setInputTrackPreviewGain:(float)gain enabled:(BOOL)enabled {
    if (gain < 0.0f) {
        gain = 0.0f;
    }
    dispatch_async(_accessQueue, ^{
        _inputTrackPreviewState.gain = gain;
        _inputTrackPreviewState.enabled = enabled;
        [_inputTrackRackBridge updatePreviewGain:gain enabled:enabled];
    });
}

- (void) setRemoteBusPreviewGain:(float)gain enabled:(BOOL)enabled {
    if (gain < 0.0f) {
        gain = 0.0f;
    }
    dispatch_async(_accessQueue, ^{
        _remoteBusPreviewState.gain = gain;
        _remoteBusPreviewState.enabled = enabled;
        [_remoteBusRackBridge updatePreviewGain:gain enabled:enabled];
    });
}

- (void) setInputTrackAudioUnitChain:(NSArray *)audioUnits {
    dispatch_async(_accessQueue, ^{
        NSUInteger sampleRate = MKAudioInputProcessingSampleRateForSettings(&_audioSettings);
        [_inputTrackRackBridge updateSampleRate:sampleRate];
        // Set sidechain audio output reference for input track (captures mic signal for sidechain)
        if (self->_audioOutput != nil) {
            [_inputTrackRackBridge setSidechainAudioOutput:self->_audioOutput];
        }
        [_inputTrackRackBridge updateAudioUnitChain:audioUnits sampleRate:sampleRate];
    });
}

- (void) setInputTrackSendSourceKeys:(NSArray<NSString *> *)trackKeys {
    dispatch_async(_accessQueue, ^{
        [_inputTrackRackBridge setSendSourceKeys:trackKeys];
    });
}

- (void) setSidetoneAudioUnitChain:(NSArray *)audioUnits {
    dispatch_async(_accessQueue, ^{
        NSUInteger sampleRate = MKAudioInputProcessingSampleRateForSettings(&_audioSettings);
        [_sidetoneRackBridge updateSampleRate:sampleRate];
        if (self->_audioOutput != nil) {
            [_sidetoneRackBridge setSidechainAudioOutput:self->_audioOutput];
        }
        [_sidetoneRackBridge updateAudioUnitChain:audioUnits sampleRate:sampleRate];
    });
}

- (void) setSidetoneTrackSendSourceKeys:(NSArray<NSString *> *)trackKeys {
    dispatch_async(_accessQueue, ^{
        [_sidetoneRackBridge setSendSourceKeys:trackKeys];
    });
}

- (void) setRemoteBusAudioUnitChain:(NSArray *)audioUnits {
    dispatch_async(_accessQueue, ^{
        NSUInteger sampleRate = SAMPLE_RATE;
        if (_audioOutput != nil) {
            NSUInteger outputSampleRate = [_audioOutput outputSampleRate];
            if (outputSampleRate > 0) {
                sampleRate = outputSampleRate;
            }
        } else if (_audioDevice != nil) {
            int outputSampleRate = [_audioDevice outputSampleRate];
            if (outputSampleRate > 0) {
                sampleRate = (NSUInteger)outputSampleRate;
            }
        }
        // Set sidechain audio output reference for remote bus (captures mixed audio for sidechain)
        [_remoteBusRackBridge setSidechainAudioOutput:_audioOutput];
        [_remoteBusRackBridge updateAudioUnitChain:audioUnits sampleRate:sampleRate];
    });
}

- (void) setRemoteBusSendSourceKeys:(NSArray<NSString *> *)trackKeys {
    dispatch_async(_accessQueue, ^{
        [_remoteBusRackBridge setSendSourceKeys:trackKeys];
    });
}

- (void) setRemoteBus2AudioUnitChain:(NSArray *)audioUnits {
    dispatch_async(_accessQueue, ^{
        NSUInteger sampleRate = SAMPLE_RATE;
        if (_audioOutput != nil) {
            NSUInteger outputSampleRate = [_audioOutput outputSampleRate];
            if (outputSampleRate > 0) {
                sampleRate = outputSampleRate;
            }
        } else if (_audioDevice != nil) {
            int outputSampleRate = [_audioDevice outputSampleRate];
            if (outputSampleRate > 0) {
                sampleRate = (NSUInteger)outputSampleRate;
            }
        }
        // Set sidechain audio output reference for remote bus 2 (captures mixed audio for sidechain)
        [_remoteBusRackBridge2 setSidechainAudioOutput:_audioOutput];
        [_remoteBusRackBridge2 updateAudioUnitChain:audioUnits sampleRate:sampleRate];
    });
}

- (void) setRemoteBus2SendSourceKeys:(NSArray<NSString *> *)trackKeys {
    dispatch_async(_accessQueue, ^{
        [_remoteBusRackBridge2 setSendSourceKeys:trackKeys];
    });
}

- (void) setRemoteBus2PreviewGain:(float)gain enabled:(BOOL)enabled {
    if (gain < 0.0f) {
        gain = 0.0f;
    }
    dispatch_async(_accessQueue, ^{
        _remoteBus2PreviewState.gain = gain;
        _remoteBus2PreviewState.enabled = enabled;
        [_remoteBusRackBridge2 updatePreviewGain:gain enabled:enabled];
    });
}

- (void) setBusAssignment:(NSUInteger)busIndex forSession:(NSUInteger)session {
    dispatch_async(_accessQueue, ^{
        if (_audioOutput != nil) {
            [_audioOutput setBusAssignment:busIndex forSession:session];
        }
    });
}

- (NSUInteger) busAssignmentForSession:(NSUInteger)session {
    __block NSUInteger result = 0;
    dispatch_sync(_accessQueue, ^{
        if (_audioOutput != nil) {
            result = [_audioOutput busAssignmentForSession:session];
        }
    });
    return result;
}

- (void) setRemoteTrackUsesSendRouting:(BOOL)enabled forSession:(NSUInteger)session {
    dispatch_async(_accessQueue, ^{
        if (_audioOutput != nil) {
            [_audioOutput setUsesTrackSendRouting:enabled forSession:session];
        }
    });
}

- (void) setRemoteTrackSendBusMask:(NSUInteger)busMask forSession:(NSUInteger)session {
    dispatch_async(_accessQueue, ^{
        if (_audioOutput != nil) {
            [_audioOutput setTrackSendBusMask:busMask forSession:session];
        }
    });
}

- (void) setInputTrackSendBusMask:(NSUInteger)busMask {
    dispatch_async(_accessQueue, ^{
        if (_audioOutput != nil) {
            [_audioOutput setInputTrackSendBusMask:busMask];
        }
    });
}

- (void) setRemoteTrackPreviewGain:(float)gain enabled:(BOOL)enabled forSession:(NSUInteger)session {
    if (gain < 0.0f) {
        gain = 0.0f;
    }

    dispatch_async(_accessQueue, ^{
        NSNumber *sessionKey = [NSNumber numberWithUnsignedInteger:session];
        NSValue *stateValue = [_remoteTrackPreviewStates objectForKey:sessionKey];
        MKAudioPreviewGainProcessorState *state = NULL;
        if (stateValue != nil) {
            state = (MKAudioPreviewGainProcessorState *)[stateValue pointerValue];
        }
        if (state == NULL) {
            state = (MKAudioPreviewGainProcessorState *)calloc(1, sizeof(MKAudioPreviewGainProcessorState));
            if (state == NULL) {
                return;
            }
            [_remoteTrackPreviewStates setObject:[NSValue valueWithPointer:state] forKey:sessionKey];
        }

        state->gain = gain;
        state->enabled = enabled;

        MKAudioRemoteTrackRackBridge *bridge = [self remoteTrackRackBridgeForSessionLocked:session createIfNeeded:YES];
        [bridge updatePreviewGain:gain enabled:enabled];

        if (_audioOutput != nil) {
            [_audioOutput setRemoteTrackProcessor:MKAudioRemoteTrackRackBridgeProcess context:bridge forSession:session];
        }
    });
}

- (void) clearRemoteTrackPreviewForSession:(NSUInteger)session {
    dispatch_async(_accessQueue, ^{
        NSNumber *sessionKey = [NSNumber numberWithUnsignedInteger:session];
        NSValue *stateValue = [_remoteTrackPreviewStates objectForKey:sessionKey];
        if (stateValue != nil) {
            MKAudioPreviewGainProcessorState *state = (MKAudioPreviewGainProcessorState *)[stateValue pointerValue];
            if (state != NULL) {
                free(state);
            }
            [_remoteTrackPreviewStates removeObjectForKey:sessionKey];
        }
        MKAudioRemoteTrackRackBridge *bridge = [self remoteTrackRackBridgeForSessionLocked:session createIfNeeded:NO];
        [bridge updatePreviewGain:1.0f enabled:NO];

        if (_audioOutput != nil) {
            if (bridge != nil) {
                [_audioOutput setRemoteTrackProcessor:MKAudioRemoteTrackRackBridgeProcess context:bridge forSession:session];
            } else {
                [_audioOutput clearRemoteTrackProcessorForSession:session];
            }
        }
    });
}

- (void) clearAllRemoteTrackPreview {
    dispatch_async(_accessQueue, ^{
        for (NSValue *value in [_remoteTrackPreviewStates allValues]) {
            MKAudioPreviewGainProcessorState *state = (MKAudioPreviewGainProcessorState *)[value pointerValue];
            if (state != NULL) {
                free(state);
            }
        }
        [_remoteTrackPreviewStates removeAllObjects];
        for (MKAudioRemoteTrackRackBridge *bridge in [_remoteTrackRackBridges allValues]) {
            [bridge updatePreviewGain:1.0f enabled:NO];
        }

        [self rebindRemoteTrackProcessorsToOutputLocked];
    });
}

- (void) setRemoteTrackAudioUnitChain:(NSArray *)audioUnits forSession:(NSUInteger)session {
    MKLogInfo(Audio, @"setRemoteTrackAudioUnitChain: session=%lu count=%lu", (unsigned long)session, (unsigned long)[audioUnits count]);
    dispatch_async(_accessQueue, ^{
        MKLogInfo(Audio, @"setRemoteTrackAudioUnitChain [queue]: session=%lu starting...", (unsigned long)session);

        MKAudioRemoteTrackRackBridge *bridge = [self remoteTrackRackBridgeForSessionLocked:session createIfNeeded:YES];
        MKLogInfo(Audio, @"setRemoteTrackAudioUnitChain [queue]: session=%lu bridge=%p", (unsigned long)session, bridge);

        NSUInteger sampleRate = [self currentOutputProcessingSampleRateLocked];
        MKLogInfo(Audio, @"setRemoteTrackAudioUnitChain [queue]: session=%lu sampleRate=%lu", (unsigned long)session, (unsigned long)sampleRate);

        [bridge updateSampleRate:sampleRate];
        MKLogInfo(Audio, @"setRemoteTrackAudioUnitChain [queue]: session=%lu calling updateAudioUnitChain...", (unsigned long)session);

        if (_audioOutput != nil) {
            // Set sidechain audio output reference for this bridge (critical for sidechain routing)
            [bridge setSidechainAudioOutput:_audioOutput];
            MKLogInfo(Audio, @"setRemoteTrackAudioUnitChain [queue]: session=%lu set sidechain output", (unsigned long)session);
        }

        [bridge updateAudioUnitChain:audioUnits sampleRate:sampleRate];
        MKLogInfo(Audio, @"setRemoteTrackAudioUnitChain [queue]: session=%lu updateAudioUnitChain returned", (unsigned long)session);

        if (_audioOutput != nil) {
            [_audioOutput setRemoteTrackProcessor:MKAudioRemoteTrackRackBridgeProcess context:bridge forSession:session];
            MKLogInfo(Audio, @"setRemoteTrackAudioUnitChain [queue]: session=%lu registered processor", (unsigned long)session);
        } else {
            MKLogWarning(Audio, @"setRemoteTrackAudioUnitChain [queue]: session=%lu _audioOutput is nil", (unsigned long)session);
        }

        MKLogInfo(Audio, @"setRemoteTrackAudioUnitChain [queue]: session=%lu completed", (unsigned long)session);
    });
}

- (void) setRemoteTrackSendSourceKeys:(NSArray<NSString *> *)trackKeys forSession:(NSUInteger)session {
    dispatch_async(_accessQueue, ^{
        MKAudioRemoteTrackRackBridge *bridge = [self remoteTrackRackBridgeForSessionLocked:session createIfNeeded:YES];
        [bridge setSendSourceKeys:trackKeys];

        if (_audioOutput != nil) {
            [_audioOutput setRemoteTrackProcessor:MKAudioRemoteTrackRackBridgeProcess context:bridge forSession:session];
        }
    });
}

- (void) clearRemoteTrackAudioUnitChainForSession:(NSUInteger)session {
    dispatch_async(_accessQueue, ^{
        NSNumber *sessionKey = [NSNumber numberWithUnsignedInteger:session];
        MKAudioRemoteTrackRackBridge *bridge = [self remoteTrackRackBridgeForSessionLocked:session createIfNeeded:NO];
        if (bridge != nil) {
            [bridge updateAudioUnitChain:nil sampleRate:[self currentOutputProcessingSampleRateLocked]];
            NSValue *previewValue = [_remoteTrackPreviewStates objectForKey:sessionKey];
            MKAudioPreviewGainProcessorState *previewState = (MKAudioPreviewGainProcessorState *)[previewValue pointerValue];
            BOOL keepPreviewProcessor = previewState != NULL && previewState->enabled;
            if (keepPreviewProcessor) {
                [bridge updatePreviewGain:previewState->gain enabled:YES];
                if (_audioOutput != nil) {
                    [_audioOutput setRemoteTrackProcessor:MKAudioRemoteTrackRackBridgeProcess context:bridge forSession:session];
                }
            } else {
                [_remoteTrackRackBridges removeObjectForKey:sessionKey];
                if (_audioOutput != nil) {
                    [_audioOutput clearRemoteTrackProcessorForSession:session];
                }
            }
        }
    });
}

- (void) clearAllRemoteTrackAudioUnitChains {
    dispatch_async(_accessQueue, ^{
        NSUInteger sampleRate = [self currentOutputProcessingSampleRateLocked];
        NSArray *sessionKeys = [[_remoteTrackRackBridges allKeys] copy];
        for (NSNumber *sessionKey in sessionKeys) {
            MKAudioRemoteTrackRackBridge *bridge = [_remoteTrackRackBridges objectForKey:sessionKey];
            if (bridge == nil) {
                continue;
            }
            [bridge updateAudioUnitChain:nil sampleRate:sampleRate];
            NSValue *previewValue = [_remoteTrackPreviewStates objectForKey:sessionKey];
            MKAudioPreviewGainProcessorState *previewState = (MKAudioPreviewGainProcessorState *)[previewValue pointerValue];
            if (!(previewState != NULL && previewState->enabled)) {
                [_remoteTrackRackBridges removeObjectForKey:sessionKey];
            }
        }
        [sessionKeys release];

        if (_audioOutput != nil) {
            [self rebindRemoteTrackProcessorsToOutputLocked];
        }
    });
}

- (NSArray<NSNumber *> *) copyRemoteSessionOrder {
    __block NSArray *order = nil;
    dispatch_sync(_accessQueue, ^{
        if (_audioOutput != nil) {
            order = [_audioOutput copyRemoteSessionOrder];
        } else {
            order = [[NSArray alloc] init];
        }
    });
    return order;
}

- (NSDictionary *)copyDSPStatus:(NSUInteger)session {
    __block NSDictionary *status = nil;
    dispatch_sync(_accessQueue, ^{
        MKAudioRemoteTrackRackBridge *bridge = [self remoteTrackRackBridgeForSessionLocked:session createIfNeeded:NO];
        if (bridge != nil) {
            status = [bridge copyStatus];
        } else if (_audioOutput != nil) {
            status = [_audioOutput copyDSPStatusForSession:session];
        } else {
            status = [[NSDictionary alloc] init];
        }
    });
    return status;
}

#pragma mark - Sidechain FIFOs

- (void) writeSidechainInputSamples:(const float *)samples frameCount:(NSUInteger)frameCount channels:(NSUInteger)channels {
    os_unfair_lock_lock(&_sidechainInputLock);
    if (samples == NULL || frameCount == 0 || channels == 0 || channels > 2 || frameCount > MK_SIDECHAIN_MAX_FRAMES) {
        _sidechainInputReadPos = 0;
        _sidechainInputWritePos = 0;
        _sidechainInputBufferedFrames = 0;
        _sidechainInputPPChannels = 0;
        _sidechainInputPPSampleRate = 0;
        os_unfair_lock_unlock(&_sidechainInputLock);
        return;
    }

    if (_sidechainInputPPSampleRate != SAMPLE_RATE || _sidechainInputPPChannels != channels) {
        _sidechainInputReadPos = 0;
        _sidechainInputWritePos = 0;
        _sidechainInputBufferedFrames = 0;
    }

    if (frameCount > _sidechainInputRingCapacityFrames) {
        samples += (frameCount - _sidechainInputRingCapacityFrames) * channels;
        frameCount = _sidechainInputRingCapacityFrames;
    }

    NSUInteger availableSpace = _sidechainInputRingCapacityFrames - _sidechainInputBufferedFrames;
    if (frameCount > availableSpace) {
        NSUInteger framesToDrop = frameCount - availableSpace;
        _sidechainInputReadPos = (_sidechainInputReadPos + framesToDrop) % _sidechainInputRingCapacityFrames;
        _sidechainInputBufferedFrames -= framesToDrop;
    }

    NSUInteger framesUntilWrap = _sidechainInputRingCapacityFrames - _sidechainInputWritePos;
    NSUInteger firstChunk = MIN(frameCount, framesUntilWrap);
    memcpy(_sidechainInputRingBuffer + (_sidechainInputWritePos * channels),
           samples,
           firstChunk * channels * sizeof(float));
    if (firstChunk < frameCount) {
        memcpy(_sidechainInputRingBuffer,
               samples + (firstChunk * channels),
               (frameCount - firstChunk) * channels * sizeof(float));
    }

    _sidechainInputWritePos = (_sidechainInputWritePos + frameCount) % _sidechainInputRingCapacityFrames;
    _sidechainInputBufferedFrames += frameCount;
    _sidechainInputPPChannels = channels;
    _sidechainInputPPSampleRate = SAMPLE_RATE;
    os_unfair_lock_unlock(&_sidechainInputLock);
}

- (const float *) readSidechainInputBufferWithMaxFrameCount:(NSUInteger)maxFrameCount
                                              outFrameCount:(NSUInteger *)outFrameCount
                                                   channels:(NSUInteger *)outChannels {
    os_unfair_lock_lock(&_sidechainInputLock);
    if (maxFrameCount == 0 || _sidechainInputBufferedFrames == 0 || _sidechainInputPPSampleRate != SAMPLE_RATE || _sidechainInputPPChannels == 0) {
        os_unfair_lock_unlock(&_sidechainInputLock);
        return NULL;
    }

    NSUInteger channels = _sidechainInputPPChannels;
    NSUInteger framesToRead = MIN(maxFrameCount, _sidechainInputBufferedFrames);
    NSUInteger framesUntilWrap = _sidechainInputRingCapacityFrames - _sidechainInputReadPos;
    NSUInteger firstChunk = MIN(framesToRead, framesUntilWrap);
    memcpy(_sidechainInputReadBuffer,
           _sidechainInputRingBuffer + (_sidechainInputReadPos * channels),
           firstChunk * channels * sizeof(float));
    if (firstChunk < framesToRead) {
        memcpy(_sidechainInputReadBuffer + (firstChunk * channels),
               _sidechainInputRingBuffer,
               (framesToRead - firstChunk) * channels * sizeof(float));
    }

    _sidechainInputReadPos = (_sidechainInputReadPos + framesToRead) % _sidechainInputRingCapacityFrames;
    _sidechainInputBufferedFrames -= framesToRead;
    if (outFrameCount != NULL) {
        *outFrameCount = framesToRead;
    }
    if (outChannels != NULL) {
        *outChannels = channels;
    }
    os_unfair_lock_unlock(&_sidechainInputLock);
    return _sidechainInputReadBuffer;
}

- (void) writeSidetoneSidechainSamples:(const float *)samples frameCount:(NSUInteger)frameCount channels:(NSUInteger)channels {
    os_unfair_lock_lock(&_sidechainSidetoneLock);
    if (samples == NULL || frameCount == 0 || channels == 0 || channels > 2 || frameCount > MK_SIDECHAIN_MAX_FRAMES) {
        _sidechainSidetoneReadPos = 0;
        _sidechainSidetoneWritePos = 0;
        _sidechainSidetoneBufferedFrames = 0;
        _sidechainSidetonePPChannels = 0;
        _sidechainSidetonePPSampleRate = 0;
        os_unfair_lock_unlock(&_sidechainSidetoneLock);
        return;
    }

    if (_sidechainSidetonePPSampleRate != SAMPLE_RATE || _sidechainSidetonePPChannels != channels) {
        _sidechainSidetoneReadPos = 0;
        _sidechainSidetoneWritePos = 0;
        _sidechainSidetoneBufferedFrames = 0;
    }

    if (frameCount > _sidechainSidetoneRingCapacityFrames) {
        samples += (frameCount - _sidechainSidetoneRingCapacityFrames) * channels;
        frameCount = _sidechainSidetoneRingCapacityFrames;
    }

    NSUInteger availableSpace = _sidechainSidetoneRingCapacityFrames - _sidechainSidetoneBufferedFrames;
    if (frameCount > availableSpace) {
        NSUInteger framesToDrop = frameCount - availableSpace;
        _sidechainSidetoneReadPos = (_sidechainSidetoneReadPos + framesToDrop) % _sidechainSidetoneRingCapacityFrames;
        _sidechainSidetoneBufferedFrames -= framesToDrop;
    }

    NSUInteger framesUntilWrap = _sidechainSidetoneRingCapacityFrames - _sidechainSidetoneWritePos;
    NSUInteger firstChunk = MIN(frameCount, framesUntilWrap);
    memcpy(_sidechainSidetoneRingBuffer + (_sidechainSidetoneWritePos * channels),
           samples,
           firstChunk * channels * sizeof(float));
    if (firstChunk < frameCount) {
        memcpy(_sidechainSidetoneRingBuffer,
               samples + (firstChunk * channels),
               (frameCount - firstChunk) * channels * sizeof(float));
    }

    _sidechainSidetoneWritePos = (_sidechainSidetoneWritePos + frameCount) % _sidechainSidetoneRingCapacityFrames;
    _sidechainSidetoneBufferedFrames += frameCount;
    _sidechainSidetonePPChannels = channels;
    _sidechainSidetonePPSampleRate = SAMPLE_RATE;
    os_unfair_lock_unlock(&_sidechainSidetoneLock);
}

- (const float *) readSidetoneSidechainBufferWithMaxFrameCount:(NSUInteger)maxFrameCount
                                                 outFrameCount:(NSUInteger *)outFrameCount
                                                      channels:(NSUInteger *)outChannels {
    os_unfair_lock_lock(&_sidechainSidetoneLock);
    if (maxFrameCount == 0 || _sidechainSidetoneBufferedFrames == 0 || _sidechainSidetonePPSampleRate != SAMPLE_RATE || _sidechainSidetonePPChannels == 0) {
        os_unfair_lock_unlock(&_sidechainSidetoneLock);
        return NULL;
    }

    NSUInteger channels = _sidechainSidetonePPChannels;
    NSUInteger framesToRead = MIN(maxFrameCount, _sidechainSidetoneBufferedFrames);
    NSUInteger framesUntilWrap = _sidechainSidetoneRingCapacityFrames - _sidechainSidetoneReadPos;
    NSUInteger firstChunk = MIN(framesToRead, framesUntilWrap);
    memcpy(_sidechainSidetoneReadBuffer,
           _sidechainSidetoneRingBuffer + (_sidechainSidetoneReadPos * channels),
           firstChunk * channels * sizeof(float));
    if (firstChunk < framesToRead) {
        memcpy(_sidechainSidetoneReadBuffer + (firstChunk * channels),
               _sidechainSidetoneRingBuffer,
               (framesToRead - firstChunk) * channels * sizeof(float));
    }

    _sidechainSidetoneReadPos = (_sidechainSidetoneReadPos + framesToRead) % _sidechainSidetoneRingCapacityFrames;
    _sidechainSidetoneBufferedFrames -= framesToRead;
    if (outFrameCount != NULL) {
        *outFrameCount = framesToRead;
    }
    if (outChannels != NULL) {
        *outChannels = channels;
    }
    os_unfair_lock_unlock(&_sidechainSidetoneLock);
    return _sidechainSidetoneReadBuffer;
}

- (void) writeInputMonitorSamples:(const float *)samples frameCount:(NSUInteger)frameCount channels:(NSUInteger)channels sampleRate:(NSUInteger)sampleRate {
    os_unfair_lock_lock(&_inputMonitorLock);
    if (samples == NULL || frameCount == 0 || channels == 0 || channels > 2 || frameCount > MK_SIDECHAIN_MAX_FRAMES || sampleRate != SAMPLE_RATE) {
        _inputMonitorReadPos = 0;
        _inputMonitorWritePos = 0;
        _inputMonitorBufferedFrames = 0;
        _inputMonitorPPChannels = 0;
        _inputMonitorPPSampleRate = sampleRate;
        os_unfair_lock_unlock(&_inputMonitorLock);
        return;
    }

    if (_inputMonitorPPSampleRate != sampleRate || _inputMonitorPPChannels != channels) {
        _inputMonitorReadPos = 0;
        _inputMonitorWritePos = 0;
        _inputMonitorBufferedFrames = 0;
    }

    if (frameCount > _inputMonitorRingCapacityFrames) {
        samples += (frameCount - _inputMonitorRingCapacityFrames) * channels;
        frameCount = _inputMonitorRingCapacityFrames;
    }

    NSUInteger availableSpace = _inputMonitorRingCapacityFrames - _inputMonitorBufferedFrames;
    if (frameCount > availableSpace) {
        NSUInteger framesToDrop = frameCount - availableSpace;
        _inputMonitorReadPos = (_inputMonitorReadPos + framesToDrop) % _inputMonitorRingCapacityFrames;
        _inputMonitorBufferedFrames -= framesToDrop;
    }

    NSUInteger framesUntilWrap = _inputMonitorRingCapacityFrames - _inputMonitorWritePos;
    NSUInteger firstChunk = MIN(frameCount, framesUntilWrap);
    memcpy(_inputMonitorRingBuffer + (_inputMonitorWritePos * channels),
           samples,
           firstChunk * channels * sizeof(float));
    if (firstChunk < frameCount) {
        memcpy(_inputMonitorRingBuffer,
               samples + (firstChunk * channels),
               (frameCount - firstChunk) * channels * sizeof(float));
    }

    _inputMonitorWritePos = (_inputMonitorWritePos + frameCount) % _inputMonitorRingCapacityFrames;
    _inputMonitorBufferedFrames += frameCount;
    _inputMonitorPPChannels = channels;
    _inputMonitorPPSampleRate = sampleRate;
    os_unfair_lock_unlock(&_inputMonitorLock);
}

- (const float *) readInputMonitorBufferWithMaxFrameCount:(NSUInteger)maxFrameCount
                                           outFrameCount:(NSUInteger *)outFrameCount
                                                channels:(NSUInteger *)outChannels {
    os_unfair_lock_lock(&_inputMonitorLock);
    if (maxFrameCount == 0 || _inputMonitorBufferedFrames < maxFrameCount || _inputMonitorPPSampleRate != SAMPLE_RATE || _inputMonitorPPChannels == 0) {
        os_unfair_lock_unlock(&_inputMonitorLock);
        return NULL;
    }

    NSUInteger channels = _inputMonitorPPChannels;
    NSUInteger framesUntilWrap = _inputMonitorRingCapacityFrames - _inputMonitorReadPos;
    NSUInteger firstChunk = MIN(maxFrameCount, framesUntilWrap);
    memcpy(_inputMonitorReadBuffer,
           _inputMonitorRingBuffer + (_inputMonitorReadPos * channels),
           firstChunk * channels * sizeof(float));
    if (firstChunk < maxFrameCount) {
        memcpy(_inputMonitorReadBuffer + (firstChunk * channels),
               _inputMonitorRingBuffer,
               (maxFrameCount - firstChunk) * channels * sizeof(float));
    }

    _inputMonitorReadPos = (_inputMonitorReadPos + maxFrameCount) % _inputMonitorRingCapacityFrames;
    _inputMonitorBufferedFrames -= maxFrameCount;
    if (outFrameCount != NULL) {
        *outFrameCount = maxFrameCount;
    }
    if (outChannels != NULL) {
        *outChannels = channels;
    }
    os_unfair_lock_unlock(&_inputMonitorLock);
    return _inputMonitorReadBuffer;
}

@end
