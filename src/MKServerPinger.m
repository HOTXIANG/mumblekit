// Copyright 2009-2012 The MumbleKit Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import "MKServerPinger.h"
#import "../../Source/Classes/SwiftUI/Core/MumbleLogger.h"
#import <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netdb.h>
#include <fcntl.h>
#include <unistd.h>
#include <math.h>

static void MKServerPingerOnMain(dispatch_block_t block) {
    if ([NSThread isMainThread]) block();
    else dispatch_sync(dispatch_get_main_queue(), block);
}

// Ignore padding and IPv6 flow information when matching DNS results to recvfrom.
static NSData *MKServerPingerAddress(const struct sockaddr *address, socklen_t length) {
    if (address->sa_family == AF_INET && length >= sizeof(struct sockaddr_in)) {
        const struct sockaddr_in *source = (const struct sockaddr_in *)address;
        struct sockaddr_in value = { 0 };
        value.sin_len = sizeof(value);
        value.sin_family = AF_INET;
        value.sin_port = source->sin_port;
        value.sin_addr = source->sin_addr;
        return [NSData dataWithBytes:&value length:sizeof(value)];
    }
    if (address->sa_family == AF_INET6 && length >= sizeof(struct sockaddr_in6)) {
        const struct sockaddr_in6 *source = (const struct sockaddr_in6 *)address;
        struct sockaddr_in6 value = { 0 };
        value.sin6_len = sizeof(value);
        value.sin6_family = AF_INET6;
        value.sin6_port = source->sin6_port;
        value.sin6_addr = source->sin6_addr;
        value.sin6_scope_id = source->sin6_scope_id;
        return [NSData dataWithBytes:&value length:sizeof(value)];
    }
    return nil;
}

@interface MKServerPinger () {
    NSData *_address;
    NSHashTable *_delegates;
    BOOL _started; // Main queue only; the controller retains registered pingers.
}
- (NSData *)address;
@end

@interface MKServerPingerController : NSObject {
    NSMutableDictionary *_randvalues;
    NSMutableDictionary *_pingers;
    int _sock4;
    int _sock6;
    dispatch_source_t _reader4;
    dispatch_source_t _reader6;
    dispatch_source_t _timer;
    NSUInteger _stateGeneration;
}
+ (MKServerPingerController *)sharedController;
- (BOOL)addPinger:(MKServerPinger *)pinger;
- (void)removePinger:(MKServerPinger *)pinger;
- (void)setupPingerState;
- (void)teardownPingerState;
- (void)socketReader:(int)sock;
- (void)timerTicked;
@end

@implementation MKServerPingerController

+ (MKServerPingerController *)sharedController {
    static MKServerPingerController *controller;
    static dispatch_once_t token;
    dispatch_once(&token, ^{ controller = [[MKServerPingerController alloc] init]; });
    return controller;
}

- (id)init {
    if ((self = [super init])) {
        _pingers = [[NSMutableDictionary alloc] init];
        _randvalues = [[NSMutableDictionary alloc] init];
        _sock4 = _sock6 = -1;
    }
    return self;
}

- (void)dealloc {
    [self teardownPingerState];
    [_pingers release];
    [_randvalues release];
    [super dealloc];
}

- (int)createSocketForFamily:(int)family reader:(dispatch_source_t *)reader {
    int sock = socket(family, SOCK_DGRAM, 0);
    if (sock < 0) return -1;
    int value = 1;
    setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &value, sizeof(value));
    int flags = fcntl(sock, F_GETFL, 0);
    if (flags == -1 || fcntl(sock, F_SETFL, flags | O_NONBLOCK) == -1) {
        close(sock);
        return -1;
    }
    struct sockaddr_storage storage = { 0 };
    socklen_t length;
    if (family == AF_INET) {
        struct sockaddr_in *address = (struct sockaddr_in *)&storage;
        address->sin_len = length = sizeof(*address);
        address->sin_family = AF_INET;
    } else {
        struct sockaddr_in6 *address = (struct sockaddr_in6 *)&storage;
        address->sin6_len = length = sizeof(*address);
        address->sin6_family = AF_INET6;
    }
    if (bind(sock, (struct sockaddr *)&storage, length) != 0) {
        close(sock);
        return -1;
    }
    *reader = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)sock, 0, dispatch_get_main_queue());
    if (!*reader) { close(sock); return -1; }
    NSUInteger generation = _stateGeneration;
    dispatch_source_set_event_handler(*reader, ^{
        if (generation == self->_stateGeneration) [self socketReader:sock];
    });
    // Close after Dispatch relinquishes its descriptor registration. Capturing
    // this descriptor prevents an old cancellation from closing a new socket.
    dispatch_source_set_cancel_handler(*reader, ^{ close(sock); });
    dispatch_resume(*reader);
    return sock;
}

