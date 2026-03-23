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

    // DSP observability - per-session status
    NSMutableDictionary  *_sessionDSPStatuses;

    // Sidechain buffer pool - pre-allocated, no runtime allocation
    struct MKSidechainSlot _sidechainUserSlots[MK_SIDECHAIN_MAX_SESSIONS];
    float    _sidechainMasterBus1[MK_SIDECHAIN_MAX_FRAMES * 2];
    float    _sidechainMasterBus2[MK_SIDECHAIN_MAX_FRAMES * 2];
    BOOL     _sidechainMasterBus1Valid;
    BOOL     _sidechainMasterBus2Valid;
    const float *_sidechainInputBuffer;
    NSUInteger   _sidechainInputFrameCount;
    NSUInteger   _sidechainInputChannels;
    NSUInteger   _sidechainFrameCount;
    NSUInteger   _sidechainChannels;
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
    _sidechainFrameCount = nsamp;
    _sidechainChannels = _numChannels;

    // Update input sidechain from ping-pong buffer
    {
        MKAudio *audio = [MKAudio sharedAudio];
        if (audio != nil) {
            NSUInteger scFrames = 0, scChannels = 0;
            const float *scBuf = [audio readSidechainInputBufferWithFrameCount:&scFrames channels:&scChannels];
            [self setSidechainInputBuffer:scBuf frameCount:scFrames channels:scChannels];
        }
    }

    NSMutableArray *mix = [[NSMutableArray alloc] init];
    NSMutableArray *sidetoneMix = [[NSMutableArray alloc] init];
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
    
    if (_settings.enableSideTone) {
        MKAudioOutputSidetone *sidetone = [[MKAudio sharedAudio] sidetoneOutput];
        if ([sidetone needSamples:nsamp]) {
            [sidetoneMix addObject:[[MKAudio sharedAudio] sidetoneOutput]];
        }
    }
    
    if (_settings.audioMixerDebug) {
        NSMutableDictionary *mixerInfo = [[[NSMutableDictionary alloc] init] autorelease];
        NSMutableArray *sources = [[[NSMutableArray alloc] init] autorelease];
        NSMutableArray *removed = [[[NSMutableArray alloc] init] autorelease];

        for (id ou in mix) {
            [sources addObject:[self audioOutputDebugDescription:ou]];
        }
        for (id ou in sidetoneMix) {
            [sources addObject:[self audioOutputDebugDescription:ou]];
        }
    
        for (id ou in del) {
            [sources addObject:[self audioOutputDebugDescription:ou]];
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
    memset(mixBuffer1, 0, bufferBytes);
    memset(mixBuffer2, 0, bufferBytes);

    if ([mix count] > 0 || [sidetoneMix count] > 0) {
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

            // Sidechain: capture pre-fader per-user audio
            if (nsamp <= MK_SIDECHAIN_MAX_FRAMES) {
                for (int si = 0; si < MK_SIDECHAIN_MAX_SESSIONS; si++) {
                    if (!_sidechainUserSlots[si].valid) {
                        _sidechainUserSlots[si].session = sessionID;
                        _sidechainUserSlots[si].valid = YES;
                        memcpy(_sidechainUserSlots[si].buffer, userBuffer, sizeof(float) * nsamp * sourceChannels);
                        break;
                    }
                }
            }

            if (trackProcessor != NULL) {
                trackProcessor(userBuffer, (NSUInteger)nsamp, sourceChannels, (NSUInteger)_mixerFrequency, trackContext);
            }

            // 根据 busAssignment 路由到 mixBuffer1 或 mixBuffer2
            NSNumber *busAssign = [_sessionBusAssignment objectForKey:sessionKey];
            float *targetBuffer = (busAssign != nil && [busAssign unsignedIntegerValue] == 1) ? mixBuffer2 : mixBuffer1;

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

        // Sidechain: capture pre-processor master bus audio
        if (nsamp <= MK_SIDECHAIN_MAX_FRAMES) {
            memcpy(_sidechainMasterBus1, mixBuffer1, bufferBytes);
            _sidechainMasterBus1Valid = YES;
            memcpy(_sidechainMasterBus2, mixBuffer2, bufferBytes);
            _sidechainMasterBus2Valid = YES;
            MKLogInfo(Audio, @"MKAudioOutput: Captured sidechain buffers for masterBus1/masterBus2 (%u frames, %u channels)", (unsigned)nsamp, (unsigned)_numChannels);
        }

        // 分别对两个总线应用各自的处理器
        if (_remoteBusProcessor != NULL && [mix count] > 0) {
            _remoteBusProcessor(mixBuffer1, (NSUInteger)nsamp, (NSUInteger)_numChannels, (NSUInteger)_mixerFrequency, _remoteBusProcessorContext);
        }
        if (_remoteBus2Processor != NULL && [mix count] > 0) {
            _remoteBus2Processor(mixBuffer2, (NSUInteger)nsamp, (NSUInteger)_numChannels, (NSUInteger)_mixerFrequency, _remoteBus2ProcessorContext);
        }

        for (MKAudioOutputUser *ou in sidetoneMix) {
            const float * restrict userBuffer = [ou buffer];
            NSUInteger sourceChannels = MAX((NSUInteger)1, [ou outputChannels]);
            for (s = 0; s < nchan; ++s) {
                const float str = _speakerVolume[s] * globalVolume;
                NSUInteger sourceChannelIndex = sourceChannels > 1 ? MIN((NSUInteger)s, sourceChannels - 1) : 0;
                float * restrict o = mixBuffer1 + s;
                for (i = 0; i < nsamp; ++i) {
                    float sample = userBuffer[i * sourceChannels + sourceChannelIndex];
                    if (nchan == 1 && sourceChannels > 1) {
                        sample = 0.5f * (userBuffer[i * sourceChannels] + userBuffer[i * sourceChannels + 1]);
                    }
                    o[i*nchan] += sample * str;
                }
            }
        }

        // 合并两个总线到最终输出
        short *outputBuffer = (short *)frames;
        for (i = 0; i < nsamp * _numChannels; ++i) {
            float combined = mixBuffer1[i] + mixBuffer2[i];
            if (combined >= 1.0f) {
                outputBuffer[i] = 32767;
            } else if (combined < -1.0f) {
                outputBuffer[i] = -32768;
            } else {
                outputBuffer[i] = combined * 32768.0f;
            }
        }
    } else {
        memset((short *)frames, 0, nsamp * _numChannels * sizeof(short));
    }
    [_outputLock unlock];

    for (MKAudioOutputUser *ou in del) {
        [self removeBuffer:ou];
    }

    retVal = [mix count] > 0 || [sidetoneMix count] > 0;

    [mix release];
    [sidetoneMix release];
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
        if (_sidechainInputBuffer != NULL && _sidechainInputFrameCount > 0) {
            *outFrameCount = _sidechainInputFrameCount;
            *outChannels = _sidechainInputChannels;
            return _sidechainInputBuffer;
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

    if ([key hasPrefix:@"session:"]) {
        NSUInteger session = (NSUInteger)[[key substringFromIndex:8] integerValue];
        for (int si = 0; si < MK_SIDECHAIN_MAX_SESSIONS; si++) {
            if (_sidechainUserSlots[si].valid && _sidechainUserSlots[si].session == session) {
                *outFrameCount = _sidechainFrameCount;
                *outChannels = _sidechainChannels;
                return _sidechainUserSlots[si].buffer;
            }
        }
    }

    return NULL;
}

- (void) setSidechainInputBuffer:(const float *)buffer frameCount:(NSUInteger)frameCount channels:(NSUInteger)channels {
    _sidechainInputBuffer = buffer;
    _sidechainInputFrameCount = frameCount;
    _sidechainInputChannels = channels;
}

@end
