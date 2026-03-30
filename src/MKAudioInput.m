// Copyright 2005-2012 The MumbleKit Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import <MumbleKit/MKServerModel.h>
#import <MumbleKit/MKVersion.h>
#import <MumbleKit/MKConnection.h>
#import <MumbleKit/MKAudio.h>
#import "MKPacketDataStream.h"
#import "MKAudioInput.h"
#import "MKAudioOutput.h"
#import "MKAudioOutputSidetone.h"
#import "MKAudioDevice.h"
#import "../../Source/Classes/SwiftUI/Core/MumbleLogger.h"

#include <speex/speex.h>
#include <speex/speex_preprocess.h>
#include <speex/speex_echo.h>
#include <speex/speex_resampler.h>
#include <speex/speex_jitter.h>
#include <speex/speex_types.h>
#include <opus.h>

@interface MKAudioInput () {
    @public
    int                    micSampleSize;
    int                    numMicChannels;

    @private
    MKAudioDevice          *_device;
    MKAudioSettings        _settings;

    SpeexPreprocessState   *_preprocessorState;
    SpeexResamplerState    *_micResampler;
    SpeexBits              _speexBits;
    void                   *_speexEncoder;
    OpusEncoder            *_opusEncoder;

    int                    frameSize;
    int                    micFrequency;
    int                    sampleRate;
    int                    encodeChannels;

    int                    micFilled;
    int                    micLength;
    int                    bitrate;
    int                    frameCounter;
    int                    _bufferedFrames;

    BOOL                   doResetPreprocessor;

    short                  *psMic;
    short                  *psOut;

    MKUDPMessageType       udpMessageType;
    NSMutableArray         *frameList;

    MKCodecFormat          _codecFormat;
    BOOL                   _doTransmit;
    BOOL                   _forceTransmit;
    BOOL                   _lastTransmit;

    signed long            _preprocRunningAvg;
    signed long            _preprocAvgItems;

    float                  _speechProbability;
    float                  _peakCleanMic;

    BOOL                   _selfMuted;
    BOOL                   _muted;
    BOOL                   _suppressed;
 
    BOOL                   _vadGateEnabled;
    double                 _vadGateTimeSeconds;
    double                 _vadOpenLastTime;

    NSMutableData          *_encodingOutputBuffer;
    NSMutableData          *_opusBuffer;
    MKAudioInputInt16ProcessCallback _inputTrackProcessor;
    void                   *_inputTrackProcessorContext;
    MKAudioInputInt16ProcessCallback _sidetoneTrackProcessor;
    void                   *_sidetoneTrackProcessorContext;
    
    MKConnection           *_connection;
}
@end

@implementation MKAudioInput

