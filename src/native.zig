//! Windows x64 ABI, Winsock, RIO and every native resource owner the client uses.
//!
//! The dependency direction is one-way: this file never imports a state machine, so a module that
//! describes protocol behaviour can depend on it without ever being depended on in return. The
//! nested namespaces are compile-time containers; none of them has a runtime instance, a vtable or
//! a heap allocation of its own.

const std = @import("std");
const types = @import("types.zig");

/// The Windows SDK surface. Everything below the ABI line lives here, so a layout assumption is
/// stated once and can be checked with @sizeOf/@offsetOf at compile time.
pub const sdk = struct {
    pub const c = struct {
        pub const BOOL = c_int;
        pub const DWORD = u32;
        pub const ULONG = u32;
        pub const ULONG_PTR = usize;
        pub const SOCKET = usize;
        pub const HANDLE = ?*anyopaque;
        pub const GUID = extern struct { Data1: u32, Data2: u16, Data3: u16, Data4: [8]u8 };
        pub const LARGE_INTEGER = extern struct { QuadPart: i64 };

        pub const TRUE: BOOL = 1;
        pub const FALSE: BOOL = 0;
        pub const INVALID_SOCKET: SOCKET = std.math.maxInt(SOCKET);
        pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
        pub const AF_INET: c_int = 2;
        pub const SOCK_STREAM: c_int = 1;
        pub const SOCK_DGRAM: c_int = 2;
        pub const IPPROTO_TCP: c_int = 6;
        pub const IPPROTO_UDP: c_int = 17;
        pub const SOL_SOCKET: c_int = 0xffff;
        pub const SO_SNDBUF: c_int = 0x1001;
        pub const SO_RCVBUF: c_int = 0x1002;
        pub const SO_UPDATE_CONNECT_CONTEXT: c_int = 0x7010;
        pub const TCP_NODELAY: c_int = 1;
        pub const INADDR_ANY: u32 = 0;
        pub const WSA_FLAG_OVERLAPPED: DWORD = 0x01;
        pub const WSA_FLAG_REGISTERED_IO: DWORD = 0x100;
        pub const SIO_GET_EXTENSION_FUNCTION_POINTER: DWORD = 0xC8000006;
        pub const SIO_GET_MULTIPLE_EXTENSION_FUNCTION_POINTER: DWORD = 0xC8000024;
        pub const RIO_MSG_WAITALL: DWORD = 0x00000004;
        pub const ERROR_SUCCESS: DWORD = 0;
        pub const ERROR_NOT_ENOUGH_MEMORY: DWORD = 8;
        pub const ERROR_INVALID_DATA: DWORD = 13;
        pub const ERROR_INSUFFICIENT_BUFFER: DWORD = 122;
        pub const ERROR_ARITHMETIC_OVERFLOW: DWORD = 534;
        pub const WAIT_TIMEOUT: DWORD = 258;
        pub const WAIT_OBJECT_0: DWORD = 0;
        pub const ERROR_IO_PENDING: DWORD = 997;
        pub const ERROR_IO_INCOMPLETE: DWORD = 996;
        pub const ERROR_INVALID_STATE: DWORD = 5023;
        pub const INFINITE: DWORD = 0xffffffff;
        pub const MEM_COMMIT: DWORD = 0x1000;
        pub const MEM_RESERVE: DWORD = 0x2000;
        pub const MEM_RELEASE: DWORD = 0x8000;
        pub const PAGE_READWRITE: DWORD = 0x04;
        pub const CTRL_C_EVENT: DWORD = 0;
        pub const CTRL_BREAK_EVENT: DWORD = 1;
        pub const CTRL_CLOSE_EVENT: DWORD = 2;
        pub const STD_OUTPUT_HANDLE: DWORD = 0xfffffff5;
        pub const STD_ERROR_HANDLE: DWORD = 0xfffffff4;
        pub const ALL_PROCESSOR_GROUPS: u16 = 0xffff;

        pub const WSADATA = extern struct {
            wVersion: u16,
            wHighVersion: u16,
            iMaxSockets: u16,
            iMaxUdpDg: u16,
            lpVendorInfo: ?[*:0]u8,
            szDescription: [257]u8,
            szSystemStatus: [129]u8,
        };
        pub const OVERLAPPED = extern struct {
            Internal: ULONG_PTR,
            InternalHigh: ULONG_PTR,
            data: extern union {
                offsets: extern struct { Offset: DWORD, OffsetHigh: DWORD },
                Pointer: ?*anyopaque,
            },
            hEvent: HANDLE,
        };
        pub const IN_ADDR = extern struct { S_un: extern union {
            S_un_b: extern struct { s_b1: u8, s_b2: u8, s_b3: u8, s_b4: u8 },
            S_un_w: extern struct { s_w1: u16, s_w2: u16 },
            S_addr: u32,
        } };
        pub const SOCKADDR = extern struct { sa_family: u16, sa_data: [14]u8 };
        pub const SOCKADDR_IN = extern struct { sin_family: u16, sin_port: u16, sin_addr: IN_ADDR, sin_zero: [8]u8 };
        pub const SOCKADDR_STORAGE = extern struct { ss_family: u16, __ss_pad1: [6]u8, __ss_align: i64, __ss_pad2: [112]u8 };
        pub const ADDRINFOW = extern struct {
            ai_flags: c_int,
            ai_family: c_int,
            ai_socktype: c_int,
            ai_protocol: c_int,
            ai_addrlen: usize,
            ai_canonname: ?[*:0]u16,
            ai_addr: ?*SOCKADDR,
            ai_next: ?*ADDRINFOW,
        };

        const RIO_BUFFERID_t = opaque {};
        const RIO_CQ_t = opaque {};
        const RIO_RQ_t = opaque {};
        pub const RIO_BUFFERID = ?*RIO_BUFFERID_t;
        pub const RIO_CQ = ?*RIO_CQ_t;
        pub const RIO_RQ = ?*RIO_RQ_t;
        pub const RIO_INVALID_BUFFERID: RIO_BUFFERID = @ptrFromInt(0xffffffff);
        pub const RIO_INVALID_CQ: RIO_CQ = null;
        pub const RIO_INVALID_RQ: RIO_RQ = null;
        pub const RIO_CORRUPT_CQ: ULONG = 0xffffffff;
        pub const RIO_IOCP_COMPLETION: c_int = 2;
        pub const RIO_BUF = extern struct { BufferId: RIO_BUFFERID, Offset: ULONG, Length: ULONG };
        pub const RIORESULT = extern struct { Status: i32, BytesTransferred: ULONG, SocketContext: ?*anyopaque, RequestContext: ?*anyopaque };
        pub const RIO_NOTIFICATION_COMPLETION = extern struct {
            Type: c_int,
            Iocp: extern struct { IocpHandle: HANDLE, CompletionKey: ?*anyopaque, Overlapped: ?*anyopaque },
        };
        pub const LPFN_RIORECEIVE = *const fn (RIO_RQ, [*c]RIO_BUF, ULONG, DWORD, ?*anyopaque) callconv(.winapi) BOOL;
        pub const LPFN_RIORECEIVEEX = *const fn (RIO_RQ, [*c]RIO_BUF, ULONG, ?*RIO_BUF, ?*RIO_BUF, ?*RIO_BUF, ?*RIO_BUF, DWORD, ?*anyopaque) callconv(.winapi) BOOL;
        pub const LPFN_RIOSEND = *const fn (RIO_RQ, [*c]RIO_BUF, ULONG, DWORD, ?*anyopaque) callconv(.winapi) BOOL;
        pub const LPFN_RIOSENDEX = *const fn (RIO_RQ, [*c]RIO_BUF, ULONG, ?*RIO_BUF, ?*RIO_BUF, ?*RIO_BUF, ?*RIO_BUF, DWORD, ?*anyopaque) callconv(.winapi) BOOL;
        pub const LPFN_RIOCLOSECOMPLETIONQUEUE = *const fn (RIO_CQ) callconv(.winapi) void;
        pub const LPFN_RIOCREATECOMPLETIONQUEUE = *const fn (DWORD, ?*RIO_NOTIFICATION_COMPLETION) callconv(.winapi) RIO_CQ;
        pub const LPFN_RIOCREATEREQUESTQUEUE = *const fn (SOCKET, ULONG, ULONG, ULONG, ULONG, RIO_CQ, RIO_CQ, ?*anyopaque) callconv(.winapi) RIO_RQ;
        pub const LPFN_RIODEQUEUECOMPLETION = *const fn (RIO_CQ, [*c]RIORESULT, ULONG) callconv(.winapi) ULONG;
        pub const LPFN_RIODEREGISTERBUFFER = *const fn (RIO_BUFFERID) callconv(.winapi) void;
        pub const LPFN_RIONOTIFY = *const fn (RIO_CQ) callconv(.winapi) c_int;
        pub const LPFN_RIOREGISTERBUFFER = *const fn ([*c]u8, DWORD) callconv(.winapi) RIO_BUFFERID;
        pub const LPFN_RIORESIZECOMPLETIONQUEUE = *const fn (RIO_CQ, DWORD) callconv(.winapi) BOOL;
        pub const LPFN_RIORESIZEREQUESTQUEUE = *const fn (RIO_RQ, DWORD, DWORD) callconv(.winapi) BOOL;
        pub const LPFN_CONNECTEX = *const fn (SOCKET, *const SOCKADDR, c_int, ?*const anyopaque, DWORD, ?*DWORD, *OVERLAPPED) callconv(.winapi) BOOL;
        pub const RIO_EXTENSION_FUNCTION_TABLE = extern struct {
            cbSize: DWORD,
            RIOReceive: ?LPFN_RIORECEIVE,
            RIOReceiveEx: ?LPFN_RIORECEIVEEX,
            RIOSend: ?LPFN_RIOSEND,
            RIOSendEx: ?LPFN_RIOSENDEX,
            RIOCloseCompletionQueue: ?LPFN_RIOCLOSECOMPLETIONQUEUE,
            RIOCreateCompletionQueue: ?LPFN_RIOCREATECOMPLETIONQUEUE,
            RIOCreateRequestQueue: ?LPFN_RIOCREATEREQUESTQUEUE,
            RIODequeueCompletion: ?LPFN_RIODEQUEUECOMPLETION,
            RIODeregisterBuffer: ?LPFN_RIODEREGISTERBUFFER,
            RIONotify: ?LPFN_RIONOTIFY,
            RIORegisterBuffer: ?LPFN_RIOREGISTERBUFFER,
            RIOResizeCompletionQueue: ?LPFN_RIORESIZECOMPLETIONQUEUE,
            RIOResizeRequestQueue: ?LPFN_RIORESIZEREQUESTQUEUE,
        };
        pub const WSAID_MULTIPLE_RIO: GUID = .{ .Data1 = 0x8509e081, .Data2 = 0x96dd, .Data3 = 0x4005, .Data4 = .{ 0xb1, 0x65, 0x9e, 0x2e, 0xe8, 0xc7, 0x9e, 0x3f } };
        pub const WSAID_CONNECTEX: GUID = .{ .Data1 = 0x25a207b9, .Data2 = 0xddf3, .Data3 = 0x4660, .Data4 = .{ 0x8e, 0xe9, 0x76, 0xe5, 0x8c, 0x74, 0x06, 0x3e } };

        pub extern fn WSAStartup(u16, *WSADATA) callconv(.winapi) c_int;
        pub extern fn WSACleanup() callconv(.winapi) c_int;
        pub extern fn WSAGetLastError() callconv(.winapi) c_int;
        pub extern fn WSASocketW(c_int, c_int, c_int, ?*anyopaque, u32, DWORD) callconv(.winapi) SOCKET;
        pub extern fn closesocket(SOCKET) callconv(.winapi) c_int;
        pub extern fn setsockopt(SOCKET, c_int, c_int, [*c]const u8, c_int) callconv(.winapi) c_int;
        pub extern fn bind(SOCKET, *const SOCKADDR, c_int) callconv(.winapi) c_int;
        pub extern fn connect(SOCKET, *const SOCKADDR, c_int) callconv(.winapi) c_int;
        pub extern fn WSAIoctl(SOCKET, DWORD, ?*anyopaque, DWORD, ?*anyopaque, DWORD, *DWORD, ?*OVERLAPPED, ?*anyopaque) callconv(.winapi) c_int;
        pub extern fn WSAGetOverlappedResult(SOCKET, *OVERLAPPED, *DWORD, BOOL, *DWORD) callconv(.winapi) BOOL;
        pub extern fn GetAddrInfoW(?[*:0]const u16, ?[*:0]const u16, ?*const ADDRINFOW, *[*c]ADDRINFOW) callconv(.winapi) c_int;
        pub extern fn FreeAddrInfoW([*c]ADDRINFOW) callconv(.winapi) void;
        pub extern fn htons(u16) callconv(.winapi) u16;
        pub extern fn htonl(u32) callconv(.winapi) u32;
        pub extern fn GetLastError() callconv(.winapi) DWORD;
        pub extern fn GetCurrentProcess() callconv(.winapi) HANDLE;
        pub extern fn TerminateProcess(HANDLE, u32) callconv(.winapi) BOOL;
        pub extern fn GetStdHandle(DWORD) callconv(.winapi) HANDLE;
        pub extern fn WriteFile(HANDLE, [*]const u8, DWORD, *DWORD, ?*OVERLAPPED) callconv(.winapi) BOOL;
        pub extern fn CloseHandle(HANDLE) callconv(.winapi) BOOL;
        pub extern fn VirtualAlloc(?*anyopaque, usize, DWORD, DWORD) callconv(.winapi) ?*anyopaque;
        pub extern fn VirtualFree(?*anyopaque, usize, DWORD) callconv(.winapi) BOOL;
        pub extern fn CreateIoCompletionPort(HANDLE, HANDLE, ULONG_PTR, DWORD) callconv(.winapi) HANDLE;
        pub extern fn GetQueuedCompletionStatus(HANDLE, *DWORD, *ULONG_PTR, *[*c]OVERLAPPED, DWORD) callconv(.winapi) BOOL;
        pub extern fn PostQueuedCompletionStatus(HANDLE, DWORD, ULONG_PTR, ?*OVERLAPPED) callconv(.winapi) BOOL;
        pub extern fn CreateEventW(?*anyopaque, BOOL, BOOL, ?[*:0]const u16) callconv(.winapi) HANDLE;
        pub extern fn SetEvent(HANDLE) callconv(.winapi) BOOL;
        pub extern fn WaitForSingleObject(HANDLE, DWORD) callconv(.winapi) DWORD;
        pub extern fn CreateThread(?*anyopaque, usize, *const fn (?*anyopaque) callconv(.winapi) DWORD, ?*anyopaque, DWORD, ?*DWORD) callconv(.winapi) HANDLE;
        pub extern fn GetTickCount64() callconv(.winapi) u64;
        pub extern fn GetActiveProcessorCount(u16) callconv(.winapi) DWORD;
        pub extern fn Sleep(DWORD) callconv(.winapi) void;
        pub extern fn QueryPerformanceCounter(*LARGE_INTEGER) callconv(.winapi) BOOL;
        pub extern fn QueryPerformanceFrequency(*LARGE_INTEGER) callconv(.winapi) BOOL;
        pub extern fn SetConsoleCtrlHandler(?*const fn (DWORD) callconv(.winapi) BOOL, BOOL) callconv(.winapi) BOOL;
        /// The multimedia timer resolution request. QPC measures elapsed time; this asks the
        /// scheduler for a finer wait granularity, and the two are not substitutes.
        pub extern fn timeBeginPeriod(period: u32) callconv(.winapi) u32;
        pub extern fn timeEndPeriod(period: u32) callconv(.winapi) u32;
        pub extern fn getenv([*:0]const u8) callconv(.c) ?[*:0]u8;
    };

    comptime {
        // Windows x64 is the only target this project claims, and the layout is checked rather than
        // assumed: a wrong field offset would surface as silent memory corruption. Every value below
        // is the one the Microsoft SDK headers produce, and the test gate that compiles the same
        // measurements with cl.exe re-checks all of them against the installed SDK. The ABI struct
        // is named in full because this container also declares it.
        const abi = sdk.c;
        if (@sizeOf(usize) != 8) @compileError("the client targets 64-bit Windows only");
        if (@sizeOf(abi.LARGE_INTEGER) != 8) @compileError("LARGE_INTEGER must be 8 bytes");
        if (@sizeOf(abi.GUID) != 16) @compileError("GUID must be 16 bytes");
        if (@sizeOf(abi.OVERLAPPED) != 32) @compileError("OVERLAPPED must be 32 bytes on x64");
        if (@offsetOf(abi.OVERLAPPED, "hEvent") != 24) @compileError("OVERLAPPED.hEvent must be at offset 24");
        if (@sizeOf(abi.SOCKADDR_IN) != 16) @compileError("SOCKADDR_IN must be 16 bytes");
        if (@offsetOf(abi.SOCKADDR_IN, "sin_port") != 2) @compileError("SOCKADDR_IN.sin_port must be at offset 2");
        if (@sizeOf(abi.SOCKADDR_STORAGE) != 128) @compileError("SOCKADDR_STORAGE must be 128 bytes");
        if (@sizeOf(abi.ADDRINFOW) != 48) @compileError("ADDRINFOW must be 48 bytes");
        if (@sizeOf(abi.RIO_BUF) != 16) @compileError("RIO_BUF must be 16 bytes");
        // LONG + ULONG + two pointers.
        if (@sizeOf(abi.RIORESULT) != 24) @compileError("RIORESULT must be 24 bytes");
        if (@offsetOf(abi.RIORESULT, "RequestContext") != 16) @compileError("RIORESULT.RequestContext must be at offset 16");
        // The completion type, then a union whose Iocp arm is the larger of its two members.
        if (@sizeOf(abi.RIO_NOTIFICATION_COMPLETION) != 32) @compileError("RIO_NOTIFICATION_COMPLETION must be 32 bytes");
        if (@offsetOf(abi.RIO_NOTIFICATION_COMPLETION, "Iocp") != 8) @compileError("RIO_NOTIFICATION_COMPLETION.Iocp must be at offset 8");
        // ULONG cbSize, then thirteen entry points.
        if (@sizeOf(abi.RIO_EXTENSION_FUNCTION_TABLE) != 112) @compileError("RIO_EXTENSION_FUNCTION_TABLE must be 112 bytes");
    }
};

