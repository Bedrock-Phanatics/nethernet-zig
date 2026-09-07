const std = @import("std");
pub const Scheme = std.crypto.sign.ecdsa.EcdsaP384Sha384;
const b64 = std.base64.url_safe_no_pad;
pub const maximum_size = 1024 * 1024;
const prefix = [_]u8{ 0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00 };

pub fn encode64(a: std.mem.Allocator, data: []const u8) ![]u8 {
    const out = try a.alloc(u8, b64.Encoder.calcSize(data.len));
    _ = b64.Encoder.encode(out, data);
    return out;
}
pub fn decode64(a: std.mem.Allocator, text: []const u8) ![]u8 {
    if (text.len > maximum_size) return error.IdentityTooLarge;
    const codec = if (std.mem.indexOfAny(u8, text, "+/") != null) std.base64.standard_no_pad else b64;
    const unpadded = std.mem.trimEnd(u8, text, "=");
    const out = try a.alloc(u8, try codec.Decoder.calcSizeForSlice(unpadded));
    errdefer a.free(out);
    try codec.Decoder.decode(out, unpadded);
    return out;
}
fn split(text: []const u8) ![3][]const u8 {
    if (text.len > maximum_size) return error.IdentityTooLarge;
    var it = std.mem.splitScalar(u8, text, '.');
    var result: [3][]const u8 = undefined;
    for (&result) |*part| part.* = it.next() orelse return error.InvalidIdentity;
    if (it.next() != null) return error.InvalidIdentity;
    return result;
}
pub fn field(value: std.json.Value, name: []const u8) !std.json.Value {
    if (value != .object) return error.InvalidIdentity;
    return value.object.get(name) orelse error.InvalidIdentity;
}
pub fn string(value: std.json.Value) ![]const u8 {
    if (value != .string) return error.InvalidIdentity;
    return value.string;
}
fn integer(value: std.json.Value) !i64 {
    if (value != .integer) return error.InvalidIdentity;
    return value.integer;
}
pub fn parse(a: std.mem.Allocator, data: []const u8) !std.json.Parsed(std.json.Value) {
    if (data.len > maximum_size) return error.IdentityTooLarge;
    return std.json.parseFromSlice(std.json.Value, a, data, .{ .max_value_len = maximum_size });
}

/// Returned compact JWS is owned by caller and freed with a. Detached signatures
/// sign base64url(payload), exactly as jose-jwt does without RFC 7797 options.
pub fn sign(a: std.mem.Allocator, key: Scheme.KeyPair, header: []const u8, payload: []const u8, detached: bool) ![]u8 {
    if (header.len > maximum_size or payload.len > maximum_size) return error.IdentityTooLarge;
    const h = try encode64(a, header);
    defer a.free(h);
    const p = try encode64(a, payload);
    defer a.free(p);
    const input = try std.fmt.allocPrint(a, "{s}.{s}", .{ h, p });
    defer a.free(input);
    const signature = try key.sign(input, null);
    const s = try encode64(a, &signature.toBytes());
    defer a.free(s);
    return std.fmt.allocPrint(a, "{s}.{s}.{s}", .{ h, if (detached) "" else p, s });
}

pub fn verify(a: std.mem.Allocator, token: []const u8, key: Scheme.PublicKey, detached: ?[]const u8) !void {
    const parts = try split(token);
    const h = try decode64(a, parts[0]);
    defer a.free(h);
    const header = try parse(a, h);
    defer header.deinit();
    if (!std.mem.eql(u8, try string(try field(header.value, "alg")), "ES384")) return error.UnsupportedAlgorithm;
    if (header.value.object.get("crit") != null or header.value.object.get("b64") != null) return error.UnsupportedAlgorithm;
    const signature = try decode64(a, parts[2]);
    defer a.free(signature);
    if (signature.len != 96) return error.InvalidIdentity;
    const encoded = if (detached) |payload| try encode64(a, payload) else null;
    defer if (encoded) |bytes| a.free(bytes);
    if (detached != null and parts[1].len != 0) return error.InvalidIdentity;
    const input = try std.fmt.allocPrint(a, "{s}.{s}", .{ parts[0], encoded orelse parts[1] });
    defer a.free(input);
    try Scheme.Signature.fromBytes(signature[0..96].*).verify(input, key);
}

