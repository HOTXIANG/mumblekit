// Copyright 2012 The MumbleKit Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import <TargetConditionals.h>
#if TARGET_OS_OSX

#import <MumbleKit/MKAudio.h>
#import "MKAudioDevice.h"

#import "MKMacAudioDevice.h"

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

    AudioUnit                    _recordAudioUnit;
    AudioBufferList              _recordBufList;
    int                          _recordFrequency;
    int                          _recordSampleSize;
    int                          _recordMicChannels;

    MKAudioDeviceOutputFunc      _outputFunc;
    MKAudioDeviceInputFunc       _inputFunc;
}
@end

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

static OSStatus inputCallback(void *udata, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                              UInt32 busnum, UInt32 nframes, AudioBufferList *buflist) {
    MKMacAudioDevice *dev = (MKMacAudioDevice *)udata;
    OSStatus err;
        
    if (! dev->_recordBufList.mBuffers->mData) {
        NSLog(@"MKMacAudioDevice: No buffer allocated.");
        dev->_recordBufList.mNumberBuffers = 1;
        AudioBuffer *b = dev->_recordBufList.mBuffers;
        b->mNumberChannels = dev->_recordMicChannels;
        b->mDataByteSize = dev->_recordSampleSize * nframes;
        b->mData = calloc(1, b->mDataByteSize);
    }
    
    if (dev->_recordBufList.mBuffers->mDataByteSize < (dev->_recordSampleSize * nframes)) {
        NSLog(@"MKMacAudioDevice: Buffer too small. Allocating more space.");
        AudioBuffer *b = dev->_recordBufList.mBuffers;
        free(b->mData);
        b->mDataByteSize = dev->_recordSampleSize * nframes;
        b->mData = calloc(1, b->mDataByteSize);
    }
    
    /*
     AudioUnitRender modifies the mDataByteSize members with the
     actual read bytes count. We need to write it back otherwise
     we'll reallocate the buffer even if not needed.
     */
    UInt32 dataByteSize = dev->_recordBufList.mBuffers->mDataByteSize;
    err = AudioUnitRender(dev->_recordAudioUnit, flags, ts, busnum, nframes, &dev->_recordBufList);
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: AudioUnitRender failed. err = %ld", (unsigned long)err);
        return err;
    }
    dev->_recordBufList.mBuffers->mDataByteSize = dataByteSize;
    
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    short *buf = (short *) dev->_recordBufList.mBuffers->mData;
    MKAudioDeviceInputFunc inputFunc = dev->_inputFunc;
    if (inputFunc) {
        inputFunc(buf, nframes);
    }
    [pool release];
    
    return noErr;
}

static OSStatus outputCallback(void *udata, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                               UInt32 busnum, UInt32 nframes, AudioBufferList *buflist) {
    
    MKMacAudioDevice *dev = (MKMacAudioDevice *) udata;
    AudioBuffer *buf = buflist->mBuffers;
    MKAudioDeviceOutputFunc outputFunc = dev->_outputFunc;
    BOOL done;
    
    if (outputFunc == NULL) {
        // No frames available yet.
        buf->mDataByteSize = 0;
        return -1;
    }
    
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    done = outputFunc(buf->mData, nframes);
    if (! done) {
        // No frames available yet.
        buf->mDataByteSize = 0;
        [pool release];
        return -1;
    }
    
    [pool release];
    return noErr;
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
    UInt32 val;
    OSStatus err;
    AudioComponent comp;
    AudioComponentDescription desc;
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
        NSLog(@"MKMacAudioDevice: Unable to query for default device.");
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
                NSLog(@"MKMacAudioDevice: Preferred input device UID not found. Falling back to system default.");
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
    NSLog(@"MKMacAudioDevice: Using input device: %@ (%@)", selectedName ?: @"Unknown", selectedUID ?: @"No UID");
    
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_HALOutput;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    desc.componentFlags = 0;
    desc.componentFlagsMask = 0;
    
    comp = AudioComponentFindNext(NULL, &desc);
    if (! comp) {
        NSLog(@"MKMacAudioDevice: Unable to find AudioUnit.");
        return NO;
    }
    
    err = AudioComponentInstanceNew(comp, (AudioComponentInstance *) &_recordAudioUnit);
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: Unable to instantiate new AudioUnit.");
        return NO;
    }
    
    err = AudioUnitInitialize(_recordAudioUnit);
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: Unable to initialize AudioUnit.");
        return NO;
    }
    
    val = 1;
    err = AudioUnitSetProperty(_recordAudioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &val, sizeof(UInt32));
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: Unable to configure input scope on AudioUnit.");
        return NO;
    }
    
    val = 0;
    err = AudioUnitSetProperty(_recordAudioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &val, sizeof(UInt32));
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: Unable to configure output scope on AudioUnit.");
        return NO;
    }
    
    // Set selected input device
    len = sizeof(AudioDeviceID);
    err = AudioUnitSetProperty(_recordAudioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &devId, len);
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: Unable to set selected input device.");
        return NO;
    }
    
    len = sizeof(AudioStreamBasicDescription);
    err = AudioUnitGetProperty(_recordAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &fmt, &len);
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: Unable to query device for stream info.");
        return NO;
    }
    
    if (fmt.mChannelsPerFrame > 1) {
        NSLog(@"MKMacAudioDevice: Input device with more than one channel detected. Defaulting to 1.");
    }
    
    _recordFrequency = (int) fmt.mSampleRate;
    _recordMicChannels = 1;
    _recordSampleSize = _recordMicChannels * sizeof(short);
    
    fmt.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    fmt.mBitsPerChannel = sizeof(short) * 8;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mSampleRate = _recordFrequency;
    fmt.mChannelsPerFrame = _recordMicChannels;
    fmt.mBytesPerFrame = _recordSampleSize;
    fmt.mBytesPerPacket = _recordSampleSize;
    fmt.mFramesPerPacket = 1;
    
    len = sizeof(AudioStreamBasicDescription);
    err = AudioUnitSetProperty(_recordAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt, len);
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: Unable to set stream format for output device. (output scope)");
        return NO;
    }
    
    AURenderCallbackStruct cb;
    cb.inputProc = inputCallback;
    cb.inputProcRefCon = self;
    len = sizeof(AURenderCallbackStruct);
    err = AudioUnitSetProperty(_recordAudioUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb, len);
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: Unable to setup callback.");
        return NO;
    }
    
    err = AudioOutputUnitStart(_recordAudioUnit);
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: Unable to start AudioUnit.");
        return NO;
    }
    
    return YES;
}

