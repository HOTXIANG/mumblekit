// Copyright 2012 The MumbleKit Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import <TargetConditionals.h>
#if TARGET_OS_OSX

#import <MumbleKit/MKAudio.h>
#import "MKAudioDevice.h"

#import "MKMacAudioDevice.h"
#import "MKAudioPerfStats.h"
#import "../../Source/Classes/SwiftUI/Core/MumbleLogger.h"

#import <AudioUnit/AudioUnit.h>
#import <AudioUnit/AUComponent.h>
#import <AudioToolbox/AudioToolbox.h>

@interface MKMacAudioDevice () {
@public
    MKAudioSettings              _settings;

    AudioUnit                    _playbackAudioUnit;
    int                          _playbackFrequency;
    int                          _playbackChannels;
    int                          _playbackSampleSize;

    AudioQueueRef                _recordQueue;
    AudioQueueBufferRef          _recordQueueBuffers[3];
    AudioBufferList              _recordBufList;
    int                          _recordFrequency;
    int                          _recordSampleSize;
    int                          _recordMicChannels;

    MKAudioDeviceOutputFunc      _outputFunc;
    MKAudioDeviceInputFunc       _inputFunc;
}
@end

static MKAudioPerfStats sInputPerfStats;
static MKAudioPerfStats sOutputPerfStats;

static void MKAudioPerfLogAndReset(NSString *label, MKAudioPerfStats *stats) {
    if (stats->sampledCount == 0) {
        return;
    }

    MKLogVerbose(Audio, @"PERF audio_callback %@ callbacks=%llu sampled=%llu avg_us=%llu p95_us=%llu p99_us=%llu max_us=%llu",
          label,
          stats->callbackCount,
          stats->sampledCount,
          MKAudioPerfAverageUs(stats),
          MKAudioPerfPercentileUs(stats, 95, 100),
          MKAudioPerfPercentileUs(stats, 99, 100),
          MKAudioPerfMaxUs(stats));
    MKAudioPerfReset(stats);
}

static BOOL MUAudioDeviceHasInputStreams(AudioDeviceID devId) {
    AudioObjectPropertyAddress addr;
    addr.mSelector = kAudioDevicePropertyStreams;
    addr.mScope = kAudioDevicePropertyScopeInput;
    addr.mElement = kAudioObjectPropertyElementMain;
    
    UInt32 size = 0;
    OSStatus err = AudioObjectGetPropertyDataSize(devId, &addr, 0, NULL, &size);
    return (err == noErr && size > 0);
}

static NSString *MUCopyAudioDeviceUID(AudioDeviceID devId) {
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

static NSString *MUCopyAudioDeviceName(AudioDeviceID devId) {
    AudioObjectPropertyAddress addr;
    addr.mSelector = kAudioObjectPropertyName;
    addr.mScope = kAudioObjectPropertyScopeGlobal;
    addr.mElement = kAudioObjectPropertyElementMain;
    
    CFStringRef nameRef = NULL;
    UInt32 size = sizeof(CFStringRef);
    OSStatus err = AudioObjectGetPropertyData(devId, &addr, 0, NULL, &size, &nameRef);
    if (err != noErr || nameRef == NULL) {
        return nil;
    }
    NSString *name = [(__bridge NSString *)nameRef copy];
    CFRelease(nameRef);
    return [name autorelease];
}

static int MUInputChannelCount(AudioDeviceID devId) {
    AudioObjectPropertyAddress addr;
    addr.mSelector = kAudioDevicePropertyStreamConfiguration;
    addr.mScope = kAudioDevicePropertyScopeInput;
    addr.mElement = kAudioObjectPropertyElementMain;

    UInt32 size = 0;
    OSStatus err = AudioObjectGetPropertyDataSize(devId, &addr, 0, NULL, &size);
    if (err != noErr || size < offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer)) {
        return 1;
    }

    AudioBufferList *bufferList = (AudioBufferList *)calloc(1, size);
    if (bufferList == NULL) {
        return 1;
    }

    err = AudioObjectGetPropertyData(devId, &addr, 0, NULL, &size, bufferList);
    if (err != noErr) {
        free(bufferList);
        return 1;
    }

    UInt32 channels = 0;
    for (UInt32 i = 0; i < bufferList->mNumberBuffers; i++) {
        channels += bufferList->mBuffers[i].mNumberChannels;
    }
    free(bufferList);

    return (int)MAX((UInt32)1, channels);
}