const c = sdk.c;

/// Console and error reporting. Every native failure is described here so no call site has to
/// invent its own wording.
pub const diagnostics = struct {
    pub fn writeAll(handle_value: c.HANDLE, bytes: []const u8) bool {
        if (handle_value == null or handle_value == c.INVALID_HANDLE_VALUE) return false;
        var offset: usize = 0;
        while (offset < bytes.len) {
            var written: c.DWORD = 0;
            const amount: c.DWORD = @intCast(@min(bytes.len - offset, std.math.maxInt(c.DWORD)));
            if (c.WriteFile(handle_value, bytes[offset..].ptr, amount, &written, null) == c.FALSE or written == 0) return false;
            offset += written;
        }
        return true;
    }

    pub fn writeStdout(bytes: []const u8) bool {
        return writeAll(c.GetStdHandle(c.STD_OUTPUT_HANDLE), bytes);
    }

    pub fn writeStderr(bytes: []const u8) bool {
        return writeAll(c.GetStdHandle(c.STD_ERROR_HANDLE), bytes);
    }

    pub fn report(stage: []const u8, native_error: u32) void {
        var buffer: [512]u8 = undefined;
        const output = std.fmt.bufPrint(&buffer, "{s} failed: native_error={d}\n", .{ stage, native_error }) catch return;
        _ = writeStderr(output);
    }

    /// A failure that leaves the process unable to make progress. The reference terminates rather
    /// than unwinding, because releasing registered memory while a provider still owns it would be
    /// worse than exiting.
    pub fn failFast(stage: []const u8, native_error: u32) noreturn {
        report(stage, native_error);
        _ = c.TerminateProcess(c.GetCurrentProcess(), 4);
        unreachable;
    }
};

