#import <Foundation/Foundation.h>

#if TARGET_OS_OSX
@class NSViewController;
#endif

NS_ASSUME_NONNULL_BEGIN

@interface MKVST3PluginHost : NSObject

@property (nonatomic, readonly, copy) NSString *bundlePath;
@property (nonatomic, readonly, copy) NSString *displayName;
@property (nonatomic, readonly) NSUInteger configuredInputChannels;
@property (nonatomic, readonly) NSUInteger configuredOutputChannels;
@property (nonatomic, readonly) NSUInteger maximumFramesToRender;
@property (nonatomic, readonly) double configuredSampleRate;
@property (nonatomic, readonly, getter=isLoaded) BOOL loaded;

- (nullable instancetype)initWithBundlePath:(NSString *)bundlePath
                                displayName:(NSString *)displayName
                                      error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(init(bundlePath:displayName:));

- (BOOL)configureWithInputChannels:(NSUInteger)inputChannels
                    outputChannels:(NSUInteger)outputChannels
                        sampleRate:(double)sampleRate
             maximumFramesToRender:(NSUInteger)maximumFrames
                             error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(configure(withInputChannels:outputChannels:sampleRate:maximumFramesToRender:));

- (BOOL)processInterleavedInPlace:(float *)samples
                       frameCount:(NSUInteger)frameCount
                     hostChannels:(NSUInteger)hostChannels
                            error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(processInterleaved(inPlace:frameCount:hostChannels:));

- (NSArray<NSDictionary *> *)copyParameterSnapshots;
- (BOOL)setParameterWithID:(uint64_t)parameterID normalizedValue:(float)value NS_SWIFT_NAME(setParameter(withID:normalizedValue:));
- (float)normalizedValueForParameterID:(uint64_t)parameterID fallback:(float)fallback NS_SWIFT_NAME(normalizedValue(forParameterID:fallback:));
- (NSString *)probeSummary;

#if TARGET_OS_OSX
- (NSViewController * _Nullable)requestViewControllerWithError:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(requestViewController());
#endif

@end

NS_ASSUME_NONNULL_END
