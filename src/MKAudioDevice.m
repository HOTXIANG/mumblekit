// Copyright 2012 The MumbleKit Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import "MKAudioDevice.h"

@implementation MKAudioDevice

- (id)init {
    if ((self = [super init])) {
        atomic_init(&_callbackHealth.inputCompleted, 0);
        atomic_init(&_callbackHealth.outputCompleted, 0);
    }
    return self;
}

- (id) initWithSettings:(MKAudioSettings *)settings {
    return nil;
}

- (BOOL) setupDevice {
    return NO;
}

- (BOOL) startDevice {
    return YES;
}

- (BOOL) teardownDevice {
    return NO;
}

- (void) setupOutput:(MKAudioDeviceOutputFunc)outf {
}

- (void) setupInput:(MKAudioDeviceInputFunc)inf {
}

- (int) inputSampleRate {
    return 0;
}

- (int) outputSampleRate {
    return 0;
}

- (int) numberOfInputChannels {
    return 0;
}

- (int) numberOfOutputChannels {
    return 0;
}

@end