pub const winsock = struct {
    pub const Winsock = struct {
        started: bool = false,

        pub fn init() !Winsock {
            var data: c.WSADATA = undefined;
            const status = c.WSAStartup(0x0202, &data);
            if (status != 0) {
                diagnostics.report("WSAStartup", @intCast(status));
                return error.WsaStartup;
            }
            return .{ .started = true };
        }

        pub fn deinit(self: *Winsock) void {
            if (self.started) {
                _ = c.WSACleanup();
                self.started = false;
            }
        }
    };
};

pub const handle = struct {
    /// A kernel handle owner. Handles are closed explicitly rather than at process exit.
    pub const Handle = struct {
        value: c.HANDLE = null,

        pub fn get(self: *const Handle) c.HANDLE {
            return self.value;
        }

        pub fn deinit(self: *Handle) void {
            if (self.value != null and self.value != c.INVALID_HANDLE_VALUE) {
                _ = c.CloseHandle(self.value);
                self.value = null;
            }
        }

        pub fn take(self: *Handle) c.HANDLE {
            const value = self.value;
            self.value = null;
            return value;
        }

        pub fn reset(self: *Handle, value: c.HANDLE) void {
            self.deinit();
            self.value = value;
        }
    };

    pub const ThreadHandle = Handle;
    pub const EventHandle = Handle;
};

