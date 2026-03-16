#import "MKAudioInputRackBridge.h"

@protocol MKAudioInputRackExports <NSObject>
- (void)setPreviewGain:(float)gain enabled:(BOOL)enabled;
- (void)updateAudioUnitChain:(NSArray *)stages sampleRate:(NSUInteger)sampleRate;
- (void)setHostBufferFrames:(NSUInteger)frames;
- (void)updateProcessingSampleRate:(NSUInteger)sampleRate;
- (NSDictionary *)currentStatus;
- (void)processSamples:(short *)samples frameCount:(NSUInteger)frameCount channels:(NSUInteger)channels sampleRate:(NSUInteger)sampleRate;
@end

@interface MKAudioInputRackBridge () {
    id<MKAudioInputRackExports> _rack;
}
@end

@implementation MKAudioInputRackBridge

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        Class rackClass = NSClassFromString(@"MKAudioInputRack");
        if (rackClass == Nil) {
            rackClass = NSClassFromString(@"MumbleKit.MKAudioInputRack");
        }
        if (rackClass != Nil) {
            _rack = [[rackClass alloc] init];
        }
    }
    return self;
}

- (void)dealloc {
    [_rack release];
    _rack = nil;
    [super dealloc];
}

- (void)updatePreviewGain:(float)gain enabled:(BOOL)enabled {
    [_rack setPreviewGain:gain enabled:enabled];
}

- (void)updateAudioUnitChain:(NSArray *)stages sampleRate:(NSUInteger)sampleRate {
    [_rack updateAudioUnitChain:stages sampleRate:sampleRate];
}

- (void)updateHostBufferFrames:(NSUInteger)frames {
    [_rack setHostBufferFrames:frames];
}

- (void)updateSampleRate:(NSUInteger)sampleRate {
    [_rack updateProcessingSampleRate:sampleRate];
}

- (NSDictionary *)copyStatus {
    return [[_rack currentStatus] copy];
}

- (void)processSamples:(short *)samples
            frameCount:(NSUInteger)frameCount
              channels:(NSUInteger)channels
            sampleRate:(NSUInteger)sampleRate {
    [_rack processSamples:samples frameCount:frameCount channels:channels sampleRate:sampleRate];
}

@end

void MKAudioInputRackBridgeProcess(short *samples,
                                   NSUInteger frameCount,
                                   NSUInteger channels,
                                   NSUInteger sampleRate,
                                   void *context) {
    MKAudioInputRackBridge *bridge = (MKAudioInputRackBridge *)context;
    if (bridge == nil || samples == NULL || frameCount == 0 || channels == 0) {
        return;
    }
    [bridge processSamples:samples frameCount:frameCount channels:channels sampleRate:sampleRate];
}
