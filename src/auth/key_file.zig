const std = @import("std");

const jwt = @import("token.zig");

pub const KeyPair = jwt.Scheme.KeyPair;

pub const maximum_size = 4096;

const der = std.crypto.Certificate.der;

const scalar_size = 48;
const point_size = 97;

const ec_public_key_oid = [_]u8{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01 };
const secp384r1_oid = [_]u8{ 0x2b, 0x81, 0x04, 0x00, 0x22 };

// PKCS#8 header before the private scalar.
const prefix =
    [_]u8{ 0x30, 0x81, 0xb6, 0x02, 0x01, 0x00, 0x30, 0x10 } ++
    [_]u8{ 0x06, ec_public_key_oid.len } ++ ec_public_key_oid ++
    [_]u8{ 0x06, secp384r1_oid.len } ++ secp384r1_oid ++
    [_]u8{ 0x04, 0x81, 0x9e, 0x30, 0x81, 0x9b, 0x02, 0x01, 0x01 } ++
    [_]u8{ 0x04, scalar_size };

const infix = [_]u8{ 0xa1, 0x64, 0x03, 0x62, 0x00 };

const template = prefix ++ @as([scalar_size]u8, @splat(0)) ++ infix ++ @as([point_size]u8, @splat(0));

const scalar_offset = prefix.len;
const public_key_offset = scalar_offset + scalar_size + infix.len;

pub const encoded_size = template.len;

pub fn encode(key: KeyPair, output: *[encoded_size]u8) []const u8 {
    output.* = template;

    @memcpy(output[scalar_offset..][0..scalar_size], &key.secret_key.toBytes());
    @memcpy(output[public_key_offset..], &key.public_key.toUncompressedSec1());

    return output;
}

pub fn decode(bytes: []const u8) !KeyPair {
    if (bytes.len > maximum_size) return error.InvalidKeyFile;
    const info = try sequence(bytes, 0);
    if (info.end != bytes.len) return error.InvalidKeyFile;

    const algorithm = try sequence(bytes[0..info.end], try expectInteger(bytes[0..info.end], info.start, 0));
    const key_oid = try oid(bytes[0..algorithm.end], algorithm.start);
    const curve_oid = try oid(bytes[0..algorithm.end], key_oid.end);
    if (curve_oid.end != algorithm.end) return error.InvalidKeyFile;

    if (!std.mem.eql(u8, key_oid.contents, &ec_public_key_oid) or
        !std.mem.eql(u8, curve_oid.contents, &secp384r1_oid))
    {
        return error.UnsupportedKey;
    }

    const wrapper = try take(bytes, algorithm.end, .octetstring, .primitive);
    if (wrapper.end != info.end) return error.InvalidKeyFile;
    const ec_key = try sequence(bytes[0..wrapper.end], wrapper.start);
    if (ec_key.end != wrapper.end) return error.InvalidKeyFile;

    const scalar_index = try expectInteger(bytes[0..ec_key.end], ec_key.start, 1);
    const scalar = try take(bytes[0..ec_key.end], scalar_index, .octetstring, .primitive);
    if (scalar.contents.len != scalar_size) return error.InvalidKeyFile;

    var secret: [scalar_size]u8 = undefined;
    defer std.crypto.secureZero(u8, &secret);
    @memcpy(&secret, scalar.contents);

    const key = try KeyPair.fromSecretKey(try jwt.Scheme.SecretKey.fromBytes(secret));
    var next = scalar.end;
    if (next < ec_key.end and bytes[next] == 0xa0) {
        const parameters = try element(bytes[0..ec_key.end], next, 0xa0);
        const curve = try oid(bytes[0..parameters.end], parameters.start);
        if (curve.end != parameters.end or !std.mem.eql(u8, curve.contents, &secp384r1_oid))
            return error.InvalidKeyFile;
        next = parameters.end;
    }
    if (next < ec_key.end) {
        const public = try element(bytes[0..ec_key.end], next, 0xa1);
        const point = try take(bytes[0..public.end], public.start, .bitstring, .primitive);
        if (point.end != public.end or point.contents.len < 2 or point.contents[0] != 0)
            return error.InvalidKeyFile;
        const provided = jwt.Scheme.PublicKey.fromSec1(point.contents[1..]) catch return error.InvalidKeyFile;
        if (!std.mem.eql(u8, &provided.toUncompressedSec1(), &key.public_key.toUncompressedSec1()))
            return error.InvalidKeyFile;
        next = public.end;
    }
    if (next != ec_key.end) return error.InvalidKeyFile;
    return key;
}