pub const socket = struct {
    /// A socket owner. Closing the socket starts cancellation of its pending I/O; it does not end
    /// the lifetime of that I/O, which is why the request queue and registered windows must outlive
    /// the close until every completion has been dequeued.
    pub const Socket = struct {
        value: c.SOCKET = c.INVALID_SOCKET,

        pub fn get(self: *const Socket) c.SOCKET {
            return self.value;
        }

        pub fn deinit(self: *Socket) void {
            if (self.value != c.INVALID_SOCKET) {
                _ = c.closesocket(self.value);
                self.value = c.INVALID_SOCKET;
            }
        }

        pub fn take(self: *Socket) c.SOCKET {
            const value = self.value;
            self.value = c.INVALID_SOCKET;
            return value;
        }

        pub fn reset(self: *Socket, value: c.SOCKET) void {
            self.deinit();
            self.value = value;
        }
    };

    /// Registered I/O requires a socket created with the registered-IO flag; there is no fallback
    /// backend in this client.
    pub fn registeredFlags() c.DWORD {
        return c.WSA_FLAG_OVERLAPPED | c.WSA_FLAG_REGISTERED_IO;
    }

    pub fn registered(socket_type: c_int, protocol: c_int) c.SOCKET {
        return c.WSASocketW(c.AF_INET, socket_type, protocol, null, 0, registeredFlags());
    }

    pub fn configure(value: c.SOCKET, socket_buffer_bytes: u32, tcp: bool) bool {
        if (socket_buffer_bytes != 0) {
            var size: c_int = @intCast(socket_buffer_bytes);
            const pointer: [*c]const u8 = @ptrCast(&size);
            if (c.setsockopt(value, c.SOL_SOCKET, c.SO_SNDBUF, pointer, @intCast(@sizeOf(c_int))) != 0 or
                c.setsockopt(value, c.SOL_SOCKET, c.SO_RCVBUF, pointer, @intCast(@sizeOf(c_int))) != 0)
            {
                diagnostics.report("setsockopt(SO_SNDBUF/SO_RCVBUF)", @intCast(c.WSAGetLastError()));
                return false;
            }
        }
        if (tcp) {
            var enabled: c.BOOL = c.TRUE;
            const pointer: [*c]const u8 = @ptrCast(&enabled);
            if (c.setsockopt(value, c.IPPROTO_TCP, c.TCP_NODELAY, pointer, @intCast(@sizeOf(c.BOOL))) != 0) {
                diagnostics.report("setsockopt(TCP_NODELAY)", @intCast(c.WSAGetLastError()));
                return false;
            }
        }
        return true;
    }
};

/// Registered memory. The arena owns exactly one virtual allocation and every registration that
/// points into it, so the deregister-before-unmap order cannot be got wrong at a call site.
pub const arena = struct {
    const allocator = std.heap.page_allocator;

    pub const VirtualMemory = struct {
        pointer: ?*anyopaque = null,

        pub fn alloc(byte_count: usize) !VirtualMemory {
            const base = c.VirtualAlloc(null, byte_count, c.MEM_RESERVE | c.MEM_COMMIT, c.PAGE_READWRITE);
            if (base == null) return error.VirtualAlloc;
            return .{ .pointer = base };
        }

        pub fn bytes(self: *const VirtualMemory) [*]u8 {
            return @ptrCast(self.pointer.?);
        }

        pub fn deinit(self: *VirtualMemory) void {
            if (self.pointer) |base| {
                _ = c.VirtualFree(base, 0, c.MEM_RELEASE);
                self.pointer = null;
            }
        }
    };

    pub const CreateError = error{ Capacity, Registration, Allocation, VirtualAlloc };

    /// Total registered bytes one worker owns: a TX window and an RX window per slot.
    pub fn workerBytes(slots: u32, stride: u32) ?u32 {
        if (slots == 0 or stride == 0) return null;
        const one_direction = types.checkedProduct(u32, slots, stride) orelse return null;
        return types.checkedProduct(u32, one_direction, 2);
    }

    /// Byte offset of one slot inside a direction region, checked against that region's size.
    pub fn slotOffset(slot: u32, stride: u32, total: usize) ?usize {
        if (stride == 0) return null;
        const offset = types.checkedProduct(usize, slot, stride) orelse return null;
        const end = types.checkedAdd(usize, offset, stride) orelse return null;
        return if (end <= total) offset else null;
    }

    /// One worker-owned virtual allocation for both directions of registered RIO memory.
    ///
    /// TX windows precede RX windows, and each slot has a disjoint window in each region. RX uses
    /// one registration over the whole region because the documented RIOReceive contract permits
    /// independent receives in non-overlapping parts of one registration. TX uses one registration
    /// per window because the documented RIOSend contract prohibits using any other portion of its
    /// registration while the send is pending, even when those portions would otherwise be
    /// disjoint.
    pub const Arena = struct {
        pages: VirtualMemory = .{},
        bytes: usize = 0,
        stride: u32 = 0,
        slots: u32 = 0,
        receive_offset: usize = 0,
        send_registrations: []rio.Registration = &.{},
        receive_registration: rio.Registration = .{},

        pub fn create(api: *const rio.Api, slots: u32, stride: u32) CreateError!Arena {
            const bytes = workerBytes(slots, stride) orelse return error.Capacity;
            var pages = try VirtualMemory.alloc(bytes);
            errdefer pages.deinit();
            const registrations = allocator.alloc(rio.Registration, slots) catch return error.Allocation;
            var registered: u32 = 0;
            errdefer {
                for (registrations[0..registered]) |*registration| registration.deinit();
                allocator.free(registrations);
            }
            const base = pages.bytes();
            const receive_offset: usize = bytes / 2;
            for (0..slots) |slot| {
                const start: usize = slot * stride;
                registrations[slot] = .{};
                registrations[slot].reset(api, api.registerBuffer(base + start, stride));
                if (!registrations[slot].valid()) return error.Registration;
                registered += 1;
            }
            var receive_registration: rio.Registration = .{};
            receive_registration.reset(api, api.registerBuffer(base + receive_offset, @intCast(receive_offset)));
            if (!receive_registration.valid()) return error.Registration;
            return .{
                .pages = pages,
                .bytes = bytes,
                .stride = stride,
                .slots = slots,
                .receive_offset = receive_offset,
                .send_registrations = registrations,
                .receive_registration = receive_registration,
            };
        }

        /// Deregisters every buffer while its memory is still mapped, and only then releases the
        /// single page owner. The order is the arena's invariant, not a caller's choice.
        pub fn deinit(self: *Arena) void {
            for (self.send_registrations) |*registration| registration.deinit();
            if (self.send_registrations.len != 0) allocator.free(self.send_registrations);
            self.send_registrations = &.{};
            self.receive_registration.deinit();
            self.pages.deinit();
            self.* = .{};
        }

        /// The writable TX window of one slot, used to fill the deterministic payload before any
        /// send is posted.
        pub fn sendBytes(self: *Arena, slot: u32, length: u32) ?[]u8 {
            if (slot >= self.slots or length == 0 or length > self.stride) return null;
            const offset = slotOffset(slot, self.stride, self.receive_offset) orelse return null;
            return self.pages.bytes()[offset .. offset + length];
        }

        /// The RX window of one slot. Its bytes are only meaningful after the matching receive
        /// completion has been dequeued and before that slot is reposted.
        pub fn receiveBytes(self: *const Arena, slot: u32, length: u32) ?[]const u8 {
            if (slot >= self.slots or length == 0 or length > self.stride) return null;
            const offset = slotOffset(slot, self.stride, self.receive_offset) orelse return null;
            const start = self.receive_offset + offset;
            return self.pages.bytes()[start .. start + length];
        }

        pub fn sendView(self: *const Arena, slot: u32, length: u32) ?c.RIO_BUF {
            return self.sendViewFrom(slot, 0, length);
        }

        /// A view of part of a TX window, used to re-post the remainder of a partially completed
        /// send without touching the registration that is still owned by the pending operation.
        pub fn sendViewFrom(self: *const Arena, slot: u32, offset: u32, length: u32) ?c.RIO_BUF {
            if (slot >= self.send_registrations.len) return null;
            if (offset > self.stride or length > self.stride - offset) return null;
            return self.send_registrations[slot].slice(offset, length);
        }

        pub fn receiveView(self: *const Arena, slot: u32, length: u32) ?c.RIO_BUF {
            if (slot >= self.slots or length == 0 or length > self.stride) return null;
            const offset = slotOffset(slot, self.stride, self.receive_offset) orelse return null;
            return self.receive_registration.slice(@intCast(offset), length);
        }

        pub fn registeredBytes(self: *const Arena) usize {
            return self.bytes;
        }
    };
};