- (id) initWithDevice:(MKAudioDevice *)device andSettings:(MKAudioSettings *)settings {
    self = [super init];
    if (self == nil)
        return nil;
    
    // Set device
    _device = [device retain];

    // Copy settings
    memcpy(&_settings, settings, sizeof(MKAudioSettings));
    
    _preprocessorState = NULL;
    _micResampler = NULL;
    _speexEncoder = NULL;
    frameCounter = 0;
    _bufferedFrames = 0;
    
    _vadGateEnabled = _settings.enableVadGate;
    _vadGateTimeSeconds = _settings.vadGateTimeSeconds;
    _vadOpenLastTime = [[NSDate date] timeIntervalSince1970];
    _inputTrackProcessor = NULL;
    _inputTrackProcessorContext = NULL;
    _sidetoneTrackProcessor = NULL;
    _sidetoneTrackProcessorContext = NULL;

    micFrequency = [_device inputSampleRate];
    numMicChannels = MAX(1, [_device numberOfInputChannels]);
    int requestedChannels = _settings.enableStereoInput ? 2 : 1;
    encodeChannels = MIN(requestedChannels, numMicChannels);

    // Fall back to CELT if Opus is not enabled.
    if (![[MKVersion sharedVersion] isOpusEnabled] && _settings.codec == MKCodecFormatOpus) {
        _settings.codec = MKCodecFormatCELT;
        MKLogWarning(Audio, @"Falling back to CELT");
    }

    if (_settings.codec == MKCodecFormatSpeex && encodeChannels > 1) {
        MKLogWarning(Audio, @"MKAudioInput: Speex does not support stereo encode path. Falling back to mono.");
        encodeChannels = 1;
    }
    if (_settings.enableStereoInput && encodeChannels < 2 && _settings.codec != MKCodecFormatSpeex) {
        MKLogWarning(Audio, @"MKAudioInput: Stereo input requested but unavailable from device. Falling back to mono.");
    }

    if (_settings.codec == MKCodecFormatOpus) {
        sampleRate = SAMPLE_RATE;
        frameSize = SAMPLE_RATE / 100;
        _opusEncoder = opus_encoder_create(SAMPLE_RATE, encodeChannels, OPUS_APPLICATION_VOIP, NULL);

        // CBR (Constant Bitrate)
        opus_encoder_ctl(_opusEncoder, OPUS_SET_VBR(0));

        // Weak Network Optimization (弱网优化)
        if (_settings.enableWeakNetworkMode) {
            // Enable in-band FEC (启用前向纠错)
            opus_int32 fec = 1;
            opus_encoder_ctl(_opusEncoder, OPUS_SET_INBAND_FEC(fec));

            // Set expected packet loss percentage (设置期望丢包率)
            opus_int32 expectedLoss = _settings.weakNetworkExpectedLoss;
            if (expectedLoss < 0) expectedLoss = 0;
            if (expectedLoss > 60) expectedLoss = 60;  // Cap at 60%
            opus_encoder_ctl(_opusEncoder, OPUS_SET_PACKET_LOSS_PERC(expectedLoss));

            // Higher complexity for better PLC (更高复杂度换取更好丢包隐藏)
            opus_int32 complexity = 10;
            opus_encoder_ctl(_opusEncoder, OPUS_SET_COMPLEXITY(complexity));

            // DTX for bandwidth efficiency (DTX 节省带宽)
            opus_int32 dtx = 1;
            opus_encoder_ctl(_opusEncoder, OPUS_SET_DTX(dtx));

            MKLogInfo(Audio, @"MKAudioInput: Weak Network Mode enabled - FEC=%d, ExpectedLoss=%d%%, Bitrate=%d-%d",
                     fec, expectedLoss, _settings.weakNetworkMinBitrate, _settings.weakNetworkMaxBitrate);
        } else {
            // Default settings for good network (默认好网络配置)
            opus_int32 fec = 0;
            opus_encoder_ctl(_opusEncoder, OPUS_SET_INBAND_FEC(fec));
            opus_int32 complexity = 5;
            opus_encoder_ctl(_opusEncoder, OPUS_SET_COMPLEXITY(complexity));
        }

        MKLogInfo(Audio, @"MKAudioInput: %i bits/s, %d Hz, %d sample Opus (%d ch) weakNetwork=%d",
                 _settings.quality, sampleRate, frameSize, encodeChannels, _settings.enableWeakNetworkMode ? 1 : 0);
    } else if (_settings.codec == MKCodecFormatCELT) {
        sampleRate = SAMPLE_RATE;
        frameSize = SAMPLE_RATE / 100;
        MKLogInfo(Audio, @"MKAudioInput: %i bits/s, %d Hz, %d sample CELT (%d ch input)", _settings.quality, sampleRate, frameSize, encodeChannels);
    } else if (_settings.codec == MKCodecFormatSpeex) {
        sampleRate = 32000;

        speex_bits_init(&_speexBits);
        speex_bits_reset(&_speexBits);
        _speexEncoder = speex_encoder_init(speex_lib_get_mode(SPEEX_MODEID_UWB));
        speex_encoder_ctl(_speexEncoder, SPEEX_GET_FRAME_SIZE, &frameSize);
        speex_encoder_ctl(_speexEncoder, SPEEX_GET_SAMPLING_RATE, &sampleRate);

        int iArg = 1;
        speex_encoder_ctl(_speexEncoder, SPEEX_SET_VBR, &iArg);

        iArg = 0;
        speex_encoder_ctl(_speexEncoder, SPEEX_SET_VAD, &iArg);
        speex_encoder_ctl(_speexEncoder, SPEEX_SET_DTX, &iArg);

        float fArg = 8.0;
        speex_encoder_ctl(_speexEncoder, SPEEX_SET_VBR_QUALITY, &fArg);

        iArg = _settings.quality;
        speex_encoder_ctl(_speexEncoder, SPEEX_SET_VBR_MAX_BITRATE, &iArg);

        iArg = 5;
        speex_encoder_ctl(_speexEncoder, SPEEX_SET_COMPLEXITY, &iArg);
        MKLogInfo(Audio, @"MKAudioInput: %d bits/s, %d Hz, %d sample Speex-UWB", _settings.quality, sampleRate, frameSize);
    }

    doResetPreprocessor = YES;
    _doTransmit = NO;
    _forceTransmit = NO;
    _lastTransmit = NO;
    [self postLocalTalkState:MKTalkStatePassive];

    numMicChannels = 0;
    bitrate = 0;

    /*
     if (g.uiSession)
        setMaxBandwidth(g.iMaxBandwidth);
     */

    frameList = [[NSMutableArray alloc] initWithCapacity:_settings.audioPerPacket];

    udpMessageType = ~0;
    
    micFrequency = [_device inputSampleRate];
    numMicChannels = MAX(1, [_device numberOfInputChannels]);
    encodeChannels = MIN(encodeChannels, numMicChannels);
    if (encodeChannels < 1) {
        encodeChannels = 1;
    }
    
    [self initializeMixer];
 
    [_device setupInput:^BOOL(short *frames, unsigned int nsamp) {
        [self addMicrophoneDataWithBuffer:frames amount:nsamp];
        return YES;
    }];

    return self;
}