pub fn loadOrCreate(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !KeyPair {
    const cwd: std.Io.Dir = .cwd();

    for (0..8) |_| {
        if (cwd.readFileAlloc(io, path, allocator, .limited(maximum_size))) |bytes| {
            defer {
                std.crypto.secureZero(u8, bytes);
                allocator.free(bytes);
            }
            return decode(bytes);
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        const key = KeyPair.generate(io);

        var encoded: [encoded_size]u8 = undefined;
        defer std.crypto.secureZero(u8, &encoded);

        var file = try cwd.createFileAtomic(io, path, .{ .permissions = private_permissions });
        defer file.deinit(io);
        try file.file.writeStreamingAll(io, encode(key, &encoded));
        try file.file.sync(io);
        file.link(io) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };

        return key;
    }

    return error.IdentityRaceLost;
}

const private_permissions: std.Io.File.Permissions =
    if (@hasDecl(std.Io.File.Permissions, "fromMode"))
        .fromMode(0o600)
    else
        .default_file;

const Element = struct {
    start: usize,
    end: usize,
    contents: []const u8,
};

// The stdlib DER parser assumes checked lengths, so key files get their own bounds checks.
fn take(
    bytes: []const u8,
    index: usize,
    tag: der.Tag,
    pc: der.PC,
) !Element {
    return element(bytes, index, @bitCast(der.Identifier{ .tag = tag, .pc = pc, .class = .universal }));
}

fn element(bytes: []const u8, index: usize, identifier: u8) !Element {
    if (index > bytes.len or bytes.len - index < 2 or bytes[index] != identifier)
        return error.InvalidKeyFile;

    const size_byte = bytes[index + 1];
    var header: usize = 2;
    var length: usize = size_byte;

    if (size_byte & 0x80 != 0) {
        const long = size_byte & 0x7f;
        if (long == 0 or long > 4 or index + 2 + long > bytes.len) {
            return error.InvalidKeyFile;
        }

        header += long;
        if (bytes[index + 2] == 0) return error.InvalidKeyFile;
        length = 0;
        for (bytes[index + 2 ..][0..long]) |byte| length = (length << 8) | byte;
        if (length < 128) return error.InvalidKeyFile;
    }

    const start = index + header;
    if (length > bytes.len - start) return error.InvalidKeyFile;

    return .{
        .start = start,
        .end = start + length,
        .contents = bytes[start .. start + length],
    };
}

fn sequence(bytes: []const u8, index: usize) !Element {
    return take(bytes, index, .sequence, .constructed);
}

fn oid(bytes: []const u8, index: usize) !Element {
    return take(bytes, index, .object_identifier, .primitive);
}

fn expectInteger(bytes: []const u8, index: usize, value: u8) !usize {
    const integer = try take(bytes, index, .integer, .primitive);

    if (integer.contents.len != 1 or integer.contents[0] != value) {
        return error.InvalidKeyFile;
    }

    return integer.end;
}

const openssl_fixture = &[_]u8{
    0x30, 0x81, 0xb6, 0x02, 0x01, 0x00, 0x30, 0x10, 0x06, 0x07, 0x2a, 0x86,
    0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x22,
    0x04, 0x81, 0x9e, 0x30, 0x81, 0x9b, 0x02, 0x01, 0x01, 0x04, 0x30, 0xb9,
    0x10, 0x13, 0xfe, 0x60, 0x4a, 0xb7, 0xe0, 0x21, 0x74, 0xe4, 0x33, 0x23,
    0x27, 0xee, 0xd1, 0xba, 0xfc, 0x76, 0x92, 0xcc, 0xa6, 0x8d, 0x3d, 0x4f,
    0x85, 0x7f, 0x83, 0x36, 0xaf, 0x73, 0xcc, 0x5b, 0xf3, 0xa4, 0xb9, 0x6f,
    0x8e, 0x19, 0xbd, 0x2b, 0xb2, 0x7f, 0xf8, 0x2b, 0x68, 0x21, 0xf7, 0xa1,
    0x64, 0x03, 0x62, 0x00, 0x04, 0xac, 0x8d, 0x83, 0xe7, 0x27, 0xce, 0xf5,
    0x98, 0x66, 0xdb, 0x49, 0xc1, 0x4b, 0x82, 0x06, 0xc7, 0x28, 0xf9, 0x3d,
    0xa8, 0x69, 0x91, 0x63, 0x99, 0x9e, 0xf5, 0xe6, 0x60, 0x74, 0x5c, 0x6a,
    0xb1, 0xa1, 0xb7, 0xef, 0xbd, 0xf6, 0x6d, 0x9e, 0x96, 0xda, 0xef, 0xcf,
    0x4c, 0xd2, 0x10, 0xf7, 0x51, 0xf4, 0x19, 0xca, 0x2b, 0x38, 0xcc, 0x25,
    0x57, 0x0b, 0xc8, 0x6b, 0xaa, 0xf6, 0x46, 0x9d, 0xa5, 0x74, 0xe1, 0xca,
    0xc8, 0x50, 0xf0, 0x26, 0x85, 0x67, 0x9f, 0x61, 0x4e, 0xb2, 0xc8, 0xa9,
    0xf3, 0x37, 0xa9, 0x05, 0xe8, 0xca, 0xcd, 0xdb, 0x22, 0x96, 0xa4, 0x0d,
    0x79, 0xd4, 0x74, 0xab, 0x6b,
};

test "PKCS#8 round-trips against an openssl-generated P-384 key" {
    try std.testing.expectEqual(encoded_size, openssl_fixture.len);

    const key = try decode(openssl_fixture);

    var scalar: [96]u8 = undefined;
    try std.testing.expectEqualStrings(
        "b91013fe604ab7e02174e4332327eed1bafc7692cca68d3d4f857f8336af73cc" ++
            "5bf3a4b96f8e19bd2bb27ff82b6821f7",
        std.fmt.bufPrint(&scalar, "{x}", .{key.secret_key.toBytes()}) catch
            unreachable,
    );

    var encoded: [encoded_size]u8 = undefined;
    try std.testing.expectEqualSlices(u8, openssl_fixture, encode(key, &encoded));
}

test "PKCS#8 encoding round-trips a generated key" {
    const key = try KeyPair.generateDeterministic(@splat(7));

    var encoded: [encoded_size]u8 = undefined;
    const decoded = try decode(encode(key, &encoded));

    try std.testing.expectEqual(key.secret_key.toBytes(), decoded.secret_key.toBytes());
    try std.testing.expectEqual(
        key.public_key.toUncompressedSec1(),
        decoded.public_key.toUncompressedSec1(),
    );
}

test "malformed PKCS#8 identities are rejected without panicking" {
    var encoded: [encoded_size]u8 = undefined;
    _ = encode(try KeyPair.generateDeterministic(@splat(8)), &encoded);

    for (0..encoded.len) |length| {
        try std.testing.expectError(error.InvalidKeyFile, decode(encoded[0..length]));
    }

    try std.testing.expectError(error.InvalidKeyFile, decode(&.{}));
    try std.testing.expectError(error.InvalidKeyFile, decode(&.{0x30}));

    try std.testing.expectError(
        error.InvalidKeyFile,
        decode(&.{ 0x30, 0x84, 0xff, 0xff, 0xff, 0xff, 0x00 }),
    );
    try std.testing.expectError(
        error.InvalidKeyFile,
        decode(&.{ 0x30, 0x85, 0x00, 0x00, 0x00, 0x00, 0x00 }),
    );

    var trailing: [encoded_size + 1]u8 = undefined;
    @memcpy(trailing[0..encoded_size], &encoded);
    trailing[encoded_size] = 0;
    try std.testing.expectError(error.InvalidKeyFile, decode(&trailing));

    const info = try sequence(&encoded, 0);
    const algorithm_index = try expectInteger(&encoded, info.start, 0);
    const algorithm_element = try sequence(&encoded, algorithm_index);

    var extra_algorithm_data: [encoded_size + 2]u8 = undefined;
    @memcpy(
        extra_algorithm_data[0..algorithm_element.end],
        encoded[0..algorithm_element.end],
    );
    extra_algorithm_data[algorithm_element.end] = 0x05; // NULL
    extra_algorithm_data[algorithm_element.end + 1] = 0x00;
    @memcpy(
        extra_algorithm_data[algorithm_element.end + 2 ..],
        encoded[algorithm_element.end..],
    );
    extra_algorithm_data[2] += 2;
    extra_algorithm_data[algorithm_index + 1] += 2;
    try std.testing.expectError(
        error.InvalidKeyFile,
        decode(&extra_algorithm_data),
    );

    var damaged = encoded;

    damaged[5] = 1; // PrivateKeyInfo version 1
    try std.testing.expectError(error.InvalidKeyFile, decode(&damaged));
    damaged = encoded;

    const curve = std.mem.indexOf(u8, &damaged, &secp384r1_oid).?;
    damaged[curve + secp384r1_oid.len - 1] = 0x23; // secp521r1
    try std.testing.expectError(error.UnsupportedKey, decode(&damaged));
    damaged = encoded;

    const algorithm = std.mem.indexOf(u8, &damaged, &ec_public_key_oid).?;
    damaged[algorithm + ec_public_key_oid.len - 1] = 0x02;
    try std.testing.expectError(error.UnsupportedKey, decode(&damaged));
    damaged = encoded;

    damaged[scalar_offset - 1] = scalar_size - 1;
    try std.testing.expectError(error.InvalidKeyFile, decode(&damaged));
    damaged = encoded;

    damaged[0] = 0x31; // SET instead of SEQUENCE
    try std.testing.expectError(error.InvalidKeyFile, decode(&damaged));
}

test "identity files persist across calls and are never silently replaced" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &buffer,
        ".zig-cache/tmp/{s}/identity.der",
        .{tmp.sub_path},
    );

    const created = try loadOrCreate(io, allocator, path);
    const loaded = try loadOrCreate(io, allocator, path);

    try std.testing.expectEqual(
        created.secret_key.toBytes(),
        loaded.secret_key.toBytes(),
    );

    const written = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(maximum_size));
    defer allocator.free(written);

    try std.testing.expectEqual(encoded_size, written.len);
    try std.testing.expectEqual(
        created.secret_key.toBytes(),
        (try decode(written)).secret_key.toBytes(),
    );

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "not a key" });
    try std.testing.expectError(
        error.InvalidKeyFile,
        loadOrCreate(io, allocator, path),
    );
}

