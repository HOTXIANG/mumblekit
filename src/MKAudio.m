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
#include <errno.h>
#import <os/lock.h>
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

typedef struct _MKAudioPreviewGainProcessorState {
    float gain;
    BOOL enabled;
} MKAudioPreviewGainProcessorState;

typedef struct _MKAudioDSPChainProcessorState {
    os_unfair_lock lock;
    MKAudioPreviewGainProcessorState preview;
    NSArray *stages;
    NSArray *audioUnits;
    NSArray *mixLevels;
    NSArray *hosts;
    NSUInteger preferredChannels;
    NSUInteger hostBufferFrames;
    NSUInteger renderSampleRate;
    BOOL sampleRateRefreshPending;
    __unsafe_unretained id owner;
    float inputPeak;
    float outputPeak;
    CFAbsoluteTime lastStateProbeLogTime;
    CFAbsoluteTime lastRenderProbeLogTime;
    CFAbsoluteTime lastRenderFailureLogTime;
} MKAudioDSPChainProcessorState;

@interface MKAudioUnitChainHost : NSObject {
    os_unfair_lock _renderLock;
    AVAudioEngine *_engine;
    AVAudioSourceNode *_sourceNode;
    NSArray *_audioUnits;
    AVAudioFormat *_inputFormat;
    AVAudioFormat *_outputFormat;
    NSArray *_adapterNodes;
    AVAudioPCMBuffer *_outputBuffer;
    AVAudioEngineManualRenderingBlock _manualRenderingBlock;
    AUAudioFrameCount _maximumFramesToRender;
    NSUInteger _preferredChannels;
    const float *_currentInputSamples;
    NSUInteger _currentInputFrameCount;
    NSUInteger _currentInputChannelCount;
    NSUInteger _currentInputReadOffset;
    float *_sourceScratchBuffer;
    NSUInteger _sourceScratchCapacity;
    float *_mixScratchBuffer;
    NSUInteger _mixScratchCapacity;
}

- (instancetype)initWithAudioUnits:(NSArray *)audioUnits
                  preferredChannels:(NSUInteger)preferredChannels
                         sampleRate:(NSUInteger)sampleRate
                              error:(NSError **)outError;
- (BOOL)reconfigureWithAudioUnits:(NSArray *)audioUnits
                preferredChannels:(NSUInteger)preferredChannels
                        sampleRate:(NSUInteger)sampleRate
                            error:(NSError **)outError;
- (BOOL)processInterleavedSamples:(float *)samples
                       frameCount:(NSUInteger)frameCount
                         channels:(NSUInteger)channels
                       sampleRate:(NSUInteger)sampleRate
                         wetDryMix:(float)wetDryMix
             manualRenderingStatus:(AVAudioEngineManualRenderingStatus *)outRenderStatus
                            error:(OSStatus *)outError;
- (NSString *)probeSummary;

@end

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
    MKAudioDSPChainProcessorState _inputTrackDSPState;
    MKAudioDSPChainProcessorState _remoteBusDSPState;
    NSMutableDictionary      *_remoteTrackPreviewStates;
    NSMutableDictionary      *_remoteTrackDSPStates;  // Remote Session AU DSP chain states
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
}
#if TARGET_OS_OSX == 1
- (void)startObservingDefaultInputDeviceChanges;
- (void)stopObservingDefaultInputDeviceChanges;
- (void)handleDefaultInputDeviceChanged;
- (void)handleDefaultOutputDeviceChanged;
#endif
- (void)rebindRemoteTrackProcessorsToOutputLocked;
- (void)refreshDSPChainState:(MKAudioDSPChainProcessorState *)state stages:(NSArray *)stages logPrefix:(NSString *)logPrefix;
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

static void MKAudioInputPreviewGainProcess(short *samples, NSUInteger frameCount, NSUInteger channels, NSUInteger sampleRate, void *context) {
    (void)sampleRate;
    MKAudioPreviewGainProcessorState *state = (MKAudioPreviewGainProcessorState *)context;
    if (state == NULL || !state->enabled) {
        return;
    }
    float gain = state->gain;
    if (gain == 1.0f) {
        return;
    }

    NSUInteger sampleCount = frameCount * channels;
    for (NSUInteger i = 0; i < sampleCount; i++) {
        float scaled = ((float)samples[i]) * gain;
        if (scaled > 32767.0f) {
            scaled = 32767.0f;
        } else if (scaled < -32768.0f) {
            scaled = -32768.0f;
        }
        samples[i] = (short)scaled;
    }
}

static void MKAudioApplyPreviewGainFloat(float *samples, NSUInteger frameCount, NSUInteger channels, MKAudioPreviewGainProcessorState *state) {
    if (state == NULL || !state->enabled) {
        return;
    }

    float gain = state->gain;
    if (gain == 1.0f) {
        return;
    }

    NSUInteger sampleCount = frameCount * channels;
    for (NSUInteger i = 0; i < sampleCount; i++) {
        samples[i] *= gain;
    }
}

static float MKAudioAverageInterleavedFrame(const float *samples, NSUInteger frame, NSUInteger channels) {
    if (samples == NULL || channels == 0) {
        return 0.0f;
    }

    float sum = 0.0f;
    for (NSUInteger channel = 0; channel < channels; channel++) {
        sum += samples[frame * channels + channel];
    }
    return sum / (float)channels;
}

static NSUInteger MKAudioAudioBufferListChannelCount(const AudioBufferList *bufferList, NSUInteger fallbackChannels) {
    if (bufferList == NULL) {
        return fallbackChannels;
    }

    if (bufferList->mNumberBuffers > 1) {
        return (NSUInteger)bufferList->mNumberBuffers;
    }

    if (bufferList->mNumberBuffers == 1 && bufferList->mBuffers[0].mNumberChannels > 0) {
        return (NSUInteger)bufferList->mBuffers[0].mNumberChannels;
    }

    return fallbackChannels;
}

static BOOL MKAudioAudioBufferListIsInterleaved(const AudioBufferList *bufferList, NSUInteger fallbackChannels) {
    if (bufferList == NULL) {
        return (fallbackChannels > 1);
    }

    if (bufferList->mNumberBuffers > 1) {
        return NO;
    }

    if (bufferList->mNumberBuffers == 1) {
        return (bufferList->mBuffers[0].mNumberChannels > 1) || (fallbackChannels > 1);
    }

    return (fallbackChannels > 1);
}

static void MKAudioZeroAudioBufferList(AudioBufferList *bufferList,
                                       BOOL interleaved,
                                       NSUInteger channelCount,
                                       NSUInteger startFrame,
                                       NSUInteger frameCount) {
    if (bufferList == NULL || frameCount == 0) {
        return;
    }

    if (interleaved) {
        if (bufferList->mNumberBuffers < 1 || bufferList->mBuffers[0].mData == NULL) {
            return;
        }
        float *dest = (float *)bufferList->mBuffers[0].mData;
        memset(dest + (startFrame * channelCount), 0, frameCount * channelCount * sizeof(float));
        bufferList->mBuffers[0].mNumberChannels = (UInt32)channelCount;
        bufferList->mBuffers[0].mDataByteSize = (UInt32)((startFrame + frameCount) * channelCount * sizeof(float));
        return;
    }

    UInt32 availableBuffers = bufferList->mNumberBuffers;
    for (NSUInteger channel = 0; channel < channelCount; channel++) {
        if (channel >= availableBuffers || bufferList->mBuffers[channel].mData == NULL) {
            continue;
        }
        float *dest = (float *)bufferList->mBuffers[channel].mData;
        memset(dest + startFrame, 0, frameCount * sizeof(float));
        bufferList->mBuffers[channel].mNumberChannels = 1;
        bufferList->mBuffers[channel].mDataByteSize = (UInt32)((startFrame + frameCount) * sizeof(float));
    }
}

static BOOL MKAudioEnsureWritableAudioBufferList(AudioBufferList *bufferList,
                                                 BOOL interleaved,
                                                 NSUInteger channelCount,
                                                 NSUInteger frameCapacity,
                                                 float *scratchBuffer,
                                                 NSUInteger scratchCapacity) {
    if (bufferList == NULL || channelCount == 0) {
        return NO;
    }

    NSUInteger requiredSamples = frameCapacity * channelCount;
    if (interleaved) {
        if (bufferList->mNumberBuffers < 1) {
            return NO;
        }
        if (bufferList->mBuffers[0].mData == NULL) {
            if (scratchBuffer == NULL || scratchCapacity < requiredSamples) {
                return NO;
            }
            bufferList->mBuffers[0].mData = scratchBuffer;
        }
        bufferList->mBuffers[0].mNumberChannels = (UInt32)channelCount;
        bufferList->mBuffers[0].mDataByteSize = (UInt32)(requiredSamples * sizeof(float));
        return YES;
    }

    if (bufferList->mNumberBuffers < channelCount) {
        return NO;
    }
    if (scratchBuffer == NULL || scratchCapacity < requiredSamples) {
        for (NSUInteger channel = 0; channel < channelCount; channel++) {
            if (bufferList->mBuffers[channel].mData == NULL) {
                return NO;
            }
        }
    }

    for (NSUInteger channel = 0; channel < channelCount; channel++) {
        if (bufferList->mBuffers[channel].mData == NULL) {
            bufferList->mBuffers[channel].mData = scratchBuffer + (channel * frameCapacity);
        }
        bufferList->mBuffers[channel].mNumberChannels = 1;
        bufferList->mBuffers[channel].mDataByteSize = (UInt32)(frameCapacity * sizeof(float));
    }
    return YES;
}