- (void)postLocalTalkState:(MKTalkState)talkState {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    NSDictionary *talkStateDict = [NSDictionary dictionaryWithObjectsAndKeys:
                                   [NSNumber numberWithUnsignedInteger:talkState], @"talkState",
                                   nil];
    NSNotification *notification = [NSNotification notificationWithName:@"MKAudioUserTalkStateChanged" object:talkStateDict];
    [center performSelectorOnMainThread:@selector(postNotification:) withObject:notification waitUntilDone:NO];
}

- (void) dealloc {
    [_device setupInput:NULL];
    [_device release];

    [frameList release];
    [_opusBuffer release];
    [_encodingOutputBuffer release];

    if (psMic)
        free(psMic);
    if (psOut)
        free(psOut);

    if (_speexEncoder)
        speex_encoder_destroy(_speexEncoder);
    if (_micResampler)
        speex_resampler_destroy(_micResampler);
    if (_preprocessorState)
        speex_preprocess_state_destroy(_preprocessorState);
    if (_opusEncoder)
        opus_encoder_destroy(_opusEncoder);

    [super dealloc];
}

- (void) setMainConnectionForAudio:(MKConnection *)conn {
    @synchronized(self) {
        _connection = conn;
    }
}

- (void) initializeMixer {
    int err;
    
    if (sampleRate <= 0) {
        MKLogWarning(Audio, @"MKAudioInput: Invalid sampleRate=%d, falling back to %d.", sampleRate, SAMPLE_RATE);
        sampleRate = SAMPLE_RATE;
    }
    if (frameSize <= 0) {
        MKLogWarning(Audio, @"MKAudioInput: Invalid frameSize=%d, falling back to %d.", frameSize, SAMPLE_RATE / 100);
        frameSize = SAMPLE_RATE / 100;
    }

    MKLogDebug(Audio, @"MKAudioInput: initializeMixer -- iMicFreq=%u, iSampleRate=%u", micFrequency, sampleRate);

    micLength = (frameSize * micFrequency) / sampleRate;

    if (_micResampler)
        speex_resampler_destroy(_micResampler);

    if (psMic)
        free(psMic);
    if (psOut)
        free(psOut);

    if (micFrequency != sampleRate) {
        _micResampler = speex_resampler_init(encodeChannels, micFrequency, sampleRate, 3, &err);
        MKLogInfo(Audio, @"MKAudioInput: initialized resampler (%iHz -> %iHz)", micFrequency, sampleRate);
    }

    psMic = malloc(micLength * encodeChannels * sizeof(short));
    psOut = malloc(frameSize * encodeChannels * sizeof(short));
    micSampleSize = numMicChannels * sizeof(short);
    doResetPreprocessor = YES;

    MKLogInfo(Audio, @"MKAudioInput: Initialized mixer for input=%i ch @ %i Hz, encode=%i ch @ %i Hz", numMicChannels, micFrequency, encodeChannels, sampleRate);
}

