#import "MKVST3PluginHost.h"

#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#endif

#import <CoreFoundation/CoreFoundation.h>

#include "../3rdparty/vst3sdk/pluginterfaces/base/funknownimpl.h"
#include "../3rdparty/vst3sdk/pluginterfaces/base/ipersistent.h"
#include "../3rdparty/vst3sdk/pluginterfaces/base/ibstream.h"
#include "../3rdparty/vst3sdk/pluginterfaces/base/ipluginbase.h"
#include "../3rdparty/vst3sdk/pluginterfaces/gui/iplugview.h"
#include "../3rdparty/vst3sdk/pluginterfaces/vst/ivstaudioprocessor.h"
#include "../3rdparty/vst3sdk/pluginterfaces/vst/ivstcomponent.h"
#include "../3rdparty/vst3sdk/pluginterfaces/vst/ivsteditcontroller.h"
#include "../3rdparty/vst3sdk/pluginterfaces/vst/ivsthostapplication.h"
#include "../3rdparty/vst3sdk/pluginterfaces/vst/ivstparameterchanges.h"
#include "../3rdparty/vst3sdk/pluginterfaces/vst/vstspeaker.h"
#include "../3rdparty/vst3sdk/source/common/memorystream.h"
#include "../3rdparty/vst3sdk/source/vst/hosting/parameterchanges.h"

#include "../3rdparty/vst3sdk/pluginterfaces/base/funknown.cpp"
#include "../3rdparty/vst3sdk/pluginterfaces/base/coreiids.cpp"
#include "../3rdparty/vst3sdk/source/vst/vstinitiids.cpp"
#include "../3rdparty/vst3sdk/source/common/commoniids.cpp"
#include "../3rdparty/vst3sdk/source/common/memorystream.cpp"
#include "../3rdparty/vst3sdk/source/vst/hosting/parameterchanges.cpp"

#include <algorithm>
#include <map>
#include <memory>
#include <string>
#include <vector>

using namespace Steinberg;
using namespace Steinberg::Vst;

static NSString *const MKVST3PluginHostErrorDomain = @"MKVST3PluginHost";

#if TARGET_OS_OSX
// Custom NSView that holds the IPlugView and notifies it on resize
@interface MKVST3PlugInView : NSView {
    IPlugView *_plugView;
}
- (void)setPlugView:(IPlugView *)plugView;
- (IPlugView *)plugView;
@end

@implementation MKVST3PlugInView
- (void)setPlugView:(IPlugView *)plugView {
    _plugView = plugView;
}
- (IPlugView *)plugView {
    return _plugView;
}
- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    if (_plugView) {
        ViewRect rect = {};
        rect.left = 0;
        rect.top = 0;
        rect.right = static_cast<int32>(newSize.width);
        rect.bottom = static_cast<int32>(newSize.height);
        _plugView->onSize(&rect);
    }
}
- (void)dealloc {
    if (_plugView) {
        _plugView->release();
        _plugView = nullptr;
    }
}
@end
#endif

namespace {

static NSString *StringFromCString(const char *value) {
    if (value == nullptr || value[0] == '\0') {
        return @"";
    }
    return [NSString stringWithUTF8String:value] ?: @"";
}

static NSString *StringFromTCharBuffer(const TChar *value, size_t capacity) {
    if (value == nullptr || capacity == 0) {
        return @"";
    }
    size_t actualLength = 0;
    while (actualLength < capacity && value[actualLength] != 0) {
        actualLength++;
    }
    if (actualLength == 0) {
        return @"";
    }
    NSData *data = [NSData dataWithBytes:value length:actualLength * sizeof(TChar)];
    NSString *decoded = [[NSString alloc] initWithData:data encoding:NSUTF16LittleEndianStringEncoding];
    return decoded ?: @"";
}

static NSError *MakeError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:MKVST3PluginHostErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description ?: @"Unknown VST3 error"}];
}

template <typename T>
static T ClampValue(T value, T lowerBound, T upperBound) {
    return std::max(lowerBound, std::min(value, upperBound));
}

static SpeakerArrangement ArrangementForChannelCount(int32 channelCount) {
    switch (channelCount) {
        case 1: return SpeakerArr::kMono;
        case 2: return SpeakerArr::kStereo;
        case 3: return SpeakerArr::k30Cine;
        case 4: return SpeakerArr::k40Music;
        case 5: return SpeakerArr::k50;
        case 6: return SpeakerArr::k51;
        case 7: return SpeakerArr::k70Music;
        case 8: return SpeakerArr::k71Music;
        default: return channelCount <= 1 ? SpeakerArr::kMono : SpeakerArr::kStereo;
    }
}

struct LoadedBundle {
    CFBundleRef bundle {nullptr};
    bool (*bundleEntry)(CFBundleRef) {nullptr};
    bool (*bundleExit)() {nullptr};
    IPluginFactory *factory {nullptr};

    ~LoadedBundle() {
        if (factory) {
            factory->release();
            factory = nullptr;
        }
        if (bundle && bundleExit) {
            bundleExit();
        }
        if (bundle) {
            CFRelease(bundle);
            bundle = nullptr;
        }
    }
};

class HostAttributeList final : public IAttributeList {
public:
    HostAttributeList() = default;
    ~HostAttributeList() noexcept = default;

    tresult PLUGIN_API setInt(AttrID aid, int64 value) override {
        if (!aid) { return kInvalidArgument; }
        ints[aid] = value;
        return kResultTrue;
    }

    tresult PLUGIN_API getInt(AttrID aid, int64 &value) override {
        auto it = ints.find(aid ? aid : "");
        if (it == ints.end()) { return kResultFalse; }
        value = it->second;
        return kResultTrue;
    }

    tresult PLUGIN_API setFloat(AttrID aid, double value) override {
        if (!aid) { return kInvalidArgument; }
        doubles[aid] = value;
        return kResultTrue;
    }

    tresult PLUGIN_API getFloat(AttrID aid, double &value) override {
        auto it = doubles.find(aid ? aid : "");
        if (it == doubles.end()) { return kResultFalse; }
        value = it->second;
        return kResultTrue;
    }

    tresult PLUGIN_API setString(AttrID aid, const TChar *string) override {
        if (!aid || !string) { return kInvalidArgument; }
        strings[aid] = std::u16string(reinterpret_cast<const char16_t *>(string));
        return kResultTrue;
    }

