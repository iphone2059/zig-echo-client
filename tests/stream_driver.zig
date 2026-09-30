const client = @import("client");
pub fn main() u8 {
    if (!client.win32.writeStdout("stdout-only\n")) return 1;
    if (!client.win32.writeStderr("stderr-only\n")) return 1;
    return 0;
}
