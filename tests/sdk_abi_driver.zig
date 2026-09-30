const std = @import("std");
const client = @import("client");
const c = client.sdk.c;

pub fn main() u8 {
    var buffer: [1024]u8 = undefined;
    const output = std.fmt.bufPrint(&buffer, "WSADATA={d}\n" ++
        "SOCKADDR_IN={d}\n" ++
        "SOCKADDR_STORAGE={d}\n" ++
        "ADDRINFOW={d}\n" ++
        "OVERLAPPED={d}\n" ++
        "RIO_BUF={d}\n" ++
        "RIORESULT={d}\n" ++
        "RIO_NOTIFICATION_COMPLETION={d}\n" ++
        "RIO_EXTENSION_FUNCTION_TABLE={d}\n" ++
        "RIO_MSG_WAITALL={d}\n" ++
        "SO_UPDATE_CONNECT_CONTEXT={d}\n" ++
        "SOCKADDR_IN.sin_port={d}\n" ++
        "OVERLAPPED.hEvent={d}\n" ++
        "RIORESULT.RequestContext={d}\n" ++
        "RIO_NOTIFICATION_COMPLETION.Iocp={d}\n", .{
        @sizeOf(c.WSADATA),                      @sizeOf(c.SOCKADDR_IN),                   @sizeOf(c.SOCKADDR_STORAGE),                      @sizeOf(c.ADDRINFOW),
        @sizeOf(c.OVERLAPPED),                   @sizeOf(c.RIO_BUF),                       @sizeOf(c.RIORESULT),                             @sizeOf(c.RIO_NOTIFICATION_COMPLETION),
        @sizeOf(c.RIO_EXTENSION_FUNCTION_TABLE), c.RIO_MSG_WAITALL,                        c.SO_UPDATE_CONNECT_CONTEXT,                      @offsetOf(c.SOCKADDR_IN, "sin_port"),
        @offsetOf(c.OVERLAPPED, "hEvent"),       @offsetOf(c.RIORESULT, "RequestContext"), @offsetOf(c.RIO_NOTIFICATION_COMPLETION, "Iocp"),
    }) catch return 4;
    return if (client.win32.writeStdout(output)) 0 else 4;
}