    tresult PLUGIN_API getString(AttrID aid, TChar *string, uint32 sizeInBytes) override {
        auto it = strings.find(aid ? aid : "");
        if (it == strings.end() || !string || sizeInBytes < sizeof(TChar)) { return kResultFalse; }
        auto maxChars = static_cast<size_t>(sizeInBytes / sizeof(TChar));
        auto copyChars = std::min(maxChars - 1, it->second.size());
        memcpy(string, it->second.data(), copyChars * sizeof(TChar));
        string[copyChars] = 0;
        return kResultTrue;
    }

    tresult PLUGIN_API setBinary(AttrID aid, const void *data, uint32 sizeInBytes) override {
        if (!aid || (!data && sizeInBytes > 0)) { return kInvalidArgument; }
        binaries[aid] = std::vector<char>(reinterpret_cast<const char *>(data),
                                          reinterpret_cast<const char *>(data) + sizeInBytes);
        return kResultTrue;
    }

    tresult PLUGIN_API getBinary(AttrID aid, const void *&data, uint32 &sizeInBytes) override {
        auto it = binaries.find(aid ? aid : "");
        if (it == binaries.end()) { return kResultFalse; }
        data = it->second.data();
        sizeInBytes = static_cast<uint32>(it->second.size());
        return kResultTrue;
    }

    tresult PLUGIN_API queryInterface(const char *_iid, void **obj) override {
        QUERY_INTERFACE(_iid, obj, FUnknown::iid, IAttributeList)
        QUERY_INTERFACE(_iid, obj, IAttributeList::iid, IAttributeList)
        *obj = nullptr;
        return kNoInterface;
    }

    uint32 PLUGIN_API addRef() override { return ++refCount; }
    uint32 PLUGIN_API release() override {
        auto count = --refCount;
        if (count == 0) {
            delete this;
        }
        return count;
    }

private:
    std::atomic<uint32> refCount {1};
    std::map<std::string, int64> ints;
    std::map<std::string, double> doubles;
    std::map<std::string, std::u16string> strings;
    std::map<std::string, std::vector<char>> binaries;
};

class HostMessage final : public IMessage {
public:
    HostMessage() : attributeList(owned(new HostAttributeList())) {}
    ~HostMessage() noexcept = default;

    const char *PLUGIN_API getMessageID() override { return messageID.empty() ? nullptr : messageID.c_str(); }
    void PLUGIN_API setMessageID(const char *newMessageID) override {
        messageID = newMessageID ? newMessageID : "";
    }
    IAttributeList *PLUGIN_API getAttributes() override { return attributeList; }

    tresult PLUGIN_API queryInterface(const char *_iid, void **obj) override {
        QUERY_INTERFACE(_iid, obj, FUnknown::iid, IMessage)
        QUERY_INTERFACE(_iid, obj, IMessage::iid, IMessage)
        *obj = nullptr;
        return kNoInterface;
    }

    uint32 PLUGIN_API addRef() override { return ++refCount; }
    uint32 PLUGIN_API release() override {
        auto count = --refCount;
        if (count == 0) {
            delete this;
        }
        return count;
    }

private:
    std::atomic<uint32> refCount {1};
    std::string messageID;
    IPtr<IAttributeList> attributeList;
};

class HostApplication final : public IHostApplication {
public:
    HostApplication() = default;
    ~HostApplication() noexcept = default;

    tresult PLUGIN_API getName(String128 name) override {
        if (name == nullptr) { return kInvalidArgument; }
        NSString *hostName = @"Neomumble";
        NSUInteger length = MIN(hostName.length, static_cast<NSUInteger>(127));
        memset(name, 0, sizeof(TChar) * 128);
        [hostName getCharacters:reinterpret_cast<unichar *>(name) range:NSMakeRange(0, length)];
        return kResultTrue;
    }

    tresult PLUGIN_API createInstance(TUID cid, TUID iid, void **obj) override {
        if (!obj) { return kInvalidArgument; }
        *obj = nullptr;
        if (FUnknownPrivate::iidEqual(cid, IMessage::iid) && FUnknownPrivate::iidEqual(iid, IMessage::iid)) {
            *obj = static_cast<IMessage *>(new HostMessage());
            return kResultTrue;
        }
        if (FUnknownPrivate::iidEqual(cid, IAttributeList::iid) && FUnknownPrivate::iidEqual(iid, IAttributeList::iid)) {
            *obj = static_cast<IAttributeList *>(new HostAttributeList());
            return kResultTrue;
        }
        return kResultFalse;
    }

    tresult PLUGIN_API queryInterface(const char *_iid, void **obj) override {
        QUERY_INTERFACE(_iid, obj, FUnknown::iid, IHostApplication)
        QUERY_INTERFACE(_iid, obj, IHostApplication::iid, IHostApplication)
        *obj = nullptr;
        return kNoInterface;
    }

    uint32 PLUGIN_API addRef() override { return 1; }
    uint32 PLUGIN_API release() override { return 1; }
};

class MKVST3Owner;

class ComponentHandler final : public IComponentHandler,
                               public IComponentHandler2,
                               public IComponentHandlerSystemTime {
public:
    explicit ComponentHandler(MKVST3Owner *owner) : owner(owner) {}
    ~ComponentHandler() noexcept = default;

    tresult PLUGIN_API beginEdit(ParamID id) override;
    tresult PLUGIN_API performEdit(ParamID id, ParamValue valueNormalized) override;
    tresult PLUGIN_API endEdit(ParamID id) override;
    tresult PLUGIN_API restartComponent(int32 flags) override;
    tresult PLUGIN_API setDirty(TBool state) override;
    tresult PLUGIN_API requestOpenEditor(FIDString name) override;
    tresult PLUGIN_API startGroupEdit() override;
    tresult PLUGIN_API finishGroupEdit() override;
    tresult PLUGIN_API getSystemTime(int64 &systemTime) override;

    tresult PLUGIN_API queryInterface(const char *_iid, void **obj) override {
        QUERY_INTERFACE(_iid, obj, FUnknown::iid, IComponentHandler)
        QUERY_INTERFACE(_iid, obj, IComponentHandler::iid, IComponentHandler)
        QUERY_INTERFACE(_iid, obj, IComponentHandler2::iid, IComponentHandler2)
        QUERY_INTERFACE(_iid, obj, IComponentHandlerSystemTime::iid, IComponentHandlerSystemTime)
        *obj = nullptr;
        return kNoInterface;
    }

    uint32 PLUGIN_API addRef() override { return 1; }
    uint32 PLUGIN_API release() override { return 1; }

private:
    MKVST3Owner *owner;
};