/// The native state of one session's current transport generation.
///
/// The business machine in internal.zig decides what should happen; this record owns what the
/// kernel owns. Keeping the two apart is what lets a session transition be reasoned about without a
/// socket, and it is why only engine.zig ever touches these fields.
pub const transport = struct {
    pub const Slot = struct {
        socket: socket.Socket = .{},
        /// The request queue dies with its socket, so it is tracked, never closed separately.
        request_queue: c.RIO_RQ = c.RIO_INVALID_RQ,
        connect_overlapped: c.OVERLAPPED = std.mem.zeroes(c.OVERLAPPED),
        connect_outstanding: bool = false,
        send_outstanding: u32 = 0,
        receive_outstanding: u32 = 0,
        send_posted_bytes: u32 = 0,
        receive_posted_bytes: u32 = 0,

        /// Operations the provider still owns. A generation may not be released while this is
        /// non-zero: closing a socket starts cancellation, it does not end the I/O.
        pub fn outstanding(self: *const Slot) u32 {
            return self.send_outstanding + self.receive_outstanding + @intFromBool(self.connect_outstanding);
        }

        pub fn drained(self: *const Slot) bool {
            return self.outstanding() == 0;
        }

        /// Releases the generation's kernel objects. The outstanding counters are deliberately
        /// left alone: closing a socket starts cancellation, it does not retire the operations the
        /// provider still owns, and the drain barrier depends on those counters staying exact.
        pub fn close(self: *Slot) void {
            self.socket.deinit();
            self.request_queue = c.RIO_INVALID_RQ;
        }

        /// Opens a fresh generation with no operations and no handles.
        pub fn reset(self: *Slot) void {
            self.close();
            self.send_outstanding = 0;
            self.receive_outstanding = 0;
            self.send_posted_bytes = 0;
            self.receive_posted_bytes = 0;
        }
    };
};

