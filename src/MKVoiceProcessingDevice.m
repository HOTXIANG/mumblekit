// Copyright 2012 The MumbleKit Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import "MKVoiceProcessingDevice.h"

#import <MumbleKit/MKAudio.h>

#import <AudioUnit/AudioUnit.h>
#import <AudioUnit/AUComponent.h>
#import <AudioToolbox/AudioToolbox.h>
#if defined(TARGET_OS_VISION) && TARGET_OS_VISION
    #define IS_UIDEVICE_AVAILABLE 1
#elif TARGET_OS_IOS || TARGET_OS_TV || TARGET_OS_MACCATALYST
    #define IS_UIDEVICE_AVAILABLE 1
#else
    #define IS_UIDEVICE_AVAILABLE 0
#endif

#if IS_UIDEVICE_AVAILABLE
    #import <UIKit/UIKit.h>
#endif

@interface MKVoiceProcessingDevice () {
@public
    MKAudioSettings              _settings;
    AudioUnit                    _audioUnit;
    AudioBufferList              _buflist;
    int                          _micFrequency;
    int                          _micSampleSize;
    int                          _numMicChannels;
    int                          _numOutputChannels;
    MKAudioDeviceOutputFunc      _outputFunc;
    MKAudioDeviceInputFunc       _inputFunc;
}
@end

static OSStatus inputCallback(void *udata, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                              UInt32 busnum, UInt32 nframes, AudioBufferList *buflist) {
    MKVoiceProcessingDevice *dev = (MKVoiceProcessingDevice *)udata;
    OSStatus err;
        
    if (! dev->_buflist.mBuffers->mData) {
        NSLog(@"MKVoiceProcessingDevice: No buffer allocated. Allocating for %d frames.", (int)nframes);
        dev->_buflist.mNumberBuffers = 1;
        AudioBuffer *b = dev->_buflist.mBuffers;
        b->mNumberChannels = dev->_numMicChannels;
        b->mDataByteSize = dev->_micSampleSize * nframes;
        b->mData = calloc(1, b->mDataByteSize);
    }
    
    if (dev->_buflist.mBuffers->mDataByteSize < (dev->_micSampleSize * nframes)) {
        NSLog(@"MKVoiceProcessingDevice: Buffer too small. Allocating more space for %d frames.", (int)nframes);
        AudioBuffer *b = dev->_buflist.mBuffers;
        free(b->mData);
        b->mDataByteSize = dev->_micSampleSize * nframes;
        b->mData = calloc(1, b->mDataByteSize);
    }
        
    /*
     AudioUnitRender modifies the mDataByteSize members with the
     actual read bytes count. We need to write it back otherwise
     we'll reallocate the buffer even if not needed.
     */
    UInt32 dataByteSize = dev->_buflist.mBuffers->mDataByteSize;
    err = AudioUnitRender(dev->_audioUnit, flags, ts, busnum, nframes, &dev->_buflist);
    if (err != noErr) {
        NSLog(@"MKVoiceProcessingDevice: AudioUnitRender failed. err = %d", (int)err);
        return err;
    }
    dev->_buflist.mBuffers->mDataByteSize = dataByteSize;
    
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    short *buf = (short *) dev->_buflist.mBuffers->mData;
    MKAudioDeviceInputFunc inputFunc = dev->_inputFunc;
    if (inputFunc) {
        inputFunc(buf, nframes);
    }
    [pool release];
    
    return noErr;
}