class MKVST3Owner {
public:
    virtual void enqueueParameterChange(ParamID id, ParamValue value) = 0;
    virtual void setRestartFlags(int32 flags) = 0;
    virtual void markDirty(bool dirty) = 0;
    virtual ~MKVST3Owner() = default;
};

class OwnerBridge final : public MKVST3Owner {
public:
    explicit OwnerBridge(MKVST3PluginHost *host) : host(host) {}

    void enqueueParameterChange(ParamID id, ParamValue value) override;
    void setRestartFlags(int32 flags) override;
    void markDirty(bool dirty) override;

private:
    __unsafe_unretained MKVST3PluginHost *host;
};

tresult ComponentHandler::beginEdit(ParamID) { return kResultTrue; }
tresult ComponentHandler::performEdit(ParamID id, ParamValue valueNormalized) {
    if (owner) { owner->enqueueParameterChange(id, valueNormalized); }
    return kResultTrue;
}
tresult ComponentHandler::endEdit(ParamID) { return kResultTrue; }
tresult ComponentHandler::restartComponent(int32 flags) {
    if (owner) { owner->setRestartFlags(flags); }
    return kResultTrue;
}
tresult ComponentHandler::setDirty(TBool state) {
    if (owner) { owner->markDirty(state != 0); }
    return kResultTrue;
}
tresult ComponentHandler::requestOpenEditor(FIDString) { return kResultFalse; }
tresult ComponentHandler::startGroupEdit() { return kResultTrue; }
tresult ComponentHandler::finishGroupEdit() { return kResultTrue; }
tresult ComponentHandler::getSystemTime(int64 &systemTime) {
    systemTime = static_cast<int64>([[NSDate date] timeIntervalSince1970] * 1000000000.0);
    return kResultTrue;
}

#if TARGET_OS_OSX

class PlugFrame final : public U::ImplementsNonDestroyable<U::Directly<IPlugFrame>> {
public:
    explicit PlugFrame(NSView *hostView) : _hostView(hostView) {}

    tresult PLUGIN_API resizeView(IPlugView *view, ViewRect *newSize) override {
        if (!view || !newSize) {
            return kResultFalse;
        }
        CGFloat w = static_cast<CGFloat>(newSize->right - newSize->left);
        CGFloat h = static_cast<CGFloat>(newSize->bottom - newSize->top);
        if (w < 50 || h < 50) {
            return kResultFalse;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            NSView *hostView = _hostView;
            if (!hostView) { return; }
            NSWindow *window = hostView.window;
            if (!window) { return; }

            // Resize the host view to match plugin's requested size
            [hostView setFrameSize:NSMakeSize(w, h)];

            // Calculate the total content size (plugin + toolbar)
            // Toolbar height is approximately 49pt (picker + padding + divider)
            static const CGFloat kToolbarHeight = 49.0;
            CGFloat totalHeight = h + kToolbarHeight;

            // Resize the window content
            NSRect contentRect = NSMakeRect(0, 0, w, totalHeight);
            NSRect frame = [window frameRectForContentRect:contentRect];
            NSRect currentFrame = window.frame;

            // Keep the window's top-left corner stationary
            frame.origin.x = currentFrame.origin.x;
            frame.origin.y = currentFrame.origin.y + (currentFrame.size.height - frame.size.height);

            [window setFrame:frame display:YES animate:YES];

            // Lock window to plugin size
            window.minSize = frame.size;
            window.maxSize = frame.size;

            // Notify the plugin that the resize is complete
            view->onSize(newSize);
        });
        return kResultTrue;
    }

private:
    __weak NSView *_hostView;
};
#endif

} // namespace

@interface MKVST3PluginHost () {
    NSLock *_lock;
    std::unique_ptr<LoadedBundle> _bundle;
    std::unique_ptr<HostApplication> _hostApplication;
    std::unique_ptr<OwnerBridge> _ownerBridge;
    std::unique_ptr<ComponentHandler> _componentHandler;
    IPtr<IComponent> _component;
    IPtr<IAudioProcessor> _processor;
    IPtr<IEditController> _controller;
    std::unique_ptr<Steinberg::MemoryStream> _componentState;
    std::unique_ptr<ParameterChanges> _inputParameterChanges;
    std::map<ParamID, ParamValue> _pendingParameterChanges;
    std::vector<std::vector<Sample32>> _inputChannelBuffers;
    std::vector<std::vector<Sample32>> _outputChannelBuffers;
    std::vector<Sample32 *> _inputBufferPointers;
    std::vector<Sample32 *> _outputBufferPointers;
    ProcessData _processData;
    ProcessSetup _processSetup;
    NSUInteger _configuredInputChannels;
    NSUInteger _configuredOutputChannels;
    NSUInteger _maximumFramesToRender;
    double _configuredSampleRate;
    BOOL _loaded;
    BOOL _dirty;
    BOOL _controllerSharesComponent;
    int32 _restartFlags;
}
@end

@interface MKVST3PluginHost (OwnerCallbacks)
- (void)enqueueParameterChangeFromComponent:(uint32_t)parameterID value:(double)value;
- (void)setRestartFlagsFromComponent:(int32)flags;
- (void)markDirtyFromComponent:(BOOL)dirty;
@end

@implementation MKVST3PluginHost (OwnerCallbacks)

- (void)enqueueParameterChangeFromComponent:(uint32_t)parameterID value:(double)value {
    [_lock lock];
    _pendingParameterChanges[parameterID] = ClampValue(static_cast<ParamValue>(value),
                                                       static_cast<ParamValue>(0.0),
                                                       static_cast<ParamValue>(1.0));
    [_lock unlock];
}

- (void)setRestartFlagsFromComponent:(int32)flags {
    [_lock lock];
    _restartFlags = flags;
    [_lock unlock];
}

- (void)markDirtyFromComponent:(BOOL)dirty {
    [_lock lock];
    _dirty = dirty;
    [_lock unlock];
}

@end

namespace {

void OwnerBridge::enqueueParameterChange(ParamID id, ParamValue value) {
    [host enqueueParameterChangeFromComponent:id value:value];
}

void OwnerBridge::setRestartFlags(int32 flags) {
    [host setRestartFlagsFromComponent:flags];
}

void OwnerBridge::markDirty(bool dirty) {
    [host markDirtyFromComponent:dirty];
}

} // namespace

@implementation MKVST3PluginHost