static Float64 MUNominalSampleRate(AudioDeviceID devId) {
    AudioObjectPropertyAddress addr;
    addr.mSelector = kAudioDevicePropertyNominalSampleRate;
    addr.mScope = kAudioObjectPropertyScopeGlobal;
    addr.mElement = kAudioObjectPropertyElementMain;

    Float64 sampleRate = 48000.0;
    UInt32 size = sizeof(Float64);
    OSStatus err = AudioObjectGetPropertyData(devId, &addr, 0, NULL, &size, &sampleRate);
    if (err != noErr || sampleRate <= 0.0) {
        return 48000.0;
    }
    return sampleRate;
}

static UInt32 MUAudioQueueInputBufferByteSize(int sampleRate, int channels) {
    int framesPerBuffer = MAX(256, sampleRate / 50);
    return (UInt32)(framesPerBuffer * MAX(1, channels) * sizeof(short));
}

static BOOL MUFindInputDeviceByUID(NSString *uid, AudioDeviceID *outDevId) {
    if (uid == nil || [uid length] == 0 || outDevId == NULL) return NO;
    
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
        if (!MUAudioDeviceHasInputStreams(candidate)) continue;
        NSString *candidateUID = MUCopyAudioDeviceUID(candidate);
        if (candidateUID && [candidateUID isEqualToString:uid]) {
            *outDevId = candidate;
            found = YES;
            break;
        }
    }
    
    free(devIds);
    return found;
}

static OSStatus outputCallback(void *udata, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                               UInt32 busnum, UInt32 nframes, AudioBufferList *buflist) {
    
    MKMacAudioDevice *dev = (MKMacAudioDevice *) udata;
    AudioBuffer *buf = buflist->mBuffers;
    MKAudioDeviceOutputFunc outputFunc = dev->_outputFunc;
    BOOL done;
    bool shouldSample = MKAudioPerfShouldSample(&sOutputPerfStats);
    uint64_t startTicks = shouldSample ? MKAudioPerfNowTicks() : 0;
    
    if (outputFunc == NULL) {
        // No frames available yet.
        buf->mDataByteSize = 0;
        return -1;
    }
    
    // P0 修复：验证音频缓冲区指针有效性，防止 EXC_BAD_ACCESS
    if (buf->mData == NULL || buf->mDataByteSize == 0) {
        MKLogWarning(Audio, @"MKMacAudioDevice: outputCallback received invalid buffer (data=%p, size=%u). Skipping.",
              buf->mData, (unsigned int)buf->mDataByteSize);
        buf->mDataByteSize = 0;
        return -1;
    }
    
    // 额外检查：确保数据指针是合理的内存地址（不是明显的无效地址）
    // 0x400000000 以上的地址通常是无效的（在 macOS 用户空间）
    uintptr_t dataPtr = (uintptr_t)buf->mData;
    if (dataPtr < 0x1000 || (dataPtr & 0x7) != 0) {
        // 指针未对齐或明显无效
        MKLogWarning(Audio, @"MKMacAudioDevice: outputCallback received suspicious buffer pointer %p. Skipping.",
              buf->mData);
        buf->mDataByteSize = 0;
        return -1;
    }
    
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    @try {
        done = outputFunc(buf->mData, nframes);
    } @catch (NSException *exception) {
        MKLogError(Audio, @"MKMacAudioDevice: outputFunc threw exception: %@. Audio playback interrupted.", exception);
        done = NO;
    } @finally {
        if (! done) {
            // No frames available yet.
            buf->mDataByteSize = 0;
        }
        [pool release];
    }

    if (shouldSample) {
        MKAudioPerfRecordTicks(&sOutputPerfStats, MKAudioPerfNowTicks() - startTicks);
    }
    
    return done ? noErr : -1;
}

