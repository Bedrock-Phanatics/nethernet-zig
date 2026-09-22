const std = @import("std");
const nethernet = @import("nethernet");
const Connection = nethernet.Connection;
const framing = nethernet.framing;
const Peer = nethernet.Peer;
const auth = nethernet.sdp_identity;

test "native peers negotiate and exchange both channel types" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const a = try Peer.create(allocator, io, .{ .disable_trickle = true });
    defer a.destroy();

    const b = try Peer.create(allocator, io, .{ .disable_trickle = true });
    defer b.destroy();

    const buffer = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(buffer);

    try a.offer();

    const started = std.Io.Clock.awake.now(io);
    while (!a.ready() or !b.ready()) {
        if (started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > 15_000) {
            return error.Timeout;
        }

        for ([_]*Peer{ a, b }, [_]*Peer{ b, a }) |source, destination| {
            if (try source.poll(buffer)) |event| switch (event) {
                .offer, .answer => |sdp| {
                    const terminated = try allocator.dupeZ(u8, sdp);
                    defer allocator.free(terminated);

                    try destination.remoteDescription(
                        terminated,
                        if (event == .offer) .offer else .answer,
                    );
                },
                else => return error.UnexpectedEvent,
            };
        }

        if ((!a.ready() or !b.ready()) and
            !a.hasPending(false) and
            !b.hasPending(false))
        {
            try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        }
    }

    for ([_]framing.Reliability{ .reliable, .unreliable }) |reliability| {
        try a.send("hello", reliability, buffer);

        var received = false;
        while (!received) {
            b.wakeup.prepare();
            if (started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > 20_000) {
                return error.Timeout;
            }

            if (try b.poll(buffer)) |event| switch (event) {
                .reliable_fragment, .unreliable_fragment => |fragment| {
                    try std.testing.expectEqualSlices(
                        u8,
                        &.{ 0, 'h', 'e', 'l', 'l', 'o' },
                        fragment,
                    );
                    try std.testing.expectEqual(
                        reliability == .reliable,
                        event == .reliable_fragment,
                    );
                    received = true;
                },
                else => return error.UnexpectedEvent,
            };

            if (!received and !b.hasPending(false)) {
                try std.Io.sleep(io, .fromMilliseconds(1), .awake);
            }
        }
    }

    const diagnostics = a.diagnostics();
    try std.testing.expect(
        diagnostics.ice_state == .connected or diagnostics.ice_state == .completed,
    );
    try std.testing.expectEqual(.complete, diagnostics.gathering_state);
    try std.testing.expectEqual(.open, diagnostics.reliable.state);
    try std.testing.expectEqual(.open, diagnostics.unreliable.state);
    try std.testing.expect(diagnostics.reliable.buffered_outgoing_bytes != null);
    try std.testing.expect(diagnostics.unreliable.buffered_outgoing_bytes != null);

    var local_ice: [128]u8 = undefined;
    var remote_ice: [128]u8 = undefined;
    const ice_addresses = (try a.selectedIceAddresses(&local_ice, &remote_ice)).?;
    try std.testing.expect(ice_addresses.local.len != 0);
    try std.testing.expect(ice_addresses.remote.len != 0);

    a.close();
    a.close();
}

test "connections verify identities, reassemble large messages, and reconnect" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const payload = try allocator.alloc(u8, framing.maximum_segment_payload + 13);
    defer allocator.free(payload);

    for (payload, 0..) |*byte, index| byte.* = @truncate(index);

    for (0..2) |_| {
        const client = try Connection.create(
            allocator,
            io,
            .client,
            7,
            "server",
            .{ .native = .{ .disable_trickle = true } },
        );
        defer client.destroy();

        const server = try Connection.create(
            allocator,
            io,
            .server,
            7,
            "client",
            .{
                .native = .{ .disable_trickle = true },
                .allow_anonymous = true,
            },
        );
        defer server.destroy();

        try client.start();

        const started = std.Io.Clock.awake.now(io);
        while (!client.ready() or !server.ready()) {
            if (started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > 20_000) {
                return error.Timeout;
            }

            for (
                [_]*Connection{ client, server },
                [_]*Connection{ server, client },
                [_][]const u8{ "client", "server" },
            ) |source, destination, name| {
                if (try source.poll()) |event| switch (event) {
                    .signal => |signal| {
                        var routed = signal;
                        routed.network_id = name;
                        try destination.applySignal(routed);
                    },
                    else => return error.UnexpectedEvent,
                };
            }

            if ((!client.ready() or !server.ready()) and
                !client.peer.hasPending(true) and
                !server.peer.hasPending(true))
            {
                try std.Io.sleep(io, .fromMilliseconds(1), .awake);
            }
        }

        try std.testing.expect(client.public_key != null);
        try std.testing.expect(client.remoteIceCandidateCount() > 0);

        try client.send(payload, .reliable);
        const message = try server.receive();
        try std.testing.expectEqualSlices(u8, payload, message.data);
        try std.testing.expectEqual(@as(u64, payload.len), server.received_bytes);

        var draining_receive = try io.concurrent(Connection.receive, .{server});
        var receive_taken = false;
        defer if (!receive_taken) {
            _ = draining_receive.cancel(io) catch {};
        };

        try client.send(payload, .reliable);
        const drained = try draining_receive.await(io);
        receive_taken = true;
        try std.testing.expectEqualSlices(u8, payload, drained.data);
        try std.testing.expectEqual(@as(u64, payload.len * 2), server.received_bytes);

        const receipt = "large-message-received";
        try server.send(receipt, .reliable);
        const acknowledged = try client.receive();
        try std.testing.expectEqualSlices(u8, receipt, acknowledged.data);

        try client.closeGracefully();
        try std.testing.expectError(error.InvalidState, client.send("late", .reliable));
        client.close();
        client.close();
    }
}