- (instancetype)initWithBundlePath:(NSString *)bundlePath
                       displayName:(NSString *)displayName
                             error:(NSError * _Nullable __autoreleasing *)error {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    _bundlePath = [bundlePath copy];
    _displayName = [displayName copy];
    _lock = [[NSLock alloc] init];
    _configuredSampleRate = 48000.0;
    _maximumFramesToRender = 256;
    _hostApplication = std::make_unique<HostApplication>();
    _ownerBridge = std::make_unique<OwnerBridge>(self);
    _inputParameterChanges = std::make_unique<ParameterChanges>(128);
    memset(&_processData, 0, sizeof(_processData));
    memset(&_processSetup, 0, sizeof(_processSetup));

    NSError *loadError = nil;
    if (![self loadBundleAndCreatePlugin:&loadError]) {
        if (error) {
            *error = loadError;
        }
        return nil;
    }
    _loaded = YES;
    return self;
}

- (void)dealloc {
    [_lock lock];
    [self teardownProcessing];
    if (_controller) {
        if (!_controllerSharesComponent) {
            _controller->terminate();
        }
        _controller = nullptr;
    }
    if (_component) {
        _component->terminate();
        _component = nullptr;
    }
    _processor = nullptr;
    _componentHandler.reset();
    _ownerBridge.reset();
    _hostApplication.reset();
    _bundle.reset();
    [_lock unlock];
}

- (NSUInteger)configuredInputChannels { return _configuredInputChannels; }
- (NSUInteger)configuredOutputChannels { return _configuredOutputChannels; }
- (NSUInteger)maximumFramesToRender { return _maximumFramesToRender; }
- (double)configuredSampleRate { return _configuredSampleRate; }
- (BOOL)isLoaded { return _loaded; }

- (BOOL)configureWithInputChannels:(NSUInteger)inputChannels
                    outputChannels:(NSUInteger)outputChannels
                        sampleRate:(double)sampleRate
             maximumFramesToRender:(NSUInteger)maximumFrames
                             error:(NSError * _Nullable __autoreleasing *)error {
    NSLog(@"MKVST3: configure '%@' in=%lu out=%lu sr=%.0f maxFrames=%lu",
          _displayName, (unsigned long)inputChannels, (unsigned long)outputChannels, sampleRate, (unsigned long)maximumFrames);
    [_lock lock];
    NSError *innerError = nil;
    BOOL ok = [self configureLockedWithInputChannels:inputChannels
                                      outputChannels:outputChannels
                                          sampleRate:sampleRate
                               maximumFramesToRender:maximumFrames
                                               error:&innerError];
    [_lock unlock];
    if (!ok) {
        NSLog(@"MKVST3: configure FAILED: %@", innerError.localizedDescription ?: @"unknown");
        if (error) {
            *error = innerError;
        }
    } else {
        NSLog(@"MKVST3: configure OK for '%@'", _displayName);
    }
    return ok;
}

- (BOOL)processInterleavedInPlace:(float *)samples
                       frameCount:(NSUInteger)frameCount
                     hostChannels:(NSUInteger)hostChannels
                            error:(NSError * _Nullable __autoreleasing *)error {
    if (samples == NULL || frameCount == 0 || hostChannels == 0) {
        return YES;
    }

    [_lock lock];
    NSError *innerError = nil;
    BOOL ok = [self processLockedInterleavedInPlace:samples
                                         frameCount:frameCount
                                       hostChannels:hostChannels
                                              error:&innerError];
    [_lock unlock];
    if (!ok && error) {
        *error = innerError;
    }
    return ok;
}

- (NSArray<NSDictionary *> *)copyParameterSnapshots {
    [_lock lock];
    NSMutableArray<NSDictionary *> *snapshots = [NSMutableArray array];
    try {
        if (_controller) {
            int32 count = _controller->getParameterCount();
            NSLog(@"MKVST3: '%@' has %d parameters", _displayName, count);
            for (int32 index = 0; index < count; index++) {
                ParameterInfo info = {};
                if (_controller->getParameterInfo(index, info) != kResultTrue) {
                    continue;
                }
                NSString *name = StringFromTCharBuffer(info.title, 128);
                if (name.length == 0) {
                    name = [NSString stringWithFormat:@"Param %u", info.id];
                }
                float normalized = static_cast<float>(_controller->getParamNormalized(info.id));
                NSDictionary *snapshot = @{
                    @"id": @(static_cast<uint64_t>(info.id)),
                    @"name": name,
                    @"minValue": @0.0f,
                    @"maxValue": @1.0f,
                    @"value": @(normalized),
                    @"stepCount": @(info.stepCount),
                    @"flags": @(info.flags)
                };
                [snapshots addObject:snapshot];
            }
        }
    } catch (...) {
        // Swallow — return whatever snapshots we collected so far.
    }
    [_lock unlock];
    return [snapshots copy];
}

- (BOOL)setParameterWithID:(uint64_t)parameterID normalizedValue:(float)value {
    [_lock lock];
    BOOL ok = NO;
    if (_controller) {
        auto normalized = ClampValue(static_cast<ParamValue>(value), static_cast<ParamValue>(0.0), static_cast<ParamValue>(1.0));
        if (auto hostEditing = U::cast<IEditControllerHostEditing>(_controller)) {
            hostEditing->beginEditFromHost(static_cast<ParamID>(parameterID));
            _controller->setParamNormalized(static_cast<ParamID>(parameterID), normalized);
            hostEditing->endEditFromHost(static_cast<ParamID>(parameterID));
        } else {
            _controller->setParamNormalized(static_cast<ParamID>(parameterID), normalized);
        }
        _pendingParameterChanges[static_cast<ParamID>(parameterID)] = normalized;
        ok = YES;
    }
    [_lock unlock];
    return ok;
}

- (float)normalizedValueForParameterID:(uint64_t)parameterID fallback:(float)fallback {
    [_lock lock];
    float value = fallback;
    if (_controller) {
        value = static_cast<float>(_controller->getParamNormalized(static_cast<ParamID>(parameterID)));
    }
    [_lock unlock];
    return value;
}

- (NSString *)probeSummary {
    [_lock lock];
    NSString *summary = [NSString stringWithFormat:@"vst in=%luch out=%luch sr=%d max=%lu restart=%d",
                         (unsigned long)_configuredInputChannels,
                         (unsigned long)_configuredOutputChannels,
                         (int)_configuredSampleRate,
                         (unsigned long)_maximumFramesToRender,
                         _restartFlags];
    [_lock unlock];
    return summary;
}

