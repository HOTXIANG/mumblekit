// Internal stream framing primitives. Kept independent of sockets for fault injection.
#import <Foundation/Foundation.h>
#include <stdint.h>

static const NSUInteger MKConnectionMaximumFrameLength = 8 * 1024 * 1024;
static const NSUInteger MKConnectionMaximumQueuedBytes = 16 * 1024 * 1024;
static const NSUInteger MKConnectionVoiceBacklogLimit = 64 * 1024;

typedef struct {
    NSMutableArray *frames;
    NSUInteger offset;
    NSUInteger pendingBytes;
} MKConnectionWriteQueue;

static inline void MKConnectionResetWriteQueue(MKConnectionWriteQueue *queue) {
    [queue->frames release];
    memset(queue, 0, sizeof(*queue));
}

// A frame already partially written must never be dropped or interleaved.
static inline BOOL MKConnectionEnqueueFrame(MKConnectionWriteQueue *queue, uint16_t type, NSData *payload) {
    NSUInteger length = [payload length];
    if (length > MKConnectionMaximumFrameLength ||
        queue->pendingBytes > MKConnectionMaximumQueuedBytes - length - 6) {
        return NO;
    }
    uint8_t header[] = { type >> 8, type & 0xff, length >> 24, length >> 16, length >> 8, length & 0xff };
    NSMutableData *frame = [NSMutableData dataWithBytes:header length:sizeof(header)];
    [frame appendData:payload];
    if (!queue->frames) queue->frames = [[NSMutableArray alloc] init];
    [queue->frames addObject:frame];
    queue->pendingBytes += [frame length];
    return YES;
}

// Returns NO only for an actual stream error; zero/short writes preserve the tail.
static inline BOOL MKConnectionFlushFrames(MKConnectionWriteQueue *queue, NSOutputStream *stream,
                                           NSUInteger *bytesWritten, uint32_t *completedFrames) {
    *bytesWritten = 0;
    *completedFrames = 0;
    while ([queue->frames count] && [stream hasSpaceAvailable]) {
        NSData *frame = [queue->frames objectAtIndex:0];
        NSUInteger remaining = [frame length] - queue->offset;
        NSInteger written = [stream write:(const uint8_t *)[frame bytes] + queue->offset maxLength:remaining];
        if (written < 0 || (NSUInteger)written > remaining) return NO;
        if (written == 0) break;
        queue->offset += written;
        queue->pendingBytes -= written;
        *bytesWritten += written;
        if (queue->offset == [frame length]) {
            [queue->frames removeObjectAtIndex:0];
            queue->offset = 0;
            *completedFrames += 1;
        }
    }
    return YES;
}

typedef struct {
    uint8_t header[6];
    NSUInteger headerLength;
    uint16_t type;
    NSUInteger payloadLength;
    NSUInteger offset;
    NSMutableData *payload;
} MKConnectionReadState;

typedef NS_ENUM(NSInteger, MKConnectionReadResult) {
    MKConnectionReadDrained = 0,
    MKConnectionReadContinue,
    MKConnectionReadError,
    MKConnectionReadEOF,
    MKConnectionReadOversized,
};

static inline void MKConnectionResetReadState(MKConnectionReadState *state) {
    [state->payload release];
    memset(state, 0, sizeof(*state));
}

static inline MKConnectionReadResult MKConnectionReadFrames(MKConnectionReadState *state, NSInputStream *stream,
                                                           BOOL (^receiveFrame)(uint16_t, NSData *)) {
    NSUInteger completed = 0;
    while ([stream hasBytesAvailable]) {
        if (state->headerLength < sizeof(state->header)) {
            NSUInteger remaining = sizeof(state->header) - state->headerLength;
            NSInteger count = [stream read:state->header + state->headerLength maxLength:remaining];
            if (count < 0 || (NSUInteger)count > remaining) return MKConnectionReadError;
            if (count == 0) return MKConnectionReadEOF;
            state->headerLength += count;
            if (state->headerLength != sizeof(state->header)) continue;
            const uint8_t *header = state->header;
            state->type = ((uint16_t)header[0] << 8) | header[1];
            state->payloadLength = ((uint32_t)header[2] << 24) | ((uint32_t)header[3] << 16) |
                                   ((uint32_t)header[4] << 8) | header[5];
            if (state->payloadLength > MKConnectionMaximumFrameLength) return MKConnectionReadOversized;
            state->payload = [[NSMutableData alloc] initWithLength:state->payloadLength];
        }
        if (state->offset < state->payloadLength) {
            if (![stream hasBytesAvailable]) return MKConnectionReadDrained;
            NSUInteger remaining = state->payloadLength - state->offset;
            NSInteger count = [stream read:(uint8_t *)[state->payload mutableBytes] + state->offset maxLength:remaining];
            if (count < 0 || (NSUInteger)count > remaining) return MKConnectionReadError;
            if (count == 0) return MKConnectionReadEOF;
            state->offset += count;
            if (state->offset < state->payloadLength) continue;
        }
        BOOL keepReading = receiveFrame(state->type, state->payload);
        MKConnectionResetReadState(state);
        if (!keepReading) return MKConnectionReadDrained;
        // Yield between bursts so stop requests and watchdogs cannot be starved.
        if (++completed == 64) return MKConnectionReadContinue;
    }
    return MKConnectionReadDrained;
}

static inline BOOL MKConnectionDeadlineExpired(uint64_t now, uint64_t start, uint64_t duration) {
    return start != 0 && now >= start && now - start >= duration;
}

// Replies prove bidirectional health only when they match a recent outstanding
// request. Keep a bounded window so loss and reordering need no allocations.
typedef struct {
    uint64_t timestamps[16];
    uint64_t sentAtUsec[16];
    NSUInteger next;
    uint64_t lastReplyUsec;
    uint64_t lastReplyTimestamp;
} MKConnectionPingState;

static inline void MKConnectionRecordPing(MKConnectionPingState *state, uint64_t timestamp, uint64_t now) {
    NSUInteger slot = state->next++ % 16;
    state->timestamps[slot] = timestamp;
    state->sentAtUsec[slot] = now;
}

static inline BOOL MKConnectionAcceptPingReply(MKConnectionPingState *state, uint64_t timestamp,
                                               uint64_t now, uint64_t maximumRTTUsec) {
    if (state->lastReplyUsec && timestamp <= state->lastReplyTimestamp) return NO;
    for (NSUInteger slot = 0; slot < 16; ++slot) {
        uint64_t sentAt = state->sentAtUsec[slot];
        if (!sentAt || state->timestamps[slot] != timestamp) continue;
        state->sentAtUsec[slot] = 0;
        if (now < sentAt || now - sentAt >= maximumRTTUsec) return NO;
        state->lastReplyTimestamp = timestamp;
        state->lastReplyUsec = now;
        return YES;
    }
    return NO;
}