/// The RIO extension table and every object reached through it. RIO exports no importable symbols,
/// so a table entry is either present or the call is a hard failure; there is no silent fallback.
pub const rio = struct {
    pub const Api = struct {
        table: c.RIO_EXTENSION_FUNCTION_TABLE,

        pub fn tableComplete(table: *const c.RIO_EXTENSION_FUNCTION_TABLE) bool {
            return table.RIOReceive != null and table.RIOReceiveEx != null and table.RIOSend != null and table.RIOSendEx != null and
                table.RIOCloseCompletionQueue != null and table.RIOCreateCompletionQueue != null and table.RIOCreateRequestQueue != null and
                table.RIODequeueCompletion != null and table.RIODeregisterBuffer != null and table.RIONotify != null and
                table.RIORegisterBuffer != null and table.RIOResizeCompletionQueue != null and table.RIOResizeRequestQueue != null;
        }

        /// The extension table is fetched once per run through WSAIoctl. Windows offers no static
        /// address for these entry points, so this cost is inherent and is paid exactly once.
        pub fn load() !Api {
            var probe = socket.Socket{ .value = socket.registered(c.SOCK_STREAM, c.IPPROTO_TCP) };
            defer probe.deinit();
            if (probe.value == c.INVALID_SOCKET) {
                diagnostics.report("WSASocketW(RIO probe)", @intCast(c.WSAGetLastError()));
                return error.ProbeSocket;
            }
            var table: c.RIO_EXTENSION_FUNCTION_TABLE = std.mem.zeroes(c.RIO_EXTENSION_FUNCTION_TABLE);
            table.cbSize = @intCast(@sizeOf(c.RIO_EXTENSION_FUNCTION_TABLE));
            var identifier: c.GUID = c.WSAID_MULTIPLE_RIO;
            var returned: c.DWORD = 0;
            const status = c.WSAIoctl(
                probe.value,
                c.SIO_GET_MULTIPLE_EXTENSION_FUNCTION_POINTER,
                &identifier,
                @intCast(@sizeOf(c.GUID)),
                &table,
                @intCast(@sizeOf(c.RIO_EXTENSION_FUNCTION_TABLE)),
                &returned,
                null,
                null,
            );
            if (status != 0) {
                diagnostics.report("SIO_GET_MULTIPLE_EXTENSION_FUNCTION_POINTER(RIO)", @intCast(c.WSAGetLastError()));
                return error.LoadRio;
            }
            if (!tableComplete(&table)) return error.InvalidRioTable;
            return .{ .table = table };
        }

        pub inline fn registerBuffer(self: *const Api, pointer: [*]u8, bytes: u32) c.RIO_BUFFERID {
            return self.table.RIORegisterBuffer.?(@ptrCast(pointer), bytes);
        }

        pub inline fn deregisterBuffer(self: *const Api, id: c.RIO_BUFFERID) void {
            self.table.RIODeregisterBuffer.?(id);
        }

        pub inline fn createCq(self: *const Api, size: u32, notification: *c.RIO_NOTIFICATION_COMPLETION) c.RIO_CQ {
            return self.table.RIOCreateCompletionQueue.?(size, notification);
        }

        pub inline fn closeCq(self: *const Api, queue: c.RIO_CQ) void {
            self.table.RIOCloseCompletionQueue.?(queue);
        }

        pub inline fn createRq(
            self: *const Api,
            socket_value: c.SOCKET,
            max_receive: u32,
            max_receive_buffers: u32,
            max_send: u32,
            max_send_buffers: u32,
            receive_cq: c.RIO_CQ,
            send_cq: c.RIO_CQ,
            socket_context: ?*anyopaque,
        ) c.RIO_RQ {
            return self.table.RIOCreateRequestQueue.?(socket_value, max_receive, max_receive_buffers, max_send, max_send_buffers, receive_cq, send_cq, socket_context);
        }

        pub inline fn receive(self: *const Api, rq: c.RIO_RQ, buffer: *c.RIO_BUF, flags: u32, context: ?*anyopaque) bool {
            return self.table.RIOReceive.?(rq, buffer, 1, flags, context) != c.FALSE;
        }

        pub inline fn send(self: *const Api, rq: c.RIO_RQ, buffer: *c.RIO_BUF, flags: u32, context: ?*anyopaque) bool {
            return self.table.RIOSend.?(rq, buffer, 1, flags, context) != c.FALSE;
        }

        pub inline fn notify(self: *const Api, queue: c.RIO_CQ) c_int {
            return self.table.RIONotify.?(queue);
        }

        pub inline fn dequeue(self: *const Api, queue: c.RIO_CQ, results: [*]c.RIORESULT, count: u32) u32 {
            return self.table.RIODequeueCompletion.?(queue, results, count);
        }
    };

    pub const Extensions = struct {
        rio: Api,
        connect_ex: ?c.LPFN_CONNECTEX,

        pub fn load() !Extensions {
            const api = try Api.load();
            var probe = socket.Socket{ .value = socket.registered(c.SOCK_STREAM, c.IPPROTO_TCP) };
            defer probe.deinit();
            if (probe.value == c.INVALID_SOCKET) {
                diagnostics.report("WSASocketW(ConnectEx probe)", @intCast(c.WSAGetLastError()));
                return error.ProbeSocket;
            }
            var identifier = c.WSAID_CONNECTEX;
            var connect_ex: ?c.LPFN_CONNECTEX = null;
            var returned: c.DWORD = 0;
            if (c.WSAIoctl(
                probe.value,
                c.SIO_GET_EXTENSION_FUNCTION_POINTER,
                &identifier,
                @sizeOf(c.GUID),
                @ptrCast(&connect_ex),
                @sizeOf(?c.LPFN_CONNECTEX),
                &returned,
                null,
                null,
            ) != 0 or connect_ex == null) {
                diagnostics.report("SIO_GET_EXTENSION_FUNCTION_POINTER(ConnectEx)", @intCast(c.WSAGetLastError()));
                return error.LoadConnectEx;
            }
            return .{ .rio = api, .connect_ex = connect_ex };
        }
    };

    /// A registered region. It keeps the table entry it was created with so it can be released
    /// without borrowing the transport that owns the function table.
    pub const Registration = struct {
        api: ?*const Api = null,
        id: c.RIO_BUFFERID = c.RIO_INVALID_BUFFERID,

        pub fn valid(self: *const Registration) bool {
            return self.api != null and self.id != c.RIO_INVALID_BUFFERID and self.id != null;
        }

        pub fn take(self: *Registration) c.RIO_BUFFERID {
            const value = self.id;
            self.api = null;
            self.id = c.RIO_INVALID_BUFFERID;
            return value;
        }

        pub fn reset(self: *Registration, api: ?*const Api, id: c.RIO_BUFFERID) void {
            self.deinit();
            self.api = api;
            self.id = id;
        }

        pub fn deinit(self: *Registration) void {
            if (self.api) |api| {
                if (self.id != c.RIO_INVALID_BUFFERID and self.id != null) api.deregisterBuffer(self.id);
            }
            self.api = null;
            self.id = c.RIO_INVALID_BUFFERID;
        }

        /// A RIO_BUF view of part of the registration. The identity of the owning registration is
        /// preserved, which is what makes a partial re-post legal.
        pub fn slice(self: *const Registration, offset: u32, length: u32) ?c.RIO_BUF {
            if (!self.valid()) return null;
            const end = @as(u64, offset) + @as(u64, length);
            if (end > std.math.maxInt(u32)) return null;
            return .{ .BufferId = self.id, .Offset = offset, .Length = length };
        }
    };

    /// A RIO completion queue bound to an IOCP. The notification is armed only while work is in
    /// flight, so a busy worker never pays for a redundant RIONotify.
    pub const CompletionQueue = struct {
        api: ?*const Api = null,
        value: c.RIO_CQ = c.RIO_INVALID_CQ,
        armed: bool = false,

        pub fn valid(self: *const CompletionQueue) bool {
            return self.api != null and self.value != c.RIO_INVALID_CQ;
        }

        pub fn take(self: *CompletionQueue) c.RIO_CQ {
            const value = self.value;
            self.api = null;
            self.value = c.RIO_INVALID_CQ;
            self.armed = false;
            return value;
        }

        pub fn reset(self: *CompletionQueue, api: ?*const Api, value: c.RIO_CQ) void {
            self.deinit();
            self.api = api;
            self.value = value;
        }

        pub fn deinit(self: *CompletionQueue) void {
            if (self.api) |api| {
                if (self.value != c.RIO_INVALID_CQ) api.closeCq(self.value);
            }
            self.api = null;
            self.value = c.RIO_INVALID_CQ;
            self.armed = false;
        }

        /// Only ERROR_SUCCESS is accepted: any other status leaves the queue unarmed and the caller
        /// must not assume a wake-up is coming. WSAEALREADY means the ownership state disagrees with
        /// the provider, which is an internal error rather than a notification to consume.
        pub fn arm(self: *CompletionQueue) bool {
            const api = self.api orelse return false;
            if (self.armed) return false;
            if (self.value == c.RIO_INVALID_CQ) return false;
            if (api.notify(self.value) != 0) return false;
            self.armed = true;
            return true;
        }

        /// A delivery clears the armed state; the next queued operation re-arms it.
        pub fn onDelivery(self: *CompletionQueue) bool {
            if (!self.armed) return false;
            self.armed = false;
            return true;
        }
    };
};