static void MKAudioCopyHostInterleavedToAudioBufferList(const float *source,
                                                        NSUInteger sourceChannels,
                                                        NSUInteger frameCount,
                                                        AudioBufferList *destination,
                                                        BOOL destinationInterleaved,
                                                        NSUInteger destinationChannels) {
    if (source == NULL || destination == NULL || sourceChannels == 0 || destinationChannels == 0) {
        return;
    }

    if (destinationInterleaved) {
        if (destination->mNumberBuffers < 1 || destination->mBuffers[0].mData == NULL) {
            return;
        }

        float *dest = (float *)destination->mBuffers[0].mData;
        for (NSUInteger frame = 0; frame < frameCount; frame++) {
            if (destinationChannels == 1) {
                dest[frame] = MKAudioAverageInterleavedFrame(source, frame, sourceChannels);
                continue;
            }

            for (NSUInteger channel = 0; channel < destinationChannels; channel++) {
                float sample = 0.0f;
                if (sourceChannels == 1) {
                    sample = source[frame];
                } else {
                    NSUInteger sourceChannel = MIN(channel, sourceChannels - 1);
                    sample = source[frame * sourceChannels + sourceChannel];
                }
                dest[frame * destinationChannels + channel] = sample;
            }
        }

        destination->mBuffers[0].mNumberChannels = (UInt32)destinationChannels;
        destination->mBuffers[0].mDataByteSize = (UInt32)(frameCount * destinationChannels * sizeof(float));
        return;
    }

    UInt32 availableBuffers = destination->mNumberBuffers;
    for (NSUInteger channel = 0; channel < destinationChannels; channel++) {
        if (channel >= availableBuffers || destination->mBuffers[channel].mData == NULL) {
            continue;
        }

        float *dest = (float *)destination->mBuffers[channel].mData;
        for (NSUInteger frame = 0; frame < frameCount; frame++) {
            if (destinationChannels == 1) {
                dest[frame] = MKAudioAverageInterleavedFrame(source, frame, sourceChannels);
                continue;
            }

            if (sourceChannels == 1) {
                dest[frame] = source[frame];
            } else {
                NSUInteger sourceChannel = MIN(channel, sourceChannels - 1);
                dest[frame] = source[frame * sourceChannels + sourceChannel];
            }
        }

        destination->mBuffers[channel].mNumberChannels = 1;
        destination->mBuffers[channel].mDataByteSize = (UInt32)(frameCount * sizeof(float));
    }
}

static float MKAudioReadAudioBufferListSample(const AudioBufferList *source,
                                              BOOL sourceInterleaved,
                                              NSUInteger sourceChannels,
                                              NSUInteger frame,
                                              NSUInteger channel) {
    if (source == NULL || sourceChannels == 0) {
        return 0.0f;
    }

    if (sourceInterleaved) {
        if (source->mNumberBuffers < 1 || source->mBuffers[0].mData == NULL) {
            return 0.0f;
        }
        float *buffer = (float *)source->mBuffers[0].mData;
        return buffer[frame * sourceChannels + MIN(channel, sourceChannels - 1)];
    }

    if (channel >= source->mNumberBuffers || source->mBuffers[channel].mData == NULL) {
        return 0.0f;
    }
    float *buffer = (float *)source->mBuffers[channel].mData;
    return buffer[frame];
}

static void MKAudioCopyAudioBufferListToHostInterleaved(const AudioBufferList *source,
                                                        BOOL sourceInterleaved,
                                                        NSUInteger sourceChannels,
                                                        NSUInteger frameCount,
                                                        float *destination,
                                                        NSUInteger destinationChannels) {
    if (source == NULL || destination == NULL || sourceChannels == 0 || destinationChannels == 0) {
        return;
    }

    for (NSUInteger frame = 0; frame < frameCount; frame++) {
        if (destinationChannels == 1) {
            float sum = 0.0f;
            for (NSUInteger channel = 0; channel < sourceChannels; channel++) {
                sum += MKAudioReadAudioBufferListSample(source, sourceInterleaved, sourceChannels, frame, channel);
            }
            destination[frame] = sum / (float)sourceChannels;
            continue;
        }

        for (NSUInteger channel = 0; channel < destinationChannels; channel++) {
            float sample = 0.0f;
            if (sourceChannels == 1) {
                sample = MKAudioReadAudioBufferListSample(source, sourceInterleaved, sourceChannels, frame, 0);
            } else {
                NSUInteger sourceChannel = MIN(channel, sourceChannels - 1);
                sample = MKAudioReadAudioBufferListSample(source, sourceInterleaved, sourceChannels, frame, sourceChannel);
            }
            destination[frame * destinationChannels + channel] = sample;
        }
    }
}

static AVAudioFormat *MKAudioInputFormatForAudioUnit(id audioUnit) {
    if (audioUnit == nil || ![audioUnit respondsToSelector:@selector(AUAudioUnit)]) {
        return nil;
    }

    AUAudioUnit *au = [audioUnit AUAudioUnit];
    if (au == nil || [au inputBusses] == nil || [[au inputBusses] count] == 0) {
        return nil;
    }

    return [[[au inputBusses] objectAtIndexedSubscript:0] format];
}

static AVAudioFormat *MKAudioOutputFormatForAudioUnit(id audioUnit) {
    if (audioUnit == nil || ![audioUnit respondsToSelector:@selector(AUAudioUnit)]) {
        return nil;
    }

    AUAudioUnit *au = [audioUnit AUAudioUnit];
    if (au == nil || [au outputBusses] == nil || [[au outputBusses] count] == 0) {
        return nil;
    }

    return [[[au outputBusses] objectAtIndexedSubscript:0] format];
}

static AVAudioFormat *MKAudioFormatWithSampleRateAndChannels(AVAudioFormat *format,
                                                             double sampleRate,
                                                             AVAudioChannelCount channels) {
    if (channels == 0) {
        return nil;
    }

    AVAudioCommonFormat commonFormat = AVAudioPCMFormatFloat32;
    BOOL interleaved = YES;
    double formatSampleRate = 48000.0;
    if (format != nil) {
        formatSampleRate = [format sampleRate];
        commonFormat = [format commonFormat];
        interleaved = [format isInterleaved];
    }

    double effectiveSampleRate = sampleRate > 0.0 ? sampleRate : formatSampleRate;
    if (commonFormat != AVAudioPCMFormatFloat32) {
        commonFormat = AVAudioPCMFormatFloat32;
    }

    if (format != nil
        && [format commonFormat] == commonFormat
        && [format sampleRate] == effectiveSampleRate
        && [format channelCount] == channels
        && [format isInterleaved] == interleaved) {
        return format;
    }

    return [[[AVAudioFormat alloc] initWithCommonFormat:commonFormat
                                             sampleRate:effectiveSampleRate
                                               channels:channels
                                            interleaved:interleaved] autorelease];
}

static NSString *MKAudioFormatProbeSummary(AVAudioFormat *format) {
    if (format == nil) {
        return @"nil";
    }

    return [NSString stringWithFormat:@"%luch@%.0f/%@",
            (unsigned long)[format channelCount],
            [format sampleRate],
            [format isInterleaved] ? @"i" : @"ni"];
}

static NSError *MKAudioNSErrorFromException(NSException *exception, OSStatus fallbackCode) {
    if (exception == nil) {
        return [NSError errorWithDomain:NSOSStatusErrorDomain code:fallbackCode userInfo:nil];
    }

    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    if ([exception reason] != nil) {
        [userInfo setObject:[exception reason] forKey:NSLocalizedDescriptionKey];
    }
    if ([exception name] != nil) {
        [userInfo setObject:[exception name] forKey:@"MKAudioExceptionName"];
    }
    return [NSError errorWithDomain:NSOSStatusErrorDomain
                               code:fallbackCode
                           userInfo:userInfo];
}

static BOOL MKAudioAttachNodeSafely(AVAudioEngine *engine, AVAudioNode *node, NSError **outError) {
    @try {
        [engine attachNode:node];
        return YES;
    }
    @catch (NSException *exception) {
        if (outError != NULL) {
            *outError = MKAudioNSErrorFromException(exception, kAudioUnitErr_InvalidElement);
        }
        return NO;
    }
}

static BOOL MKAudioConnectNodesSafely(AVAudioEngine *engine,
                                      AVAudioNode *source,
                                      AVAudioNode *destination,
                                      AVAudioFormat *format,
                                      NSError **outError) {
    @try {
        [engine connect:source to:destination format:format];
        return YES;
    }
    @catch (NSException *exception) {
        if (outError != NULL) {
            *outError = MKAudioNSErrorFromException(exception, kAudioUnitErr_FormatNotSupported);
        }
        return NO;
    }
}

static BOOL MKAudioConfigureAudioUnitForFormats(id audioUnit,
                                                AVAudioFormat *inputFormat,
                                                AVAudioFormat *outputFormat,
                                                AUAudioFrameCount maximumFrames,
                                                NSError **outError) {
    if (audioUnit == nil || ![audioUnit respondsToSelector:@selector(AUAudioUnit)]) {
        return YES;
    }

    AUAudioUnit *au = [audioUnit AUAudioUnit];
    if (au == nil) {
        return YES;
    }

    @try {
        if ([audioUnit respondsToSelector:@selector(setBypass:)]) {
            [(id)audioUnit setBypass:NO];
        }
        [au setShouldBypassEffect:NO];

        if ([au renderResourcesAllocated]) {
            [au deallocateRenderResources];
        }

        if (inputFormat != nil && [au inputBusses] != nil && [[au inputBusses] count] > 0) {
            [[[au inputBusses] objectAtIndexedSubscript:0] setFormat:inputFormat error:outError];
            if (outError != NULL && *outError != nil) {
                return NO;
            }
        }

        if (outputFormat != nil && [au outputBusses] != nil && [[au outputBusses] count] > 0) {
            [[[au outputBusses] objectAtIndexedSubscript:0] setFormat:outputFormat error:outError];
            if (outError != NULL && *outError != nil) {
                return NO;
            }
        }

        [au setMaximumFramesToRender:MAX([au maximumFramesToRender], maximumFrames)];
        return YES;
    }
    @catch (NSException *exception) {
        if (outError != NULL) {
            *outError = MKAudioNSErrorFromException(exception, kAudioUnitErr_FormatNotSupported);
        }
        return NO;
    }
}

static AUAudioFrameCount MKAudioMaximumFramesForAudioUnits(NSArray *audioUnits) {
    AUAudioFrameCount maximumFrames = 4096;
    for (id audioUnit in audioUnits) {
        if (audioUnit == nil || ![audioUnit respondsToSelector:@selector(AUAudioUnit)]) {
            continue;
        }
        AUAudioUnit *au = [audioUnit AUAudioUnit];
        if (au == nil) {
            continue;
        }
        AUAudioFrameCount candidate = [au maximumFramesToRender];
        if (candidate > maximumFrames) {
            maximumFrames = candidate;
        }
    }
    return maximumFrames;
}

@implementation MKAudioUnitChainHost