- (void)setupPingerState {
    if (_timer != NULL) return;
    ++_stateGeneration;
    _sock4 = [self createSocketForFamily:AF_INET reader:&_reader4];
    _sock6 = [self createSocketForFamily:AF_INET6 reader:&_reader6];
    if (_sock4 < 0 && _sock6 < 0) MKLogWarning(Network, @"MKServerPinger: unable to create UDP sockets.");
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    NSUInteger generation = _stateGeneration;
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(_timer, ^{
        if (generation == self->_stateGeneration) [self timerTicked];
    });
    dispatch_resume(_timer);
}

- (void)teardownPingerState {
    ++_stateGeneration;
    if (_timer) {
        dispatch_source_cancel(_timer);
        dispatch_release(_timer);
        _timer = NULL;
    }
    if (_reader4) {
        dispatch_source_cancel(_reader4);
        dispatch_release(_reader4);
        _reader4 = NULL;
    }
    if (_reader6) {
        dispatch_source_cancel(_reader6);
        dispatch_release(_reader6);
        _reader6 = NULL;
    }
    _sock4 = _sock6 = -1;
}

- (void)socketReader:(int)sock {
    for (unsigned packet = 0; packet < 32; ++packet) {
        struct sockaddr_storage address = { 0 };
        socklen_t length = sizeof(address);
        UInt32 ping[6];
        ssize_t received = recvfrom(sock, ping, sizeof(ping), 0, (struct sockaddr *)&address, &length);
        if (received < 0) break;
        if (received != sizeof(ping)) continue;
        NSData *key = MKServerPingerAddress((struct sockaddr *)&address, length);
        NSNumber *random = key ? [_randvalues objectForKey:key] : nil;
        if (!random) continue;
        UInt64 timestamp = (((UInt64)ping[1] << 32) | ping[2]) ^ [random unsignedLongLongValue];
        NSTimeInterval original;
        memcpy(&original, &timestamp, sizeof(original));
        NSTimeInterval elapsed = [NSProcessInfo processInfo].systemUptime - original;
        if (!isfinite(elapsed) || elapsed < 0 || elapsed > 60) continue;
        MKServerPingerResult result = {
            .version = CFSwapInt32BigToHost(ping[0]),
            .cur_users = CFSwapInt32BigToHost(ping[3]),
            .max_users = CFSwapInt32BigToHost(ping[4]),
            .bandwidth = CFSwapInt32BigToHost(ping[5]),
            .ping = elapsed
        };
        NSUInteger generation = _stateGeneration;
        // A callback may stop itself or every pinger at this address.
        NSArray *targets = [[_pingers objectForKey:key] copy];
        for (MKServerPinger *pinger in targets) {
            id<MKServerPingerDelegate> delegate = [[pinger delegate] retain];
            [delegate serverPingerResult:&result];
            [delegate release];
        }
        [targets release];
        if (generation != _stateGeneration) break;
    }
}