test "PKCS#8 rejects inconsistent public keys and trailing nested data" {
    var encoded: [encoded_size]u8 = undefined;
    const key = try KeyPair.generateDeterministic(@splat(21));
    _ = encode(key, &encoded);
    const other = try KeyPair.generateDeterministic(@splat(22));
    @memcpy(encoded[public_key_offset..], &other.public_key.toUncompressedSec1());
    try std.testing.expectError(error.InvalidKeyFile, decode(&encoded));
    _ = encode(key, &encoded);
    encoded[scalar_offset + scalar_size] = 0xa2;
    try std.testing.expectError(error.InvalidKeyFile, decode(&encoded));
    _ = encode(key, &encoded);
    encoded[scalar_offset + scalar_size + 1] -= 1;
    try std.testing.expectError(error.InvalidKeyFile, decode(&encoded));
    _ = encode(key, &encoded);
    encoded[public_key_offset - 1] = 1;
    try std.testing.expectError(error.InvalidKeyFile, decode(&encoded));
    try std.testing.expectError(error.InvalidKeyFile, sequence(&.{ 0x30, 0x81, 1, 0 }, 0));
    try std.testing.expectError(error.InvalidKeyFile, sequence(&.{ 0x30, 0x82, 0, 128 }, 0));
}

test "concurrent identity creation publishes one complete key" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}/shared.der", .{tmp.sub_path});
    var tasks: [8]std.Io.Future(@typeInfo(@TypeOf(loadOrCreate)).@"fn".return_type.?) = undefined;
    var started: usize = 0;
    defer for (tasks[0..started]) |*task| {
        _ = task.cancel(io) catch {};
    };
    for (&tasks) |*task| {
        task.* = try io.concurrent(loadOrCreate, .{ io, std.testing.allocator, path });
        started += 1;
    }
    const expected = try tasks[0].await(io);
    for (tasks[1..]) |*task| {
        const actual = try task.await(io);
        try std.testing.expectEqualSlices(u8, &expected.secret_key.toBytes(), &actual.secret_key.toBytes());
    }
    const loaded = try loadOrCreate(io, std.testing.allocator, path);
    try std.testing.expectEqualSlices(u8, &expected.secret_key.toBytes(), &loaded.secret_key.toBytes());
}
