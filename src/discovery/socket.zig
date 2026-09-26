const std = @import("std");
const builtin = @import("builtin");
const net = std.Io.net;
const Threaded = std.Io.Threaded;
const windows = std.os.windows;

pub fn bind(io: std.Io, address: net.IpAddress) !net.Socket {
    if (address.getPort() != 7551) return address.bind(io, .{
        .mode = .dgram,
        .protocol = .udp,
        .allow_broadcast = true,
    });

    try io.checkCancel();
    if (builtin.os.tag == .windows) return bindWindows(io, address);
    return bindPosix(io, address);
}

fn bindWindows(io: std.Io, address: net.IpAddress) !net.Socket {
    const ws = windows.ws2_32;
    var handle: windows.HANDLE = undefined;
    var status: windows.IO_STATUS_BLOCK = undefined;
    // Use an AFD handle, matching std.Io's socket lifecycle.
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
            .Protocol = @intFromEnum(net.Protocol.udp),
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
    for ([_]u32{ ws.SO.BROADCAST, ws.SO.REUSEADDR }) |option| {
        try control(io, .{
            .file = .{ .handle = handle, .flags = .{ .nonblocking = true } },
            .code = windows.IOCTL.AFD.SOCKOPT,
            .in = std.mem.asBytes(&windows.AFD.SOCKOPT_INFO{
                .mode = .set,
                .level = ws.SOL.SOCKET,
                .optname = option,
                .optval = &enabled,
                .optlen = @sizeOf(@TypeOf(enabled)),
            }),
        });
    }

    const Storage = extern struct { info: windows.AFD.BIND_INFO, address: Threaded.PosixAddress };
    var storage: Storage = .{ .info = .{ .Mode = .Active }, .address = undefined };
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

fn bindPosix(io: std.Io, address: net.IpAddress) !net.Socket {
    const posix = std.posix;
    const has_cloexec = @hasDecl(posix.SOCK, "CLOEXEC");
    const flags = posix.SOCK.DGRAM | if (has_cloexec) posix.SOCK.CLOEXEC else 0;
    const fd: posix.socket_t = while (true) {
        const rc = posix.system.socket(Threaded.posixAddressFamily(&address), flags, @intFromEnum(net.Protocol.udp));
        switch (posix.errno(rc)) {
            .SUCCESS => break @intCast(rc),
            .INTR => try io.checkCancel(),
            .AFNOSUPPORT => return error.AddressFamilyUnsupported,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS, .NOMEM => return error.SystemResources,
            else => |err| return posix.unexpectedErrno(err),
        }
    };
    errdefer Threaded.closeFd(fd);
    if (!has_cloexec) {
        while (true) switch (posix.errno(posix.system.fcntl(fd, posix.F.SETFD, @as(usize, posix.FD_CLOEXEC)))) {
            .SUCCESS => break,
            .INTR => try io.checkCancel(),
            else => |err| return posix.unexpectedErrno(err),
        };
    }
    const enabled: c_int = 1;
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.BROADCAST, std.mem.asBytes(&enabled));
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&enabled));
    var storage: Threaded.PosixAddress = undefined;
    const length = Threaded.addressToPosix(&address, &storage);
    while (true) switch (posix.errno(posix.system.bind(fd, &storage.any, length))) {
        .SUCCESS => break,
        .INTR => try io.checkCancel(),
        .ADDRINUSE => return error.AddressInUse,
        .ACCES => return error.AccessDenied,
        .ADDRNOTAVAIL => return error.AddressUnavailable,
        .AFNOSUPPORT => return error.AddressFamilyUnsupported,
        .NOMEM => return error.SystemResources,
        else => |err| return posix.unexpectedErrno(err),
    };
    return .{ .handle = fd, .address = address };
}
