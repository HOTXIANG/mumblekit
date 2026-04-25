// Copyright 2005-2012 The MumbleKit Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import "MKUtils.h"
#import <MumbleKit/MKAudio.h>
#import "MKAudioOutput.h"
#import "MKAudioOutputSpeech.h"
#import "MKAudioOutputUser.h"
#import "MKAudioOutputSidetone.h"
#import "MKAudioDevice.h"
#import "../../Source/Classes/SwiftUI/Core/MumbleLogger.h"

#import <AudioUnit/AudioUnit.h>
#import <AudioUnit/AUComponent.h>
#import <AudioToolbox/AudioToolbox.h>
#import <os/lock.h>

typedef struct {
    os_unfair_lock lock;
    float inputPeak;
    float outputPeak;
    OSStatus lastRenderStatus;
    NSUInteger frameCount;
} MKAudioDSPStatus;

@interface MKAudioOutput () {
    MKAudioDevice        *_device;
    MKAudioSettings       _settings;
    AudioUnit             _audioUnit;
    int                   _sampleSize;
    int                   _frameSize;
    int                   _mixerFrequency;
    int                   _numChannels;
    float                *_speakerVolume;
    NSLock               *_outputLock;
    NSMutableDictionary  *_outputs;

    NSLock               *_mixerInfoLock;
    NSDictionary         *_mixerInfo;

    double                _cngAmpliScaler;
    double                _cngLastSample;
    long                  _cngRegister1;
    long                  _cngRegister2;
    BOOL                  _cngEnabled;

    NSMutableDictionary  *_sessionVolumes;
    NSMutableDictionary  *_sessionMutes;
    NSMutableArray       *_remoteSessionOrder;
    NSMutableDictionary  *_remoteTrackProcessors;
    NSMutableDictionary  *_remoteTrackProcessorContexts;
    MKAudioOutputFloatProcessCallback _remoteBusProcessor;
    void                 *_remoteBusProcessorContext;
    MKAudioOutputFloatProcessCallback _remoteBus2Processor;
    void                 *_remoteBus2ProcessorContext;
    NSMutableDictionary  *_sessionBusAssignment;  // session -> NSNumber(0 or 1)
    NSMutableDictionary  *_sessionUsesTrackSendRouting; // session -> NSNumber(BOOL)
    NSMutableDictionary  *_sessionTrackSendBusMasks; // session -> NSNumber(bitmask)
    NSUInteger            _inputTrackSendBusMask; // bitmask for master bus1/bus2

    // DSP observability - per-session status
    NSMutableDictionary  *_sessionDSPStatuses;

    // Sidechain buffer pool - pre-allocated, no runtime allocation
    struct MKSidechainSlot _sidechainUserSlots[MK_SIDECHAIN_MAX_SESSIONS];
    float    _sidechainMasterBus1[MK_SIDECHAIN_MAX_FRAMES * 2];
    float    _sidechainMasterBus2[MK_SIDECHAIN_MAX_FRAMES * 2];
    float    _sidechainInput[MK_SIDECHAIN_MAX_FRAMES * 2];
    float    _sidechainSidetone[MK_SIDECHAIN_MAX_FRAMES * 2];
    BOOL     _sidechainMasterBus1Valid;
    BOOL     _sidechainMasterBus2Valid;
    BOOL     _sidechainInputValid;
    BOOL     _sidechainSidetoneValid;
    NSUInteger   _sidechainInputFrameCount;
    NSUInteger   _sidechainInputChannels;
    NSUInteger   _sidechainSidetoneFrameCount;
    NSUInteger   _sidechainSidetoneChannels;
    NSUInteger   _sidechainFrameCount;
    NSUInteger   _sidechainChannels;
    NSUInteger   _inputMonitorLastSequence;
}
@end

@implementation MKAudioOutput

