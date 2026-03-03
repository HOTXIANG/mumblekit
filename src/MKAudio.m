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
#import "MKAudioOutput.h"
#import "MKAudioOutputSidetone.h"
#import <MumbleKit/MKConnection.h>

#import <AVFoundation/AVFoundation.h> // ✅ 必须引入

#if TARGET_OS_IPHONE == 1
# import "MKVoiceProcessingDevice.h"
# import "MKiOSAudioDevice.h"
#elif TARGET_OS_OSX == 1
# import "MKVoiceProcessingDevice.h"
# import "MKMacAudioDevice.h"
#endif

#import <AudioUnit/AudioUnit.h>
#import <AudioUnit/AUComponent.h>
#import <AudioToolbox/AudioToolbox.h>
#if TARGET_OS_OSX == 1
#import <CoreAudio/CoreAudio.h>
#endif

#if TARGET_OS_IPHONE || TARGET_IPHONE_SIMULATOR
#import <UIKit/UIKit.h>
#endif

NSString *MKAudioDidRestartNotification = @"MKAudioDidRestartNotification";
NSString *MKAudioErrorNotification = @"MKAudioErrorNotification";
#if TARGET_OS_OSX == 1
static NSString *const MUMacAudioInputDevicesChangedNotification = @"MUMacAudioInputDevicesChanged";
static NSString *const MUMacAudioVPIOToHALTransitionNotification = @"MUMacAudioVPIOToHALTransition";
#endif

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
#if TARGET_OS_OSX == 1
    BOOL                     _isObservingDefaultInputDevice;
    CFAbsoluteTime           _lastDefaultInputSwitchTime;
    CFAbsoluteTime           _lastDefaultOutputSwitchTime;
    BOOL                     _isRestartingForDeviceChange;
    BOOL                     _lastDeviceWasVPIO;
#endif
    
    // P0 修复：使用串行队列替代 @synchronized，提升性能
    dispatch_queue_t         _accessQueue;
}
#if TARGET_OS_OSX == 1
- (void)startObservingDefaultInputDeviceChanges;
- (void)stopObservingDefaultInputDeviceChanges;
- (void)handleDefaultInputDeviceChanged;
- (void)handleDefaultOutputDeviceChanged;
#endif
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

@implementation MKAudio

#pragma mark - Singleton & Init

+ (MKAudio *) sharedAudio {
    static dispatch_once_t pred;
    static MKAudio *audio;

    dispatch_once(&pred, ^{
        audio = [[MKAudio alloc] init];
        [audio setupAudioSession]; // ✅ 初始化现代音频会话
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
        NSLog(@"MKAudio: Failed to set session category: %@", error.localizedDescription);
    }

    // 3. 设置硬件采样率 (推荐 48kHz)
    [session setPreferredSampleRate:48000.0 error:nil];
    
    // 4. 设置 I/O Buffer (低延迟设置，0.02s = 20ms)
    [session setPreferredIOBufferDuration:0.02 error:nil];
#endif
}

- (void)updateAudioSessionSettings {
    // 当设置改变时（例如用户切换了扬声器/听筒偏好），重新应用配置
    [self setupAudioSession];
}

#pragma mark - Notification Handlers

#if TARGET_OS_IOS
- (void)handleInterruption:(NSNotification *)notification {
    NSDictionary *userInfo = notification.userInfo;
    AVAudioSessionInterruptionType type = [userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];

    if (type == AVAudioSessionInterruptionTypeBegan) {
        NSLog(@"MKAudio: Interruption BEGAN (Phone call etc.)");
        [self stop];
    } else if (type == AVAudioSessionInterruptionTypeEnded) {
        NSLog(@"MKAudio: Interruption ENDED. Restarting audio engine...");
        // 不再依赖 ShouldResume 标志位。电话挂断后该标志经常不被设置，
        // 导致音频引擎永远无法恢复。只要中断结束且连接仍然活跃，就无条件重启。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self setupAudioSession];
            NSError *error = nil;
            [[AVAudioSession sharedInstance] setActive:YES withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&error];
            if (error) {
                NSLog(@"MKAudio: Failed to reactivate session after interruption: %@", error);
            }
            [self restart];
        });
    }
}