/// Completion routing for RIO and IOCP.
///
/// The 64-bit request context is self-contained: operation, session index, send slot and transport
/// generation are encoded directly, so no pointer-valued side table is needed. A generation
/// mismatch is a stale completion and never steers the live state machine.
///
/// This is the Completion layer, not the Transport layer: it owns no kernel object -- no request
/// queue, no completion queue, no OVERLAPPED, no socket -- and it is one of the four data kinds the
/// methodology lets the pure engine consume. The scheduler depends on it by design.
pub const completion = struct {
    pub const Operation = enum(u8) {
        connect = 1,
        send = 2,
        receive = 3,
        /// Internal transport event; never encoded into an OS request context.
        generation_drained = 4,
    };

    const op_bits: u6 = 3;
    const session_bits: u6 = 20;
    const slot_bits: u6 = 16;
    const generation_bits: u6 = 8;
    const context_bits: u6 = op_bits + session_bits + slot_bits + generation_bits;

    comptime {
        // The packed value travels through APIs typed as PVOID, so it deliberately stays below
        // 2^47 instead of manufacturing a non-canonical x64 pointer bit pattern.
        if (context_bits != 47) @compileError("client request context must stay 47 bits");
    }

    const op_mask: u64 = (@as(u64, 1) << op_bits) - 1;
    const session_mask: u64 = (@as(u64, 1) << session_bits) - 1;
    const slot_mask: u64 = (@as(u64, 1) << slot_bits) - 1;
    const generation_mask: u64 = (@as(u64, 1) << generation_bits) - 1;
    const context_mask: u64 = (@as(u64, 1) << context_bits) - 1;

    pub const maximum_session_index: u32 = @intCast(session_mask);
    pub const maximum_send_slot: u32 = @intCast(slot_mask);
    pub const maximum_generation: u32 = @intCast(generation_mask);
    pub const no_send_slot: u32 = 0;

    pub const Context = struct {
        index: u32,
        generation: u32,
        slot: u32,
        operation: Operation,
    };

    pub fn encode(index: u32, generation: u32, slot: u32, operation: Operation) ?*anyopaque {
        if (operation == .generation_drained) return null;
        if (index > maximum_session_index) return null;
        if (generation == 0 or generation > maximum_generation) return null;
        if (slot > maximum_send_slot) return null;
        if (operation != .send and slot != no_send_slot) return null;
        const value = @as(u64, @backingInt(operation)) |
            (@as(u64, index) << op_bits) |
            (@as(u64, slot) << (op_bits + session_bits)) |
            (@as(u64, generation) << (op_bits + session_bits + slot_bits));
        return @ptrFromInt(@as(usize, @intCast(value)));
    }

    /// Rejects rather than masks any bit outside the documented canonical payload. This turns a
    /// corrupted or forged completion context into an error instead of an alias of a live request.
    pub fn decode(context: usize) ?Context {
        const value: u64 = context;
        if (value & ~context_mask != 0) return null;
        const operation: Operation = switch (value & op_mask) {
            1 => .connect,
            2 => .send,
            3 => .receive,
            else => return null,
        };
        const index: u32 = @intCast((value >> op_bits) & session_mask);
        const slot: u32 = @intCast((value >> (op_bits + session_bits)) & slot_mask);
        const generation: u32 = @intCast((value >> (op_bits + session_bits + slot_bits)) & generation_mask);
        if (generation == 0) return null;
        if (operation != .send and slot != no_send_slot) return null;
        return .{ .index = index, .generation = generation, .slot = slot, .operation = operation };
    }

    /// A generation number is never reused until the previous generation has fully drained, so
    /// wrapping cannot alias a still-live request.
    pub fn nextGeneration(current: u32) u32 {
        if (current == 0 or current >= maximum_generation) return 1;
        return current + 1;
    }

    pub const error_netname_deleted: i32 = 64;
    pub const error_sem_timeout: i32 = 121;
    pub const error_operation_aborted: i32 = 995;
    pub const error_connection_refused: i32 = 1_225;
    pub const error_network_unreachable: i32 = 1_231;
    pub const error_host_unreachable: i32 = 1_232;
    pub const error_protocol_unreachable: i32 = 1_233;
    pub const error_port_unreachable: i32 = 1_234;
    pub const error_connection_aborted: i32 = 1_236;
    pub const wsaemsgsize: i32 = 10_040;
    pub const wsaenetdown: i32 = 10_050;
    pub const wsaenetunreach: i32 = 10_051;
    pub const wsaenetreset: i32 = 10_052;
    pub const wsa_econnaborted: i32 = 10_053;
    pub const wsa_econnreset: i32 = 10_054;
    pub const wsa_eshutdown: i32 = 10_058;
    pub const wsa_etimedout: i32 = 10_060;
    pub const wsa_econnrefused: i32 = 10_061;
    pub const wsa_ehostdown: i32 = 10_064;
    pub const wsa_ehostunreach: i32 = 10_065;

    /// Completion statuses that can be contained to one connection generation. An unknown native
    /// completion failure is a process-level transport fault rather than something to hide behind
    /// an endless reconnect loop.
    pub fn isConnectionLevel(status: i32) bool {
        return switch (status) {
            error_netname_deleted,
            error_sem_timeout,
            error_operation_aborted,
            error_connection_refused,
            error_network_unreachable,
            error_host_unreachable,
            error_protocol_unreachable,
            error_port_unreachable,
            error_connection_aborted,
            wsaemsgsize,
            wsaenetdown,
            wsaenetunreach,
            wsaenetreset,
            wsa_econnaborted,
            wsa_econnreset,
            wsa_eshutdown,
            wsa_etimedout,
            wsa_econnrefused,
            wsa_ehostdown,
            wsa_ehostunreach,
            => true,
            else => false,
        };
    }
};

pub const endpoint = struct {
    const error_io_pending: i32 = 997;
    const wsa_einval_like: i32 = 10022;

    /// Resolves the target exactly as the reference does: the host is passed to GetAddrInfoW and an
    /// unresolvable name is a network failure rather than a usage error.
    pub fn resolveIpv4(host: [*:0]const u16, port: u16) ?c.SOCKADDR_IN {
        var service: [16]u16 = @splat(0);
        var ascii: [16]u8 = undefined;
        const digits = std.fmt.bufPrint(&ascii, "{d}", .{port}) catch return null;
        for (digits, 0..) |character, index| service[index] = character;
        var hints: c.ADDRINFOW = std.mem.zeroes(c.ADDRINFOW);
        hints.ai_family = c.AF_INET;
        hints.ai_socktype = c.SOCK_STREAM;
        var results: [*c]c.ADDRINFOW = null;
        const status = c.GetAddrInfoW(host, @ptrCast(&service), &hints, &results);
        if (status != 0 or results == null) {
            diagnostics.report("GetAddrInfoW(IPv4)", @intCast(status));
            return null;
        }
        defer c.FreeAddrInfoW(results);
        return (@as(*const c.SOCKADDR_IN, @ptrCast(@alignCast(results.*.ai_addr)))).*;
    }

    pub fn localEndpoint(port: u16) c.SOCKADDR_IN {
        var local: c.SOCKADDR_IN = std.mem.zeroes(c.SOCKADDR_IN);
        local.sin_family = c.AF_INET;
        local.sin_addr.S_un.S_addr = c.htonl(c.INADDR_ANY);
        local.sin_port = c.htons(port);
        return local;
    }

    pub fn bindLocal(socket_value: c.SOCKET, port: u16) bool {
        var local = localEndpoint(port);
        if (c.bind(socket_value, @ptrCast(&local), @sizeOf(c.SOCKADDR_IN)) != 0) {
            diagnostics.report("bind(client)", @intCast(c.WSAGetLastError()));
            return false;
        }
        return true;
    }

    pub fn connectUdp(socket_value: c.SOCKET, target: *const c.SOCKADDR_IN) bool {
        if (c.connect(socket_value, @ptrCast(target), @sizeOf(c.SOCKADDR_IN)) != 0) {
            diagnostics.report("connect(UDP client)", @intCast(c.WSAGetLastError()));
            return false;
        }
        return true;
    }

    /// Posts ConnectEx. Null means the operation was accepted, whether it completed inline or is
    /// still pending; a value is the native error that refused it before it was ever in flight.
    pub fn beginConnect(
        connect_ex: c.LPFN_CONNECTEX,
        socket_value: c.SOCKET,
        target: *const c.SOCKADDR_IN,
        overlapped: *c.OVERLAPPED,
    ) ?i32 {
        if (connect_ex(socket_value, @ptrCast(target), @sizeOf(c.SOCKADDR_IN), null, 0, null, overlapped) != c.FALSE) return null;
        const status = c.WSAGetLastError();
        if (status == error_io_pending) return null;
        return status;
    }

    /// A connected socket only becomes usable for RIO once the accept/connect context has been
    /// updated; the failure is not optional and is reported with the failing stage.
    pub fn updateConnectContext(socket_value: c.SOCKET) bool {
        if (c.setsockopt(socket_value, c.SOL_SOCKET, c.SO_UPDATE_CONNECT_CONTEXT, null, 0) != 0) {
            diagnostics.report("setsockopt(SO_UPDATE_CONNECT_CONTEXT)", @intCast(c.WSAGetLastError()));
            return false;
        }
        return true;
    }
};