- (instancetype)initWithAudioUnits:(NSArray *)audioUnits
                  preferredChannels:(NSUInteger)preferredChannels
                         sampleRate:(NSUInteger)sampleRate
                              error:(NSError **)outError {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    _renderLock = OS_UNFAIR_LOCK_INIT;
    _engine = nil;
    _sourceNode = nil;
    _audioUnits = nil;
    _inputFormat = nil;
    _outputFormat = nil;
    _adapterNodes = nil;
    _outputBuffer = nil;
    _manualRenderingBlock = nil;
    _maximumFramesToRender = 0;
    _preferredChannels = MAX((NSUInteger)1, preferredChannels);
    _currentInputSamples = NULL;
    _currentInputFrameCount = 0;
    _currentInputChannelCount = 0;
    _currentInputReadOffset = 0;
    _sourceScratchBuffer = NULL;
    _sourceScratchCapacity = 0;
    _mixScratchBuffer = NULL;
    _mixScratchCapacity = 0;

    if (![self reconfigureWithAudioUnits:audioUnits
                       preferredChannels:_preferredChannels
                              sampleRate:sampleRate
                                   error:outError]) {
        [self release];
        return nil;
    }

    return self;
}

- (void)dealloc {
    os_unfair_lock_lock(&_renderLock);
    _currentInputSamples = NULL;
    _currentInputFrameCount = 0;
    _currentInputChannelCount = 0;
    _currentInputReadOffset = 0;
    free(_sourceScratchBuffer);
    _sourceScratchBuffer = NULL;
    _sourceScratchCapacity = 0;
    free(_mixScratchBuffer);
    _mixScratchBuffer = NULL;
    _mixScratchCapacity = 0;
    [_manualRenderingBlock release];
    _manualRenderingBlock = nil;
    [_outputBuffer release];
    _outputBuffer = nil;
    [_sourceNode release];
    _sourceNode = nil;
    [_audioUnits release];
    _audioUnits = nil;
    [_inputFormat release];
    _inputFormat = nil;
    [_outputFormat release];
    _outputFormat = nil;
    [_adapterNodes release];
    _adapterNodes = nil;
    if (_engine != nil) {
        [_engine stop];
        [_engine release];
        _engine = nil;
    }
    os_unfair_lock_unlock(&_renderLock);
    [super dealloc];
}

- (BOOL)reconfigureWithAudioUnits:(NSArray *)audioUnits
                preferredChannels:(NSUInteger)preferredChannels
                        sampleRate:(NSUInteger)sampleRate
                            error:(NSError **)outError {
    NSError *localError = nil;
    AVAudioEngine *newEngine = nil;
    AVAudioSourceNode *newSourceNode = nil;
    NSArray *newAudioUnits = nil;
    NSArray *newAdapterNodes = nil;
    AVAudioFormat *newInputFormat = nil;
    AVAudioFormat *newOutputFormat = nil;
    AVAudioPCMBuffer *newOutputBuffer = nil;
    AVAudioEngineManualRenderingBlock newManualRenderingBlock = nil;
    AUAudioFrameCount newMaximumFrames = 0;
    float *newSourceScratchBuffer = NULL;
    NSUInteger newSourceScratchCapacity = 0;
    float *newMixScratchBuffer = NULL;
    NSUInteger newMixScratchCapacity = 0;
    NSUInteger effectivePreferredChannels = MAX((NSUInteger)1, preferredChannels);
    double effectiveSampleRate = sampleRate > 0 ? (double)sampleRate : 48000.0;

    if (audioUnits != nil && [audioUnits count] > 0) {
        AVAudioFormat *inputBusFormat = MKAudioInputFormatForAudioUnit([audioUnits objectAtIndexedSubscript:0]);
        AVAudioFormat *outputBusFormat = MKAudioOutputFormatForAudioUnit([audioUnits lastObject]);
        AVAudioFormat *inputFormat = nil;
        AVAudioFormat *renderOutputFormat = nil;
        if (inputBusFormat == nil) {
            inputBusFormat = outputBusFormat;
        }
        if (outputBusFormat == nil) {
            outputBusFormat = inputBusFormat;
        }

        if (inputBusFormat == nil || outputBusFormat == nil) {
            localError = [NSError errorWithDomain:NSOSStatusErrorDomain code:kAudioUnitErr_FormatNotSupported userInfo:nil];
            goto commit;
        }

        if ([inputBusFormat commonFormat] != AVAudioPCMFormatFloat32 || [outputBusFormat commonFormat] != AVAudioPCMFormatFloat32) {
            localError = [NSError errorWithDomain:NSOSStatusErrorDomain code:kAudioUnitErr_FormatNotSupported userInfo:nil];
            goto commit;
        }

        inputFormat = MKAudioFormatWithSampleRateAndChannels(inputBusFormat,
                                                             effectiveSampleRate,
                                                             [inputBusFormat channelCount]);
        renderOutputFormat = MKAudioFormatWithSampleRateAndChannels(outputBusFormat,
                                                                    effectiveSampleRate,
                                                                    (AVAudioChannelCount)effectivePreferredChannels);
        if (inputFormat == nil || renderOutputFormat == nil) {
            localError = [NSError errorWithDomain:NSOSStatusErrorDomain code:kAudioUnitErr_FormatNotSupported userInfo:nil];
            goto commit;
        }

        newMaximumFrames = MKAudioMaximumFramesForAudioUnits(audioUnits);
        newEngine = [[AVAudioEngine alloc] init];
        if (newEngine == nil) {
            localError = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOMEM userInfo:nil];
            goto commit;
        }

        if (![newEngine enableManualRenderingMode:AVAudioEngineManualRenderingModeRealtime
                                           format:renderOutputFormat
                                maximumFrameCount:newMaximumFrames
                                            error:&localError]) {
            goto commit;
        }

        __unsafe_unretained MKAudioUnitChainHost *unsafeSelf = self;
        NSMutableArray *adapterNodes = [NSMutableArray array];
        newSourceNode = [[AVAudioSourceNode alloc] initWithFormat:inputFormat
                                                      renderBlock:^OSStatus(BOOL * _Nonnull isSilence,
                                                                            const AudioTimeStamp * _Nonnull timestamp,
                                                                            AVAudioFrameCount inNumberOfFrames,
                                                                            AudioBufferList * _Nonnull outputData) {
            (void)timestamp;
            NSUInteger availableFrames = 0;
            if (unsafeSelf->_currentInputFrameCount > unsafeSelf->_currentInputReadOffset) {
                availableFrames = unsafeSelf->_currentInputFrameCount - unsafeSelf->_currentInputReadOffset;
            }
            NSUInteger framesToCopy = MIN((NSUInteger)inNumberOfFrames, availableFrames);
            NSUInteger outputChannels = MKAudioAudioBufferListChannelCount(outputData, [inputFormat channelCount]);
            BOOL outputInterleaved = MKAudioAudioBufferListIsInterleaved(outputData, outputChannels);
            if (outputData == NULL) {
                return kAudio_ParamError;
            }
            if (!MKAudioEnsureWritableAudioBufferList(outputData,
                                                     outputInterleaved,
                                                     outputChannels,
                                                     (NSUInteger)inNumberOfFrames,
                                                     unsafeSelf->_sourceScratchBuffer,
                                                     unsafeSelf->_sourceScratchCapacity)) {
                return kAudio_MemFullError;
            }

            if (unsafeSelf->_currentInputSamples == NULL || unsafeSelf->_currentInputChannelCount == 0) {
                MKAudioZeroAudioBufferList(outputData,
                                           outputInterleaved,
                                           outputChannels,
                                           0,
                                           inNumberOfFrames);
                if (isSilence != NULL) {
                    *isSilence = YES;
                }
                return noErr;
            }

            MKAudioCopyHostInterleavedToAudioBufferList(unsafeSelf->_currentInputSamples + (unsafeSelf->_currentInputReadOffset * unsafeSelf->_currentInputChannelCount),
                                                        unsafeSelf->_currentInputChannelCount,
                                                        framesToCopy,
                                                        outputData,
                                                        outputInterleaved,
                                                        outputChannels);
            unsafeSelf->_currentInputReadOffset += framesToCopy;
            if (framesToCopy < (NSUInteger)inNumberOfFrames) {
                MKAudioZeroAudioBufferList(outputData,
                                           outputInterleaved,
                                           outputChannels,
                                           framesToCopy,
                                           (NSUInteger)inNumberOfFrames - framesToCopy);
            }
            if (isSilence != NULL) {
                *isSilence = NO;
            }
            return noErr;
        }];
        if (newSourceNode == nil) {
            localError = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOMEM userInfo:nil];
            goto commit;
        }

        if (!MKAudioAttachNodeSafely(newEngine, newSourceNode, &localError)) {
            goto commit;
        }

        AVAudioNode *previousNode = (AVAudioNode *)newSourceNode;
        AVAudioFormat *previousFormat = inputFormat;
        for (id audioUnit in audioUnits) {
            AVAudioNode *effectNode = (AVAudioNode *)audioUnit;
            AVAudioFormat *effectInputBusFormat = MKAudioInputFormatForAudioUnit(audioUnit);
            AVAudioFormat *effectOutputBusFormat = MKAudioOutputFormatForAudioUnit(audioUnit);
            AVAudioFormat *effectInputReferenceFormat = effectInputBusFormat != nil ? effectInputBusFormat : previousFormat;
            AVAudioFormat *effectInputFormat = MKAudioFormatWithSampleRateAndChannels(effectInputReferenceFormat,
                                                                                      effectiveSampleRate,
                                                                                      [effectInputReferenceFormat channelCount]);
            AVAudioFormat *effectOutputReferenceFormat = effectOutputBusFormat != nil ? effectOutputBusFormat : effectInputFormat;
            AVAudioFormat *effectOutputFormat = MKAudioFormatWithSampleRateAndChannels(effectOutputReferenceFormat,
                                                                                       effectiveSampleRate,
                                                                                       [effectOutputReferenceFormat channelCount]);

            if (!MKAudioConfigureAudioUnitForFormats(audioUnit,
                                                     effectInputFormat,
                                                     effectOutputFormat,
                                                     newMaximumFrames,
                                                     &localError)) {
                goto commit;
            }

            if (!MKAudioAttachNodeSafely(newEngine, effectNode, &localError)) {
                goto commit;
            }

            AVAudioNode *sourceNode = previousNode;
            if ([previousFormat channelCount] != [effectInputFormat channelCount]) {
                AVAudioMixerNode *adapterNode = [[AVAudioMixerNode alloc] init];
                if (adapterNode == nil) {
                    localError = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOMEM userInfo:nil];
                    goto commit;
                }
                [adapterNodes addObject:adapterNode];
                if (!MKAudioAttachNodeSafely(newEngine, adapterNode, &localError)) {
                    [adapterNode release];
                    goto commit;
                }
                if (!MKAudioConnectNodesSafely(newEngine, previousNode, adapterNode, nil, &localError) &&
                    !MKAudioConnectNodesSafely(newEngine, previousNode, adapterNode, previousFormat, &localError)) {
                    [adapterNode release];
                    goto commit;
                }
                sourceNode = adapterNode;
                [adapterNode release];
            }

            if (!MKAudioConnectNodesSafely(newEngine, sourceNode, effectNode, nil, &localError) &&
                !MKAudioConnectNodesSafely(newEngine, sourceNode, effectNode, effectInputFormat, &localError)) {
                goto commit;
            }
            previousNode = effectNode;
            previousFormat = effectOutputFormat;
        }

        AVAudioMixerNode *finalAdapterNode = [[AVAudioMixerNode alloc] init];
        if (finalAdapterNode == nil) {
            localError = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOMEM userInfo:nil];
            goto commit;
        }
        [adapterNodes addObject:finalAdapterNode];
        if (!MKAudioAttachNodeSafely(newEngine, finalAdapterNode, &localError)) {
            [finalAdapterNode release];
            goto commit;
        }
        if (!MKAudioConnectNodesSafely(newEngine, previousNode, finalAdapterNode, nil, &localError) &&
            !MKAudioConnectNodesSafely(newEngine, previousNode, finalAdapterNode, previousFormat, &localError)) {
            [finalAdapterNode release];
            goto commit;
        }

        if (!MKAudioConnectNodesSafely(newEngine, finalAdapterNode, [newEngine mainMixerNode], nil, &localError) &&
            !MKAudioConnectNodesSafely(newEngine, finalAdapterNode, [newEngine mainMixerNode], renderOutputFormat, &localError)) {
            [finalAdapterNode release];
            goto commit;
        }
        [finalAdapterNode release];

        [newEngine prepare];
        if (![newEngine startAndReturnError:&localError]) {
            goto commit;
        }

        newSourceScratchCapacity = (NSUInteger)newMaximumFrames * (NSUInteger)[inputFormat channelCount];
        if (newSourceScratchCapacity > 0) {
            newSourceScratchBuffer = (float *)calloc(newSourceScratchCapacity, sizeof(float));
            if (newSourceScratchBuffer == NULL) {
                localError = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOMEM userInfo:nil];
                goto commit;
            }
        }
        newOutputBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:[newEngine manualRenderingFormat]
                                                        frameCapacity:newMaximumFrames];
        if (newOutputBuffer == nil) {
            localError = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOMEM userInfo:nil];
            goto commit;
        }

        newManualRenderingBlock = [[newEngine manualRenderingBlock] copy];
        if (newManualRenderingBlock == nil) {
            localError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFeatureUnsupportedError userInfo:nil];
            goto commit;
        }
        newMixScratchCapacity = (NSUInteger)newMaximumFrames * (NSUInteger)[renderOutputFormat channelCount];
        if (newMixScratchCapacity > 0) {
            newMixScratchBuffer = (float *)calloc(newMixScratchCapacity, sizeof(float));
            if (newMixScratchBuffer == NULL) {
                localError = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOMEM userInfo:nil];
                goto commit;
            }
        }
        newAudioUnits = [audioUnits copy];
        newInputFormat = [inputFormat retain];
        newAdapterNodes = [adapterNodes copy];
        newOutputFormat = [[newEngine manualRenderingFormat] retain];
    }