- (id) initWithDevice:(MKAudioDevice *)device andSettings:(MKAudioSettings *)settings {
    if ((self = [super init])) {
        memcpy(&_settings, settings, sizeof(MKAudioSettings));
        _device = [device retain];
        _sampleSize = 0;
        _frameSize = SAMPLE_RATE / 100;
        _mixerFrequency = 0;
        _outputLock = [[NSLock alloc] init];
        _outputs = [[NSMutableDictionary alloc] init];
        
        _sessionVolumes = [[NSMutableDictionary alloc] init];
        _sessionMutes = [[NSMutableDictionary alloc] init];
        _remoteSessionOrder = [[NSMutableArray alloc] init];
        _remoteTrackProcessors = [[NSMutableDictionary alloc] init];
        _remoteTrackProcessorContexts = [[NSMutableDictionary alloc] init];
        _remoteBusProcessor = NULL;
        _remoteBusProcessorContext = NULL;
        _remoteBus2Processor = NULL;
        _remoteBus2ProcessorContext = NULL;
        _sessionBusAssignment = [[NSMutableDictionary alloc] init];
        _sessionUsesTrackSendRouting = [[NSMutableDictionary alloc] init];
        _sessionTrackSendBusMasks = [[NSMutableDictionary alloc] init];
        _inputTrackSendBusMask = 0;
        _sessionDSPStatuses = [[NSMutableDictionary alloc] init];

        _mixerFrequency = [_device outputSampleRate];
        if (_mixerFrequency <= 0) {
            _mixerFrequency = [_device inputSampleRate];
        }
        if (_mixerFrequency <= 0) {
            _mixerFrequency = SAMPLE_RATE;
        }
        _numChannels = [_device numberOfOutputChannels];
        _sampleSize = _numChannels * sizeof(short);
        
        _cngRegister1 = 0x67452301;
        _cngRegister2 = 0xefcdab89;
        _cngEnabled = settings->enableComfortNoise;
        _cngAmpliScaler = 2.0f / 0xffffffff;
        _cngAmpliScaler *= 0.00150;
        _cngAmpliScaler *= settings->comfortNoiseLevel;
        _cngLastSample = 0.0;
            
       if (_speakerVolume) {
            free(_speakerVolume);
        }
        _speakerVolume = malloc(sizeof(float)*_numChannels);
        
        int i;
        for (i = 0; i < _numChannels; ++i) {
            _speakerVolume[i] = 1.0f;
        }
        
        [_device setupOutput:^BOOL(short *frames, unsigned int nsamp) {
            return [self mixFrames:frames amount:nsamp];
        }];
        
        _mixerInfo = [[NSDictionary dictionaryWithObjectsAndKeys:
                [NSDate date], @"last-update",
                [NSArray array], @"sources",
                [NSArray array], @"removed",
            nil] retain];
        _mixerInfoLock = [[NSLock alloc] init];
    }
    return self;
}

- (void) dealloc {
    [_mixerInfoLock release];
    [_mixerInfo release];
    [_device setupOutput:NULL];
    [_device release];
    [_outputLock release];
    [_outputs release];
    [_sessionVolumes release];
    [_sessionMutes release];
    [_remoteSessionOrder release];
    [_remoteTrackProcessors release];
    [_remoteTrackProcessorContexts release];
    [_sessionBusAssignment release];
    [_sessionUsesTrackSendRouting release];
    [_sessionTrackSendBusMasks release];
    [_sessionDSPStatuses release];
    [super dealloc];
}

- (NSDictionary *) audioOutputDebugDescription:(id)ou {
    if ([ou isKindOfClass:[MKAudioOutputSpeech class]]) {
        MKAudioOutputSpeech *ous = (MKAudioOutputSpeech *)ou;
        
        NSString *msgType = nil;
        switch ([ous messageType]) {
            case UDPVoiceCELTAlphaMessage:
                msgType = @"celt-alpha";
                break;
            case UDPVoiceCELTBetaMessage:
                msgType = @"celt-beta";
                break;
            case UDPVoiceSpeexMessage:
                msgType = @"speex";
                break;
            case UDPVoiceOpusMessage:
                msgType = @"opus";
                break;
            default:
                msgType = @"unknown";
                break;
        }
        
        return [NSDictionary dictionaryWithObjectsAndKeys:
                @"user", @"kind",
                [NSString stringWithFormat:@"session %lu codec %@", (unsigned long) [ous userSession], msgType], @"identifier",
            nil];
    } else if ([ou isKindOfClass:[MKAudioOutputSidetone class]]) {
        return [NSDictionary dictionaryWithObjectsAndKeys:
                    @"sidetone", @"kind",
                    @"sidetone", @"identifier",
            nil];
    } else {
        return [NSDictionary dictionaryWithObjectsAndKeys:
                @"unknown", @"kind",
                @"unknown", @"identifier",
            nil];
    }
}