- (BOOL) teardownRecording {
    OSStatus err;
    
    err = AudioOutputUnitStop(_recordAudioUnit);
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: unable to stop AudioUnit.");
        return NO;
    }
    
    err = AudioComponentInstanceDispose(_recordAudioUnit);
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: unable to dispose of AudioUnit.");
        return NO;
    }
    
    AudioBuffer *b = _recordBufList.mBuffers;
    if (b && b->mData)
        free(b->mData);
    
    NSLog(@"MKMacAudioDevice: teardown finished.");
    return YES;
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
        NSLog(@"MKMacAudioDevice: Unable to find AudioUnit.");
        return NO;
    }
    
    err = AudioComponentInstanceNew(comp, (AudioComponentInstance *) &_playbackAudioUnit);
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: Unable to instantiate new AudioUnit.");
        return NO;
    }
    
    err = AudioUnitInitialize(_playbackAudioUnit);
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: Unable to initialize AudioUnit.");
        return NO;
    }
    
    len = sizeof(AudioStreamBasicDescription);
    err = AudioUnitGetProperty(_playbackAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &fmt, &len);
    if (err != noErr) {
        NSLog(@"MKAudioOuptut: Unable to get output stream format from AudioUnit.");
        return NO;
    }
    
    _playbackFrequency = (int) 48000;
    _playbackChannels = (int) fmt.mChannelsPerFrame;
    _playbackSampleSize = _playbackChannels * sizeof(short);
    
    fmt.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    fmt.mBitsPerChannel = sizeof(short) * 8;
    
    NSLog(@"MKMacAudioDevice: Output device currently configured as %iHz sample rate, %i channels, %i sample size", _playbackFrequency, _playbackChannels, _playbackSampleSize);
    
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mSampleRate = (float) _playbackFrequency;
    fmt.mBytesPerFrame = _playbackSampleSize;
    fmt.mBytesPerPacket = _playbackSampleSize;
    fmt.mFramesPerPacket = 1;
    
    len = sizeof(AudioStreamBasicDescription);
    err = AudioUnitSetProperty(_playbackAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, len);
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: Unable to set stream format for output device.");
        return NO;
    }
    
    AURenderCallbackStruct cb;
    cb.inputProc = outputCallback;
    cb.inputProcRefCon = self;
    len = sizeof(AURenderCallbackStruct);
    err = AudioUnitSetProperty(_playbackAudioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Global, 0, &cb, len);
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: Could not set render callback.");
        return NO;
    }
    
    // On desktop we call AudioDeviceSetProperty() with kAudioDevicePropertyBufferFrameSize
    // to setup our frame size.
    
    err = AudioOutputUnitStart(_playbackAudioUnit);
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: Unable to start AudioUnit");
        return NO;
    }
    
    return YES;
}

- (BOOL) teardownPlayback {
    OSStatus err = AudioOutputUnitStop(_playbackAudioUnit);
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: unable to stop AudioUnit.");
        return NO;
    }
    
    err = AudioComponentInstanceDispose(_playbackAudioUnit);
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: unable to dispose of AudioUnit.");
        return NO;
    }
    
    NSLog(@"MKMacAudioDevice: teardown finished.");
    return YES;
}

- (BOOL) setupDevice {
    BOOL ok = YES;
    if (ok)
        ok = [self setupRecording];
    if (ok)
        ok = [self setupPlayback];
    return ok;
}

- (BOOL) teardownDevice {
    BOOL ok = YES;
    if (ok)
        ok = [self teardownRecording];
    if (ok)
        ok = [self teardownPlayback];
    return ok;
}

- (void) setupOutput:(MKAudioDeviceOutputFunc)outf {
    _outputFunc = [outf copy];
}

- (void) setupInput:(MKAudioDeviceInputFunc)inf {
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
