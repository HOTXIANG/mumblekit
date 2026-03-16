#import "MKAudioRemoteTrackRackBridge.h"

@protocol MKAudioRemoteTrackRackExports <NSObject>
- (void)setPreviewGain:(float)gain enabled:(BOOL)enabled;
- (void)updateAudioUnitChain:(NSArray *)stages sampleRate:(NSUInteger)sampleRate;
- (void)setHostBufferFrames:(NSUInteger)frames;
- (void)updateProcessingSampleRate:(NSUInteger)sampleRate;
- (NSDictionary *)currentStatus;
- (void)processSamples:(float *)samples frameCount:(NSUInteger)frameCount channels:(NSUInteger)channels sampleRate:(NSUInteger)sampleRate;
@end

@interface MKAudioRemoteTrackRackBridge () {
    id<MKAudioRemoteTrackRackExports> _rack;
}
@end

@implementation MKAudioRemoteTrackRackBridge

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        Class rackClass = NSClassFromString(@"MKAudioRemoteTrackRack");
        if (rackClass == Nil) {
            rackClass = NSClassFromString(@"MumbleKit.MKAudioRemoteTrackRack");
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

- (void)processSamples:(float *)samples
            frameCount:(NSUInteger)frameCount
              channels:(NSUInteger)channels
            sampleRate:(NSUInteger)sampleRate {
    [_rack processSamples:samples frameCount:frameCount channels:channels sampleRate:sampleRate];
}

@end

void MKAudioRemoteTrackRackBridgeProcess(float *samples,
                                         NSUInteger frameCount,
                                         NSUInteger channels,
                                         NSUInteger sampleRate,
                                         void *context) {
    MKAudioRemoteTrackRackBridge *bridge = (MKAudioRemoteTrackRackBridge *)context;
    if (bridge == nil || samples == NULL || frameCount == 0 || channels == 0) {
        return;
    }
    [bridge processSamples:samples frameCount:frameCount channels:channels sampleRate:sampleRate];
}