- (BOOL) mixFrames:(void *)frames amount:(unsigned int)nsamp {
    unsigned int i, s;
    BOOL retVal = NO;
    float globalVolume = _settings.volume;
    if (globalVolume < 0.0f) {
        globalVolume = 0.0f;
    }

    // Sidechain: invalidate all slots at start of each cycle
    for (int si = 0; si < MK_SIDECHAIN_MAX_SESSIONS; si++) {
        _sidechainUserSlots[si].valid = NO;
    }
    _sidechainMasterBus1Valid = NO;
    _sidechainMasterBus2Valid = NO;
    _sidechainInputValid = NO;
    _sidechainSidetoneValid = NO;
    _sidechainFrameCount = nsamp;
    _sidechainChannels = _numChannels;
    _sidechainInputFrameCount = 0;
    _sidechainInputChannels = 0;
    _sidechainSidetoneFrameCount = 0;
    _sidechainSidetoneChannels = 0;

    // Update post-input-track and post-sidetone-track sidechain snapshots from ping-pong buffers.
    {
        MKAudio *audio = [MKAudio sharedAudio];
        if (audio != nil) {
            NSUInteger scFrames = 0, scChannels = 0;
            const float *scBuf = [audio readSidechainInputBufferWithMaxFrameCount:(NSUInteger)nsamp
                                                                     outFrameCount:&scFrames
                                                                          channels:&scChannels];
            [self setSidechainInputBuffer:scBuf frameCount:scFrames channels:scChannels];
            NSUInteger sidetoneFrames = 0, sidetoneChannels = 0;
            const float *sidetoneBuf = [audio readSidetoneSidechainBufferWithMaxFrameCount:(NSUInteger)nsamp
                                                                              outFrameCount:&sidetoneFrames
                                                                                   channels:&sidetoneChannels];
            [self setSidetoneTrackSidechainBuffer:sidetoneBuf frameCount:sidetoneFrames channels:sidetoneChannels];
        }
    }

    NSUInteger inputMonitorFrameCount = 0, inputMonitorChannels = 0;
    const float *inputMonitorBuffer = NULL;
    BOOL hasInputMonitorFrame = NO;
    {
        MKAudio *audio = [MKAudio sharedAudio];
        if (audio != nil && _settings.enableSideTone && _settings.sidetoneVolume > 0.0001f) {
            inputMonitorBuffer = [audio readInputMonitorBufferWithMaxFrameCount:(NSUInteger)nsamp
                                                                  outFrameCount:&inputMonitorFrameCount
                                                                       channels:&inputMonitorChannels];
            hasInputMonitorFrame = (inputMonitorBuffer != NULL);
        }
    }

    NSMutableArray *mix = [[NSMutableArray alloc] init];
    NSMutableArray *del = [[NSMutableArray alloc] init];
    unsigned int nchan = _numChannels;

    [_outputLock lock];
    for (NSNumber *sessionKey in _remoteSessionOrder) {
        MKAudioOutputUser *ou = [_outputs objectForKey:sessionKey];
        if (ou == nil) {
            continue;
        }
        if (! [ou needSamples:nsamp]) {
            [del addObject:ou];
        } else {
            [mix addObject:ou];
        }
    }
    
    if (_settings.audioMixerDebug) {
        NSMutableDictionary *mixerInfo = [[[NSMutableDictionary alloc] init] autorelease];
        NSMutableArray *sources = [[[NSMutableArray alloc] init] autorelease];
        NSMutableArray *removed = [[[NSMutableArray alloc] init] autorelease];

        for (id ou in mix) {
            [sources addObject:[self audioOutputDebugDescription:ou]];
        }
        for (id ou in del) {
            [removed addObject:[self audioOutputDebugDescription:ou]];
        }

    
        [mixerInfo setObject:[NSDate date] forKey:@"last-update"];
        [mixerInfo setObject:sources forKey:@"sources"];
        [mixerInfo setObject:removed forKey:@"removed"];
    
        [_mixerInfoLock lock];
        [_mixerInfo release];
        _mixerInfo = [mixerInfo retain];
        [_mixerInfoLock unlock];
    }
    
    const size_t bufferBytes = sizeof(float) * _numChannels * nsamp;
    float *mixBuffer1 = alloca(bufferBytes);
    float *mixBuffer2 = alloca(bufferBytes);
    float *sidetoneBuffer = alloca(bufferBytes);
    memset(mixBuffer1, 0, bufferBytes);
    memset(mixBuffer2, 0, bufferBytes);
    memset(sidetoneBuffer, 0, bufferBytes);

    for (MKAudioOutputUser *ou in mix) {
        NSUInteger sessionID = [(MKAudioOutputSpeech *)ou userSession];
        NSNumber *sessionKey = [NSNumber numberWithUnsignedInteger:sessionID];

        if ([[_sessionMutes objectForKey:sessionKey] boolValue]) {
            continue;
        }

        float volMultiplier = 1.0f;
        NSNumber *customVol = [_sessionVolumes objectForKey:sessionKey];
        if (customVol) {
            volMultiplier = [customVol floatValue];
        }

        MKAudioOutputFloatProcessCallback trackProcessor = NULL;
        void *trackContext = NULL;
        NSValue *processorValue = [_remoteTrackProcessors objectForKey:sessionKey];
        NSValue *contextValue = [_remoteTrackProcessorContexts objectForKey:sessionKey];
        if (processorValue != nil) {
            trackProcessor = (MKAudioOutputFloatProcessCallback)[processorValue pointerValue];
            if (contextValue != nil) {
                trackContext = [contextValue pointerValue];
            }
        }

        float *userBuffer = [ou buffer];
        NSUInteger sourceChannels = MAX((NSUInteger)1, [ou outputChannels]);

        if (trackProcessor != NULL) {
            trackProcessor(userBuffer, (NSUInteger)nsamp, sourceChannels, (NSUInteger)_mixerFrequency, trackContext);
        }

        // Sidechain: capture post-track per-user audio so multiple destinations can reuse it.
        if (nsamp <= MK_SIDECHAIN_MAX_FRAMES) {
            for (int si = 0; si < MK_SIDECHAIN_MAX_SESSIONS; si++) {
                if (!_sidechainUserSlots[si].valid) {
                    _sidechainUserSlots[si].session = sessionID;
                    _sidechainUserSlots[si].frameCount = nsamp;
                    _sidechainUserSlots[si].channels = sourceChannels;
                    _sidechainUserSlots[si].valid = YES;
                    memcpy(_sidechainUserSlots[si].buffer, userBuffer, sizeof(float) * nsamp * sourceChannels);
                    break;
                }
            }
        }

        BOOL usesTrackSendRouting = [[_sessionUsesTrackSendRouting objectForKey:sessionKey] boolValue];
        NSUInteger sendBusMask = [[_sessionTrackSendBusMasks objectForKey:sessionKey] unsignedIntegerValue];
        NSUInteger directBusMask = 0;
        if (usesTrackSendRouting) {
            directBusMask = sendBusMask & 0x3;
        } else {
            NSNumber *busAssign = [_sessionBusAssignment objectForKey:sessionKey];
            directBusMask = (busAssign != nil && [busAssign unsignedIntegerValue] == 1) ? 0x2 : 0x1;
        }

        if (directBusMask != 0) {
            for (NSUInteger busIndex = 0; busIndex < 2; busIndex++) {
                if ((directBusMask & (1u << busIndex)) == 0) {
                    continue;
                }
                float *targetBuffer = (busIndex == 0) ? mixBuffer1 : mixBuffer2;
                for (s = 0; s < nchan; ++s) {
                    const float str = _speakerVolume[s] * volMultiplier * globalVolume;
                    NSUInteger sourceChannelIndex = sourceChannels > 1 ? MIN((NSUInteger)s, sourceChannels - 1) : 0;

                    float * restrict o = targetBuffer + s;
                    for (i = 0; i < nsamp; ++i) {
                        float sample = userBuffer[i * sourceChannels + sourceChannelIndex];
                        if (nchan == 1 && sourceChannels > 1) {
                            sample = 0.5f * (userBuffer[i * sourceChannels] + userBuffer[i * sourceChannels + 1]);
                        }
                        o[i*nchan] += sample * str;
                    }
                }
            }
        }
    }

    if (hasInputMonitorFrame) {
        NSUInteger framesToMix = MIN((NSUInteger)nsamp, inputMonitorFrameCount);
        NSUInteger sourceChannels = MAX((NSUInteger)1, inputMonitorChannels);
        for (s = 0; s < nchan; ++s) {
            const float str = _speakerVolume[s] * _settings.sidetoneVolume * globalVolume;
            NSUInteger sourceChannelIndex = sourceChannels > 1 ? MIN((NSUInteger)s, sourceChannels - 1) : 0;
            float * restrict o = sidetoneBuffer + s;
            for (i = 0; i < framesToMix; ++i) {
                float sample = inputMonitorBuffer[i * sourceChannels + sourceChannelIndex];
                if (nchan == 1 && sourceChannels > 1) {
                    sample = 0.5f * (inputMonitorBuffer[i * sourceChannels] + inputMonitorBuffer[i * sourceChannels + 1]);
                }
                o[i*nchan] += sample * str;
            }
        }
    }

    if (_sidechainInputValid && _sidechainInputFrameCount > 0 && (_inputTrackSendBusMask & 0x3) != 0) {
        NSUInteger framesToMix = MIN((NSUInteger)nsamp, _sidechainInputFrameCount);
        NSUInteger sourceChannels = MAX((NSUInteger)1, _sidechainInputChannels);
        for (NSUInteger busIndex = 0; busIndex < 2; busIndex++) {
            if ((_inputTrackSendBusMask & (1u << busIndex)) == 0) {
                continue;
            }
            float *targetBuffer = (busIndex == 0) ? mixBuffer1 : mixBuffer2;
            for (s = 0; s < nchan; ++s) {
                const float str = _speakerVolume[s] * globalVolume;
                NSUInteger sourceChannelIndex = sourceChannels > 1 ? MIN((NSUInteger)s, sourceChannels - 1) : 0;
                float * restrict o = targetBuffer + s;
                for (i = 0; i < framesToMix; ++i) {
                    float sample = _sidechainInput[i * sourceChannels + sourceChannelIndex];
                    if (nchan == 1 && sourceChannels > 1) {
                        sample = 0.5f * (_sidechainInput[i * sourceChannels] + _sidechainInput[i * sourceChannels + 1]);
                    }
                    o[i*nchan] += sample * str;
                }
            }
        }
    }

    // 允许总线在没有远端用户时也渲染，这样轨道 send 可以直接进 master 轨。
    if (_remoteBusProcessor != NULL) {
        _remoteBusProcessor(mixBuffer1, (NSUInteger)nsamp, (NSUInteger)_numChannels, (NSUInteger)_mixerFrequency, _remoteBusProcessorContext);
    }
    if (_remoteBus2Processor != NULL) {
        _remoteBus2Processor(mixBuffer2, (NSUInteger)nsamp, (NSUInteger)_numChannels, (NSUInteger)_mixerFrequency, _remoteBus2ProcessorContext);
    }

    // Sidechain: capture post-track/post-bus signals after their plugins have run.
    if (nsamp <= MK_SIDECHAIN_MAX_FRAMES) {
        memcpy(_sidechainMasterBus1, mixBuffer1, bufferBytes);
        _sidechainMasterBus1Valid = YES;
        memcpy(_sidechainMasterBus2, mixBuffer2, bufferBytes);
        _sidechainMasterBus2Valid = YES;
    }

    // 合并两个总线到最终输出，并用最终结果决定是否需要 CNG。
    short *outputBuffer = (short *)frames;
    retVal = NO;
    for (i = 0; i < nsamp * _numChannels; ++i) {
        float combined = mixBuffer1[i] + mixBuffer2[i] + sidetoneBuffer[i];
        if (combined > 0.00001f || combined < -0.00001f) {
            retVal = YES;
        }
        if (combined >= 1.0f) {
            outputBuffer[i] = 32767;
        } else if (combined < -1.0f) {
            outputBuffer[i] = -32768;
        } else {
            outputBuffer[i] = combined * 32768.0f;
        }
    }
    [_outputLock unlock];

    for (MKAudioOutputUser *ou in del) {
        [self removeBuffer:ou];
    }

    retVal = retVal || hasInputMonitorFrame;

    [mix release];
    [del release];

    if(!retVal && _cngEnabled) {
        short *outputBuffer = (short *)frames;
        
        for (i = 0; i < nsamp * _numChannels; ++i) {
            float    runningvalue;
            
            _cngRegister1 ^= _cngRegister2;
            runningvalue = (float)_cngRegister2 * _cngAmpliScaler;
            runningvalue *= globalVolume;
            runningvalue += _cngLastSample; //one pole smoother
            runningvalue *= 0.5;            //one pole smoother
            _cngLastSample = runningvalue;
            _cngRegister2 += _cngRegister1;
            
            if (runningvalue >= 1.0f) {
                outputBuffer[i] = 32767;
            } else if (runningvalue < -1.0f) {
                outputBuffer[i] = -32768;
            } else {
                outputBuffer[i] = runningvalue * 32768.0f;
            }
        }
        retVal = YES;
    }

    return retVal;
}