commit:
    os_unfair_lock_lock(&_renderLock);
    _currentInputSamples = NULL;
    _currentInputFrameCount = 0;
    _currentInputChannelCount = 0;
    _currentInputReadOffset = 0;

    [_manualRenderingBlock release];
    _manualRenderingBlock = newManualRenderingBlock;
    newManualRenderingBlock = nil;

    [_outputBuffer release];
    _outputBuffer = newOutputBuffer;
    newOutputBuffer = nil;

    [_sourceNode release];
    _sourceNode = newSourceNode;
    newSourceNode = nil;

    [_audioUnits release];
    _audioUnits = newAudioUnits;
    newAudioUnits = nil;

    [_inputFormat release];
    _inputFormat = newInputFormat;
    newInputFormat = nil;

    [_outputFormat release];
    _outputFormat = newOutputFormat;
    newOutputFormat = nil;

    [_adapterNodes release];
    _adapterNodes = newAdapterNodes;
    newAdapterNodes = nil;

    if (_engine != nil) {
        [_engine stop];
        [_engine release];
    }
    _engine = newEngine;
    newEngine = nil;

    free(_sourceScratchBuffer);
    _sourceScratchBuffer = newSourceScratchBuffer;
    newSourceScratchBuffer = NULL;
    _sourceScratchCapacity = newSourceScratchCapacity;
    newSourceScratchCapacity = 0;
    free(_mixScratchBuffer);
    _mixScratchBuffer = newMixScratchBuffer;
    newMixScratchBuffer = NULL;
    _mixScratchCapacity = newMixScratchCapacity;
    newMixScratchCapacity = 0;
    _maximumFramesToRender = newMaximumFrames;
    _preferredChannels = effectivePreferredChannels;
    os_unfair_lock_unlock(&_renderLock);

    if (newManualRenderingBlock != nil) {
        [newManualRenderingBlock release];
    }
    [newOutputBuffer release];
    [newSourceNode release];
    [newAudioUnits release];
    [newAdapterNodes release];
    [newInputFormat release];
    [newOutputFormat release];
    free(newSourceScratchBuffer);
    free(newMixScratchBuffer);
    if (newEngine != nil) {
        [newEngine stop];
        [newEngine release];
    }

    if (outError != NULL) {
        *outError = localError;
    }
    return (localError == nil);
}

- (BOOL)processInterleavedSamples:(float *)samples
                       frameCount:(NSUInteger)frameCount
                         channels:(NSUInteger)channels
                       sampleRate:(NSUInteger)sampleRate
                        wetDryMix:(float)wetDryMix
             manualRenderingStatus:(AVAudioEngineManualRenderingStatus *)outRenderStatus
                            error:(OSStatus *)outError {
    (void)sampleRate;
    if (samples == NULL || frameCount == 0 || channels == 0) {
        if (outRenderStatus != NULL) {
            *outRenderStatus = AVAudioEngineManualRenderingStatusError;
        }
        if (outError != NULL) {
            *outError = kAudio_ParamError;
        }
        return NO;
    }

    if (wetDryMix <= 0.0f) {
        if (outRenderStatus != NULL) {
            *outRenderStatus = AVAudioEngineManualRenderingStatusSuccess;
        }
        if (outError != NULL) {
            *outError = noErr;
        }
        return YES;
    }
    if (wetDryMix > 1.0f) {
        wetDryMix = 1.0f;
    }

    os_unfair_lock_lock(&_renderLock);
    if (_manualRenderingBlock == nil || _outputBuffer == nil || _outputFormat == nil) {
        os_unfair_lock_unlock(&_renderLock);
        if (outRenderStatus != NULL) {
            *outRenderStatus = AVAudioEngineManualRenderingStatusError;
        }
        if (outError != NULL) {
            *outError = kAudioUnitErr_NoConnection;
        }
        return NO;
    }

    if (frameCount > (NSUInteger)_maximumFramesToRender) {
        os_unfair_lock_unlock(&_renderLock);
        if (outRenderStatus != NULL) {
            *outRenderStatus = AVAudioEngineManualRenderingStatusError;
        }
        if (outError != NULL) {
            *outError = kAudioUnitErr_TooManyFramesToProcess;
        }
        return NO;
    }

    NSUInteger sampleCount = frameCount * channels;
    BOOL needsDryWetMix = (wetDryMix < 1.0f);
    if (needsDryWetMix && (_mixScratchBuffer == NULL || _mixScratchCapacity < sampleCount)) {
        os_unfair_lock_unlock(&_renderLock);
        if (outRenderStatus != NULL) {
            *outRenderStatus = AVAudioEngineManualRenderingStatusError;
        }
        if (outError != NULL) {
            *outError = kAudio_MemFullError;
        }
        return NO;
    }
    if (needsDryWetMix) {
        memcpy(_mixScratchBuffer, samples, sampleCount * sizeof(float));
    }

    _currentInputSamples = samples;
    _currentInputFrameCount = frameCount;
    _currentInputChannelCount = channels;
    _currentInputReadOffset = 0;
    [_outputBuffer setFrameLength:(AVAudioFrameCount)frameCount];
    AVAudioFormat *renderedOutputFormat = [_outputBuffer format];
    MKAudioZeroAudioBufferList([_outputBuffer mutableAudioBufferList],
                               [renderedOutputFormat isInterleaved],
                               [renderedOutputFormat channelCount],
                               0,
                               frameCount);

    OSStatus renderError = noErr;
    AVAudioEngineManualRenderingStatus renderStatus = _manualRenderingBlock((AVAudioFrameCount)frameCount,
                                                                            [_outputBuffer mutableAudioBufferList],
                                                                            &renderError);

    _currentInputSamples = NULL;
    _currentInputFrameCount = 0;
    _currentInputChannelCount = 0;
    _currentInputReadOffset = 0;

    if (renderStatus == AVAudioEngineManualRenderingStatusSuccess) {
        MKAudioCopyAudioBufferListToHostInterleaved([_outputBuffer audioBufferList],
                                                    [renderedOutputFormat isInterleaved],
                                                    [renderedOutputFormat channelCount],
                                                    frameCount,
                                                    samples,
                                                    channels);
        if (needsDryWetMix) {
            float dryMix = 1.0f - wetDryMix;
            for (NSUInteger i = 0; i < sampleCount; i++) {
                samples[i] = (_mixScratchBuffer[i] * dryMix) + (samples[i] * wetDryMix);
            }
        }
    }
    os_unfair_lock_unlock(&_renderLock);

    if (outRenderStatus != NULL) {
        *outRenderStatus = renderStatus;
    }
    if (outError != NULL) {
        *outError = renderError;
    }

    return (renderStatus == AVAudioEngineManualRenderingStatusSuccess);
}

- (NSString *)probeSummary {
    NSString *summary = nil;
    os_unfair_lock_lock(&_renderLock);
    AVAudioFormat *inputFormat = _inputFormat;
    AVAudioFormat *outputFormat = _outputBuffer != nil ? [_outputBuffer format] : _outputFormat;
    AVAudioFormat *manualFormat = _engine != nil ? [_engine manualRenderingFormat] : nil;
    summary = [[NSString alloc] initWithFormat:@"in=%@ out=%@ manual=%@ max=%u pref=%lu",
               MKAudioFormatProbeSummary(inputFormat),
               MKAudioFormatProbeSummary(outputFormat),
               MKAudioFormatProbeSummary(manualFormat),
               (unsigned int)_maximumFramesToRender,
               (unsigned long)_preferredChannels];
    os_unfair_lock_unlock(&_renderLock);
    return [summary autorelease];
}