static void inputQueueCallback(void *udata,
                               AudioQueueRef queue,
                               AudioQueueBufferRef buffer,
                               const AudioTimeStamp *startTime,
                               UInt32 numPackets,
                               const AudioStreamPacketDescription *packetDescriptions) {
    (void)startTime;
    (void)packetDescriptions;

    MKMacAudioDevice *dev = (MKMacAudioDevice *)udata;
    if (dev == nil || dev->_recordQueue != queue || buffer == NULL) {
        return;
    }

    UInt32 frames = numPackets;
    if (frames == 0 && dev->_recordSampleSize > 0) {
        frames = buffer->mAudioDataByteSize / dev->_recordSampleSize;
    }

    bool shouldSample = MKAudioPerfShouldSample(&sInputPerfStats);
    uint64_t startTicks = shouldSample ? MKAudioPerfNowTicks() : 0;

    if (frames > 0 && buffer->mAudioData != NULL && buffer->mAudioDataByteSize >= frames * dev->_recordSampleSize) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        @try {
            MKAudioDeviceInputFunc inputFunc = dev->_inputFunc;
            if (inputFunc) {
                inputFunc((short *)buffer->mAudioData, frames);
            }
        } @catch (NSException *exception) {
            MKLogError(Audio, @"MKMacAudioDevice: inputFunc threw exception: %@. Audio recording interrupted.", exception);
        } @finally {
            [pool release];
        }
    }

    if (shouldSample) {
        MKAudioPerfRecordTicks(&sInputPerfStats, MKAudioPerfNowTicks() - startTicks);
    }

    if (dev->_recordQueue == queue) {
        OSStatus err = AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
        if (err != noErr) {
            MKLogWarning(Audio, @"MKMacAudioDevice: unable to re-enqueue input buffer (err=%d).", (int)err);
        }
    }
}

@implementation MKMacAudioDevice

- (id) initWithSettings:(MKAudioSettings *)settings {
    if ((self = [super init])) {
        memcpy(&_settings, settings, sizeof(MKAudioSettings));
    }
    return self;
}

- (void) dealloc {
    [_inputFunc release];
    [_outputFunc release];
    [super dealloc];
}

