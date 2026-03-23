#import <Foundation/Foundation.h>
#import "MKAudioOutput.h"

@interface MKAudioRemoteBusRackBridge : NSObject

/// Set the MKAudioOutput reference for sidechain buffer lookup.
/// Called by MKAudio before each processing cycle.
@property (assign, nonatomic) MKAudioOutput *sidechainAudioOutput;

- (void)updatePreviewGain:(float)gain enabled:(BOOL)enabled;
- (void)updateAudioUnitChain:(NSArray *)stages sampleRate:(NSUInteger)sampleRate;
- (void)updateHostBufferFrames:(NSUInteger)frames;
- (void)updateSampleRate:(NSUInteger)sampleRate;
- (NSDictionary *)copyStatus;
- (void)processSamples:(float *)samples
            frameCount:(NSUInteger)frameCount
              channels:(NSUInteger)channels
            sampleRate:(NSUInteger)sampleRate;

@end

FOUNDATION_EXPORT void MKAudioRemoteBusRackBridgeProcess(float *samples,
                                                         NSUInteger frameCount,
                                                         NSUInteger channels,
                                                         NSUInteger sampleRate,
                                                         void *context);