@end

static NSString *const MKAudioDSPStageAudioUnitKey = @"audioUnit";
static NSString *const MKAudioDSPStageMixKey = @"mix";

static NSArray *MKAudioNormalizedDSPStages(NSArray *stageEntries) {
    if (stageEntries == nil) {
        return nil;
    }

    NSMutableArray *mutable = [NSMutableArray arrayWithCapacity:[stageEntries count]];
    Class audioUnitClass = NSClassFromString(@"AVAudioUnit");
    for (id entry in stageEntries) {
        id audioUnit = nil;
        float mix = 1.0f;

        if ([entry isKindOfClass:[NSDictionary class]]) {
            NSDictionary *descriptor = (NSDictionary *)entry;
            audioUnit = [descriptor objectForKey:MKAudioDSPStageAudioUnitKey];
            id mixValue = [descriptor objectForKey:MKAudioDSPStageMixKey];
            if ([mixValue respondsToSelector:@selector(floatValue)]) {
                mix = [mixValue floatValue];
            }
        } else {
            audioUnit = entry;
        }

        if (audioUnitClass != Nil && ![audioUnit isKindOfClass:audioUnitClass]) {
            continue;
        }
        if (mix < 0.0f) {
            mix = 0.0f;
        } else if (mix > 1.0f) {
            mix = 1.0f;
        }

        [mutable addObject:@{
            MKAudioDSPStageAudioUnitKey: audioUnit,
            MKAudioDSPStageMixKey: @(mix)
        }];
    }
    return [NSArray arrayWithArray:mutable];
}

static NSArray *MKAudioAudioUnitsFromDSPStages(NSArray *stages) {
    if (stages == nil) {
        return nil;
    }

    NSMutableArray *units = [NSMutableArray arrayWithCapacity:[stages count]];
    for (NSDictionary *stage in stages) {
        id audioUnit = [stage objectForKey:MKAudioDSPStageAudioUnitKey];
        if (audioUnit != nil) {
            [units addObject:audioUnit];
        }
    }
    return [NSArray arrayWithArray:units];
}

static NSArray *MKAudioMixLevelsFromDSPStages(NSArray *stages) {
    if (stages == nil) {
        return nil;
    }

    NSMutableArray *mixes = [NSMutableArray arrayWithCapacity:[stages count]];
    for (NSDictionary *stage in stages) {
        id mixValue = [stage objectForKey:MKAudioDSPStageMixKey];
        if (![mixValue respondsToSelector:@selector(floatValue)]) {
            mixValue = @(1.0f);
        }
        [mixes addObject:@([mixValue floatValue])];
    }
    return [NSArray arrayWithArray:mixes];
}

static void MKAudioTearDownStageHosts(NSArray *hosts, NSUInteger preferredChannels) {
    for (id candidate in hosts) {
        if (![candidate isKindOfClass:[MKAudioUnitChainHost class]]) {
            continue;
        }
        [(MKAudioUnitChainHost *)candidate reconfigureWithAudioUnits:nil
                                                   preferredChannels:preferredChannels
                                                          sampleRate:48000
                                                               error:nil];
    }
}

static NSArray *MKAudioBuildStageHosts(NSArray *audioUnits, NSUInteger preferredChannels, NSUInteger sampleRate, NSString *logPrefix) {
    if (audioUnits == nil || [audioUnits count] == 0) {
        return nil;
    }

    NSMutableArray *hosts = [NSMutableArray arrayWithCapacity:[audioUnits count]];
    for (NSUInteger index = 0; index < [audioUnits count]; index++) {
        id audioUnit = [audioUnits objectAtIndexedSubscript:index];
        NSError *hostError = nil;
        MKAudioUnitChainHost *host = [[MKAudioUnitChainHost alloc] initWithAudioUnits:@[ audioUnit ]
                                                                     preferredChannels:preferredChannels
                                                                           sampleRate:sampleRate
                                                                                 error:&hostError];
        if (host == nil) {
            NSLog(@"MKAudio: %@ - failed to create AU host for stage %lu: %@",
                  logPrefix,
                  (unsigned long)(index + 1),
                  [hostError localizedDescription]);
            [hosts addObject:[NSNull null]];
            continue;
        }
        [hosts addObject:host];
        [host release];
    }
    return [NSArray arrayWithArray:hosts];
}

static BOOL MKAudioShouldLogRenderFailure(MKAudioDSPChainProcessorState *state) {
    if (state == NULL) {
        return YES;
    }

    BOOL shouldLog = NO;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    os_unfair_lock_lock(&state->lock);
    if (state->lastRenderFailureLogTime <= 0.0 || (now - state->lastRenderFailureLogTime) >= 2.0) {
        state->lastRenderFailureLogTime = now;
        shouldLog = YES;
    }
    os_unfair_lock_unlock(&state->lock);
    return shouldLog;
}

static BOOL MKAudioShouldLogStateProbe(MKAudioDSPChainProcessorState *state, CFAbsoluteTime minimumInterval) {
    if (state == NULL) {
        return YES;
    }

    BOOL shouldLog = NO;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    os_unfair_lock_lock(&state->lock);
    if (state->lastStateProbeLogTime <= 0.0 || (now - state->lastStateProbeLogTime) >= minimumInterval) {
        state->lastStateProbeLogTime = now;
        shouldLog = YES;
    }
    os_unfair_lock_unlock(&state->lock);
    return shouldLog;
}

static BOOL MKAudioShouldLogRenderProbe(MKAudioDSPChainProcessorState *state, CFAbsoluteTime minimumInterval) {
    if (state == NULL) {
        return YES;
    }

    BOOL shouldLog = NO;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    os_unfair_lock_lock(&state->lock);
    if (state->lastRenderProbeLogTime <= 0.0 || (now - state->lastRenderProbeLogTime) >= minimumInterval) {
        state->lastRenderProbeLogTime = now;
        shouldLog = YES;
    }
    os_unfair_lock_unlock(&state->lock);
    return shouldLog;
}

static float MKAudioPeakForInterleavedSamples(const float *samples, NSUInteger frameCount, NSUInteger channels) {
    if (samples == NULL || frameCount == 0 || channels == 0) {
        return 0.0f;
    }

    float peak = 0.0f;
    NSUInteger sampleCount = frameCount * channels;
    for (NSUInteger i = 0; i < sampleCount; i++) {
        float value = fabsf(samples[i]);
        if (value > peak) {
            peak = value;
        }
    }
    return peak;
}

static void MKAudioApplyHardClipInterleaved(float *samples, NSUInteger frameCount, NSUInteger channels) {
    if (samples == NULL || frameCount == 0 || channels == 0) {
        return;
    }

    NSUInteger sampleCount = frameCount * channels;
    for (NSUInteger i = 0; i < sampleCount; i++) {
        if (samples[i] > 1.0f) {
            samples[i] = 1.0f;
        } else if (samples[i] < -1.0f) {
            samples[i] = -1.0f;
        }
    }
}

static float MKAudioPeakForInterleavedChannel(const float *samples,
                                              NSUInteger frameCount,
                                              NSUInteger channels,
                                              NSUInteger channelIndex) {
    if (samples == NULL || frameCount == 0 || channels == 0 || channelIndex >= channels) {
        return 0.0f;
    }

    float peak = 0.0f;
    for (NSUInteger frame = 0; frame < frameCount; frame++) {
        float value = fabsf(samples[(frame * channels) + channelIndex]);
        if (value > peak) {
            peak = value;
        }
    }
    return peak;
}

static NSArray *MKAudioCopyHostProbeSummaries(NSArray *hosts) {
    if (hosts == nil || [hosts count] == 0) {
        return @[];
    }

    NSMutableArray *result = [NSMutableArray arrayWithCapacity:[hosts count]];
    for (id candidate in hosts) {
        if ([candidate isKindOfClass:[MKAudioUnitChainHost class]]) {
            NSString *summary = [(MKAudioUnitChainHost *)candidate probeSummary];
            [result addObject:(summary != nil ? summary : @"nil")];
        } else {
            [result addObject:@"null"];
        }
    }
    return [NSArray arrayWithArray:result];
}

static void MKAudioLogDSPChainProbeState(MKAudioDSPChainProcessorState *state,
                                         NSString *logPrefix,
                                         NSString *reason) {
    if (state == NULL || ![logPrefix isEqualToString:@"Remote Bus"] || !MKAudioShouldLogStateProbe(state, 0.5)) {
        return;
    }

    NSArray *audioUnits = nil;
    NSArray *mixLevels = nil;
    NSArray *hosts = nil;
    NSUInteger preferredChannels = 0;
    NSUInteger hostBufferFrames = 0;
    NSUInteger renderSampleRate = 0;
    BOOL sampleRateRefreshPending = NO;

    os_unfair_lock_lock(&state->lock);
    audioUnits = [state->audioUnits retain];
    mixLevels = [state->mixLevels retain];
    hosts = [state->hosts retain];
    preferredChannels = state->preferredChannels;
    hostBufferFrames = state->hostBufferFrames;
    renderSampleRate = state->renderSampleRate;
    sampleRateRefreshPending = state->sampleRateRefreshPending;
    os_unfair_lock_unlock(&state->lock);

    NSArray *hostSummaries = MKAudioCopyHostProbeSummaries(hosts);
    NSLog(@"MKAudioProbe: %@ [%@] stages=%lu mixes=%@ hosts=%@ prefCh=%lu hostBuf=%lu renderSR=%lu pending=%@",
          logPrefix,
          reason,
          (unsigned long)[audioUnits count],
          mixLevels != nil ? mixLevels : @[],
          hostSummaries,
          (unsigned long)preferredChannels,
          (unsigned long)hostBufferFrames,
          (unsigned long)renderSampleRate,
          sampleRateRefreshPending ? @"YES" : @"NO");

    [audioUnits release];
    [mixLevels release];
    [hosts release];
}