- (void) addMicrophoneDataWithBuffer:(short *)input amount:(NSUInteger)nsamp {
    int i;

    while (nsamp > 0) {
        NSUInteger left = MIN(nsamp, micLength - micFilled);

        short *output = psMic + (micFilled * encodeChannels);

        for (i = 0; i < left; i++) {
            short *inFrame = input + (i * numMicChannels);
            short *outFrame = output + (i * encodeChannels);
            short sampleL = inFrame[0];
            short sampleR = (numMicChannels > 1) ? inFrame[1] : sampleL;

            if (encodeChannels > 1) {
                outFrame[0] = sampleL;
                outFrame[1] = sampleR;
            } else {
                if (numMicChannels > 1) {
                    int mixed = ((int)sampleL + (int)sampleR) / 2;
                    outFrame[0] = (short)mixed;
                } else {
                    outFrame[0] = sampleL;
                }
            }
        }

        input += (left * numMicChannels);
        micFilled += left;
        nsamp -= left;

        if (micFilled == micLength) {
            // Should we resample?
            if (_micResampler) {
                spx_uint32_t inlen = micLength;
                spx_uint32_t outlen = frameSize;
                if (encodeChannels > 1) {
                    speex_resampler_process_interleaved_int(_micResampler, psMic, &inlen, psOut, &outlen);
                } else {
                    speex_resampler_process_int(_micResampler, 0, psMic, &inlen, psOut, &outlen);
                }
            }
            micFilled = 0;

            [self processAndEncodeAudioFrame];
        }
    }
}

- (void) updateInputMonitorSendForFrame:(short *)frame
                             frameCount:(NSUInteger)frameCount
                               channels:(NSUInteger)channels
                             sampleRate:(NSUInteger)processingSampleRate
                                 active:(BOOL)active {
    MKAudio *audio = [MKAudio sharedAudio];
    if (audio == nil) {
        return;
    }

    if (!active || frame == NULL || frameCount == 0 || channels == 0 || channels > 2 || processingSampleRate != SAMPLE_RATE) {
        [audio writeSidetoneSidechainSamples:NULL frameCount:0 channels:0];
        [audio writeInputMonitorSamples:NULL frameCount:0 channels:0 sampleRate:processingSampleRate];
        return;
    }

    NSUInteger sampleCount = frameCount * channels;
    short sidetoneFrame[sampleCount];
    // Sidetone is a dedicated output bus fed by the post-input-track signal.
    // Start from the current input-track frame, then let the sidetone rack
    // apply its own plugin chain on top.
    memcpy(sidetoneFrame, frame, sampleCount * sizeof(short));
    if (_sidetoneTrackProcessor != NULL) {
        _sidetoneTrackProcessor(sidetoneFrame,
                                frameCount,
                                channels,
                                processingSampleRate,
                                _sidetoneTrackProcessorContext);
    }

    float monitorBuffer[sampleCount];
    for (NSUInteger sampleIndex = 0; sampleIndex < sampleCount; sampleIndex++) {
        monitorBuffer[sampleIndex] = (float)sidetoneFrame[sampleIndex] / 32768.0f;
    }
    [audio writeSidetoneSidechainSamples:monitorBuffer frameCount:frameCount channels:channels];
    [audio writeInputMonitorSamples:monitorBuffer frameCount:frameCount channels:channels sampleRate:processingSampleRate];
}

- (void) resetPreprocessor {
    int iArg;

    _preprocAvgItems = 0;
    _preprocRunningAvg = 0;

    if (_preprocessorState)
        speex_preprocess_state_destroy(_preprocessorState);

    _preprocessorState = speex_preprocess_state_init(frameSize, sampleRate);
    SpeexPreprocessState *state = _preprocessorState;

    iArg = 1;
    speex_preprocess_ctl(state, SPEEX_PREPROCESS_SET_VAD, &iArg);
    
    iArg = 0;
    speex_preprocess_ctl(state, SPEEX_PREPROCESS_SET_AGC, &iArg);

    iArg = _settings.enableDenoise ? 1 : 0;
    speex_preprocess_ctl(state, SPEEX_PREPROCESS_SET_DENOISE, &iArg);
    speex_preprocess_ctl(state, SPEEX_PREPROCESS_SET_DEREVERB, &iArg);

    /*iArg = 30000;
    speex_preprocess_ctl(state, SPEEX_PREPROCESS_SET_AGC_TARGET, &iArg);*/

    //float v = 30000.0f / (float) 0.0f; // iMinLoudness
    //iArg = iroundf(floorf(20.0f * log10f(v)));
    //speex_preprocess_ctl(state, SPEEX_PREPROCESS_SET_AGC_MAX_GAIN, &iArg);

    iArg = _settings.noiseSuppression;
    speex_preprocess_ctl(state, SPEEX_PREPROCESS_SET_NOISE_SUPPRESS, &iArg);
}

