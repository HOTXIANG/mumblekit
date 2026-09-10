// Copyright 2012 The MumbleKit Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import <MumbleKit/MKAudio.h>
#import "MKAudioDevice.h"

#import "MKiOSAudioDevice.h"
#import "MKAudioPerfStats.h"
#import "MKAudioDeviceIO.h"
#import "../../Source/Classes/SwiftUI/Core/MumbleLogger.h"

#import <AudioUnit/AudioUnit.h>
#import <AudioUnit/AUComponent.h>
#import <AudioToolbox/AudioToolbox.h>

@interface MKiOSAudioDevice () {
@public
    MKAudioSettings              _settings;
    AudioUnit                    _audioUnit;
    AudioBufferList              _buflist;
    UInt32                       _inputBufferCapacity;
    MKAudioPerfStats              _inputPerfStats;
    MKAudioPerfStats              _outputPerfStats;
    int                          _micFrequency;
    int                          _micSampleSize;
    int                          _numMicChannels;
    int                          _numOutputChannels;
    MKAudioDeviceOutputFunc      _outputFunc;
    MKAudioDeviceInputFunc       _inputFunc;
}
@end

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

static OSStatus inputCallback(void *udata, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                              UInt32 busnum, UInt32 nframes, AudioBufferList *buflist) {
    MKiOSAudioDevice *dev = (MKiOSAudioDevice *)udata;
    OSStatus err;
    bool shouldSample = MKAudioPerfShouldSample(&dev->_inputPerfStats);
    uint64_t startTicks = shouldSample ? MKAudioPerfNowTicks() : 0;
    
    if (dev->_audioUnit == NULL || dev->_buflist.mBuffers[0].mData == NULL ||
        dev->_micSampleSize <= 0 || nframes > dev->_inputBufferCapacity / dev->_micSampleSize) {
        return kAudioUnitErr_TooManyFramesToProcess;
    }
    AudioBuffer *inputBuffer = &dev->_buflist.mBuffers[0];
    UInt32 expectedBytes = nframes * dev->_micSampleSize;
    inputBuffer->mDataByteSize = expectedBytes;
    err = AudioUnitRender(dev->_audioUnit, flags, ts, busnum, nframes, &dev->_buflist);
    if (err != noErr) return err;
    if (inputBuffer->mDataByteSize < expectedBytes) {
        // Short input must not expose samples left over from an earlier callback.
        return noErr;
    }

    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    short *buf = (short *) dev->_buflist.mBuffers->mData;
    MKAudioDeviceInputFunc inputFunc = dev->_inputFunc;
    if (inputFunc) {
        inputFunc(buf, nframes);
        if (nframes > 0) MKAudioHealthRecord(&dev->_callbackHealth.inputCompleted);
    }
    [pool release];
    if (shouldSample) {
        MKAudioPerfRecordTicks(&dev->_inputPerfStats, MKAudioPerfNowTicks() - startTicks);
    }
    
    return noErr;
}

static OSStatus outputCallback(void *udata, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                               UInt32 busnum, UInt32 nframes, AudioBufferList *buflist) {
    MKiOSAudioDevice *dev = (MKiOSAudioDevice *)udata;
    if (!MKAudioDeviceCanRender(buflist, nframes, dev->_numOutputChannels) || dev->_outputFunc == NULL) {
        MKAudioDeviceSilence(buflist, flags);
        return noErr;
    }
    bool shouldSample = MKAudioPerfShouldSample(&dev->_outputPerfStats);
    uint64_t startTicks = shouldSample ? MKAudioPerfNowTicks() : 0;
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    if (!dev->_outputFunc(buflist->mBuffers[0].mData, nframes)) {
        MKAudioDeviceSilence(buflist, flags);
    }
    MKAudioHealthRecord(&dev->_callbackHealth.outputCompleted);
    [pool release];
    if (shouldSample) MKAudioPerfRecordTicks(&dev->_outputPerfStats, MKAudioPerfNowTicks() - startTicks);
    return noErr;
}