- (void) removeBuffer:(MKAudioOutputUser *)u {
    if ([u respondsToSelector:@selector(userSession)]) {
        NSNumber *sessionKey = [NSNumber numberWithUnsignedInteger:[(id)u userSession]];
        [_outputLock lock];
        [_outputs removeObjectForKey:sessionKey];
        [_remoteSessionOrder removeObject:sessionKey];
        // 注意：不清除 _remoteTrackProcessors / _remoteTrackProcessorContexts /
        // _sessionVolumes / _sessionMutes —— 这些是用户级持久设置，
        // 应在 VAD 静默→重新说话周期间保留。
        // 它们由 MKAudio 层显式管理（setRemoteTrackAudioUnitChain / clearRemoteTrack 等）。
        [_outputLock unlock];
    }
}

- (void) addFrameToBufferWithSession:(NSUInteger)session data:(NSData *)data sequence:(NSUInteger)seq type:(MKUDPMessageType)msgType {
    if (_numChannels == 0)
        return;

    NSNumber *sessionKey = [NSNumber numberWithUnsignedInteger:session];

    [_outputLock lock];
    MKAudioOutputSpeech *outputUser = [_outputs objectForKey:sessionKey];
    [outputUser retain];
    [_outputLock unlock];

    if (outputUser == nil || [outputUser messageType] != msgType) {
        if (outputUser != nil) {
            [self removeBuffer:outputUser];
            [outputUser release];
        }
        BOOL useStereoOutput = _settings.enableStereoOutput && _numChannels > 1;
        outputUser = [[MKAudioOutputSpeech alloc] initWithSession:session sampleRate:_mixerFrequency messageType:msgType useStereo:useStereoOutput];
        [_outputLock lock];
        [_outputs setObject:outputUser forKey:sessionKey];
        if (![_remoteSessionOrder containsObject:sessionKey]) {
            [_remoteSessionOrder addObject:sessionKey];
        }
        [_outputLock unlock];
    }

    [outputUser addFrame:data forSequence:seq];
    [outputUser release];
}