static void MKAudioLogRemoteBusRenderProbe(MKAudioDSPChainProcessorState *state,
                                           NSUInteger frameCount,
                                           NSUInteger channels,
                                           NSUInteger sampleRate,
                                           NSUInteger configuredSampleRate,
                                           NSUInteger hostBufferFrames,
                                           NSArray *hosts,
                                           float inputPeak,
                                           float outputPeak,
                                           float inputLeftPeak,
                                           float inputRightPeak,
                                           float outputLeftPeak,
                                           float outputRightPeak) {
    if (state == NULL) {
        return;
    }

    NSArray *hostSummaries = MKAudioCopyHostProbeSummaries(hosts);
    NSLog(@"MKAudioProbe: Remote Bus [render] frames=%lu channels=%lu sampleRate=%lu configuredSR=%lu hostBuf=%lu inPeak=%.3f outPeak=%.3f inL=%.3f inR=%.3f outL=%.3f outR=%.3f hosts=%@",
          (unsigned long)frameCount,
          (unsigned long)channels,
          (unsigned long)sampleRate,
          (unsigned long)configuredSampleRate,
          (unsigned long)hostBufferFrames,
          inputPeak,
          outputPeak,
          inputLeftPeak,
          inputRightPeak,
          outputLeftPeak,
          outputRightPeak,
          hostSummaries);
}

static void MKAudioStoreDSPPeaks(MKAudioDSPChainProcessorState *state, float inputPeak, float outputPeak) {
    if (state == NULL) {
        return;
    }

    os_unfair_lock_lock(&state->lock);
    state->inputPeak = inputPeak;
    state->outputPeak = outputPeak;
    os_unfair_lock_unlock(&state->lock);
}

static void MKAudioUpdateDSPChainState(MKAudioDSPChainProcessorState *state, NSArray *audioUnits, NSString *logPrefix, BOOL forceRebuild) {
    if (state == NULL) {
        return;
    }

    NSArray *normalizedStages = MKAudioNormalizedDSPStages(audioUnits);
    NSArray *filteredUnits = MKAudioAudioUnitsFromDSPStages(normalizedStages);
    NSArray *mixLevels = MKAudioMixLevelsFromDSPStages(normalizedStages);
    NSArray *currentStages = nil;
    NSArray *currentUnits = nil;
    NSArray *currentMixLevels = nil;
    NSArray *currentHosts = nil;

    os_unfair_lock_lock(&state->lock);
    currentStages = [state->stages retain];
    currentUnits = [state->audioUnits retain];
    currentMixLevels = [state->mixLevels retain];
    currentHosts = [state->hosts retain];
    NSUInteger renderSampleRate = state->renderSampleRate > 0 ? state->renderSampleRate : 48000;
    os_unfair_lock_unlock(&state->lock);

    BOOL stagesUnchanged = ((currentStages == normalizedStages) || [currentStages isEqualToArray:normalizedStages]);
    BOOL unitsUnchanged = ((currentUnits == filteredUnits) || [currentUnits isEqualToArray:filteredUnits]);
    BOOL mixesUnchanged = ((currentMixLevels == mixLevels) || [currentMixLevels isEqualToArray:mixLevels]);
    [currentStages release];
    [currentUnits release];
    [currentMixLevels release];
    if (!forceRebuild && stagesUnchanged && unitsUnchanged && mixesUnchanged) {
        [currentHosts release];
        return;
    }

    NSArray *hostsToStore = nil;
    if (!forceRebuild && unitsUnchanged) {
        hostsToStore = currentHosts;
    } else {
        // AVAudioUnit instances are owned by a single AVAudioEngine at a time.
        // Tear down old hosts before rebuilding so units can be safely reattached.
        MKAudioTearDownStageHosts(currentHosts, state->preferredChannels);
        [currentHosts release];
        currentHosts = nil;
        hostsToStore = MKAudioBuildStageHosts(filteredUnits, state->preferredChannels, renderSampleRate, logPrefix);
    }

    os_unfair_lock_lock(&state->lock);
    [state->stages release];
    state->stages = [normalizedStages retain];
    [state->audioUnits release];
    state->audioUnits = [filteredUnits retain];
    [state->mixLevels release];
    state->mixLevels = [mixLevels retain];
    [state->hosts release];
    state->hosts = [hostsToStore retain];
    os_unfair_lock_unlock(&state->lock);

    [currentHosts release];
    MKAudioLogDSPChainProbeState(state, logPrefix, forceRebuild ? @"rebuild" : @"update");
}

static BOOL MKAudioScheduleDSPChainSampleRateRefresh(MKAudioDSPChainProcessorState *state,
                                                     NSUInteger sampleRate,
                                                     NSString *logPrefix) {
    if (state == NULL || sampleRate == 0) {
        return NO;
    }

    __unsafe_unretained MKAudio *owner = nil;
    NSArray *stages = nil;
    BOOL shouldSchedule = NO;

    os_unfair_lock_lock(&state->lock);
    if (state->renderSampleRate != sampleRate && !state->sampleRateRefreshPending) {
        state->renderSampleRate = sampleRate;
        state->sampleRateRefreshPending = YES;
        owner = state->owner;
        stages = [state->stages retain];
        shouldSchedule = YES;
    }
    os_unfair_lock_unlock(&state->lock);

    if (!shouldSchedule || owner == nil) {
        [stages release];
        return NO;
    }

    [owner refreshDSPChainState:state stages:stages logPrefix:logPrefix];

    return YES;
}

static void MKAudioClearDSPChainState(MKAudioDSPChainProcessorState *state) {
    if (state == NULL) {
        return;
    }

    NSArray *hosts = nil;
    os_unfair_lock_lock(&state->lock);
    [state->stages release];
    state->stages = nil;
    [state->audioUnits release];
    state->audioUnits = nil;
    [state->mixLevels release];
    state->mixLevels = nil;
    state->sampleRateRefreshPending = NO;
    hosts = [state->hosts retain];
    [state->hosts release];
    state->hosts = nil;
    os_unfair_lock_unlock(&state->lock);

    MKAudioTearDownStageHosts(hosts, state->preferredChannels);
    [hosts release];
}

static void MKAudioProcessDSPStagesFloat(float *samples,
                                         NSUInteger frameCount,
                                         NSUInteger channels,
                                         NSUInteger sampleRate,
                                         MKAudioDSPChainProcessorState *state,
                                         NSString *logPrefix) {
    NSArray *audioUnits = nil;
    NSArray *mixLevels = nil;
    NSArray *hosts = nil;
    NSUInteger configuredSampleRate = 48000;
    BOOL sampleRateRefreshPending = NO;
    os_unfair_lock_lock(&state->lock);
    audioUnits = [state->audioUnits retain];
    mixLevels = [state->mixLevels retain];
    hosts = [state->hosts retain];
    NSUInteger hostBufferFrames = state->hostBufferFrames;
    configuredSampleRate = state->renderSampleRate > 0 ? state->renderSampleRate : 48000;
    sampleRateRefreshPending = state->sampleRateRefreshPending;
    os_unfair_lock_unlock(&state->lock);

    float inputPeak = MKAudioPeakForInterleavedSamples(samples, frameCount, channels);
    BOOL shouldProbeRender = [logPrefix isEqualToString:@"Remote Bus"] && MKAudioShouldLogRenderProbe(state, 1.0);
    float inputLeftPeak = 0.0f;
    float inputRightPeak = 0.0f;
    if (shouldProbeRender) {
        inputLeftPeak = MKAudioPeakForInterleavedChannel(samples, frameCount, channels, 0);
        inputRightPeak = MKAudioPeakForInterleavedChannel(samples, frameCount, channels, MIN((NSUInteger)1, channels - 1));
    }

    if (audioUnits == nil || [audioUnits count] == 0 || hosts == nil || [hosts count] == 0) {
        MKAudioStoreDSPPeaks(state, inputPeak, inputPeak);
        if (shouldProbeRender) {
            MKAudioLogRemoteBusRenderProbe(state,
                                           frameCount,
                                           channels,
                                           sampleRate,
                                           configuredSampleRate,
                                           hostBufferFrames,
                                           hosts,
                                           inputPeak,
                                           inputPeak,
                                           inputLeftPeak,
                                           inputRightPeak,
                                           inputLeftPeak,
                                           inputRightPeak);
        }
        [audioUnits release];
        [mixLevels release];
        [hosts release];
        return;
    }

    if ((sampleRate > 0 && configuredSampleRate != sampleRate)
        || sampleRateRefreshPending) {
        MKAudioScheduleDSPChainSampleRateRefresh(state, sampleRate, logPrefix);
        MKAudioStoreDSPPeaks(state, inputPeak, inputPeak);
        [audioUnits release];
        [mixLevels release];
        [hosts release];
        return;
    }

    NSUInteger stageCount = MIN([audioUnits count], MIN([mixLevels count], [hosts count]));
    for (NSUInteger index = 0; index < stageCount; index++) {
        id hostCandidate = [hosts objectAtIndexedSubscript:index];
        if (![hostCandidate isKindOfClass:[MKAudioUnitChainHost class]]) {
            continue;
        }

        float wetDryMix = 1.0f;
        id mixValue = [mixLevels objectAtIndexedSubscript:index];
        if ([mixValue respondsToSelector:@selector(floatValue)]) {
            wetDryMix = [mixValue floatValue];
        }

        // Process the full callback block in one render pass. Splitting a live
        // buffer into smaller host-sized chunks caused audible discontinuities
        // with effects that internally pull fixed quanta or latency-compensated
        // lookahead blocks.
        NSUInteger chunkSize = frameCount;
        (void)hostBufferFrames;
        for (NSUInteger offset = 0; offset < frameCount; offset += chunkSize) {
            NSUInteger framesThisPass = MIN(chunkSize, frameCount - offset);
            AVAudioEngineManualRenderingStatus renderStatus = AVAudioEngineManualRenderingStatusError;
            OSStatus renderError = noErr;
            if (![(MKAudioUnitChainHost *)hostCandidate processInterleavedSamples:(samples + (offset * channels))
                                                                       frameCount:framesThisPass
                                                                         channels:channels
                                                                       sampleRate:sampleRate
                                                                        wetDryMix:wetDryMix
                                                             manualRenderingStatus:&renderStatus
                                                                            error:&renderError]) {
                if (MKAudioShouldLogRenderFailure(state)) {
                    NSLog(@"MKAudio: %@ - AU host render failed at stage %lu, status=%ld, error=%d",
                          logPrefix,
                          (unsigned long)(index + 1),
                          (long)renderStatus,
                          (int)renderError);
                }
            }
        }
    }

    MKAudioApplyHardClipInterleaved(samples, frameCount, channels);

    float outputPeak = MKAudioPeakForInterleavedSamples(samples, frameCount, channels);
    MKAudioStoreDSPPeaks(state, inputPeak, outputPeak);
    if (shouldProbeRender) {
        float outputLeftPeak = MKAudioPeakForInterleavedChannel(samples, frameCount, channels, 0);
        float outputRightPeak = MKAudioPeakForInterleavedChannel(samples, frameCount, channels, MIN((NSUInteger)1, channels - 1));
        MKAudioLogRemoteBusRenderProbe(state,
                                       frameCount,
                                       channels,
                                       sampleRate,
                                       configuredSampleRate,
                                       hostBufferFrames,
                                       hosts,
                                       inputPeak,
                                       outputPeak,
                                       inputLeftPeak,
                                       inputRightPeak,
                                       outputLeftPeak,
                                       outputRightPeak);
    }
    [audioUnits release];
    [mixLevels release];
    [hosts release];
}