#if TARGET_OS_OSX
- (NSViewController * _Nullable)requestViewControllerWithError:(NSError * _Nullable __autoreleasing *)error {
    [_lock lock];
    if (!_controller) {
        [_lock unlock];
        NSLog(@"MKVST3: requestViewController FAILED - no controller for '%@'", _displayName);
        if (error) {
            *error = MakeError(-32, @"VST3 controller is not available.");
        }
        return nil;
    }

    IPlugView *plugView = _controller->createView(ViewType::kEditor);
    [_lock unlock];

    if (!plugView) {
        NSLog(@"MKVST3: requestViewController FAILED - '%@' has no editor view", _displayName);
        if (error) {
            *error = MakeError(-33, @"VST3 plug-in does not provide an editor view.");
        }
        return nil;
    }

    if (plugView->isPlatformTypeSupported(kPlatformTypeNSView) != kResultTrue) {
        NSLog(@"MKVST3: requestViewController FAILED - '%@' editor doesn't support NSView", _displayName);
        plugView->release();
        if (error) {
            *error = MakeError(-34, @"VST3 plug-in editor does not support NSView.");
        }
        return nil;
    }

    ViewRect rect = {};
    if (plugView->getSize(&rect) != kResultTrue) {
        rect.left = 0; rect.top = 0;
        rect.right = 600; rect.bottom = 400;
    }
    CGFloat w = static_cast<CGFloat>(rect.right - rect.left);
    CGFloat h = static_cast<CGFloat>(rect.bottom - rect.top);
    if (w < 50) w = 600;
    if (h < 50) h = 400;

    MKVST3PlugInView *hostView = [[MKVST3PlugInView alloc] initWithFrame:NSMakeRect(0, 0, w, h)];
    hostView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [hostView setPlugView:plugView];  // Store plugView for resize notifications

    auto plugFrame = new PlugFrame(hostView);
    plugView->setFrame(plugFrame);

    if (plugView->attached((__bridge void *)hostView, kPlatformTypeNSView) != kResultTrue) {
        plugView->setFrame(nullptr);
        [hostView setPlugView:nil];  // Clear before release
        plugView->release();
        if (error) {
            *error = MakeError(-35, @"VST3 plug-in editor failed to attach to host view.");
        }
        return nil;
    }

    NSViewController *viewController = [[NSViewController alloc] init];
    viewController.view = hostView;
    viewController.preferredContentSize = NSMakeSize(w, h);  // Plugin's preferred size

    NSLog(@"MKVST3: Created editor view %.0fx%.0f for '%@'", w, h, _displayName);
    return viewController;
}
#endif