- (NSDictionary *) copyMixerInfo {
    NSDictionary *mixerInfoCopy = nil;
    [_mixerInfoLock lock];
    mixerInfoCopy = [_mixerInfo copy];
    [_mixerInfoLock unlock];
    return mixerInfoCopy;
}

- (void) setMasterVolume:(float)volume {
    [_outputLock lock];
    _settings.volume = volume;
    [_outputLock unlock];
}

- (void) setVolume:(float)volume forSession:(NSUInteger)session {
    [_outputLock lock];
    [_sessionVolumes setObject:[NSNumber numberWithFloat:volume] forKey:[NSNumber numberWithUnsignedInteger:session]];
    [_outputLock unlock];
}

- (void) setMuted:(BOOL)muted forSession:(NSUInteger)session {
    [_outputLock lock];
    [_sessionMutes setObject:[NSNumber numberWithBool:muted] forKey:[NSNumber numberWithUnsignedInteger:session]];
    [_outputLock unlock];
}

- (void) setRemoteTrackProcessor:(MKAudioOutputFloatProcessCallback)processor context:(void *)context forSession:(NSUInteger)session {
    NSNumber *sessionKey = [NSNumber numberWithUnsignedInteger:session];
    [_outputLock lock];
    if (processor != NULL) {
        [_remoteTrackProcessors setObject:[NSValue valueWithPointer:processor] forKey:sessionKey];
        [_remoteTrackProcessorContexts setObject:[NSValue valueWithPointer:context] forKey:sessionKey];
    } else {
        [_remoteTrackProcessors removeObjectForKey:sessionKey];
        [_remoteTrackProcessorContexts removeObjectForKey:sessionKey];
    }
    [_outputLock unlock];
}