static void MKAudioInputDSPProcess(short *samples, NSUInteger frameCount, NSUInteger channels, NSUInteger sampleRate, void *context) {
    MKAudioDSPChainProcessorState *state = (MKAudioDSPChainProcessorState *)context;
    if (samples == NULL || frameCount == 0 || channels == 0 || state == NULL) {
        return;
    }

    MKAudioPreviewGainProcessorState preview;
    NSArray *audioUnits = nil;
    os_unfair_lock_lock(&state->lock);
    preview = state->preview;
    audioUnits = [state->audioUnits retain];
    os_unfair_lock_unlock(&state->lock);

    MKAudioInputPreviewGainProcess(samples, frameCount, channels, sampleRate, &preview);

    if (audioUnits == nil || audioUnits.count == 0) {
        [audioUnits release];
        return;
    }

    NSUInteger sampleCount = frameCount * channels;
    float *floatSamples = (float *)calloc(sampleCount, sizeof(float));
    if (floatSamples == NULL) {
        NSLog(@"MKAudio: Input Track - calloc failed!");
        [audioUnits release];
        return;
    }

    for (NSUInteger i = 0; i < sampleCount; i++) {
        floatSamples[i] = ((float)samples[i]) / 32768.0f;
    }

    MKAudioProcessDSPStagesFloat(floatSamples, frameCount, channels, sampleRate, state, @"Input Track");

    for (NSUInteger i = 0; i < sampleCount; i++) {
        float scaled = floatSamples[i] * 32767.0f;
        if (scaled > 32767.0f) {
            scaled = 32767.0f;
        } else if (scaled < -32768.0f) {
            scaled = -32768.0f;
        }
        samples[i] = (short)scaled;
    }

    free(floatSamples);
    [audioUnits release];
}

static void MKAudioRemoteBusPreviewGainProcess(float *samples, NSUInteger frameCount, NSUInteger channels, NSUInteger sampleRate, void *context) {
    (void)sampleRate;
    MKAudioPreviewGainProcessorState *state = (MKAudioPreviewGainProcessorState *)context;
    if (state == NULL || !state->enabled) {
        return;
    }
    float gain = state->gain;
    if (gain == 1.0f) {
        return;
    }

    NSUInteger sampleCount = frameCount * channels;
    for (NSUInteger i = 0; i < sampleCount; i++) {
        samples[i] *= gain;
    }
}

static void MKAudioRemoteBusDSPProcess(float *samples, NSUInteger frameCount, NSUInteger channels, NSUInteger sampleRate, void *context) {
    MKAudioDSPChainProcessorState *state = (MKAudioDSPChainProcessorState *)context;
    if (samples == NULL || frameCount == 0 || channels == 0 || state == NULL) {
        return;
    }

    MKAudioPreviewGainProcessorState preview;
    NSArray *audioUnits = nil;
    os_unfair_lock_lock(&state->lock);
    preview = state->preview;
    audioUnits = [state->audioUnits retain];
    os_unfair_lock_unlock(&state->lock);

    MKAudioApplyPreviewGainFloat(samples, frameCount, channels, &preview);

    if (audioUnits == nil || audioUnits.count == 0) {
        [audioUnits release];
        return;
    }

    MKAudioProcessDSPStagesFloat(samples, frameCount, channels, sampleRate, state, @"Remote Bus");

    [audioUnits release];
}

static void MKAudioRemoteTrackPreviewGainProcess(float *samples, NSUInteger frameCount, NSUInteger channels, NSUInteger sampleRate, void *context) {
    MKAudioRemoteBusPreviewGainProcess(samples, frameCount, channels, sampleRate, context);
}

static void MKAudioRemoteTrackDSPProcess(float *samples, NSUInteger frameCount, NSUInteger channels, NSUInteger sampleRate, void *context) {
    MKAudioDSPChainProcessorState *state = (MKAudioDSPChainProcessorState *)context;
    if (samples == NULL || frameCount == 0 || channels == 0 || state == NULL) {
        return;
    }

    MKAudioPreviewGainProcessorState preview;
    NSArray *audioUnits = nil;
    os_unfair_lock_lock(&state->lock);
    preview = state->preview;
    audioUnits = [state->audioUnits retain];
    os_unfair_lock_unlock(&state->lock);

    MKAudioApplyPreviewGainFloat(samples, frameCount, channels, &preview);

    if (audioUnits == nil || audioUnits.count == 0) {
        [audioUnits release];
        return;
    }

    MKAudioProcessDSPStagesFloat(samples, frameCount, channels, sampleRate, state, @"Remote Track");
    [audioUnits release];
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

        _inputTrackPreviewState.gain = 1.0f;
        _inputTrackPreviewState.enabled = NO;
        _remoteBusPreviewState.gain = 1.0f;
        _remoteBusPreviewState.enabled = NO;

        _inputTrackDSPState.preview = _inputTrackPreviewState;
        _inputTrackDSPState.lock = OS_UNFAIR_LOCK_INIT;
        _inputTrackDSPState.stages = nil;
        _inputTrackDSPState.audioUnits = nil;
        _inputTrackDSPState.mixLevels = nil;
        _inputTrackDSPState.hosts = nil;
        _inputTrackDSPState.preferredChannels = 1;
        _inputTrackDSPState.hostBufferFrames = 256;
        _inputTrackDSPState.renderSampleRate = 48000;
        _inputTrackDSPState.sampleRateRefreshPending = NO;
        _inputTrackDSPState.owner = self;
        _inputTrackDSPState.inputPeak = 0.0f;
        _inputTrackDSPState.outputPeak = 0.0f;
        _remoteBusDSPState.preview = _remoteBusPreviewState;
        _remoteBusDSPState.lock = OS_UNFAIR_LOCK_INIT;
        _remoteBusDSPState.stages = nil;
        _remoteBusDSPState.audioUnits = nil;
        _remoteBusDSPState.mixLevels = nil;
        _remoteBusDSPState.hosts = nil;
        _remoteBusDSPState.preferredChannels = 2;
        _remoteBusDSPState.hostBufferFrames = 256;
        _remoteBusDSPState.renderSampleRate = 48000;
        _remoteBusDSPState.sampleRateRefreshPending = NO;
        _remoteBusDSPState.owner = self;
        _remoteBusDSPState.inputPeak = 0.0f;
        _remoteBusDSPState.outputPeak = 0.0f;
        _pluginHostBufferFrames = 256;
        _remoteTrackPreviewStates = [[NSMutableDictionary alloc] init];
        _remoteTrackDSPStates = [[NSMutableDictionary alloc] init];
        
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

    for (NSValue *value in [_remoteTrackDSPStates allValues]) {
        MKAudioDSPChainProcessorState *state = (MKAudioDSPChainProcessorState *)[value pointerValue];
        if (state != NULL) {
            NSArray *hosts = nil;
            os_unfair_lock_lock(&state->lock);
            [state->audioUnits release];
            state->audioUnits = nil;
            [state->mixLevels release];
            state->mixLevels = nil;
            hosts = [state->hosts retain];
            [state->hosts release];
            state->hosts = nil;
            os_unfair_lock_unlock(&state->lock);
            MKAudioTearDownStageHosts(hosts, state->preferredChannels);
            [hosts release];
            free(state);
        }
    }
    [_remoteTrackDSPStates release];
    _remoteTrackDSPStates = nil;

    NSArray *inputHosts = nil;
    os_unfair_lock_lock(&_inputTrackDSPState.lock);
    [_inputTrackDSPState.audioUnits release];
    _inputTrackDSPState.audioUnits = nil;
    [_inputTrackDSPState.mixLevels release];
    _inputTrackDSPState.mixLevels = nil;
    inputHosts = [_inputTrackDSPState.hosts retain];
    [_inputTrackDSPState.hosts release];
    _inputTrackDSPState.hosts = nil;
    os_unfair_lock_unlock(&_inputTrackDSPState.lock);
    MKAudioTearDownStageHosts(inputHosts, _inputTrackDSPState.preferredChannels);
    [inputHosts release];

    NSArray *remoteBusHosts = nil;
    os_unfair_lock_lock(&_remoteBusDSPState.lock);
    [_remoteBusDSPState.audioUnits release];
    _remoteBusDSPState.audioUnits = nil;
    [_remoteBusDSPState.mixLevels release];
    _remoteBusDSPState.mixLevels = nil;
    remoteBusHosts = [_remoteBusDSPState.hosts retain];
    [_remoteBusDSPState.hosts release];
    _remoteBusDSPState.hosts = nil;
    os_unfair_lock_unlock(&_remoteBusDSPState.lock);
    MKAudioTearDownStageHosts(remoteBusHosts, _remoteBusDSPState.preferredChannels);
    [remoteBusHosts release];
    
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
        [_audioInput setInputTrackProcessor:MKAudioInputDSPProcess context:&_inputTrackDSPState];
        
        [_audioInput setSelfMuted:_cachedSelfMuted];
        [_audioInput setSuppressed:_cachedSuppressed];
        [_audioInput setMuted:_cachedMuted];
        
        _audioOutput = [[MKAudioOutput alloc] initWithDevice:_audioDevice andSettings:&settingsSnapshot];
        [_audioOutput setRemoteBusProcessor:MKAudioRemoteBusDSPProcess context:&_remoteBusDSPState];
        [self rebindRemoteTrackProcessorsToOutputLocked];
        
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
        os_unfair_lock_lock(&_inputTrackDSPState.lock);
        _inputTrackDSPState.hostBufferFrames = normalized;
        os_unfair_lock_unlock(&_inputTrackDSPState.lock);

        os_unfair_lock_lock(&_remoteBusDSPState.lock);
        _remoteBusDSPState.hostBufferFrames = normalized;
        os_unfair_lock_unlock(&_remoteBusDSPState.lock);

        for (NSValue *value in [_remoteTrackDSPStates allValues]) {
            MKAudioDSPChainProcessorState *state = (MKAudioDSPChainProcessorState *)[value pointerValue];
            if (state == NULL) {
                continue;
            }
            os_unfair_lock_lock(&state->lock);
            state->hostBufferFrames = normalized;
            os_unfair_lock_unlock(&state->lock);
        }

        MKAudioLogDSPChainProbeState(&_remoteBusDSPState, @"Remote Bus", @"setPluginHostBufferFrames");
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
        os_unfair_lock_lock(&_inputTrackDSPState.lock);
        result = [[NSDictionary alloc] initWithObjectsAndKeys:
                  [NSNumber numberWithFloat:_inputTrackDSPState.inputPeak], @"inputPeak",
                  [NSNumber numberWithFloat:_inputTrackDSPState.outputPeak], @"outputPeak",
                  nil];
        os_unfair_lock_unlock(&_inputTrackDSPState.lock);
    });
    return result;
}

