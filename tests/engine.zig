const std = @import("std");
const client = @import("client");
const win32 = client.win32;
const rio = client.rio;
const c = win32.c;

test "client Win32 owners transfer reset and destroy exactly once" {
    var socket: win32.Socket = .{};
    try std.testing.expectEqual(c.INVALID_SOCKET, socket.get());
    try std.testing.expectEqual(c.INVALID_SOCKET, socket.take());
    socket.reset(c.INVALID_SOCKET);
    socket.deinit();
    var handle: win32.Handle = .{};
    try std.testing.expect(handle.get() == null);
    handle.reset(null);
    handle.deinit();
    var memory = try win32.VirtualMemory.alloc(4096);
    const pointer = memory.take();
    memory.reset(pointer);
    memory.deinit();
    memory.deinit();
}

test "client registered sockets require overlapped RIO and ABI is exact" {
    try std.testing.expectEqual(c.WSA_FLAG_OVERLAPPED | c.WSA_FLAG_REGISTERED_IO, win32.registeredSocketFlags());
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(c.RIO_BUF));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(c.RIORESULT));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(c.OVERLAPPED));
}

test "client loads complete RIO table and ConnectEx" {
    var empty: c.RIO_EXTENSION_FUNCTION_TABLE = std.mem.zeroes(c.RIO_EXTENSION_FUNCTION_TABLE);
    try std.testing.expect(!rio.Api.tableComplete(&empty));
    var winsock = try win32.Winsock.init();
    defer winsock.deinit();
    const extensions = try rio.Extensions.load();
    try std.testing.expect(rio.Api.tableComplete(&extensions.rio.table));
    try std.testing.expect(extensions.connect_ex != null);
}
