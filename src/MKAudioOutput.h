// Copyright 2005-2012 The MumbleKit Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import <MumbleKit/MKAudio.h>
#import <MumbleKit/MKUser.h>
#import <MumbleKit/MKConnection.h>
#import "MKAudioOutputUser.h"
#import "MKAudioDevice.h"

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

- (NSArray *) copyRemoteSessionOrder;

@end