- (NSDictionary *)copyRemoteBusDSPStatus {
    __block NSDictionary *result = nil;
    dispatch_sync(_accessQueue, ^{
        os_unfair_lock_lock(&_remoteBusDSPState.lock);
        result = [[NSDictionary alloc] initWithObjectsAndKeys:
                  [NSNumber numberWithFloat:_remoteBusDSPState.inputPeak], @"inputPeak",
                  [NSNumber numberWithFloat:_remoteBusDSPState.outputPeak], @"outputPeak",
                  nil];
        os_unfair_lock_unlock(&_remoteBusDSPState.lock);
    });
    return result;
}

- (void)refreshDSPChainState:(MKAudioDSPChainProcessorState *)state stages:(NSArray *)stages logPrefix:(NSString *)logPrefix {
    if (state == NULL) {
        [stages release];
        return;
    }

    dispatch_async(_accessQueue, ^{
        if (stages != nil) {
            MKAudioUpdateDSPChainState(state, stages, logPrefix, YES);
        }

        os_unfair_lock_lock(&state->lock);
        state->sampleRateRefreshPending = NO;
        os_unfair_lock_unlock(&state->lock);

        [stages release];
    });
}

- (void)rebindRemoteTrackProcessorsToOutputLocked {
    if (_audioOutput == nil) {
        return;
    }

    [_audioOutput clearAllRemoteTrackProcessors];

    for (NSNumber *sessionKey in _remoteTrackPreviewStates) {
        NSValue *previewValue = [_remoteTrackPreviewStates objectForKey:sessionKey];
        MKAudioPreviewGainProcessorState *previewState = (MKAudioPreviewGainProcessorState *)[previewValue pointerValue];
        if (previewState != NULL) {
            [_audioOutput setRemoteTrackProcessor:MKAudioRemoteTrackPreviewGainProcess
                                          context:previewState
                                       forSession:[sessionKey unsignedIntegerValue]];
        }
    }

    for (NSNumber *sessionKey in _remoteTrackDSPStates) {
        NSValue *dspValue = [_remoteTrackDSPStates objectForKey:sessionKey];
        MKAudioDSPChainProcessorState *dspState = (MKAudioDSPChainProcessorState *)[dspValue pointerValue];
        if (dspState != NULL) {
            [_audioOutput setRemoteTrackProcessor:MKAudioRemoteTrackDSPProcess
                                          context:dspState
                                       forSession:[sessionKey unsignedIntegerValue]];
        }
    }
}

- (void) setInputTrackPreviewGain:(float)gain enabled:(BOOL)enabled {
    if (gain < 0.0f) {
        gain = 0.0f;
    }
    dispatch_async(_accessQueue, ^{
        _inputTrackPreviewState.gain = gain;
        _inputTrackPreviewState.enabled = enabled;
        os_unfair_lock_lock(&_inputTrackDSPState.lock);
        _inputTrackDSPState.preview = _inputTrackPreviewState;
        os_unfair_lock_unlock(&_inputTrackDSPState.lock);
    });
}

- (void) setRemoteBusPreviewGain:(float)gain enabled:(BOOL)enabled {
    if (gain < 0.0f) {
        gain = 0.0f;
    }
    dispatch_async(_accessQueue, ^{
        _remoteBusPreviewState.gain = gain;
        _remoteBusPreviewState.enabled = enabled;
        os_unfair_lock_lock(&_remoteBusDSPState.lock);
        _remoteBusDSPState.preview = _remoteBusPreviewState;
        os_unfair_lock_unlock(&_remoteBusDSPState.lock);
    });
}

- (void) setInputTrackAudioUnitChain:(NSArray *)audioUnits {
    dispatch_async(_accessQueue, ^{
        MKAudioUpdateDSPChainState(&_inputTrackDSPState, audioUnits, @"Input Track", NO);
    });
}

- (void) setRemoteBusAudioUnitChain:(NSArray *)audioUnits {
    dispatch_async(_accessQueue, ^{
        MKAudioUpdateDSPChainState(&_remoteBusDSPState, audioUnits, @"Remote Bus", NO);
        MKAudioLogDSPChainProbeState(&_remoteBusDSPState, @"Remote Bus", @"setRemoteBusAudioUnitChain");
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

        NSValue *dspValue = [_remoteTrackDSPStates objectForKey:sessionKey];
        MKAudioDSPChainProcessorState *dspState = (MKAudioDSPChainProcessorState *)[dspValue pointerValue];
        if (dspState != NULL) {
            os_unfair_lock_lock(&dspState->lock);
            dspState->preview = *state;
            os_unfair_lock_unlock(&dspState->lock);
        }

        if (_audioOutput != nil) {
            if (dspState != NULL) {
                [_audioOutput setRemoteTrackProcessor:MKAudioRemoteTrackDSPProcess context:dspState forSession:session];
            } else {
                [_audioOutput setRemoteTrackProcessor:MKAudioRemoteTrackPreviewGainProcess context:state forSession:session];
            }
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

        NSValue *dspValue = [_remoteTrackDSPStates objectForKey:sessionKey];
        MKAudioDSPChainProcessorState *dspState = (MKAudioDSPChainProcessorState *)[dspValue pointerValue];
        if (dspState != NULL) {
            os_unfair_lock_lock(&dspState->lock);
            dspState->preview.gain = 1.0f;
            dspState->preview.enabled = NO;
            os_unfair_lock_unlock(&dspState->lock);
        }

        if (_audioOutput != nil) {
            if (dspState != NULL) {
                [_audioOutput setRemoteTrackProcessor:MKAudioRemoteTrackDSPProcess context:dspState forSession:session];
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

        for (NSValue *value in [_remoteTrackDSPStates allValues]) {
            MKAudioDSPChainProcessorState *state = (MKAudioDSPChainProcessorState *)[value pointerValue];
            if (state != NULL) {
                os_unfair_lock_lock(&state->lock);
                state->preview.gain = 1.0f;
                state->preview.enabled = NO;
                os_unfair_lock_unlock(&state->lock);
            }
        }

        [self rebindRemoteTrackProcessorsToOutputLocked];
    });
}

- (void) setRemoteTrackAudioUnitChain:(NSArray *)audioUnits forSession:(NSUInteger)session {
    dispatch_async(_accessQueue, ^{
        NSNumber *sessionKey = [NSNumber numberWithUnsignedInteger:session];
        NSValue *stateValue = [_remoteTrackDSPStates objectForKey:sessionKey];
        MKAudioDSPChainProcessorState *state = (MKAudioDSPChainProcessorState *)[stateValue pointerValue];

        if (state == NULL) {
            state = (MKAudioDSPChainProcessorState *)calloc(1, sizeof(MKAudioDSPChainProcessorState));
            if (state == NULL) {
                return;
            }
            state->lock = OS_UNFAIR_LOCK_INIT;
            state->preview.gain = 1.0f;
            state->preview.enabled = NO;
            state->stages = nil;
            state->audioUnits = nil;
            state->mixLevels = nil;
            state->hosts = nil;
            state->preferredChannels = 2;
            state->hostBufferFrames = _pluginHostBufferFrames;
            state->renderSampleRate = 48000;
            state->sampleRateRefreshPending = NO;
            state->owner = self;
            state->inputPeak = 0.0f;
            state->outputPeak = 0.0f;

            // 同步 preview state
            NSValue *previewValue = [_remoteTrackPreviewStates objectForKey:sessionKey];
            if (previewValue != nil) {
                MKAudioPreviewGainProcessorState *previewState = (MKAudioPreviewGainProcessorState *)[previewValue pointerValue];
                if (previewState != NULL) {
                    state->preview = *previewState;
                }
            }

            [_remoteTrackDSPStates setObject:[NSValue valueWithPointer:state] forKey:sessionKey];
        }

        MKAudioUpdateDSPChainState(state, audioUnits, [NSString stringWithFormat:@"Remote Track %lu", (unsigned long)session], NO);

        if (_audioOutput != nil) {
            [_audioOutput setRemoteTrackProcessor:MKAudioRemoteTrackDSPProcess context:state forSession:session];
        }
    });
}

- (void) clearRemoteTrackAudioUnitChainForSession:(NSUInteger)session {
    dispatch_async(_accessQueue, ^{
        NSNumber *sessionKey = [NSNumber numberWithUnsignedInteger:session];
        NSValue *stateValue = [_remoteTrackDSPStates objectForKey:sessionKey];
        if (stateValue != nil) {
            MKAudioDSPChainProcessorState *state = (MKAudioDSPChainProcessorState *)[stateValue pointerValue];
            if (state != NULL) {
                MKAudioClearDSPChainState(state);

                if (_audioOutput != nil) {
                    NSValue *previewValue = [_remoteTrackPreviewStates objectForKey:sessionKey];
                    MKAudioPreviewGainProcessorState *previewState = (MKAudioPreviewGainProcessorState *)[previewValue pointerValue];
                    if (previewState != NULL) {
                        [_audioOutput setRemoteTrackProcessor:MKAudioRemoteTrackPreviewGainProcess context:previewState forSession:session];
                    } else {
                        [_audioOutput clearRemoteTrackProcessorForSession:session];
                    }
                }

                free(state);
            }
            [_remoteTrackDSPStates removeObjectForKey:sessionKey];
        }
    });
}

- (void) clearAllRemoteTrackAudioUnitChains {
    dispatch_async(_accessQueue, ^{
        for (NSValue *value in [_remoteTrackDSPStates allValues]) {
            MKAudioDSPChainProcessorState *state = (MKAudioDSPChainProcessorState *)[value pointerValue];
            if (state != NULL) {
                MKAudioClearDSPChainState(state);
                free(state);
            }
        }
        [_remoteTrackDSPStates removeAllObjects];

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
        if (_audioOutput != nil) {
            status = [_audioOutput copyDSPStatusForSession:session];
        } else {
            status = [[NSDictionary alloc] init];
        }
    });
    return status;
}

@end