- (int) encodeAudioFrameOfSpeech:(BOOL)isSpeech intoBuffer:(unsigned char *)encbuf ofSize:(NSUInteger)max  {
    int len = 0;
    int encoded = 1;  
    BOOL resampled = micFrequency != sampleRate;
    
    if (max < 500)
        return -1;

    BOOL useOpus = YES;
    if (_lastTransmit) {
        useOpus = udpMessageType == UDPVoiceOpusMessage;
    } else if ([[MKVersion sharedVersion] isOpusEnabled]) {
        @synchronized(self) {
            if (_connection) {
                useOpus = [_connection shouldUseOpus];
            }
        }
    }
    
    if (useOpus && (_settings.codec == MKCodecFormatOpus || _settings.codec == MKCodecFormatCELT)) {
        encoded = 0;
        udpMessageType = UDPVoiceOpusMessage;
        if (_opusBuffer == nil)
            _opusBuffer = [[NSMutableData alloc] init];
        _bufferedFrames++;
        [_opusBuffer appendBytes:(resampled ? psOut : psMic) length:frameSize * encodeChannels * sizeof(short)];
        if (!isSpeech || _bufferedFrames >= _settings.audioPerPacket) {
            // Ensure we have enough frames for the Opus encoder.
            // Pad with silence if needed.
            if (_bufferedFrames < _settings.audioPerPacket) {
                NSUInteger numMissingFrames = _settings.audioPerPacket - _bufferedFrames;
                NSUInteger extraBytes = numMissingFrames * frameSize * encodeChannels * sizeof(short);
                [_opusBuffer increaseLengthBy:extraBytes];
                _bufferedFrames += numMissingFrames;
            }
            if (!_lastTransmit) {
                opus_encoder_ctl(_opusEncoder, OPUS_RESET_STATE, NULL);
            }

            // Force CELT mode when using Opus if we were asked to.
            if (_settings.opusForceCELTMode) {
#define OPUS_SET_FORCE_MODE_REQUEST  11002
#define OPUS_SET_FORCE_MODE(x)       OPUS_SET_FORCE_MODE_REQUEST, __opus_check_int(x)
#define MODE_CELT_ONLY               1002
                opus_encoder_ctl(_opusEncoder, OPUS_SET_FORCE_MODE(MODE_CELT_ONLY));
            }

            // Adaptive Bitrate Control (自适应码率控制)
            int targetBitrate = _settings.quality;
            if (_settings.enableWeakNetworkMode && _settings.weakNetworkAdaptiveBitrate) {
                targetBitrate = [self calculateAdaptiveBitrate];
            }
            opus_encoder_ctl(_opusEncoder, OPUS_SET_BITRATE(targetBitrate));

            len = opus_encode(_opusEncoder, (short *) [_opusBuffer bytes], (opus_int32)(_bufferedFrames * frameSize), encbuf, (opus_int32)max);
            [_opusBuffer setLength:0];
            if (len <= 0) {
                bitrate = 0;
                return -1;
            }
            bitrate = (len * 100 * 8) / _bufferedFrames;
            encoded = 1;
        }
    } else if (!useOpus && (_settings.codec == MKCodecFormatCELT || _settings.codec == MKCodecFormatOpus)) {
        // During reconnect/codec-negotiation window, server codec preference may not be finalized yet.
        // Never crash on unsupported CELT path; just skip this frame and wait for Opus-ready state.
        bitrate = 0;
        return -1;
    } else if (_settings.codec == MKCodecFormatSpeex) {
        int vbr = 0;
        speex_encoder_ctl(_speexEncoder, SPEEX_GET_VBR_MAX_BITRATE, &vbr);
        if (vbr != _settings.quality) {
            vbr = _settings.quality;
            speex_encoder_ctl(_speexEncoder, SPEEX_SET_VBR_MAX_BITRATE, &vbr);
        }
        if (!_lastTransmit)
            speex_encoder_ctl(_speexEncoder, SPEEX_RESET_STATE, NULL);
        speex_encode_int(_speexEncoder, psOut, &_speexBits);
        len = speex_bits_write(&_speexBits, (char *)encbuf, 127);
        speex_bits_reset(&_speexBits);
        _bufferedFrames++;
        bitrate = len * 50 * 8;
        udpMessageType = UDPVoiceSpeexMessage;
    }
    
    return encoded ? len : -1;
}

