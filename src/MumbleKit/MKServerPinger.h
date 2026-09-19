// Copyright 2009-2012 The MumbleKit Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import <Foundation/Foundation.h>

typedef struct _MKServerPingerResult {
    UInt32  version;
    UInt32  cur_users;
    UInt32  max_users;
    UInt32  bandwidth;
    double  ping;
} MKServerPingerResult;

/// @protocol MKServerPingerDelegate MKServerPinger.h MumbleKit/MKServerPinger.h
@protocol MKServerPingerDelegate <NSObject>
- (void) serverPingerResult:(MKServerPingerResult *)result;
@end

/// @protocol MKServerPinger MKServerPinger.h MumbleKit/MKServerPinger.h
///
/// MKServerPinger implements a pinger object that can ping and query Mumble
/// servers for information typically shown in a server list.
///
/// Active pingers are retained by the shared controller. The owner MUST call stop
/// when results are no longer needed, including from its own dealloc/deinit.
/// Replies are delivered synchronously on the main queue. A callback may stop
/// itself or other pingers. Multiple pingers for one address share one UDP probe.
@interface MKServerPinger : NSObject

/// Initialize a new MKServerPinger that pings the server running
/// on the given hostname and port combination.
///
/// @param hostname  The hostname of the server to ping.
/// @param port      The port number of the server to ping.
///
/// @returns Returns an MKServerPinger object. To get ping results, one must
///          register a delegate implementing the MKServerPingerDelegate protocol.
- (id) initWithHostname:(NSString *)hostname port:(NSString *)port;

/// Resolve the address on the calling thread. With startImmediately:NO, this
/// creates no timer/socket registration and sends no packets until start.
- (id)initWithHostname:(NSString *)hostname port:(NSString *)port startImmediately:(BOOL)startImmediately;

/// Register once. Safe to repeat, including after stop. Bind the delegate again
/// before restarting because stop clears it. Main-queue serialized; an off-main
/// call waits for the main queue, so do not block the main queue waiting on it.
- (void)start;

/// Clear the weak delegate and unregister synchronously. Safe to repeat or call
/// from an owner's background deinit. The last registration cancels all probing.
- (void)stop;

/// Returns the currently-set delegate for the MKServerPinger object.
///
/// @returns Returns an object implementing the MKServerPingerDelegate protocol.
- (id<MKServerPingerDelegate>)delegate;

/// Set a zeroing weak delegate, called on main when the server responds.
///
/// @param delegate  The objec to register as the MKServerPinger's delegate.
///                  Must implement the MKServerPingerDelegate protocol.
- (void) setDelegate:(id<MKServerPingerDelegate>)delegate;

@end
