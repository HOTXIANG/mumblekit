#ifndef MKAudioCallbackHealth_h
#define MKAudioCallbackHealth_h

#include <stdatomic.h>
#include <stdint.h>
#include <stdbool.h>
#include <time.h>

typedef struct {
    atomic_uint_fast64_t inputCompleted;
    atomic_uint_fast64_t outputCompleted;
} MKAudioCallbackHealth;

static inline uint64_t MKAudioHealthNow(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

// A successful callback includes DSP completion. Silence is valid audio activity.
static inline void MKAudioHealthRecord(atomic_uint_fast64_t *completed) {
    atomic_store_explicit(completed, MKAudioHealthNow(), memory_order_relaxed);
}

static inline bool MKAudioHealthExpired(uint64_t now, uint64_t started, uint64_t completed) {
    uint64_t reference = completed ? completed : started;
    return now >= reference && now - reference >= 5ULL * 1000000000ULL;
}
#endif