static OSStatus outputCallback(void *udata, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                               UInt32 busnum, UInt32 nframes, AudioBufferList *buflist) {
    MKVoiceProcessingDevice *dev = (MKVoiceProcessingDevice *) udata;
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

@implementation MKVoiceProcessingDevice

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

- (BOOL) setupDevice {
    UInt32 len;
    UInt32 val;
    OSStatus err;
    AudioComponent comp;
    AudioComponentDescription desc;
    AudioStreamBasicDescription inputFmt;
    AudioStreamBasicDescription outputFmt;
    
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_VoiceProcessingIO;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    desc.componentFlags = 0;
    desc.componentFlagsMask = 0;
    
    comp = AudioComponentFindNext(NULL, &desc);
    if (! comp) {
        NSLog(@"MKVoiceProcessingDevice: Unable to find AudioUnit.");
        return NO;
    }
    
    err = AudioComponentInstanceNew(comp, (AudioComponentInstance *) &_audioUnit);
    if (err != noErr) {
        NSLog(@"MKVoiceProcessingDevice: Unable to instantiate new AudioUnit. err=%d", (int)err);
        return NO;
    }
    
    val = 1;
    err = AudioUnitSetProperty(_audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &val, sizeof(UInt32));
    if (err != noErr) {
        NSLog(@"MKVoiceProcessingDevice: Unable to configure input scope. err=%d", (int)err);
        return NO;
    }
    
    val = 1;
    err = AudioUnitSetProperty(_audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &val, sizeof(UInt32));
    if (err != noErr) {
        NSLog(@"MKVoiceProcessingDevice: Unable to configure output scope. err=%d", (int)err);
        return NO;
    }
    
    AURenderCallbackStruct cb;
    cb.inputProc = inputCallback;
    cb.inputProcRefCon = self;
    len = sizeof(AURenderCallbackStruct);
    err = AudioUnitSetProperty(_audioUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb, len);
    if (err != noErr) {
        NSLog(@"MKVoiceProcessingDevice: Unable to setup input callback. err=%d", (int)err);
        return NO;
    }
    
    cb.inputProc = outputCallback;
    cb.inputProcRefCon = self;
    len = sizeof(AURenderCallbackStruct);
    err = AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Global, 0, &cb, len);
    if (err != noErr) {
        NSLog(@"MKVoiceProcessingDevice: Could not set render callback. err=%d", (int)err);
        return NO;
    }
    
    len = sizeof(AudioStreamBasicDescription);
    err = AudioUnitGetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &inputFmt, &len);
    if (err != noErr) {
        NSLog(@"MKVoiceProcessingDevice: Unable to query input stream info. err=%d", (int)err);
        return NO;
    }
    
    len = sizeof(AudioStreamBasicDescription);
    err = AudioUnitGetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &outputFmt, &len);
    if (err != noErr) {
        NSLog(@"MKVoiceProcessingDevice: Unable to query output stream info. err=%d", (int)err);
        return NO;
    }
    
    if (_settings.enableStereoInput) {
        NSLog(@"MKVoiceProcessingDevice: Stereo input is not supported in voice-processing mode. Defaulting to mono.");
    }
    _micFrequency = 48000;
    _numMicChannels = 1;
    int hardwareOutputChannels = (int)MAX((UInt32)1, outputFmt.mChannelsPerFrame);
    int requestedOutputChannels = _settings.enableStereoOutput ? 2 : 1;
    _numOutputChannels = MIN(requestedOutputChannels, hardwareOutputChannels);
    if (_settings.enableStereoOutput && _numOutputChannels < 2) {
        NSLog(@"MKVoiceProcessingDevice: Stereo output requested but unavailable on current route. Falling back to mono.");
    }
    _micSampleSize = _numMicChannels * sizeof(short);
    
    inputFmt.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    inputFmt.mBitsPerChannel = sizeof(short) * 8;
    inputFmt.mFormatID = kAudioFormatLinearPCM;
    inputFmt.mSampleRate = _micFrequency;
    inputFmt.mChannelsPerFrame = _numMicChannels;
    inputFmt.mBytesPerFrame = _micSampleSize;
    inputFmt.mBytesPerPacket = _micSampleSize;
    inputFmt.mFramesPerPacket = 1;
    
    outputFmt.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    outputFmt.mBitsPerChannel = sizeof(short) * 8;
    outputFmt.mFormatID = kAudioFormatLinearPCM;
    outputFmt.mSampleRate = _micFrequency;
    outputFmt.mChannelsPerFrame = _numOutputChannels;
    outputFmt.mBytesPerFrame = _numOutputChannels * sizeof(short);
    outputFmt.mBytesPerPacket = _numOutputChannels * sizeof(short);
    outputFmt.mFramesPerPacket = 1;
    
    len = sizeof(AudioStreamBasicDescription);
    err = AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &inputFmt, len);
    if (err != noErr) {
        NSLog(@"MKVoiceProcessingDevice: Unable to set stream format for output device. (output scope)");
        return NO;
    }
    
    len = sizeof(AudioStreamBasicDescription);
    err = AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &outputFmt, len);
    if (err != noErr) {
        NSLog(@"MKVoiceProcessingDevice: Unable to set stream format for input device. (input scope)");
        return NO;
    }
    
    val = 0;
    len = sizeof(UInt32);
    err = AudioUnitSetProperty(_audioUnit, kAUVoiceIOProperty_BypassVoiceProcessing, kAudioUnitScope_Global, 0, &val, len);
    if (err != noErr) {
        NSLog(@"MKVoiceProcessingDevice: Unable to ENABLE voice processing (Bypass failed). err=%d", (int)err);
    }
        
    val = 1;
    len = sizeof(UInt32);
    err = AudioUnitSetProperty(_audioUnit, kAUVoiceIOProperty_VoiceProcessingEnableAGC, kAudioUnitScope_Global, 0, &val, len);
    if (err != noErr) {
        NSLog(@"MKVoiceProcessingDevice: Unable to ENABLE VPIO AGC. err=%d", (int)err);
    }
    
    val = 0;
    len = sizeof(UInt32);
    err = AudioUnitSetProperty(_audioUnit, kAUVoiceIOProperty_MuteOutput, kAudioUnitScope_Global, 0, &val, len);
    if (err != noErr) {
        NSLog(@"MKVoiceProcessingDevice: unable to unmute output. err=%d", (int)err);
    }
    
    err = AudioUnitInitialize(_audioUnit);
    if (err != noErr) {
        NSLog(@"MKVoiceProcessingDevice: Unable to initialize AudioUnit. err=%d", (int)err);
        return NO;
    }
    
    err = AudioOutputUnitStart(_audioUnit);
    if (err != noErr) {
        NSLog(@"MKVoiceProcessingDevice: Unable to start AudioUnit. err=%d", (int)err);
        return NO;
    }
    
    return YES;
}

- (BOOL) teardownDevice {
    OSStatus err;
    
    err = AudioOutputUnitStop(_audioUnit);
    if (err != noErr) {
        NSLog(@"MKVoiceProcessingDevice: unable to stop AudioUnit. err=%d", (int)err);
        return NO;
    }
    
    err = AudioComponentInstanceDispose(_audioUnit);
    if (err != noErr) {
        NSLog(@"MKVoiceProcessingDevice: unable to dispose of AudioUnit. err=%d", (int)err);
        return NO;
    }
    
    AudioBuffer *b = _buflist.mBuffers;
    if (b && b->mData)
        free(b->mData);
    
    NSLog(@"MKVoiceProcessingDevice: teardown finished.");
    return YES;
}

- (void) setupOutput:(MKAudioDeviceOutputFunc)outf {
    _outputFunc = [outf copy];
}

- (void) setupInput:(MKAudioDeviceInputFunc)inf {
    _inputFunc = [inf copy];
}

- (int) inputSampleRate {
    return _micFrequency;
}

- (int) outputSampleRate {
    return _micFrequency;
}

- (int) numberOfInputChannels {
    return _numMicChannels;
}

- (int) numberOfOutputChannels {
    return _numOutputChannels;
}

@end
