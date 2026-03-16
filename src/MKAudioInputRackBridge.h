#import <Foundation/Foundation.h>
#import "MKAudioInput.h"

@interface MKAudioInputRackBridge : NSObject

- (void)updatePreviewGain:(float)gain enabled:(BOOL)enabled;
- (void)updateAudioUnitChain:(NSArray *)stages sampleRate:(NSUInteger)sampleRate;
- (void)updateHostBufferFrames:(NSUInteger)frames;
- (void)updateSampleRate:(NSUInteger)sampleRate;
- (NSDictionary *)copyStatus;
- (void)processSamples:(short *)samples
            frameCount:(NSUInteger)frameCount
              channels:(NSUInteger)channels
            sampleRate:(NSUInteger)sampleRate;

@end

FOUNDATION_EXPORT void MKAudioInputRackBridgeProcess(short *samples,
                                                     NSUInteger frameCount,
                                                     NSUInteger channels,
                                                     NSUInteger sampleRate,
                                                     void *context);
