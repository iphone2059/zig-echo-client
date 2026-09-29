pub const Protocol = enum(u8) { none = 0, tcp = 1, udp = 2 };
pub const PatternKind = enum(u8) { default_text = 0, literal_text = 1, binary_counter = 2, printable_counter = 3 };
pub const ExitCode = enum(u8) { success = 0, usage = 1, network = 2, echo_failure = 3, internal = 4 };

pub const Options = struct {
    protocol: Protocol = .none,
    pattern_kind: PatternKind = .default_text,
    host: []const u8 = "",
    literal_pattern: []const u8 = "",
    remote_port: u16 = 7,
    local_port: u16 = 0,
    echo_count: u64 = 5,
    timeout_seconds: u32 = 5,
    interval_milliseconds: u32 = 0,
    socket_buffer_bytes: u32 = 0,
    pipeline_depth: u32 = 1,
    pattern_bytes: u32 = 0,
    run_seconds: u32 = 0,
    reconnect_seconds: i32 = -1,
    report_seconds: u32 = 0,
    session_count: u32 = 1,
    worker_count: u32 = 0,
    cq_capacity: u32 = 4096,
    memory_bytes: u64 = 1024 * 1024 * 1024,
    quiet: bool = false,
    stats: bool = false,
    help: bool = false,
};

pub const maximum_tcp_batch_bytes: u32 = 64 * 1024 * 1024;
pub const maximum_udp_payload: u32 = 65507;