/// JWT validity uses Unix seconds; protocol deadlines use monotonic time.
pub fn serverToken(a: std.mem.Allocator, key: Scheme.KeyPair, now: i64) ![]u8 {
    var der: [120]u8 = undefined;
    @memcpy(der[0..prefix.len], &prefix);
    @memcpy(der[prefix.len..], &key.public_key.toUncompressedSec1());
    var encoded: [160]u8 = undefined;
    const pk = std.base64.standard.Encoder.encode(&encoded, &der);
    const claims = try std.json.Stringify.valueAlloc(a, .{ .exp = try std.math.add(i64, now, 60), .iat = now, .cpk = pk }, .{});
    defer a.free(claims);
    const header = try std.json.Stringify.valueAlloc(a, .{ .alg = "ES384", .x5u = pk }, .{});
    defer a.free(header);
    return sign(a, key, header, claims, false);
}

/// Validates time claims and cpk. For issuer-signed client tokens, callers must
/// verify the issuer separately; self_signed=false does not authenticate issuers.
pub fn claimPublicKey(a: std.mem.Allocator, token: []const u8, now: i64, self_signed: bool) !Scheme.PublicKey {
    const parts = try split(token);
    const h = try decode64(a, parts[0]);
    defer a.free(h);
    const header = try parse(a, h);
    defer header.deinit();
    const algorithm = try string(try field(header.value, "alg"));
    if (!std.mem.eql(u8, algorithm, "ES384") and !std.mem.eql(u8, algorithm, "RS256")) return error.UnsupportedAlgorithm;
    const p = try decode64(a, parts[1]);
    defer a.free(p);
    const claims = try parse(a, p);
    defer claims.deinit();
    const expiration = try integer(try field(claims.value, "exp"));
    if (@as(i128, expiration) < @as(i128, now) - 60) return error.ExpiredIdentity;
    for ([_][]const u8{ "nbf", "iat" }) |name| if (claims.value.object.get(name)) |value| {
        if (@as(i128, try integer(value)) > @as(i128, now) + 60) return error.InvalidIdentity;
    };
    const claim = try field(claims.value, "cpk");
    const key = if (claim == .string) blk: {
        const der = try decode64(a, claim.string);
        defer a.free(der);
        if (der.len != prefix.len + 97 or !std.mem.startsWith(u8, der, &prefix)) return error.UnsupportedKey;
        break :blk try Scheme.PublicKey.fromSec1(der[prefix.len..]);
    } else blk: {
        if (!std.mem.eql(u8, try string(try field(claim, "kty")), "EC") or !std.mem.eql(u8, try string(try field(claim, "crv")), "P-384")) return error.UnsupportedKey;
        const x = try decode64(a, try string(try field(claim, "x")));
        defer a.free(x);
        const y = try decode64(a, try string(try field(claim, "y")));
        defer a.free(y);
        if (x.len != 48 or y.len != 48) return error.InvalidIdentity;
        var sec1: [97]u8 = undefined;
        sec1[0] = 4;
        @memcpy(sec1[1..49], x);
        @memcpy(sec1[49..], y);
        break :blk try Scheme.PublicKey.fromSec1(&sec1);
    };
    if (self_signed) try verify(a, token, key, null);
    return key;
}

test "server identity, expiry, detached signatures, and tampering" {
    const a = std.testing.allocator;
    const key = try Scheme.KeyPair.generateDeterministic(.{1} ** 48);
    const token = try serverToken(a, key, 1000);
    defer a.free(token);
    const pk = try claimPublicKey(a, token, 1000, true);
    try std.testing.expectError(error.ExpiredIdentity, claimPublicKey(a, token, 1121, true));
    const sig = try sign(a, key, "{\"alg\":\"ES384\"}", "fingerprints", true);
    defer a.free(sig);
    try verify(a, sig, pk, "fingerprints");
    if (verify(a, sig, pk, "tampered")) |_| return error.TamperingAccepted else |_| {}
}

fn allocationScenario(a: std.mem.Allocator) !void {
    const key = try Scheme.KeyPair.generateDeterministic(.{3} ** 48);
    const token = try serverToken(a, key, 1000);
    defer a.free(token);
    _ = try claimPublicKey(a, token, 1000, true);
}
test "every identity allocation failure releases partial state" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
}
