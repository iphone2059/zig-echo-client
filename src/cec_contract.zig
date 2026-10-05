//! The client binary's command-line contract, in one place.
//!
//! Switches, ranges, diagnostic tokens and help text live here so the four language ports can be
//! compared file by file. Reference implementation: echo-binary-contract-v1 (the C++ client).

/// Identifier of the frozen binary contract this file implements.
pub const version = "echo-binary-contract-v1";

/// Diagnostic tokens that must follow "Invalid arguments: " on stderr.
pub const token = struct {
    pub const protocol_option = "protocol-option";
    pub const invalid_number = "invalid-number";
    pub const out_of_range = "out-of-range";
    pub const unknown_switch = "unknown-switch";
};

/// Usage text, printed on stdout for a valid /h command line and on stderr for a usage error.
pub const usage =
    "Usage: zig-echo-client target /p tcp|udp [/r port] [/l port] [/n count]\n" ++
    "       [/t seconds] [/i ms] [/d text | /z bytes | /zt bytes] [/k tcp-depth]\n" ++
    "       [/c sessions] [/threads workers] [/w seconds] [/rc [seconds]]\n" ++
    "       [/report seconds] [/b bytes] [/cq capacity] [/memory bytes] [/q] [/stats]\n" ++
    "Data I/O is always RIO; CQ notification is always IOCP. No fallback backend exists.\n";