- (void) clearRemoteTrackProcessorForSession:(NSUInteger)session {
    NSNumber *sessionKey = [NSNumber numberWithUnsignedInteger:session];
    [_outputLock lock];
    [_remoteTrackProcessors removeObjectForKey:sessionKey];
    [_remoteTrackProcessorContexts removeObjectForKey:sessionKey];
    [_outputLock unlock];
}

- (void) clearAllRemoteTrackProcessors {
    [_outputLock lock];
    [_remoteTrackProcessors removeAllObjects];
    [_remoteTrackProcessorContexts removeAllObjects];
    [_outputLock unlock];
}

- (void) setRemoteBusProcessor:(MKAudioOutputFloatProcessCallback)processor context:(void *)context {
    [_outputLock lock];
    _remoteBusProcessor = processor;
    _remoteBusProcessorContext = context;
    [_outputLock unlock];
}

- (void) clearRemoteBusProcessor {
    [_outputLock lock];
    _remoteBusProcessor = NULL;
    _remoteBusProcessorContext = NULL;
    [_outputLock unlock];
}

- (void) setRemoteBus2Processor:(MKAudioOutputFloatProcessCallback)processor context:(void *)context {
    [_outputLock lock];
    _remoteBus2Processor = processor;
    _remoteBus2ProcessorContext = context;
    [_outputLock unlock];
}

