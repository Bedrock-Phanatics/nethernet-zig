const std = @import("std");
const builtin = @import("builtin");
const net = std.Io.net;
const Threaded = std.Io.Threaded;
const windows = std.os.windows;

/// Like vanilla, the port is never shared: a unicast signal to a shared 7551 reaches just one of its sockets.
/// Windows lets a later dual-stack or SO_REUSEADDR socket bind over ours unless it's exclusive.
pub fn bind(io: std.Io, address: net.IpAddress) !net.Socket {
    if (builtin.os.tag != .windows) return address.bind(io, .{
        .mode = .dgram,
        .protocol = .udp,
        .allow_broadcast = true,
    });
    try io.checkCancel();
    return bindWindows(io, address);
}

fn bindWindows(io: std.Io, address: net.IpAddress) !net.Socket {
    const ws = windows.ws2_32;
    var handle: windows.HANDLE = undefined;
    var status: windows.IO_STATUS_BLOCK = undefined;
    // An AFD handle matches how std.Io manages sockets.
    switch (windows.ntdll.NtCreateFile(
        &handle,
        .{
            .STANDARD = .{ .RIGHTS = .{ .WRITE_DAC = true }, .SYNCHRONIZE = true },
            .GENERIC = .{ .WRITE = true, .READ = true },
        },
        &.{ .ObjectName = @constCast(&windows.UNICODE_STRING.init(
            windows.AFD.DEVICE_NAME ++ .{ '\\', 'E', 'n', 'd', 'p', 'o', 'i', 'n', 't' },
        )) },
        &status,
        null,
        .{},
        .{ .READ = true, .WRITE = true },
        .OPEN_IF,
        .{ .IO = .ASYNCHRONOUS },
        &windows.AFD.OPEN_PACKET.FULL_EA_INFORMATION{ .Value = .{
            .EndpointType = .{ .CONNECTIONLESS = true, .MESSAGEMODE = true, .RAW = false },
            .GroupID = 0,
            .AddressFamily = Threaded.posixAddressFamily(&address),
            .SocketType = ws.SOCK.DGRAM,
            .Protocol = @backingInt(net.Protocol.udp),
            .TransportDeviceNameLength = 0,
            .TransportDeviceName = undefined,
        } },
        @sizeOf(windows.AFD.OPEN_PACKET.FULL_EA_INFORMATION),
    )) {
        .SUCCESS => {},
        .CANCELLED => return error.Canceled,
        .PROTOCOL_NOT_SUPPORTED => return error.AddressFamilyUnsupported,
        .NO_SUCH_FILE => return error.ProtocolUnsupportedByAddressFamily,
        else => |err| return windows.unexpectedStatus(err),
    }
    errdefer windows.CloseHandle(handle);

    const enabled: u32 = 1;
    try control(io, .{
        .file = .{ .handle = handle, .flags = .{ .nonblocking = true } },
        .code = windows.IOCTL.AFD.SOCKOPT,
        .in = std.mem.asBytes(&windows.AFD.SOCKOPT_INFO{
            .mode = .set,
            .level = ws.SOL.SOCKET,
            .optname = ws.SO.BROADCAST,
            .optval = &enabled,
            .optlen = @sizeOf(@TypeOf(enabled)),
        }),
    });

    const Storage = extern struct { info: windows.AFD.BIND_INFO, address: Threaded.PosixAddress };
    // AFD_SHARE_EXCLUSIVE, what SO_EXCLUSIVEADDRUSE becomes.
    var storage: Storage = .{ .info = .{ .Mode = @fromBackingInt(@intCast(3)) }, .address = undefined };
    const length = Threaded.addressToPosix(&address, &storage.address);
    try control(io, .{
        .file = .{ .handle = handle, .flags = .{ .nonblocking = true } },
        .code = windows.IOCTL.AFD.BIND,
        .in = std.mem.asBytes(&storage)[0 .. @offsetOf(Storage, "address") + length],
        .out = std.mem.asBytes(&storage.address)[0..length],
    });
    return .{ .handle = handle, .address = Threaded.addressFromPosix(&storage.address) };
}

fn control(io: std.Io, operation: std.Io.Operation.DeviceIoControl) !void {
    const result = try io.operate(.{ .device_io_control = operation });
    switch (result.device_io_control.u.Status) {
        .SUCCESS => {},
        .CANCELLED => return error.Canceled,
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        .SHARING_VIOLATION, .ADDRESS_ALREADY_EXISTS => return error.AddressInUse,
        .ACCESS_DENIED => return error.AccessDenied,
        else => |status| return windows.unexpectedStatus(status),
    }
}