- (void)timerTicked {
    for (NSData *address in [_randvalues allKeys]) {
        NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
        UInt64 bits;
        memcpy(&bits, &now, sizeof(bits));
        UInt64 random = bits ^ [[_randvalues objectForKey:address] unsignedLongLongValue];
        UInt32 ping[3] = { 0, (UInt32)(random >> 32), (UInt32)random };
        const struct sockaddr *destination = (const struct sockaddr *)address.bytes;
        int sock = destination->sa_family == AF_INET ? _sock4 : _sock6;
        if (sock >= 0 && sendto(sock, ping, sizeof(ping), 0, destination, (socklen_t)address.length) < 0) {
            MKLogWarning(Network, @"MKServerPinger: sendto failed: %s", strerror(errno));
        }
    }
}

- (BOOL)addPinger:(MKServerPinger *)pinger {
    NSData *address = [pinger address];
    if (!address) return NO;
    NSMutableArray *targets = [_pingers objectForKey:address];
    if (!targets) {
        UInt64 random = ((UInt64)arc4random() << 32) | arc4random();
        [_randvalues setObject:[NSNumber numberWithUnsignedLongLong:random] forKey:address];
        targets = [NSMutableArray array];
        [_pingers setObject:targets forKey:address];
    }
    if ([targets indexOfObjectIdenticalTo:pinger] == NSNotFound) [targets addObject:pinger];
    // Address count is not registration count: many rows may share one server.
    [self setupPingerState];
    return YES;
}

- (void)removePinger:(MKServerPinger *)pinger {
    NSData *address = [pinger address];
    if (!address) return;
    NSMutableArray *targets = [_pingers objectForKey:address];
    [targets removeObjectIdenticalTo:pinger];
    if (targets && targets.count == 0) {
        [_pingers removeObjectForKey:address];
        [_randvalues removeObjectForKey:address];
    }
    if (_pingers.count == 0) [self teardownPingerState];
}
@end

@implementation MKServerPinger

- (id)initWithHostname:(NSString *)hostname port:(NSString *)port {
    return [self initWithHostname:hostname port:port startImmediately:YES];
}

- (id)initWithHostname:(NSString *)hostname port:(NSString *)port startImmediately:(BOOL)startImmediately {
    if ((self = [super init])) {
        _delegates = [[NSHashTable weakObjectsHashTable] retain];
        struct addrinfo *addresses = NULL;
        struct addrinfo hints = { 0 };
        hints.ai_family = PF_UNSPEC;
        hints.ai_socktype = SOCK_DGRAM;
        hints.ai_flags = AI_ADDRCONFIG;
        if (hostname.length && port.length && getaddrinfo(hostname.UTF8String, port.UTF8String, &hints, &addresses) == 0) {
            for (struct addrinfo *candidate = addresses; candidate; candidate = candidate->ai_next) {
                _address = [MKServerPingerAddress(candidate->ai_addr, (socklen_t)candidate->ai_addrlen) retain];
                if (_address) break;
            }
            freeaddrinfo(addresses);
        }
        if (startImmediately) [self start];
    }
    return self;
}

- (void)dealloc {
    // Active instances belong to the controller until explicit stop. Deferred or
    // stopped instances have no registration to mutate from their dealloc thread.
    [_delegates release];
    [_address release];
    [super dealloc];
}

- (void)start {
    MKServerPingerOnMain(^{
        if (!self->_started) self->_started = [[MKServerPingerController sharedController] addPinger:self];
    });
}

- (void)stop {
    [self retain];
    // Clear immediately, including during an owner's off-main deinit. Delegates
    // are zeroing weak references; an already executing callback holds its own retain.
    @synchronized(self) { [_delegates removeAllObjects]; }
    MKServerPingerOnMain(^{
        if (!self->_started) return;
        self->_started = NO;
        [[MKServerPingerController sharedController] removePinger:self];
    });
    [self release];
}

- (void)setDelegate:(id<MKServerPingerDelegate>)delegate {
    @synchronized(self) {
        [_delegates removeAllObjects];
        if (delegate) [_delegates addObject:delegate];
    }
}

- (id<MKServerPingerDelegate>)delegate {
    @synchronized(self) { return [[[_delegates anyObject] retain] autorelease]; }
}

- (NSData *)address { return _address; }
@end