- (BOOL)loadBundleAndCreatePlugin:(NSError * _Nullable __autoreleasing *)error {
    NSLog(@"MKVST3: Loading VST3 bundle: %@", _bundlePath);
    auto bundle = std::make_unique<LoadedBundle>();
    CFURLRef url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault,
                                                 (CFStringRef)_bundlePath,
                                                 kCFURLPOSIXPathStyle,
                                                 true);
    if (url == nullptr) {
        NSLog(@"MKVST3: FAIL(-1) bundle URL creation failed for: %@", _bundlePath);
        if (error) {
            *error = MakeError(-1, @"Failed to create VST3 bundle URL.");
        }
        return NO;
    }

    bundle->bundle = CFBundleCreate(kCFAllocatorDefault, url);
    CFRelease(url);
    if (bundle->bundle == nullptr) {
        NSLog(@"MKVST3: FAIL(-2) CFBundleCreate failed for: %@", _bundlePath);
        if (error) {
            *error = MakeError(-2, @"Failed to create VST3 bundle.");
        }
        return NO;
    }

    NSLog(@"MKVST3: Loading executable for: %@", _bundlePath);
    CFErrorRef cfError = nullptr;
    if (!CFBundleLoadExecutableAndReturnError(bundle->bundle, &cfError)) {
        NSString *description = @"Failed to load VST3 executable.";
        if (cfError) {
            NSString *cfDesc = CFBridgingRelease(CFErrorCopyDescription(cfError));
            CFRelease(cfError);
            if ([cfDesc containsString:@"Team ID"] || [cfDesc containsString:@"code signature"]) {
                description = [NSString stringWithFormat:@"Code signing error loading %@: %@. "
                               "Ensure com.apple.security.cs.disable-library-validation entitlement is set.",
                               _bundlePath.lastPathComponent, cfDesc];
            } else {
                description = cfDesc;
            }
        }
        NSLog(@"MKVST3: FAIL(-3) %@", description);
        if (error) {
            *error = MakeError(-3, description);
        }
        return NO;
    }
    NSLog(@"MKVST3: Executable loaded successfully");

    CFStringRef bundleEntryName = CFStringCreateWithCString(kCFAllocatorDefault, "bundleEntry", kCFStringEncodingASCII);
    CFStringRef bundleExitName = CFStringCreateWithCString(kCFAllocatorDefault, "bundleExit", kCFStringEncodingASCII);
    CFStringRef factoryName = CFStringCreateWithCString(kCFAllocatorDefault, "GetPluginFactory", kCFStringEncodingASCII);

    bundle->bundleEntry = reinterpret_cast<bool (*)(CFBundleRef)>(CFBundleGetFunctionPointerForName(bundle->bundle, bundleEntryName));
    bundle->bundleExit = reinterpret_cast<bool (*)()>(CFBundleGetFunctionPointerForName(bundle->bundle, bundleExitName));
    auto getFactory = reinterpret_cast<IPluginFactory *(*)()>(CFBundleGetFunctionPointerForName(bundle->bundle, factoryName));

    CFRelease(bundleEntryName);
    CFRelease(bundleExitName);
    CFRelease(factoryName);

    NSLog(@"MKVST3: Executable loaded. bundleEntry=%p bundleExit=%p getFactory=%p",
          (void *)bundle->bundleEntry, (void *)bundle->bundleExit, (void *)getFactory);

    if (!bundle->bundleEntry || !bundle->bundleExit || !getFactory) {
        NSLog(@"MKVST3: FAIL(-4) missing entry points for: %@", _bundlePath);
        if (error) {
            *error = MakeError(-4, @"Bundle does not export required VST3 entry points.");
        }
        return NO;
    }

    // All subsequent calls invoke third-party plugin code that may throw C++
    // exceptions or ObjC exceptions (e.g. "file not found" from iZotope, etc.).
    // Catch them here so an unhealthy plug-in does not terminate the host.
    @try {
    try {

    NSLog(@"MKVST3: Calling bundleEntry...");
    if (!bundle->bundleEntry(bundle->bundle)) {
        NSLog(@"MKVST3: FAIL(-5) bundleEntry returned false for: %@", _bundlePath);
        if (error) {
            *error = MakeError(-5, @"VST3 bundleEntry failed.");
        }
        return NO;
    }

    NSLog(@"MKVST3: Calling GetPluginFactory...");
    bundle->factory = getFactory();
    if (bundle->factory == nullptr) {
        NSLog(@"MKVST3: FAIL(-6) GetPluginFactory returned null for: %@", _bundlePath);
        if (error) {
            *error = MakeError(-6, @"GetPluginFactory returned null.");
        }
        return NO;
    }
    _bundle = std::move(bundle);

    auto pluginFactory3 = FUnknownPtr<IPluginFactory3>(_bundle->factory);
    auto pluginFactory2 = FUnknownPtr<IPluginFactory2>(_bundle->factory);
    bool instantiated = false;

    int32 classCount = _bundle->factory->countClasses();
    NSLog(@"MKVST3: Factory has %d classes", classCount);
    for (int32 classIndex = 0; classIndex < classCount; classIndex++) {
        PClassInfoW classInfoW = {};
        PClassInfo2 classInfo2 = {};
        PClassInfo classInfo = {};
        std::string category;
        std::string subCategories;
        TUID classID = {};

        if (pluginFactory3 && pluginFactory3->getClassInfoUnicode(classIndex, &classInfoW) == kResultTrue) {
            category = classInfoW.category;
            subCategories = classInfoW.subCategories;
            memcpy(classID, classInfoW.cid, sizeof(TUID));
        } else if (pluginFactory2 && pluginFactory2->getClassInfo2(classIndex, &classInfo2) == kResultTrue) {
            category = classInfo2.category;
            subCategories = classInfo2.subCategories;
            memcpy(classID, classInfo2.cid, sizeof(TUID));
        } else if (_bundle->factory->getClassInfo(classIndex, &classInfo) == kResultTrue) {
            category = classInfo.category;
            memcpy(classID, classInfo.cid, sizeof(TUID));
        } else {
            continue;
        }

        NSLog(@"MKVST3: Class[%d] category='%s' subCategories='%s'", classIndex, category.c_str(), subCategories.c_str());
        if (category != kVstAudioEffectClass) {
            continue;
        }
        // Skip instruments (synths, samplers, etc.) - we only want effects
        if (subCategories.find("Instrument") == 0) {
            NSLog(@"MKVST3: Skipping instrument class at index %d", classIndex);
            continue;
        }

        NSLog(@"MKVST3: Found audio effect class at index %d, creating instance...", classIndex);
        IComponent *rawComponent = nullptr;
        if (_bundle->factory->createInstance(classID, IComponent::iid, reinterpret_cast<void **>(&rawComponent)) != kResultTrue || rawComponent == nullptr) {
            NSLog(@"MKVST3: createInstance failed for class %d", classIndex);
            continue;
        }
        _component = owned(rawComponent);

        NSLog(@"MKVST3: Initializing component...");
        if (_component->initialize(_hostApplication.get()) != kResultOk) {
            NSLog(@"MKVST3: component->initialize failed");
            _component = nullptr;
            continue;
        }

        TUID controllerClassID = {};
        IEditController *rawController = nullptr;
        bool controllerNeedsInitialize = false;
        if (_component->queryInterface(IEditController::iid, reinterpret_cast<void **>(&rawController)) == kResultTrue && rawController != nullptr) {
            _controller = owned(rawController);
            _controllerSharesComponent = YES;
        } else if (_component->getControllerClassId(controllerClassID) == kResultTrue) {
            if (_bundle->factory->createInstance(controllerClassID, IEditController::iid, reinterpret_cast<void **>(&rawController)) == kResultTrue && rawController != nullptr) {
                _controller = owned(rawController);
                controllerNeedsInitialize = true;
                _controllerSharesComponent = NO;
            }
        }

        NSLog(@"MKVST3: Controller acquired: %s (shared=%d, needsInit=%d)", _controller ? "yes" : "no", (int)_controllerSharesComponent, controllerNeedsInitialize);
        if (!_controller || (controllerNeedsInitialize && _controller->initialize(_hostApplication.get()) != kResultOk)) {
            if (_controller) {
                if (!_controllerSharesComponent) {
                    _controller->terminate();
                }
                _controller = nullptr;
            }
            _component->terminate();
            _component = nullptr;
            continue;
        }

        _processor = U::cast<IAudioProcessor>(_component);
        if (!_processor) {
            if (!_controllerSharesComponent) {
                _controller->terminate();
            }
            _controller = nullptr;
            _component->terminate();
            _component = nullptr;
            continue;
        }

        _componentHandler = std::make_unique<ComponentHandler>(_ownerBridge.get());
        _controller->setComponentHandler(_componentHandler.get());
        [self syncControllerStateFromComponentLocked];
        instantiated = true;
        NSLog(@"MKVST3: Successfully instantiated '%@'", _displayName);
        break;
    }

    if (!instantiated) {
        NSLog(@"MKVST3: FAIL(-7) no audio effect class found in %@ (%d classes scanned)", _bundlePath, classCount);
        if (error) {
            *error = MakeError(-7, @"No VST3 audio effect class found in bundle.");
        }
        return NO;
    }
    return YES;

    } catch (const std::exception& e) {
        NSLog(@"MKVST3: FAIL(-8) C++ exception: %s", e.what());
        if (error) {
            *error = MakeError(-8, [NSString stringWithFormat:@"VST3 plug-in threw C++ exception: %s", e.what()]);
        }
        _bundle = nullptr;
        _component = nullptr;
        _controller = nullptr;
        _processor = nullptr;
        return NO;
    } catch (...) {
        NSLog(@"MKVST3: FAIL(-8) unknown C++ exception");
        if (error) {
            *error = MakeError(-8, @"VST3 plug-in threw an unknown C++ exception during loading.");
        }
        _bundle = nullptr;
        _component = nullptr;
        _controller = nullptr;
        _processor = nullptr;
        return NO;
    }
    } @catch (NSException *exception) {
        NSLog(@"MKVST3: FAIL(-9) ObjC exception: %@", exception.reason ?: exception.name);
        if (error) {
            *error = MakeError(-9, [NSString stringWithFormat:@"VST3 plug-in threw ObjC exception: %@", exception.reason ?: exception.name]);
        }
        _bundle = nullptr;
        _component = nullptr;
        _controller = nullptr;
        _processor = nullptr;
        return NO;
    }
}