@implementation MKiOSAudioDevice

- (id) initWithSettings:(MKAudioSettings *)settings {
    if ((self = [super init])) {
        memcpy(&_settings, settings, sizeof(MKAudioSettings));
    }
    return self;
}

- (void) dealloc {
    [self teardownDevice];
    [_inputFunc release];
    [_outputFunc release];
    [super dealloc];
}

- (BOOL) setupDevice {
    if (_audioUnit != NULL) [self teardownDevice];
    UInt32 len;
    UInt32 val;
    OSStatus err;
    AudioComponent comp;
    AudioComponentDescription desc;
    AudioStreamBasicDescription inputFmt;
    AudioStreamBasicDescription outputFmt;

    MKAudioPerfReset(&_inputPerfStats);
    MKAudioPerfReset(&_outputPerfStats);

    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_RemoteIO;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    desc.componentFlags = 0;
    desc.componentFlagsMask = 0;
    
    comp = AudioComponentFindNext(NULL, &desc);
    if (! comp) {
        MKLogError(Audio, @"MKiOSAudioDevice: Unable to find AudioUnit.");
        return NO;
    }
    
    err = AudioComponentInstanceNew(comp, (AudioComponentInstance *) &_audioUnit);
    if (err != noErr) {
        MKLogError(Audio, @"MKiOSAudioDevice: Unable to instantiate new AudioUnit.");
        return NO;
    }
        
    val = 1;
    err = AudioUnitSetProperty(_audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &val, sizeof(UInt32));
    if (err != noErr) {
        MKLogError(Audio, @"MKiOSAudioDevice: Unable to configure input scope on AudioUnit.");
        return NO;
    }
    
    val = 1;
    err = AudioUnitSetProperty(_audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &val, sizeof(UInt32));
    if (err != noErr) {
        MKLogError(Audio, @"MKiOSAudioDevice: Unable to configure output scope on AudioUnit.");
        return NO;
    }
    
    AURenderCallbackStruct cb;
    cb.inputProc = inputCallback;
    cb.inputProcRefCon = self;
    len = sizeof(AURenderCallbackStruct);
    err = AudioUnitSetProperty(_audioUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb, len);
    if (err != noErr) {
        MKLogError(Audio, @"MKiOSAudioDevice: Unable to setup callback.");
        return NO;
    }
    
    cb.inputProc = outputCallback;
    cb.inputProcRefCon = self;
    len = sizeof(AURenderCallbackStruct);
    err = AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Global, 0, &cb, len);
    if (err != noErr) {
        MKLogError(Audio, @"MKiOSAudioDevice: Could not set render callback.");
        return NO;
    }
    
    len = sizeof(AudioStreamBasicDescription);
    err = AudioUnitGetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &inputFmt, &len);
    if (err != noErr) {
        MKLogError(Audio, @"MKiOSAudioDevice: Unable to query input stream info.");
        return NO;
    }
    
    len = sizeof(AudioStreamBasicDescription);
    err = AudioUnitGetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &outputFmt, &len);
    if (err != noErr) {
        MKLogError(Audio, @"MKiOSAudioDevice: Unable to query output stream info.");
        return NO;
    }
    
    _micFrequency = 48000;
    int hardwareInputChannels = (int)MAX((UInt32)1, inputFmt.mChannelsPerFrame);
    int requestedInputChannels = _settings.enableStereoInput ? 2 : 1;
    _numMicChannels = MIN(requestedInputChannels, hardwareInputChannels);
    if (_settings.enableStereoInput && _numMicChannels < 2) {
        MKLogWarning(Audio, @"MKiOSAudioDevice: Stereo input requested but unavailable on current route. Falling back to mono.");
    }
    
    int hardwareOutputChannels = (int)MAX((UInt32)1, outputFmt.mChannelsPerFrame);
    int requestedOutputChannels = _settings.enableStereoOutput ? 2 : 1;
    _numOutputChannels = MIN(requestedOutputChannels, hardwareOutputChannels);
    if (_settings.enableStereoOutput && _numOutputChannels < 2) {
        MKLogWarning(Audio, @"MKiOSAudioDevice: Stereo output requested but unavailable on current route. Falling back to mono.");
    }
    _micSampleSize = _numMicChannels * sizeof(short);
    
    inputFmt.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    inputFmt.mBitsPerChannel = sizeof(short) * 8;
    inputFmt.mFormatID = kAudioFormatLinearPCM;
    inputFmt.mSampleRate = _micFrequency;
    inputFmt.mChannelsPerFrame = _numMicChannels;
    inputFmt.mBytesPerFrame = _numMicChannels * sizeof(short);
    inputFmt.mBytesPerPacket = _numMicChannels * sizeof(short);
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
        MKLogError(Audio, @"MKiOSAudioDevice: Unable to set stream format for output device. (output scope)");
        return NO;
    }
    
    len = sizeof(AudioStreamBasicDescription);
    err = AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &outputFmt, len);
    if (err != noErr) {
        MKLogError(Audio, @"MKiOSAudioDevice: Unable to set stream format for input device. (input scope)");
        return NO;
    }
    
    // Background and route changes can increase the slice size. Allocate on
    // the control thread before callbacks are enabled, with a bounded fallback.
    UInt32 maximumFrames = 4096;
    len = sizeof(maximumFrames);
    if (AudioUnitGetProperty(_audioUnit, kAudioUnitProperty_MaximumFramesPerSlice,
                             kAudioUnitScope_Global, 0, &maximumFrames, &len) != noErr) {
        maximumFrames = 4096;
    }
    maximumFrames = MAX(maximumFrames, (UInt32)4096);
    if (maximumFrames > 65536) return NO;
    _inputBufferCapacity = maximumFrames * _micSampleSize;
    _buflist.mNumberBuffers = 1;
    _buflist.mBuffers[0].mNumberChannels = _numMicChannels;
    _buflist.mBuffers[0].mDataByteSize = _inputBufferCapacity;
    _buflist.mBuffers[0].mData = calloc(1, _inputBufferCapacity);
    if (_buflist.mBuffers[0].mData == NULL) return NO;

    err = AudioUnitInitialize(_audioUnit);
    if (err != noErr) {
        MKLogError(Audio, @"MKiOSAudioDevice: Unable to initialize AudioUnit.");
        return NO;
    }
    
    return YES;
}