- (void) processAndEncodeAudioFrame {
    frameCounter++;

    if (doResetPreprocessor) {
        [self resetPreprocessor];
        doResetPreprocessor = NO;
    }

    int isSpeech = 0;
    BOOL resampled = micFrequency != sampleRate;
    short *frame = resampled ? psOut : psMic;
    int frameSamples = frameSize * encodeChannels;
    short monoFrame[frameSize];

    if (_settings.enablePreprocessor) {
        if (encodeChannels > 1) {
            int i;
            for (i = 0; i < frameSize; i++) {
                int mixed = ((int)frame[i * encodeChannels] + (int)frame[i * encodeChannels + 1]) / 2;
                monoFrame[i] = (short)mixed;
            }
            isSpeech = speex_preprocess_run(_preprocessorState, monoFrame);
        } else {
            isSpeech = speex_preprocess_run(_preprocessorState, frame);
        }
    } else {
        int i;
        float gain = _settings.micBoost; // 1.0 = 100%, 3.0 = 300%
        if (gain < 0.0f) {
            gain = 0.0f;
        }
        
        for (i = 0; i < frameSamples; i++) {
            // 1. 转为浮点数计算，防止中间计算溢出
            // 32767.0f 是 Short 的最大值
            float val = frame[i] * gain;
            
            // 2. ✅ Hard Clipping (硬限幅) 防止溢出
            // 如果超过 32767，就卡在 32767，绝不让它变成负数
            if (val > 32767.0f) {
                val = 32767.0f;
            } else if (val < -32768.0f) {
                val = -32768.0f;
            }
            
            // 3. 转回 Short
            frame[i] = (short)val;
        }
    }

    // Publish post-input-track signal for sidechain sends.
    {
        MKAudio *audio = [MKAudio sharedAudio];
        if (audio != nil) {
            float scBuf[MK_SIDECHAIN_MAX_FRAMES * 2];
            NSUInteger scCount = MIN((NSUInteger)frameSize, (NSUInteger)MK_SIDECHAIN_MAX_FRAMES);
            if (_inputTrackProcessor != NULL) {
                _inputTrackProcessor(frame, (NSUInteger)frameSize, (NSUInteger)encodeChannels, (NSUInteger)sampleRate, _inputTrackProcessorContext);
            }
            for (NSUInteger si = 0; si < scCount * encodeChannels; si++) {
                scBuf[si] = (float)frame[si] / 32768.0f;
            }
            [audio writeSidechainInputSamples:scBuf frameCount:scCount channels:encodeChannels];
        } else if (_inputTrackProcessor != NULL) {
            _inputTrackProcessor(frame, (NSUInteger)frameSize, (NSUInteger)encodeChannels, (NSUInteger)sampleRate, _inputTrackProcessorContext);
        }
    }

    float sum = 1.0f;
    int i;
    for (i = 0; i < frameSize; i++) {
        float sample = frame[i * encodeChannels];
        if (encodeChannels > 1) {
            sample = (sample + frame[i * encodeChannels + 1]) * 0.5f;
        }
        sum += sample * sample;
    }
    float micLevel = sqrtf(sum / frameSize);
    float peakSignal = 20.0f*log10f(micLevel/32768.0f);
    if (-96.0f > peakSignal)
        peakSignal = -96.0f;
    
    spx_int32_t prob = 0;
    speex_preprocess_ctl(_preprocessorState, SPEEX_PREPROCESS_GET_PROB, &prob);
    _speechProbability = prob / 100.0f;
    
    int arg;
    speex_preprocess_ctl(_preprocessorState, SPEEX_PREPROCESS_GET_AGC_GAIN, &arg);
    _peakCleanMic = peakSignal - (float)arg;
    if (-96.0f > _peakCleanMic) {
        _peakCleanMic = -96.0f;
    }
    
    if (_settings.transmitType == MKTransmitTypeVAD) {
        float level = _speechProbability;
        if (!_settings.enablePreprocessor || _settings.vadKind == MKVADKindAmplitude) {
            level = ((_peakCleanMic)/96.0f) + 1.0;
        }
        _doTransmit = NO;

        if (_settings.vadMax == 0 && _settings.vadMin == 0) {
            _doTransmit = NO;
        } else if (level > _settings.vadMax) {
            _doTransmit = YES;
            if(_vadGateEnabled) {
                _vadOpenLastTime = [[NSDate date] timeIntervalSince1970];
            }
        } else if (level > _settings.vadMin && _lastTransmit) {
            _doTransmit = YES;
            if(_vadGateEnabled) {
                _vadOpenLastTime = [[NSDate date] timeIntervalSince1970];
            }
        }
        else if (level < _settings.vadMin)
        {
            if(_vadGateEnabled) {
                double currTime = [[NSDate date] timeIntervalSince1970];
                if((currTime - _vadOpenLastTime) < _vadGateTimeSeconds) {
                    _doTransmit = YES;
                }
            }
        }
    } else if (_settings.transmitType == MKTransmitTypeContinuous) {
        _doTransmit = YES;
    } else if (_settings.transmitType == MKTransmitTypeToggle) {
        _doTransmit = _forceTransmit;
    }

    if (_selfMuted)
        _doTransmit = NO;
    if (_suppressed)
        _doTransmit = NO;
    if (_muted)
        _doTransmit = NO;
    
    [self updateInputMonitorSendForFrame:frame
                              frameCount:(NSUInteger)frameSize
                                channels:(NSUInteger)encodeChannels
                              sampleRate:(NSUInteger)sampleRate
                                  active:_settings.enableSideTone];
    
    if (_lastTransmit != _doTransmit) {
        // fixme(mkrautz): Handle more talkstates
        [self postLocalTalkState:(_doTransmit ? MKTalkStateTalking : MKTalkStatePassive)];
    }
     
     if (!_lastTransmit && !_doTransmit) {
         return;
     }
    
    if (_encodingOutputBuffer == nil)
        _encodingOutputBuffer = [[NSMutableData alloc] initWithLength:960];
    int len = [self encodeAudioFrameOfSpeech:_doTransmit intoBuffer:[_encodingOutputBuffer mutableBytes] ofSize:[_encodingOutputBuffer length]];
    if (len >= 0) {
        NSData *outputBuffer = [[NSData alloc] initWithBytes:[_encodingOutputBuffer bytes] length:len];
        [self flushCheck:outputBuffer terminator:!_doTransmit];
        [outputBuffer release];
    }
    _lastTransmit = _doTransmit;
}

