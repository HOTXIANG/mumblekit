// Shared AudioUnit buffer guards. These helpers perform no allocation or logging.
#ifndef MKAudioDeviceIO_h
#define MKAudioDeviceIO_h

#include <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>
#include <string.h>

static inline void MKAudioDeviceSilence(AudioBufferList *buffers, AudioUnitRenderActionFlags *flags) {
    if (buffers != NULL) {
        for (UInt32 index = 0; index < buffers->mNumberBuffers; ++index) {
            AudioBuffer *buffer = &buffers->mBuffers[index];
            if (buffer->mData != NULL) memset(buffer->mData, 0, buffer->mDataByteSize);
        }
    }
    if (flags != NULL) *flags |= kAudioUnitRenderAction_OutputIsSilence;
}

static inline bool MKAudioDeviceCanRender(AudioBufferList *buffers, UInt32 frames, UInt32 channels) {
    if (buffers == NULL || buffers->mNumberBuffers != 1 || frames == 0 || channels == 0) return false;
    AudioBuffer *buffer = &buffers->mBuffers[0];
    // Division avoids overflow if a route transition supplies an invalid count.
    return buffer->mData != NULL && buffer->mNumberChannels == channels &&
        frames <= buffer->mDataByteSize / sizeof(short) / channels;
}

#endif