- (void)teardownProcessing {
    if (_processor) {
        _processor->setProcessing(false);
    }
    if (_component) {
        _component->setActive(false);
    }
    if (_processData.inputs) {
        delete [] _processData.inputs;
        _processData.inputs = nullptr;
    }
    if (_processData.outputs) {
        delete [] _processData.outputs;
        _processData.outputs = nullptr;
    }
    _inputChannelBuffers.clear();
    _outputChannelBuffers.clear();
    _inputBufferPointers.clear();
    _outputBufferPointers.clear();
    memset(&_processData, 0, sizeof(_processData));
    memset(&_processSetup, 0, sizeof(_processSetup));
}

- (BOOL)configureLockedWithInputChannels:(NSUInteger)inputChannels
                          outputChannels:(NSUInteger)outputChannels
                              sampleRate:(double)sampleRate
                   maximumFramesToRender:(NSUInteger)maximumFrames
                                   error:(NSError * _Nullable __autoreleasing *)error {
    if (!_component || !_processor || !_controller) {
        if (error) {
            *error = MakeError(-10, @"VST3 plug-in is not initialized.");
        }
        return NO;
    }

    inputChannels = MAX(1, inputChannels);
    outputChannels = MAX(1, outputChannels);
    maximumFrames = MAX((NSUInteger)64, maximumFrames);
    sampleRate = sampleRate > 0.0 ? sampleRate : 48000.0;

    try {

    [self teardownProcessing];

    int32 inputBusCount = _component->getBusCount(kAudio, kInput);
    int32 outputBusCount = _component->getBusCount(kAudio, kOutput);
    NSLog(@"MKVST3: '%@' has %d input buses, %d output buses", _displayName, inputBusCount, outputBusCount);
    if (inputBusCount <= 0 || outputBusCount <= 0) {
        if (error) {
            *error = MakeError(-11, @"VST3 effect does not expose audio input/output busses.");
        }
        return NO;
    }

    // Query the plugin's preferred bus arrangements
    SpeakerArrangement preferredInput = {};
    SpeakerArrangement preferredOutput = {};
    if (_processor->getBusArrangement(kInput, 0, preferredInput) == kResultTrue &&
        _processor->getBusArrangement(kOutput, 0, preferredOutput) == kResultTrue) {
        NSLog(@"MKVST3: '%@' preferred: in=%d channels, out=%d channels",
              _displayName,
              (int)SpeakerArr::getChannelCount(preferredInput),
              (int)SpeakerArr::getChannelCount(preferredOutput));
    }

    for (int32 busIndex = 0; busIndex < inputBusCount; busIndex++) {
        _component->activateBus(kAudio, kInput, busIndex, busIndex == 0);
    }
    for (int32 busIndex = 0; busIndex < outputBusCount; busIndex++) {
        _component->activateBus(kAudio, kOutput, busIndex, busIndex == 0);
    }

    SpeakerArrangement inputArrangement = ArrangementForChannelCount(static_cast<int32>(inputChannels));
    SpeakerArrangement outputArrangement = ArrangementForChannelCount(static_cast<int32>(outputChannels));

    // Try requested arrangement first, then plugin's preferred, then common fallbacks.
    struct ArrangementPair { SpeakerArrangement in_; SpeakerArrangement out_; };
    ArrangementPair attempts[] = {
        { inputArrangement, outputArrangement },                          // requested
        { preferredInput, preferredOutput },                              // plugin's preferred
        { SpeakerArr::kStereo, SpeakerArr::kStereo },                    // stereo→stereo
        { SpeakerArr::kMono, SpeakerArr::kStereo },                      // mono→stereo
        { SpeakerArr::kMono, SpeakerArr::kMono },                        // mono→mono
    };
    bool arrangementAccepted = false;
    for (const auto &attempt : attempts) {
        // Skip invalid arrangements (0 channels)
        if (SpeakerArr::getChannelCount(attempt.in_) <= 0 ||
            SpeakerArr::getChannelCount(attempt.out_) <= 0) {
            continue;
        }
        if (_processor->setBusArrangements(const_cast<SpeakerArrangement *>(&attempt.in_), 1,
                                           const_cast<SpeakerArrangement *>(&attempt.out_), 1) == kResultTrue) {
            inputArrangement = attempt.in_;
            outputArrangement = attempt.out_;
            arrangementAccepted = true;
            NSLog(@"MKVST3: bus arrangement accepted: in=%d out=%d",
                  (int)SpeakerArr::getChannelCount(inputArrangement),
                  (int)SpeakerArr::getChannelCount(outputArrangement));
            break;
        }
    }

    // If no explicit arrangement worked, try using the plugin's default (no setBusArrangements call)
    if (!arrangementAccepted) {
        NSLog(@"MKVST3: Trying default bus configuration (no setBusArrangements)...");
        // Query what the plugin actually has configured
        if (_processor->getBusArrangement(kInput, 0, inputArrangement) == kResultTrue &&
            _processor->getBusArrangement(kOutput, 0, outputArrangement) == kResultTrue) {
            NSLog(@"MKVST3: Using plugin default: in=%d out=%d",
                  (int)SpeakerArr::getChannelCount(inputArrangement),
                  (int)SpeakerArr::getChannelCount(outputArrangement));
            arrangementAccepted = true;
        }
    }

    if (!arrangementAccepted) {
        if (error) {
            *error = MakeError(-12, @"VST3 plug-in rejected all bus arrangements (mono, stereo).");
        }
        return NO;
    }

    _configuredInputChannels = static_cast<NSUInteger>(SpeakerArr::getChannelCount(inputArrangement));
    _configuredOutputChannels = static_cast<NSUInteger>(SpeakerArr::getChannelCount(outputArrangement));
    _configuredSampleRate = sampleRate;
    _maximumFramesToRender = maximumFrames;

    _processSetup.processMode = kRealtime;
    _processSetup.symbolicSampleSize = kSample32;
    _processSetup.maxSamplesPerBlock = static_cast<int32>(maximumFrames);
    _processSetup.sampleRate = sampleRate;
    if (_processor->setupProcessing(_processSetup) != kResultOk) {
        if (error) {
            *error = MakeError(-13, @"VST3 setupProcessing failed.");
        }
        return NO;
    }

    _inputChannelBuffers.assign(_configuredInputChannels, std::vector<Sample32>(maximumFrames, 0.0f));
    _outputChannelBuffers.assign(_configuredOutputChannels, std::vector<Sample32>(maximumFrames, 0.0f));
    _inputBufferPointers.resize(_configuredInputChannels);
    _outputBufferPointers.resize(_configuredOutputChannels);
    for (NSUInteger channel = 0; channel < _configuredInputChannels; channel++) {
        _inputBufferPointers[channel] = _inputChannelBuffers[channel].data();
    }
    for (NSUInteger channel = 0; channel < _configuredOutputChannels; channel++) {
        _outputBufferPointers[channel] = _outputChannelBuffers[channel].data();
    }

    _processData.processMode = kRealtime;
    _processData.symbolicSampleSize = kSample32;
    _processData.numInputs = 1;
    _processData.numOutputs = 1;
    _processData.inputs = new AudioBusBuffers[1];
    _processData.outputs = new AudioBusBuffers[1];
    _processData.inputs[0].numChannels = static_cast<int32>(_configuredInputChannels);
    _processData.inputs[0].channelBuffers32 = _inputBufferPointers.data();
    _processData.outputs[0].numChannels = static_cast<int32>(_configuredOutputChannels);
    _processData.outputs[0].channelBuffers32 = _outputBufferPointers.data();
    _processData.inputParameterChanges = _inputParameterChanges.get();

    if (_component->setActive(true) != kResultOk) {
        if (error) {
            *error = MakeError(-14, @"VST3 setActive(true) failed.");
        }
        return NO;
    }
    if (_processor->setProcessing(true) != kResultOk) {
        if (error) {
            *error = MakeError(-15, @"VST3 setProcessing(true) failed.");
        }
        return NO;
    }
    return YES;

    } catch (const std::exception& e) {
        if (error) {
            *error = MakeError(-19, [NSString stringWithFormat:@"VST3 plug-in threw C++ exception during configure: %s", e.what()]);
        }
        return NO;
    } catch (...) {
        if (error) {
            *error = MakeError(-19, @"VST3 plug-in threw an unknown C++ exception during configure.");
        }
        return NO;
    }
}