// Flush check.
// Queue up frames, and send them to the server when enough frames have been
// queued up.
- (void) flushCheck:(NSData *)codedSpeech terminator:(BOOL)terminator {
    [frameList addObject:codedSpeech];
    
    if (! terminator && _bufferedFrames < _settings.audioPerPacket) {
        return;
    }

    int flags = 0;
    if (terminator)
        flags = 0; /* g.iPrevTarget. */

    /*
     * Server loopback:
     * flags = 0x1f;
     */
    flags |= (udpMessageType << 5);

    unsigned char data[1024];
    data[0] = (unsigned char )(flags & 0xff);
    
    int frames = _bufferedFrames;
    _bufferedFrames = 0;
    
    MKPacketDataStream *pds = [[MKPacketDataStream alloc] initWithBuffer:(data+1) length:1023];
    [pds addVarint:(frameCounter - frames)];

    if (udpMessageType == UDPVoiceOpusMessage) {
       NSData *frame = [frameList objectAtIndex:0]; 
        uint64_t header = [frame length];
        if (terminator)
            header |= (1 << 13); // Opus terminator flag
        [pds addVarint:header];
        [pds appendBytes:(unsigned char *)[frame bytes] length:[frame length]];
    } else {
        /* fix terminator stuff here. */
        NSUInteger i, nframes = [frameList count];
        for (i = 0; i < nframes; i++) {
            NSData *frame = [frameList objectAtIndex:i];
            unsigned char head = (unsigned char)[frame length];
            if (i < nframes-1)
                head |= 0x80;
            [pds appendValue:head];
            [pds appendBytes:(unsigned char *)[frame bytes] length:[frame length]];
        }
    }
    
    [frameList removeAllObjects];

    NSUInteger len = [pds size] + 1;
    NSData *msgData = [[NSData alloc] initWithBytes:data length:len];
    [pds release];
    
    @synchronized(self) {
        [_connection sendVoiceData:msgData];
    }

    [msgData release];
}

- (void) setForceTransmit:(BOOL)flag {
    _forceTransmit = flag;
}

- (BOOL) forceTransmit {
    return _forceTransmit;
}

- (long) preprocessorAvgRuntime {
    return _preprocRunningAvg;
}

- (float) speechProbability {
    return _speechProbability;
}

- (float) peakCleanMic {
    return _peakCleanMic;
}

- (void) setSelfMuted:(BOOL)selfMuted {
    _selfMuted = selfMuted;
}

- (void) setSuppressed:(BOOL)suppressed {
    _suppressed = suppressed;
}

- (void) setMuted:(BOOL)muted {
    _muted = muted;
}

- (void) setInputTrackProcessor:(MKAudioInputInt16ProcessCallback)processor context:(void *)context {
    @synchronized(self) {
        _inputTrackProcessor = processor;
        _inputTrackProcessorContext = context;
    }
}