- (void)handleRouteChange:(NSNotification *)notification {
    NSDictionary *userInfo = notification.userInfo;
    AVAudioSessionRouteChangeReason reason = [userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];
    
    NSLog(@"MKAudio: Route Changed. Reason: %lu", (unsigned long)reason);
    
    // 以下情况通常不需要重启：
    // kAudioSessionRouteChangeReasonOverride (我们自己代码改的)
    // kAudioSessionRouteChangeReasonCategoryChange (Category 改变)
    
    switch (reason) {
        case AVAudioSessionRouteChangeReasonNewDeviceAvailable: // 插入耳机
        case AVAudioSessionRouteChangeReasonOldDeviceUnavailable: // 拔出耳机
            // 只有音频引擎已经在运行时才重启，避免在未连接服务器时激活麦克风
            if (_running) {
                NSLog(@"MKAudio: Restarting audio due to device change.");
                [self restart];
            }
            break;
        default:
            break;
    }
}

- (void)handleMediaServicesReset:(NSNotification *)notification {
    NSLog(@"MKAudio: Media Services Reset (Audio daemon crashed). Re-initializing.");
    // 彻底重置
    [self stop];
    [self setupAudioSession];
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
        NSLog(@"MKAudio: Failed to observe default input device changes (%d).", (int)err);
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
        NSLog(@"MKAudio: Failed to observe device list changes (%d).", (int)devicesErr);
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
        NSLog(@"MKAudio: Failed to observe default output device changes (%d).", (int)outputErr);
        return;
    }
    
    _isObservingDefaultInputDevice = YES;
    NSLog(@"MKAudio: Observing default input/output and device list changes.");
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
        NSLog(@"MKAudio: Failed to remove default input device observer (%d).", (int)err);
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
        NSLog(@"MKAudio: Failed to remove device list observer (%d).", (int)devicesErr);
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
        NSLog(@"MKAudio: Failed to remove default output device observer (%d).", (int)outputErr);
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
            NSLog(@"MKAudio: Preferred input device missing. Auto-fallback to follow system default.");
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
        NSLog(@"MKAudio: Default input device changed. Restarting audio to apply new microphone.");
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
        NSLog(@"MKAudio: Default output device changed. Restarting audio to apply new speaker/output.");
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
    return [[UIApplication sharedApplication] applicationState] == UIApplicationStateActive;
#else
    return YES;
#endif
}

- (BOOL) isRunning {
    return _running;
}

- (void) stop {
    @synchronized(self) {
#if TARGET_OS_OSX == 1
        _lastDeviceWasVPIO = [_audioDevice isKindOfClass:[MKVoiceProcessingDevice class]];
#endif
        [_audioInput release];
        _audioInput = nil;
        [_audioOutput release];
        _audioOutput = nil;
        [_audioDevice teardownDevice];
        [_audioDevice release];
        _audioDevice = nil;
        [_sidetoneOutput release];
        _sidetoneOutput = nil;
        _running = NO;
    }
    
#if TARGET_OS_IPHONE == 1
    // ✅ 现代 API 关闭 Session
    [[AVAudioSession sharedInstance] setActive:NO error:nil];
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
        NSLog(@"MKAudio: Failed to activate AVAudioSession: %@", error);
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
                NSLog(@"MKAudio: macOS using VPIO (follow-system, built-in/Bluetooth).");
                _audioDevice = [[MKVoiceProcessingDevice alloc] initWithSettings:&settingsSnapshot];
            } else {
                NSLog(@"MKAudio: macOS using HALOutput.");
                _audioDevice = [[MKMacAudioDevice alloc] initWithSettings:&settingsSnapshot];
            }
        }
#else
# error Missing MKAudioDevice
#endif
        
        BOOL setupSuccess = [_audioDevice setupDevice];
#if TARGET_OS_OSX == 1
        if (!setupSuccess && ![_audioDevice isKindOfClass:[MKMacAudioDevice class]]) {
            NSLog(@"MKAudio: VPIO setup failed on macOS, falling back to HALOutput.");
            [_audioDevice release];
            _audioDevice = [[MKMacAudioDevice alloc] initWithSettings:&settingsSnapshot];
            setupSuccess = [_audioDevice setupDevice];
        }
#endif
        if (!setupSuccess) {
            NSLog(@"MKAudio: Failed to setup audio device.");
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
        
        [_audioInput setSelfMuted:_cachedSelfMuted];
        [_audioInput setSuppressed:_cachedSuppressed];
        [_audioInput setMuted:_cachedMuted];
        
        _audioOutput = [[MKAudioOutput alloc] initWithDevice:_audioDevice andSettings:&settingsSnapshot];
        
        if (settingsSnapshot.enableSideTone) {
            _sidetoneOutput = [[MKAudioOutputSidetone alloc] initWithSettings:&settingsSnapshot];
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
        NSLog(@"MKAudio: VPIO teardown detected, delaying start for pipeline release...");
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
        if (_audioOutput != nil) {
            [_audioOutput setMasterVolume:settingsCopy.volume];
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

@end
