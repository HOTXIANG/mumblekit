#ifndef MKAudioMacRecovery_h
#define MKAudioMacRecovery_h

#include <stdbool.h>
#include <stdint.h>

// Only the effective input/output configuration matters. Device-list membership
// and DeviceHasChanged notifications do not establish a route change.
typedef struct {
    uint32_t deviceID;
    uint32_t alive;
    uint32_t channels;
    double sampleRate;
} MKAudioMacDeviceState;

typedef struct {
    MKAudioMacDeviceState input;
    MKAudioMacDeviceState output;
} MKAudioMacRouteState;

static inline bool MKAudioMacDeviceEqual(MKAudioMacDeviceState a, MKAudioMacDeviceState b) {
    return a.deviceID == b.deviceID && a.alive == b.alive &&
        a.channels == b.channels && a.sampleRate == b.sampleRate;
}

static inline bool MKAudioMacRouteEqual(MKAudioMacRouteState a, MKAudioMacRouteState b) {
    return MKAudioMacDeviceEqual(a.input, b.input) && MKAudioMacDeviceEqual(a.output, b.output);
}

static inline MKAudioMacRouteState MKAudioMacRouteAfterStart(MKAudioMacRouteState setup,
                                                            MKAudioMacRouteState current) {
    // A real default-device switch during setup must still be reconciled. In
    // particular, HAL may already be bound to the previous device.
    if (setup.input.deviceID != current.input.deviceID || setup.output.deviceID != current.output.deviceID) return setup;
    return current;
}

static inline bool MKAudioMacRouteNeedsRestart(MKAudioMacRouteState configured,
                                              MKAudioMacRouteState current,
                                              bool usingVPIO, bool callbacksFresh) {
    if (MKAudioMacRouteEqual(configured, current)) return false;
    if (configured.input.deviceID != current.input.deviceID ||
        configured.output.deviceID != current.output.deviceID ||
        configured.input.alive != current.input.alive ||
        configured.output.alive != current.output.alive) return true;
    // VPIO manages hardware conversion. With the same live devices and working
    // client callbacks, its asynchronous format changes are not a failure.
    if (usingVPIO && callbacksFresh && current.input.alive && current.output.alive) return false;
    return true;
}
#endif