- (void) clearInputTrackProcessor {
    @synchronized(self) {
        _inputTrackProcessor = NULL;
        _inputTrackProcessorContext = NULL;
    }
}

- (void) setSidetoneTrackProcessor:(MKAudioInputInt16ProcessCallback)processor context:(void *)context {
    @synchronized(self) {
        _sidetoneTrackProcessor = processor;
        _sidetoneTrackProcessorContext = context;
    }
}

- (void) clearSidetoneTrackProcessor {
    @synchronized(self) {
        _sidetoneTrackProcessor = NULL;
        _sidetoneTrackProcessorContext = NULL;
    }
}

- (void) setInputMonitorEnabled:(BOOL)enabled {
    _settings.enableSideTone = enabled;
}

#pragma mark - Weak Network Adaptive Bitrate (弱网自适应码率)

- (int) calculateAdaptiveBitrate {
    // 从连接获取网络质量指标
    if (!_connection) {
        return _settings.weakNetworkMinBitrate;
    }

    // 获取 UDP ping 统计
    double udpPingMean = [_connection udpPingMeanMs];
    double udpPingVariance = [_connection udpPingVarianceMs];
    uint32_t udpPingSamples = [_connection udpPingSamples];

    // 标准差 = sqrt(variance)
    double udpPingStdDev = sqrt(udpPingVariance);

    // 计算延迟因子 (0.0 - 1.0, 越高表示网络越差)
    double latencyFactor = 0.0;
    if (udpPingSamples >= 5) {
        // 使用 mean + 1*stdDev 作为有效延迟指标
        double effectiveLatency = udpPingMean + udpPingStdDev;

        if (effectiveLatency > 300) {
            latencyFactor = 1.0;  // 极高延迟
        } else if (effectiveLatency > 150) {
            latencyFactor = 0.6 + (effectiveLatency - 150) / 150 * 0.4;  // 0.6-1.0
        } else if (effectiveLatency > 80) {
            latencyFactor = 0.3 + (effectiveLatency - 80) / 70 * 0.3;  // 0.3-0.6
        } else if (effectiveLatency > 50) {
            latencyFactor = (effectiveLatency - 50) / 30 * 0.3;  // 0-0.3
        }
    }

    // 获取丢包率统计 (从 connection 的 lastGood/lastLate/lastLost)
    double packetLossFactor = 0.0;
    uint32_t lastGood = [_connection lastGood];
    uint32_t lastLate = [_connection lastLate];
    uint32_t lastLost = [_connection lastLost];
    uint32_t totalPackets = lastGood + lastLate + lastLost;

    if (totalPackets > 10) {
        double lossRate = (double)(lastLate + lastLost) / (double)totalPackets;
        packetLossFactor = MIN(1.0, lossRate * 2.0);  // 50% 丢包率=1.0
    }

    // 综合网络质量因子 (0.0 = 好网络，1.0 = 极差网络)
    double networkQualityFactor = MAX(latencyFactor, packetLossFactor);

    // 根据网络质量计算目标码率
    int minBitrate = _settings.weakNetworkMinBitrate > 0 ? _settings.weakNetworkMinBitrate : 16000;
    int maxBitrate = _settings.weakNetworkMaxBitrate > 0 ? _settings.weakNetworkMaxBitrate : 64000;

    // 线性插值：网络越好码率越高，网络越差码率越低
    int targetBitrate = (int)((1.0 - networkQualityFactor) * (maxBitrate - minBitrate) + minBitrate);

    // 限制在范围内
    targetBitrate = MAX(minBitrate, MIN(maxBitrate, targetBitrate));

    // 平滑过渡：避免码率突变
    static int lastTargetBitrate = -1;
    if (lastTargetBitrate < 0) {
        lastTargetBitrate = targetBitrate;
    } else {
        // 每次最多变化 8kbps
        int maxChange = 8000;
        int delta = targetBitrate - lastTargetBitrate;
        if (delta > maxChange) delta = maxChange;
        if (delta < -maxChange) delta = -maxChange;
        targetBitrate = lastTargetBitrate + delta;
        lastTargetBitrate = targetBitrate;
    }

    MKLogVerbose(Audio, @"WeakNetwork: adaptive bitrate -- latency=%.1fms, loss=%.1f%%, factor=%.2f, target=%dbps",
                udpPingMean, packetLossFactor * 50.0, networkQualityFactor, targetBitrate);

    return targetBitrate;
}

@end
