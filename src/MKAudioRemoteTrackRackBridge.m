#import "MKAudioRemoteTrackRackBridge.h"
#import "MKAudioOutput.h"

@protocol MKAudioRemoteTrackRackExports <NSObject>
- (void)setPreviewGain:(float)gain enabled:(BOOL)enabled;
- (void)updateAudioUnitChain:(NSArray *)stages sampleRate:(NSUInteger)sampleRate;
- (void)setSendSourceKeys:(NSArray *)sourceKeys;
- (void)setHostBufferFrames:(NSUInteger)frames;
- (void)updateProcessingSampleRate:(NSUInteger)sampleRate;
- (NSDictionary *)currentStatus;
- (void)processSamples:(float *)samples frameCount:(NSUInteger)frameCount channels:(NSUInteger)channels sampleRate:(NSUInteger)sampleRate;
- (void)setSidechainProvider:(id)provider;
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

- (void)setSendSourceKeys:(NSArray *)sourceKeys {
    [_rack setSendSourceKeys:sourceKeys];
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

- (void)setSidechainAudioOutput:(MKAudioOutput *)output {
    _sidechainAudioOutput = output;
    if (output == nil) {
        [_rack setSidechainProvider:nil];
        return;
    }
    // The block captures the raw output pointer (no retain in MRC audio path)
    id provider = [^NSDictionary *(NSString *key) {
        NSUInteger frameCount = 0, channels = 0;
        const float *buf = [output sidechainBufferForSourceKey:key frameCount:&frameCount channels:&channels];
        if (buf == NULL) return nil;
        return [NSDictionary dictionaryWithObjectsAndKeys:
            [NSValue valueWithPointer:buf], @"ptr",
            [NSNumber numberWithUnsignedInteger:frameCount], @"frames",
            [NSNumber numberWithUnsignedInteger:channels], @"channels",
            nil];
    } copy];
    [_rack setSidechainProvider:provider];
    [provider release];
}

@end

static int _remoteTrackRackConsecutiveFailures = 0;
static BOOL _remoteTrackRackCleanupScheduled = NO;

void MKAudioRemoteTrackRackBridgeProcess(float *samples,
                                         NSUInteger frameCount,
                                         NSUInteger channels,
                                         NSUInteger sampleRate,
                                         void *context) {
    MKAudioRemoteTrackRackBridge *bridge = (MKAudioRemoteTrackRackBridge *)context;
    if (bridge == nil || samples == NULL || frameCount == 0 || channels == 0) {
        return;
    }
    if (_remoteTrackRackCleanupScheduled) {
        return;
    }
    @try {
        [bridge processSamples:samples frameCount:frameCount channels:channels sampleRate:sampleRate];
        _remoteTrackRackConsecutiveFailures = 0;
    } @catch (NSException *exception) {
        _remoteTrackRackConsecutiveFailures++;
        NSLog(@"MKAudioRemoteTrackRackBridge: Exception in processSamples (%d): %@ - %@",
              _remoteTrackRackConsecutiveFailures, exception.name, exception.reason);
        if (_remoteTrackRackConsecutiveFailures >= 3 && !_remoteTrackRackCleanupScheduled) {
            NSLog(@"MKAudioRemoteTrackRackBridge: Too many consecutive failures, scheduling plugin chain cleanup");
            _remoteTrackRackCleanupScheduled = YES;
            dispatch_async(dispatch_get_main_queue(), ^{
                [bridge updateAudioUnitChain:nil sampleRate:sampleRate];
                _remoteTrackRackConsecutiveFailures = 0;
                _remoteTrackRackCleanupScheduled = NO;
            });
        }
    }
}