- (void) clearRemoteBus2Processor {
    [_outputLock lock];
    _remoteBus2Processor = NULL;
    _remoteBus2ProcessorContext = NULL;
    [_outputLock unlock];
}

- (void) setInputMonitorEnabled:(BOOL)enabled gain:(float)gain {
    [_outputLock lock];
    _settings.enableSideTone = enabled;
    _settings.sidetoneVolume = gain < 0.0f ? 0.0f : gain;
    if (!enabled) {
        _inputMonitorLastSequence = 0;
    }
    [_outputLock unlock];
}

- (void) setBusAssignment:(NSUInteger)busIndex forSession:(NSUInteger)session {
    NSNumber *sessionKey = [NSNumber numberWithUnsignedInteger:session];
    [_outputLock lock];
    [_sessionBusAssignment setObject:[NSNumber numberWithUnsignedInteger:busIndex] forKey:sessionKey];
    [_outputLock unlock];
}

- (NSUInteger) busAssignmentForSession:(NSUInteger)session {
    NSNumber *sessionKey = [NSNumber numberWithUnsignedInteger:session];
    [_outputLock lock];
    NSNumber *assignment = [_sessionBusAssignment objectForKey:sessionKey];
    [_outputLock unlock];
    return assignment ? [assignment unsignedIntegerValue] : 0;
}

- (void) setUsesTrackSendRouting:(BOOL)enabled forSession:(NSUInteger)session {
    NSNumber *sessionKey = [NSNumber numberWithUnsignedInteger:session];
    [_outputLock lock];
    if (enabled) {
        [_sessionUsesTrackSendRouting setObject:[NSNumber numberWithBool:YES] forKey:sessionKey];
    } else {
        [_sessionUsesTrackSendRouting removeObjectForKey:sessionKey];
    }
    [_outputLock unlock];
}

- (void) setTrackSendBusMask:(NSUInteger)busMask forSession:(NSUInteger)session {
    NSNumber *sessionKey = [NSNumber numberWithUnsignedInteger:session];
    [_outputLock lock];
    if ((busMask & 0x3) != 0) {
        [_sessionTrackSendBusMasks setObject:[NSNumber numberWithUnsignedInteger:(busMask & 0x3)] forKey:sessionKey];
    } else {
        [_sessionTrackSendBusMasks removeObjectForKey:sessionKey];
    }
    [_outputLock unlock];
}

- (void) setInputTrackSendBusMask:(NSUInteger)busMask {
    [_outputLock lock];
    _inputTrackSendBusMask = (busMask & 0x3);
    [_outputLock unlock];
}

- (NSArray *) copyRemoteSessionOrder {
    [_outputLock lock];
    NSArray *order = [_remoteSessionOrder copy];
    [_outputLock unlock];
    return order;
}

- (NSUInteger) outputSampleRate {
    [_outputLock lock];
    NSUInteger sampleRate = (NSUInteger)_mixerFrequency;
    [_outputLock unlock];
    return sampleRate;
}

