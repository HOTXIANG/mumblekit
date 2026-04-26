// Copyright 2005-2012 The MumbleKit Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import <MumbleKit/MKAudio.h>
#import <MumbleKit/MKUser.h>
#import <MumbleKit/MKConnection.h>
#import "MKAudioOutputUser.h"
#import "MKAudioDevice.h"

#define MK_SIDECHAIN_MAX_SESSIONS 64
#define MK_SIDECHAIN_MAX_FRAMES   4096

struct MKSidechainSlot {
    float      buffer[MK_SIDECHAIN_MAX_FRAMES * 2];
    unsigned long session;
    NSUInteger frameCount;
    NSUInteger channels;
    int        valid;
};

@class MKUser;

typedef void (*MKAudioOutputFloatProcessCallback)(float *samples, NSUInteger frameCount, NSUInteger channels, NSUInteger sampleRate, void *context);

@interface MKAudioOutput : NSObject

- (id) initWithDevice:(MKAudioDevice *)device andSettings:(MKAudioSettings *)settings;
- (void) dealloc;

- (void) removeBuffer:(MKAudioOutputUser *)u;
- (BOOL) mixFrames: (void *)frames amount:(unsigned int)nframes;
- (void) addFrameToBufferWithSession:(NSUInteger)session data:(NSData *)data sequence:(NSUInteger)seq type:(MKUDPMessageType)msgType;
- (NSDictionary *) copyMixerInfo;

- (void) setMasterVolume:(float)volume;
- (void) setVolume:(float)volume forSession:(NSUInteger)session;
- (void) setMuted:(BOOL)muted forSession:(NSUInteger)session;

- (void) setRemoteTrackProcessor:(MKAudioOutputFloatProcessCallback)processor context:(void *)context forSession:(NSUInteger)session;
- (void) clearRemoteTrackProcessorForSession:(NSUInteger)session;
- (void) clearAllRemoteTrackProcessors;

- (void) setRemoteBusProcessor:(MKAudioOutputFloatProcessCallback)processor context:(void *)context;
- (void) clearRemoteBusProcessor;

- (void) setRemoteBus2Processor:(MKAudioOutputFloatProcessCallback)processor context:(void *)context;
- (void) clearRemoteBus2Processor;
- (void) setInputMonitorEnabled:(BOOL)enabled gain:(float)gain;

/// 设置用户输出到哪个总线（0=Bus1 默认, 1=Bus2）
- (void) setBusAssignment:(NSUInteger)busIndex forSession:(NSUInteger)session;
- (NSUInteger) busAssignmentForSession:(NSUInteger)session;
- (void) setUsesTrackSendRouting:(BOOL)enabled forSession:(NSUInteger)session;
- (void) setTrackSendBusMask:(NSUInteger)busMask forSession:(NSUInteger)session;
- (void) setInputTrackSendBusMask:(NSUInteger)busMask;

- (NSArray *) copyRemoteSessionOrder;
- (NSUInteger) outputSampleRate;

/// DSP Observability - Query per-track DSP status and I/O levels
- (NSDictionary *) copyDSPStatusForSession:(NSUInteger)session;

/// Sidechain buffer pool - retrieve pre-plugin/pre-bus snapshots by source key
/// Keys: @"session:NNN" (per-user), @"masterBus1", @"masterBus2", @"sidetone", @"input"
- (const float *) sidechainBufferForSourceKey:(NSString *)key
                                   frameCount:(NSUInteger *)outFrameCount
                                     channels:(NSUInteger *)outChannels;

/// Set the input track sidechain buffer (called externally by MKAudio)
- (void) setSidechainInputBuffer:(const float *)buffer frameCount:(NSUInteger)frameCount channels:(NSUInteger)channels;
- (void) setSidetoneTrackSidechainBuffer:(const float *)buffer frameCount:(NSUInteger)frameCount channels:(NSUInteger)channels;
@end