/// The production clock: the reference's raw high-resolution performance counter. Deadlines keep
/// tick precision; only the blocking IOCP wait is rounded up to whole milliseconds.
pub const clock = struct {
    pub const Clock = struct {
        frequency: u64 = 0,

        pub fn init() ?Clock {
            var value: c.LARGE_INTEGER = .{ .QuadPart = 0 };
            if (c.QueryPerformanceFrequency(&value) == c.FALSE or value.QuadPart <= 0) {
                diagnostics.report("QueryPerformanceFrequency(client timer)", c.GetLastError());
                return null;
            }
            const clock_value = Clock{ .frequency = @intCast(value.QuadPart) };
            // Check the counter before any session has posted native I/O.
            _ = clock_value.nowTicks();
            return clock_value;
        }

        pub fn nowTicks(self: *const Clock) u64 {
            // The counter is process-wide, so the clock carries only its frequency.
            _ = self;
            var value: c.LARGE_INTEGER = .{ .QuadPart = 0 };
            if (c.QueryPerformanceCounter(&value) == c.FALSE or value.QuadPart < 0) {
                diagnostics.failFast("QueryPerformanceCounter(client timer)", c.GetLastError());
            }
            return @intCast(value.QuadPart);
        }

        pub fn ticksToMilliseconds(self: *const Clock, ticks: u64) u64 {
            return clock.ticksToMilliseconds(ticks, self.frequency);
        }

        pub fn millisecondsToTicks(self: *const Clock, milliseconds: u64) u64 {
            return clock.millisecondsToTicks(milliseconds, self.frequency);
        }

        pub fn waitMillisecondsUntil(self: *const Clock, deadline: u64, now: u64) u64 {
            if (deadline <= now) return 0;
            return clock.ticksToWaitMilliseconds(deadline - now, self.frequency);
        }

        /// Rounds a tick wait up to whole milliseconds, so a blocking wait never expires early.
        pub fn ticksToWaitMilliseconds(self: *const Clock, ticks: u64) u64 {
            return clock.ticksToWaitMilliseconds(ticks, self.frequency);
        }
    };

    /// Converts a duration in milliseconds to counter ticks, rounding up so a deadline is never
    /// shortened. The wide path is only taken when the scaled counter would overflow.
    pub fn millisecondsToTicks(milliseconds: u64, frequency: u64) u64 {
        if (frequency == 0) return 0;
        if (types.checkedProduct(u64, milliseconds, frequency)) |scaled| {
            return types.ceilingDivide(u64, scaled, 1_000);
        }
        const wide = types.ceilingDivide(u128, @as(u128, milliseconds) * @as(u128, frequency), 1_000);
        return if (wide > std.math.maxInt(u64)) std.math.maxInt(u64) else @intCast(wide);
    }

    pub fn ticksToMilliseconds(ticks: u64, frequency: u64) u64 {
        if (frequency == 0) return 0;
        if (types.checkedProduct(u64, ticks, 1_000)) |scaled| return scaled / frequency;
        const wide = (@as(u128, ticks) * 1_000) / @as(u128, frequency);
        return if (wide > std.math.maxInt(u64)) std.math.maxInt(u64) else @intCast(wide);
    }

    pub fn ticksToWaitMilliseconds(ticks: u64, frequency: u64) u64 {
        if (frequency == 0) return 0;
        if (types.checkedProduct(u64, ticks, 1_000)) |scaled| {
            return types.ceilingDivide(u64, scaled, frequency);
        }
        const wide = types.ceilingDivide(u128, @as(u128, ticks) * 1_000, frequency);
        return if (wide > std.math.maxInt(u64)) std.math.maxInt(u64) else @intCast(wide);
    }

    test "millisecond boundaries survive the conversion" {
        try std.testing.expectEqual(@as(u64, 0), ticksToMilliseconds(0, 1_000_000));
        try std.testing.expectEqual(@as(u64, 0), ticksToMilliseconds(999, 1_000_000));
        try std.testing.expectEqual(@as(u64, 1), ticksToMilliseconds(1_000, 1_000_000));
        try std.testing.expectEqual(@as(u64, 1), ticksToMilliseconds(1_999, 1_000_000));
        try std.testing.expectEqual(@as(u64, 2), ticksToMilliseconds(2_000, 1_000_000));
    }

    test "large counter values do not wrap the clock" {
        try std.testing.expectEqual(std.math.maxInt(u64), ticksToMilliseconds(std.math.maxInt(u64), 1));
        try std.testing.expectEqual(@as(u64, 1_000), ticksToMilliseconds(std.math.maxInt(u64), std.math.maxInt(u64)));
    }

    test "tick deadlines and waits round up without overflow" {
        try std.testing.expectEqual(@as(u64, 1_000), millisecondsToTicks(1, 1_000_000));
        try std.testing.expectEqual(@as(u64, 2), millisecondsToTicks(1, 1_001));
        try std.testing.expectEqual(std.math.maxInt(u64), millisecondsToTicks(std.math.maxInt(u64), std.math.maxInt(u64)));
        try std.testing.expectEqual(@as(u64, 0), ticksToWaitMilliseconds(0, 1_000_000));
        try std.testing.expectEqual(@as(u64, 1), ticksToWaitMilliseconds(1, 1_000_000));
        try std.testing.expectEqual(@as(u64, 2), ticksToWaitMilliseconds(1_001, 1_000_000));
        try std.testing.expectEqual(std.math.maxInt(u64), ticksToWaitMilliseconds(std.math.maxInt(u64), 1));
        try std.testing.expectEqual(@as(u64, 1_000), ticksToWaitMilliseconds(std.math.maxInt(u64), std.math.maxInt(u64)));
    }
};

/// Active processors across all processor groups, matching the Windows reference.
pub fn processorCount() u32 {
    return @intCast(c.GetActiveProcessorCount(c.ALL_PROCESSOR_GROUPS));
}

/// Reads a process environment variable. Only startup diagnostics use it, never the hot path.
pub fn environment(name: [*:0]const u8) ?[*:0]u8 {
    return c.getenv(name);
}

test "completion contexts round trip and reject forged values" {
    const context = completion.encode(7, 3, 0, .send) orelse return error.TestUnexpectedResult;
    const decoded = completion.decode(@intFromPtr(context)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 7), decoded.index);
    try std.testing.expectEqual(@as(u32, 3), decoded.generation);
    try std.testing.expectEqual(completion.Operation.send, decoded.operation);

    try std.testing.expect(completion.decode(0) == null);
    try std.testing.expect(completion.decode(@as(usize, 1) << 47) == null);
    // A receive may never carry a send slot, which is what makes a forged context detectable.
    try std.testing.expect(completion.encode(1, 1, 3, .receive) == null);
    try std.testing.expectEqual(@as(u32, 1), completion.nextGeneration(completion.maximum_generation));
    try std.testing.expectEqual(@as(u32, 2), completion.nextGeneration(1));
}

test "arena geometry is checked" {
    try std.testing.expectEqual(@as(?u32, 8_192), arena.workerBytes(4, 1_024));
    try std.testing.expectEqual(@as(?u32, null), arena.workerBytes(0, 1_024));
    try std.testing.expectEqual(@as(?u32, null), arena.workerBytes(4, 0));
    try std.testing.expectEqual(@as(?u32, null), arena.workerBytes(1, std.math.maxInt(u32) / 2 + 1));
    try std.testing.expectEqual(@as(?usize, 3_072), arena.slotOffset(3, 1_024, 4_096));
    try std.testing.expectEqual(@as(?usize, null), arena.slotOffset(4, 1_024, 4_096));
}