- (void)syncControllerStateFromComponentLocked {
    if (!_component || !_controller) {
        return;
    }
    auto stream = std::make_unique<Steinberg::MemoryStream>();
    if (_component->getState(stream.get()) == kResultOk) {
        stream->seek(0, IBStream::kIBSeekSet, nullptr);
        _controller->setComponentState(stream.get());
        _componentState = std::move(stream);
    }
}

- (void)flushPendingParameterChangesLocked {
    _inputParameterChanges->clearQueue();
    if (_pendingParameterChanges.empty()) {
        return;
    }
    int32 queueIndex = 0;
    for (const auto &entry : _pendingParameterChanges) {
        if (auto *queue = _inputParameterChanges->addParameterData(entry.first, queueIndex)) {
            int32 pointIndex = 0;
            queue->addPoint(0, entry.second, pointIndex);
        }
    }
    _pendingParameterChanges.clear();
}

- (float)remappedInputSample:(const float *)samples
                       frame:(NSUInteger)frame
                hostChannels:(NSUInteger)hostChannels
               targetChannel:(NSUInteger)targetChannel
              targetChannels:(NSUInteger)targetChannels {
    if (hostChannels <= 1) {
        return samples[frame * hostChannels];
    }
    if (targetChannels == 1) {
        float sum = 0.0f;
        for (NSUInteger channel = 0; channel < hostChannels; channel++) {
            sum += samples[(frame * hostChannels) + channel];
        }
        return sum / static_cast<float>(hostChannels);
    }
    NSUInteger sourceChannel = MIN(targetChannel, hostChannels - 1);
    return samples[(frame * hostChannels) + sourceChannel];
}

- (float)remappedOutputSampleForFrame:(NSUInteger)frame
                          hostChannel:(NSUInteger)hostChannel
                         hostChannels:(NSUInteger)hostChannels {
    if (_configuredOutputChannels <= 1) {
        return _outputChannelBuffers[0][frame];
    }
    if (hostChannels == 1) {
        float sum = 0.0f;
        for (NSUInteger channel = 0; channel < _configuredOutputChannels; channel++) {
            sum += _outputChannelBuffers[channel][frame];
        }
        return sum / static_cast<float>(_configuredOutputChannels);
    }
    NSUInteger sourceChannel = MIN(hostChannel, _configuredOutputChannels - 1);
    return _outputChannelBuffers[sourceChannel][frame];
}

- (BOOL)processLockedInterleavedInPlace:(float *)samples
                             frameCount:(NSUInteger)frameCount
                           hostChannels:(NSUInteger)hostChannels
                                  error:(NSError * _Nullable __autoreleasing *)error {
    if (!_processor || !_component || _configuredInputChannels == 0 || _configuredOutputChannels == 0) {
        if (error) {
            *error = MakeError(-16, @"VST3 plug-in is not configured.");
        }
        return NO;
    }
    if (frameCount > _maximumFramesToRender) {
        if (error) {
            *error = MakeError(-17, @"Requested frame count exceeds VST3 maximum block size.");
        }
        return NO;
    }

    for (NSUInteger channel = 0; channel < _configuredOutputChannels; channel++) {
        std::fill(_outputChannelBuffers[channel].begin(),
                  _outputChannelBuffers[channel].begin() + frameCount,
                  0.0f);
    }
    for (NSUInteger channel = 0; channel < _configuredInputChannels; channel++) {
        for (NSUInteger frame = 0; frame < frameCount; frame++) {
            _inputChannelBuffers[channel][frame] = [self remappedInputSample:samples
                                                                       frame:frame
                                                                hostChannels:hostChannels
                                                               targetChannel:channel
                                                              targetChannels:_configuredInputChannels];
        }
    }

    [self flushPendingParameterChangesLocked];
    _processData.numSamples = static_cast<int32>(frameCount);
    _processData.inputs[0].silenceFlags = 0;
    _processData.outputs[0].silenceFlags = 0;

    try {
        if (_processor->process(_processData) != kResultOk) {
            if (error) {
                *error = MakeError(-18, @"VST3 process() failed.");
            }
            return NO;
        }
    } catch (...) {
        if (error) {
            *error = MakeError(-20, @"VST3 plug-in threw C++ exception during process().");
        }
        return NO;
    }

    for (NSUInteger frame = 0; frame < frameCount; frame++) {
        for (NSUInteger channel = 0; channel < hostChannels; channel++) {
            samples[(frame * hostChannels) + channel] = [self remappedOutputSampleForFrame:frame
                                                                                hostChannel:channel
                                                                               hostChannels:hostChannels];
        }
    }
    return YES;
}

@end