- (BOOL) startDevice {
    OSStatus err = AudioOutputUnitStart(_audioUnit);
    if (err != noErr) {
        MKLogError(Audio, @"MKiOSAudioDevice: Unable to start AudioUnit.");
        return NO;
    }

    MKLogInfo(Audio, @"MKiOSAudioDevice: AudioUnit started.");
    return YES;
}

- (BOOL) teardownDevice {
    BOOL ok = YES;
    AudioUnit unit = _audioUnit;
    if (unit != NULL) {
        // Keep the refCon and buffers alive until disposal has drained callbacks.
        // In particular, a media-services reset may make Stop/Uninitialize fail;
        // cleanup must still reach Dispose rather than releasing a live refCon.
        OSStatus stopError = AudioOutputUnitStop(unit);
        AudioUnitUninitialize(unit);
        OSStatus disposeError = AudioComponentInstanceDispose(unit);
        _audioUnit = NULL;
        ok = (disposeError == noErr);
        if (stopError != noErr || disposeError != noErr) {
            MKLogWarning(Audio, @"MKiOSAudioDevice: teardown stop=%d dispose=%d", (int)stopError, (int)disposeError);
        }
    }
    MKAudioPerfLogAndReset(@"ios_remoteio_input", &_inputPerfStats);
    MKAudioPerfLogAndReset(@"ios_remoteio_output", &_outputPerfStats);
    free(_buflist.mBuffers[0].mData);
    memset(&_buflist, 0, sizeof(_buflist));
    _inputBufferCapacity = 0;
    return ok;
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