- (BOOL) setupRecording {
    UInt32 len;
    OSStatus err;
    AudioStreamBasicDescription fmt;
    AudioDeviceID devId;
    
    // 先取系统默认输入设备（使用 AudioObject API，避免已废弃的 AudioHardwareGetProperty）
    AudioObjectPropertyAddress defaultInputAddr;
    defaultInputAddr.mSelector = kAudioHardwarePropertyDefaultInputDevice;
    defaultInputAddr.mScope = kAudioObjectPropertyScopeGlobal;
    defaultInputAddr.mElement = kAudioObjectPropertyElementMain;
    len = sizeof(AudioDeviceID);
    err = AudioObjectGetPropertyData(kAudioObjectSystemObject, &defaultInputAddr, 0, NULL, &len, &devId);
    if (err != noErr) {
        MKLogError(Audio, @"MKMacAudioDevice: Unable to query for default device.");
        return NO;
    }
    
    // 根据用户设置决定是否跟随系统，或固定到指定麦克风 UID
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL followSystem = YES;
    if ([defaults objectForKey:@"AudioFollowSystemInputDevice"] != nil) {
        followSystem = [defaults boolForKey:@"AudioFollowSystemInputDevice"];
    }
    if (!followSystem) {
        NSString *preferredUID = [[defaults stringForKey:@"AudioPreferredInputDeviceUID"]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (preferredUID && [preferredUID length] > 0) {
            AudioDeviceID preferredDevId = 0;
            if (MUFindInputDeviceByUID(preferredUID, &preferredDevId)) {
                devId = preferredDevId;
            } else {
                MKLogWarning(Audio, @"MKMacAudioDevice: Preferred input device UID not found. Falling back to system default.");
                [defaults setBool:YES forKey:@"AudioFollowSystemInputDevice"];
                [defaults setObject:@"" forKey:@"AudioPreferredInputDeviceUID"];
            }
        } else {
            [defaults setBool:YES forKey:@"AudioFollowSystemInputDevice"];
            [defaults setObject:@"" forKey:@"AudioPreferredInputDeviceUID"];
        }
    }
    
    NSString *selectedName = MUCopyAudioDeviceName(devId);
    NSString *selectedUID = MUCopyAudioDeviceUID(devId);
    MKLogInfo(Audio, @"MKMacAudioDevice: Using input device: %@ (%@)", selectedName ?: @"Unknown", selectedUID ?: @"No UID");

    _recordFrequency = (int)MUNominalSampleRate(devId);
    int hardwareInputChannels = MUInputChannelCount(devId);
    BOOL captureAllInputChannels = [defaults boolForKey:@"AudioCaptureAllInputChannels"];
    BOOL stereoInputEnabled = captureAllInputChannels && _settings.enableStereoInput;
    NSInteger configuredInputChannel = [defaults integerForKey:@"AudioSelectedInputChannel"];
    int selectedInputChannel = (int)MAX((NSInteger)1, configuredInputChannel);
    if (selectedInputChannel > hardwareInputChannels) {
        MKLogWarning(Audio, @"MKMacAudioDevice: Selected input channel %d is unavailable on selected microphone (%d hardware channels). Falling back to channel %d.",
                     selectedInputChannel, hardwareInputChannels, hardwareInputChannels);
        selectedInputChannel = hardwareInputChannels;
    }
    _recordMicChannels = hardwareInputChannels;
    if (stereoInputEnabled && hardwareInputChannels < 2) {
        MKLogWarning(Audio, @"MKMacAudioDevice: Stereo input requested but unavailable on selected microphone. Falling back to mono.");
    } else if (!captureAllInputChannels) {
        MKLogInfo(Audio, @"MKMacAudioDevice: Capturing %d hardware input channels for mono source channel %d.",
                  _recordMicChannels, selectedInputChannel);
    } else {
        MKLogInfo(Audio, @"MKMacAudioDevice: Capturing %d hardware input channels for stereo pair routing.",
                  _recordMicChannels);
    }
    _recordSampleSize = _recordMicChannels * sizeof(short);

    memset(&fmt, 0, sizeof(AudioStreamBasicDescription));
    fmt.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    fmt.mBitsPerChannel = sizeof(short) * 8;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mSampleRate = _recordFrequency;
    fmt.mChannelsPerFrame = _recordMicChannels;
    fmt.mBytesPerFrame = _recordSampleSize;
    fmt.mBytesPerPacket = _recordSampleSize;
    fmt.mFramesPerPacket = 1;

    err = AudioQueueNewInput(&fmt,
                             inputQueueCallback,
                             self,
                             NULL,
                             NULL,
                             0,
                             &_recordQueue);
    if (err != noErr) {
        MKLogError(Audio, @"MKMacAudioDevice: Unable to create AudioQueue input (err=%d).", (int)err);
        return NO;
    }

    if (selectedUID != nil) {
        CFStringRef queueDeviceUID = (CFStringRef)selectedUID;
        err = AudioQueueSetProperty(_recordQueue,
                                    kAudioQueueProperty_CurrentDevice,
                                    &queueDeviceUID,
                                    sizeof(CFStringRef));
        if (err != noErr) {
            MKLogError(Audio, @"MKMacAudioDevice: Unable to set AudioQueue input device (err=%d).", (int)err);
            return NO;
        }
    }

    UInt32 bufferByteSize = MUAudioQueueInputBufferByteSize(_recordFrequency, _recordMicChannels);
    for (NSUInteger i = 0; i < sizeof(_recordQueueBuffers) / sizeof(_recordQueueBuffers[0]); i++) {
        err = AudioQueueAllocateBuffer(_recordQueue, bufferByteSize, &_recordQueueBuffers[i]);
        if (err != noErr) {
            MKLogError(Audio, @"MKMacAudioDevice: Unable to allocate AudioQueue input buffer (err=%d).", (int)err);
            return NO;
        }
        err = AudioQueueEnqueueBuffer(_recordQueue, _recordQueueBuffers[i], 0, NULL);
        if (err != noErr) {
            MKLogError(Audio, @"MKMacAudioDevice: Unable to enqueue AudioQueue input buffer (err=%d).", (int)err);
            return NO;
        }
    }

    err = AudioQueueStart(_recordQueue, NULL);
    if (err != noErr) {
        MKLogError(Audio, @"MKMacAudioDevice: Unable to start AudioQueue input (err=%d).", (int)err);
        return NO;
    }

    MKLogInfo(Audio, @"MKMacAudioDevice: AudioQueue input started at %dHz, %d channel(s).", _recordFrequency, _recordMicChannels);
    return YES;
}

- (BOOL) teardownRecording {
    BOOL ok = YES;

    if (_recordQueue != NULL) {
        OSStatus err = AudioQueueStop(_recordQueue, true);
        if (err != noErr) {
            MKLogWarning(Audio, @"MKMacAudioDevice: unable to stop AudioQueue input (err=%d). Disposing anyway.", (int)err);
            ok = NO;
        }

        err = AudioQueueDispose(_recordQueue, true);
        if (err != noErr) {
            MKLogError(Audio, @"MKMacAudioDevice: unable to dispose of AudioQueue input (err=%d).", (int)err);
            ok = NO;
        }
        _recordQueue = NULL;
        memset(_recordQueueBuffers, 0, sizeof(_recordQueueBuffers));
    }
    
    _recordBufList.mNumberBuffers = 0;

    MKLogInfo(Audio, @"MKMacAudioDevice: recording teardown finished.");
    return ok;
}

- (BOOL) setupPlayback {
    UInt32 len;
    OSStatus err;
    AudioComponent comp;
    AudioComponentDescription desc;
    AudioStreamBasicDescription fmt;
    
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_HALOutput;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    desc.componentFlags = 0;
    desc.componentFlagsMask = 0;
    
    comp = AudioComponentFindNext(NULL, &desc);
    if (! comp) {
        MKLogError(Audio, @"MKMacAudioDevice: Unable to find AudioUnit.");
        return NO;
    }

    err = AudioComponentInstanceNew(comp, (AudioComponentInstance *) &_playbackAudioUnit);
    if (err != noErr) {
        MKLogError(Audio, @"MKMacAudioDevice: Unable to instantiate new AudioUnit.");
        return NO;
    }
    
    len = sizeof(AudioStreamBasicDescription);
    err = AudioUnitGetProperty(_playbackAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &fmt, &len);
    if (err != noErr) {
        MKLogError(Audio, @"MKAudioOuptut: Unable to get output stream format from AudioUnit.");
        return NO;
    }
    
    _playbackFrequency = (int) 48000;
    int hardwareOutputChannels = (int)MAX((UInt32)1, fmt.mChannelsPerFrame);
    int requestedOutputChannels = _settings.enableStereoOutput ? 2 : 1;
    _playbackChannels = MIN(requestedOutputChannels, hardwareOutputChannels);
    if (_settings.enableStereoOutput && _playbackChannels < 2) {
        MKLogWarning(Audio, @"MKMacAudioDevice: Stereo output requested but unavailable on selected playback device. Falling back to mono.");
    }
    _playbackSampleSize = _playbackChannels * sizeof(short);
    
    fmt.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    fmt.mBitsPerChannel = sizeof(short) * 8;
    
    MKLogInfo(Audio, @"MKMacAudioDevice: Output device currently configured as %iHz sample rate, %i channels, %i sample size", _playbackFrequency, _playbackChannels, _playbackSampleSize);
    
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mSampleRate = (float) _playbackFrequency;
    fmt.mChannelsPerFrame = _playbackChannels;
    fmt.mBytesPerFrame = _playbackSampleSize;
    fmt.mBytesPerPacket = _playbackSampleSize;
    fmt.mFramesPerPacket = 1;
    
    len = sizeof(AudioStreamBasicDescription);
    err = AudioUnitSetProperty(_playbackAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, len);
    if (err != noErr) {
        MKLogError(Audio, @"MKMacAudioDevice: Unable to set stream format for output device.");
        return NO;
    }
    
    AURenderCallbackStruct cb;
    cb.inputProc = outputCallback;
    cb.inputProcRefCon = self;
    len = sizeof(AURenderCallbackStruct);
    err = AudioUnitSetProperty(_playbackAudioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Global, 0, &cb, len);
    if (err != noErr) {
        MKLogError(Audio, @"MKMacAudioDevice: Could not set render callback.");
        return NO;
    }
    
    err = AudioUnitInitialize(_playbackAudioUnit);
    if (err != noErr) {
        MKLogError(Audio, @"MKMacAudioDevice: Unable to initialize playback AudioUnit.");
        return NO;
    }
    
    err = AudioOutputUnitStart(_playbackAudioUnit);
    if (err != noErr) {
        MKLogError(Audio, @"MKMacAudioDevice: Unable to start AudioUnit");
        return NO;
    }
    
    return YES;
}

- (BOOL) teardownPlayback {
    BOOL ok = YES;
    if (_playbackAudioUnit != NULL) {
        OSStatus err = AudioOutputUnitStop(_playbackAudioUnit);
        if (err != noErr) {
            MKLogWarning(Audio, @"MKMacAudioDevice: unable to stop playback AudioUnit (err=%d). Disposing anyway.", (int)err);
            ok = NO;
        }

        err = AudioComponentInstanceDispose(_playbackAudioUnit);
        if (err != noErr) {
            MKLogError(Audio, @"MKMacAudioDevice: unable to dispose of playback AudioUnit (err=%d).", (int)err);
            ok = NO;
        }
        _playbackAudioUnit = NULL;
    }
    
    MKLogInfo(Audio, @"MKMacAudioDevice: playback teardown finished.");
    return ok;
}

- (BOOL) setupDevice {
    MKAudioPerfReset(&sInputPerfStats);
    MKAudioPerfReset(&sOutputPerfStats);
    BOOL recordingReady = [self setupRecording];
    if (!recordingReady) {
        [self teardownRecording];
        return NO;
    }

    BOOL playbackReady = [self setupPlayback];
    if (!playbackReady) {
        [self teardownRecording];
        [self teardownPlayback];
        return NO;
    }

    return YES;
}

- (BOOL) teardownDevice {
    MKAudioPerfLogAndReset(@"mac_hal_input", &sInputPerfStats);
    MKAudioPerfLogAndReset(@"mac_hal_output", &sOutputPerfStats);
    BOOL recordingOK = [self teardownRecording];
    BOOL playbackOK = [self teardownPlayback];
    return recordingOK && playbackOK;
}

- (void) setupOutput:(MKAudioDeviceOutputFunc)outf {
    [_outputFunc release];
    _outputFunc = [outf copy];
}

- (void) setupInput:(MKAudioDeviceInputFunc)inf {
    [_inputFunc release];
    _inputFunc = [inf copy];
}

- (int) inputSampleRate {
    return _recordFrequency;
}

- (int) outputSampleRate {
    return _playbackFrequency;
}

- (int) numberOfInputChannels {
    return _recordMicChannels;
}

- (int) numberOfOutputChannels {
    return _playbackChannels;
}

@end

#endif // TARGET_OS_OSX
