//! Test-only launcher: force network namespace creation to fail with EPERM.
//! No fault-injection switch exists in the production worker.
const std = @import("std");
const worker_options = @import("worker_path");

const linux = std.os.linux;
const bpf = linux.BPF;
const seccomp = linux.SECCOMP;

const Instruction = extern struct {
    code: u16,
    jt: u8,
    jf: u8,
    k: u32,
};

const Program = extern struct {
    len: u16,
    filter: [*]const Instruction,
};
const c = @cImport({
    @cInclude("unistd.h");
});

pub fn main() void {
    const filter = [_]Instruction{
        .{
            .code = bpf.LD | bpf.W | bpf.ABS,
            .jt = 0,
            .jf = 0,
            .k = @offsetOf(seccomp.data, "nr"),
        },
        .{
            .code = bpf.JMP | bpf.JEQ | bpf.K,
            .jt = 0,
            .jf = 1,
            .k = @intFromEnum(linux.SYS.unshare),
        },
        .{
            .code = bpf.RET | bpf.K,
            .jt = 0,
            .jf = 0,
            .k = seccomp.RET.ERRNO | 1,
        },
        .{
            .code = bpf.RET | bpf.K,
            .jt = 0,
            .jf = 0,
            .k = seccomp.RET.ALLOW,
        },
    };
    const program: Program = .{ .len = filter.len, .filter = &filter };
    if (linux.errno(linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0)) != .SUCCESS)
        std.process.exit(126);
    if (linux.errno(
        linux.prctl(
            @intFromEnum(linux.PR.SET_SECCOMP),
            seccomp.MODE.FILTER,
            @intFromPtr(&program),
            0,
            0,
        ),
    ) != .SUCCESS)
        std.process.exit(126);
    const path = worker_options.worker_path ++ "";
    const argv = [_:null]?[*:0]const u8{path.ptr};
    _ = c.execv(path.ptr, @ptrCast(&argv));
    std.process.exit(126);
}
