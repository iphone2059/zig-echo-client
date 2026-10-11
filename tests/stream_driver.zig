const client = @import("client");

pub fn main() u8 {
    if (!client.native.diagnostics.writeStdout("stdout-only\n")) return 1;
    if (!client.native.diagnostics.writeStderr("stderr-only\n")) return 1;
    return 0;
}