- (NSDictionary *) copyDSPStatusForSession:(NSUInteger)session {
    NSNumber *sessionKey = [NSNumber numberWithUnsignedInteger:session];
    [_outputLock lock];
    NSValue *value = [_sessionDSPStatuses objectForKey:sessionKey];
    [_outputLock unlock];

    if (value == nil) {
        return [[NSDictionary alloc] initWithObjectsAndKeys:
            @0.0f, @"inputPeak",
            @0.0f, @"outputPeak",
            @(noErr), @"lastRenderStatus",
            @0, @"frameCount",
            nil];
    }

    MKAudioDSPStatus *status = (MKAudioDSPStatus *)[value pointerValue];
    os_unfair_lock_lock(&status->lock);
    NSDictionary *result = [[NSDictionary alloc] initWithObjectsAndKeys:
        [NSNumber numberWithFloat:status->inputPeak], @"inputPeak",
        [NSNumber numberWithFloat:status->outputPeak], @"outputPeak",
        [NSNumber numberWithInt:status->lastRenderStatus], @"lastRenderStatus",
        [NSNumber numberWithUnsignedInteger:status->frameCount], @"frameCount",
        nil];
    os_unfair_lock_unlock(&status->lock);
    return result;
}

#pragma mark - Sidechain Buffer Pool

- (const float *) sidechainBufferForSourceKey:(NSString *)key
                                   frameCount:(NSUInteger *)outFrameCount
                                     channels:(NSUInteger *)outChannels {
    if (key == nil) return NULL;

    if ([key isEqualToString:@"input"]) {
        if (_sidechainInputValid && _sidechainInputFrameCount > 0) {
            *outFrameCount = _sidechainInputFrameCount;
            *outChannels = _sidechainInputChannels;
            return _sidechainInput;
        }
        return NULL;
    }

    if ([key isEqualToString:@"masterBus1"]) {
        if (_sidechainMasterBus1Valid) {
            *outFrameCount = _sidechainFrameCount;
            *outChannels = _sidechainChannels;
            return _sidechainMasterBus1;
        }
        return NULL;
    }

    if ([key isEqualToString:@"masterBus2"]) {
        if (_sidechainMasterBus2Valid) {
            *outFrameCount = _sidechainFrameCount;
            *outChannels = _sidechainChannels;
            return _sidechainMasterBus2;
        }
        return NULL;
    }

    if ([key isEqualToString:@"sidetone"]) {
        if (_sidechainSidetoneValid) {
            *outFrameCount = _sidechainSidetoneFrameCount;
            *outChannels = _sidechainSidetoneChannels;
            return _sidechainSidetone;
        }
        return NULL;
    }

    if ([key hasPrefix:@"session:"]) {
        NSUInteger session = (NSUInteger)[[key substringFromIndex:8] integerValue];
        for (int si = 0; si < MK_SIDECHAIN_MAX_SESSIONS; si++) {
            if (_sidechainUserSlots[si].valid && _sidechainUserSlots[si].session == session) {
                *outFrameCount = _sidechainUserSlots[si].frameCount;
                *outChannels = _sidechainUserSlots[si].channels;
                return _sidechainUserSlots[si].buffer;
            }
        }
    }

    return NULL;
}

- (void) setSidechainInputBuffer:(const float *)buffer frameCount:(NSUInteger)frameCount channels:(NSUInteger)channels {
    if (buffer == NULL || frameCount == 0 || channels == 0 || channels > 2 || frameCount > MK_SIDECHAIN_MAX_FRAMES) {
        _sidechainInputValid = NO;
        _sidechainInputFrameCount = 0;
        _sidechainInputChannels = 0;
        return;
    }
    memcpy(_sidechainInput, buffer, frameCount * channels * sizeof(float));
    _sidechainInputValid = YES;
    _sidechainInputFrameCount = frameCount;
    _sidechainInputChannels = channels;
}

- (void) setSidetoneTrackSidechainBuffer:(const float *)buffer frameCount:(NSUInteger)frameCount channels:(NSUInteger)channels {
    if (buffer == NULL || frameCount == 0 || channels == 0 || channels > 2 || frameCount > MK_SIDECHAIN_MAX_FRAMES) {
        _sidechainSidetoneValid = NO;
        _sidechainSidetoneFrameCount = 0;
        _sidechainSidetoneChannels = 0;
        return;
    }
    memcpy(_sidechainSidetone, buffer, frameCount * channels * sizeof(float));
    _sidechainSidetoneFrameCount = frameCount;
    _sidechainSidetoneChannels = channels;
    _sidechainSidetoneValid = YES;
}

@end