test "a negotiated 1024-byte SCTP limit bounds fragments and unreliable sends" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const a = try Peer.create(allocator, io, .{ .disable_trickle = true });
    defer a.destroy();

    const b = try Peer.create(allocator, io, .{ .disable_trickle = true });
    defer b.destroy();

    const buffer = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(buffer);

    try a.offer();

    var advertised = false;

    const started = std.Io.Clock.awake.now(io);
    while (!a.ready() or !b.ready()) {
        if (started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > 20_000) {
            return error.Timeout;
        }

        for ([_]*Peer{ a, b }, [_]*Peer{ b, a }) |source, destination| {
            if (try source.poll(buffer)) |event| switch (event) {
                .offer, .answer => |sdp| {
                    const patched = if (source == a)
                        try std.mem.replaceOwned(
                            u8,
                            allocator,
                            sdp,
                            "a=max-message-size:262144",
                            "a=max-message-size:1024",
                        )
                    else
                        try allocator.dupe(u8, sdp);
                    defer allocator.free(patched);

                    if (source == a) {
                        if (std.mem.indexOf(u8, patched, "a=max-message-size:1024") == null) {
                            return error.MissingMaxMessageSize;
                        }
                        advertised = true;
                    }

                    const terminated = try allocator.dupeZ(u8, patched);
                    defer allocator.free(terminated);

                    try destination.remoteDescription(
                        terminated,
                        if (event == .offer) .offer else .answer,
                    );
                },
                else => return error.UnexpectedEvent,
            };
        }

        if ((!a.ready() or !b.ready()) and
            !a.hasPending(false) and
            !b.hasPending(false))
        {
            try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        }
    }

    try std.testing.expect(advertised);

    const payload = try allocator.alloc(u8, 2000);
    defer allocator.free(payload);
    for (payload, 0..) |*byte, index| byte.* = @truncate(index);

    try b.send(payload, .reliable, buffer);

    const storage = try allocator.alloc(u8, payload.len);
    defer allocator.free(storage);
    var reassembler = framing.Reassembler.init(storage, .reliable);

    var fragments: usize = 0;
    var message: ?[]const u8 = null;
    while (message == null) {
        a.wakeup.prepare();
        if (started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > 25_000) {
            return error.Timeout;
        }

        if (try a.poll(buffer)) |event| switch (event) {
            .reliable_fragment => |fragment| {
                try std.testing.expect(fragment.len <= 1024);
                fragments += 1;
                message = try reassembler.push(fragment);
            },
            else => return error.UnexpectedEvent,
        } else if (!a.hasPending(false)) {
            try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        }
    }

    try std.testing.expectEqual(@as(usize, 2), fragments);
    try std.testing.expectEqualSlices(u8, payload, message.?);

    try b.send(payload[0..1023], .unreliable, buffer);
    try std.testing.expectError(
        error.MessageTooLarge,
        b.send(payload[0..1024], .unreliable, buffer),
    );

    try a.send(payload, .reliable, buffer);

    while (true) {
        b.wakeup.prepare();
        if (started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > 30_000) {
            return error.Timeout;
        }

        if (try b.poll(buffer)) |event| switch (event) {
            .reliable_fragment => |fragment| {
                try std.testing.expectEqual(payload.len + 1, fragment.len);
                try std.testing.expectEqual(@as(u8, 0), fragment[0]);
                break;
            },
            else => return error.UnexpectedEvent,
        } else if (!b.hasPending(false)) {
            try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        }
    }
}

