#ifndef MK_AUDIO_PERF_STATS_H
#define MK_AUDIO_PERF_STATS_H

#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <mach/mach_time.h>

#define MK_AUDIO_PERF_SAMPLE_MASK 0x7ULL
#define MK_AUDIO_PERF_HISTOGRAM_BINS 32

typedef struct {
    uint64_t callbackCount;
    uint64_t sampledCount;
    uint64_t totalNs;
    uint64_t maxNs;
    uint64_t histogram[MK_AUDIO_PERF_HISTOGRAM_BINS];
} MKAudioPerfStats;

static inline void MKAudioPerfReset(MKAudioPerfStats *stats) {
    memset(stats, 0, sizeof(*stats));
}

static inline bool MKAudioPerfShouldSample(MKAudioPerfStats *stats) {
    stats->callbackCount += 1;
    return (stats->callbackCount & MK_AUDIO_PERF_SAMPLE_MASK) == 0;
}

static inline uint64_t MKAudioPerfNowTicks(void) {
    return mach_continuous_time();
}

static inline uint64_t MKAudioPerfTicksToNs(uint64_t ticks) {
    static mach_timebase_info_data_t timebase = {0, 0};
    if (timebase.denom == 0) {
        (void) mach_timebase_info(&timebase);
    }
    return (ticks * timebase.numer) / timebase.denom;
}

static inline uint32_t MKAudioPerfBucketForNs(uint64_t ns) {
    uint64_t us = ns / 1000ULL;
    uint64_t bound = 1;
    uint32_t bucket = 0;

    while ((bucket + 1) < MK_AUDIO_PERF_HISTOGRAM_BINS && us > bound) {
        bound <<= 1;
        bucket += 1;
    }
    return bucket;
}

static inline void MKAudioPerfRecordTicks(MKAudioPerfStats *stats, uint64_t elapsedTicks) {
    uint64_t elapsedNs = MKAudioPerfTicksToNs(elapsedTicks);
    uint32_t bucket = MKAudioPerfBucketForNs(elapsedNs);

    stats->sampledCount += 1;
    stats->totalNs += elapsedNs;
    if (elapsedNs > stats->maxNs) {
        stats->maxNs = elapsedNs;
    }
    stats->histogram[bucket] += 1;
}

static inline uint64_t MKAudioPerfPercentileUs(const MKAudioPerfStats *stats, uint64_t numer, uint64_t denom) {
    if (stats->sampledCount == 0 || denom == 0) {
        return 0;
    }

    uint64_t target = (stats->sampledCount * numer + (denom - 1)) / denom;
    if (target == 0) {
        target = 1;
    }

    uint64_t cumulative = 0;
    uint64_t upperBoundUs = 1;
    for (uint32_t i = 0; i < MK_AUDIO_PERF_HISTOGRAM_BINS; i++) {
        cumulative += stats->histogram[i];
        if (cumulative >= target) {
            return upperBoundUs;
        }
        upperBoundUs <<= 1;
    }

    return upperBoundUs;
}

static inline uint64_t MKAudioPerfAverageUs(const MKAudioPerfStats *stats) {
    if (stats->sampledCount == 0) {
        return 0;
    }
    return (stats->totalNs / stats->sampledCount) / 1000ULL;
}

static inline uint64_t MKAudioPerfMaxUs(const MKAudioPerfStats *stats) {
    return stats->maxNs / 1000ULL;
}

#endif