test "the local description matches current vanilla WebRTC configuration" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const peer = try Peer.create(allocator, io, .{ .disable_trickle = true });
    defer peer.destroy();

    const buffer = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(buffer);

    try peer.offer();

    try std.testing.expect(peer.channels[0] >= 0);
    try std.testing.expect(peer.channels[1] >= 0);

    const started = std.Io.Clock.awake.now(io);
    const sdp = while (true) {
        if (started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > 15_000) {
            return error.Timeout;
        }
        if (try peer.poll(buffer)) |event| switch (event) {
            .offer => |data| break data,
            else => return error.UnexpectedEvent,
        };
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    };

    try std.testing.expect(std.mem.startsWith(u8, sdp, "v=0\r\n"));
    const media_start = std.mem.indexOf(u8, sdp, "\r\nm=").? + 2;
    const session = sdp[0..media_start];
    const media_sdp = sdp[media_start..];
    try std.testing.expect(std.mem.indexOf(u8, session, "\r\no=") != null);
    try std.testing.expect(std.mem.indexOf(u8, session, "\r\ns=-\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, session, "\r\nt=0 0\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, session, "a=group:BUNDLE 0\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, media_sdp, "a=mid:0\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, media_sdp, "a=setup:actpass\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, media_sdp, "a=ice-ufrag:") != null);
    try std.testing.expect(std.mem.indexOf(u8, media_sdp, "a=ice-pwd:") != null);
    try std.testing.expect(std.mem.indexOf(u8, media_sdp, "a=sctp-port:5000\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, media_sdp, "a=max-message-size:262144\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, media_sdp, "a=end-of-candidates\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, sdp, "a=identity:") == null);

    const payload = try auth.fingerprintPayload(allocator, sdp);
    defer allocator.free(payload);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    const fingerprints = parsed.value.object.get("fingerprint").?.array.items;
    try std.testing.expect(fingerprints.len > 0);

    const key = try nethernet.IdentityKeyPair.generateDeterministic(.{9} ** 48);
    const token = try nethernet.identity.serverToken(allocator, key, 1000);
    defer allocator.free(token);
    const signed = try auth.add(allocator, sdp, .{ .key = key, .token = token });
    defer allocator.free(signed);
    const signed_payload = try auth.fingerprintPayload(allocator, signed);
    defer allocator.free(signed_payload);
    try std.testing.expectEqualStrings(payload, signed_payload);
    try std.testing.expect((try auth.verify(allocator, signed, 1000, .server, null)) != null);

    const digest_offset = std.mem.indexOfScalarPos(u8, signed, std.mem.indexOf(u8, signed, "a=fingerprint:").?, ' ').? + 1;
    signed[digest_offset] = if (signed[digest_offset] == '0') '1' else '0';
    if (auth.verify(allocator, signed, 1000, .server, null)) |_| {
        return error.TamperedFingerprintAccepted;
    } else |_| {}

    var media: usize = 0;
    var connection_count: usize = 0;
    var fingerprint_count: usize = 0;
    var candidates: usize = 0;
    var lines = std.mem.tokenizeAny(u8, sdp, "\r\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "m=")) {
            media += 1;
            var fields = std.mem.tokenizeScalar(u8, line, ' ');
            try std.testing.expectEqualStrings("m=application", fields.next().?);
            try std.testing.expect((try std.fmt.parseInt(u16, fields.next().?, 10)) > 0);
            try std.testing.expectEqualStrings("UDP/DTLS/SCTP", fields.next().?);
            try std.testing.expectEqualStrings("webrtc-datachannel", fields.next().?);
            try std.testing.expect(fields.next() == null);
        }
        if (std.mem.startsWith(u8, line, "c=")) {
            connection_count += 1;
            try std.testing.expect(std.mem.startsWith(u8, line, "c=IN IP4 ") or
                std.mem.startsWith(u8, line, "c=IN IP6 "));
            try std.testing.expect(line.len > "c=IN IP4 ".len);
        }
        if (std.mem.startsWith(u8, line, "a=fingerprint:")) {
            fingerprint_count += 1;
            const value = line["a=fingerprint:".len..];
            const space = std.mem.indexOfScalar(u8, value, ' ').?;
            const algorithm = value[0..space];
            const digest = value[space + 1 ..];
            for (digest) |byte| try std.testing.expect(byte < 'a' or byte > 'f');
            var matched = false;
            for (fingerprints) |fingerprint| {
                if (std.mem.eql(u8, algorithm, fingerprint.object.get("algorithm").?.string) and
                    std.mem.eql(u8, digest, fingerprint.object.get("digest").?.string))
                {
                    matched = true;
                    break;
                }
            }
            try std.testing.expect(matched);
        }
        if (!std.mem.startsWith(u8, line, "a=candidate:")) continue;
        candidates += 1;

        try std.testing.expect(std.mem.indexOf(u8, line, " tcp ") == null);
        try std.testing.expect(std.mem.indexOf(u8, line, " UDP ") != null or
            std.mem.indexOf(u8, line, " udp ") != null);
        try std.testing.expect(std.mem.indexOf(u8, line, "typ host") != null);
    }

    try std.testing.expectEqual(@as(usize, 1), media);
    try std.testing.expectEqual(@as(usize, 1), connection_count);
    try std.testing.expect(fingerprint_count > 0);
    try std.testing.expect(candidates > 0);
}
