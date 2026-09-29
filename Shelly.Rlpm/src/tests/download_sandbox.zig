//! Explicit privileged integration target. Never part of the ordinary test step.
const std = @import("std");
const rlpm = @import("Shelly_Rlpm");

test "root download sandbox drops credentials and preserves the parent across all switches" {
    if (std.c.getuid() != 0) return error.RootSandboxIntegrationUnavailable;
    const a = std.testing.allocator;
    const io = std.testing.io;
    const base = try rlpm.Downloads.uniquePath(a, io, "/tmp", "rlpm-sandbox-test");
    defer a.free(base);
    try std.Io.Dir.cwd().createDir(io, base, .fromMode(0o755));
    defer std.Io.Dir.cwd().deleteTree(io, base) catch unreachable;
    for (0..8) |bits| {
        const path = try std.fmt.allocPrint(a, "{s}/case-{d}", .{ base, bits });
        defer a.free(path);
        try std.Io.Dir.cwd().createDir(io, path, .fromMode(0o755));
        const cache = try std.fmt.allocPrint(a, "{s}/cache", .{path});
        defer a.free(cache);
        const source = try std.fmt.allocPrint(a, "{s}/private.pkg", .{path});
        defer a.free(source);
        const input = try std.Io.Dir.cwd().createFile(io, source, .{ .permissions = .fromMode(0o600) });
        try input.writeStreamingAll(io, "private");
        try input.setTimestamps(
            io,
            .{
                .modify_timestamp = .{ .new = .{ .nanoseconds = 1600000000000000000 } },
            },
        );
        input.close(io);
        var owner = try rlpm.Owner.init(io, a, .{
            .root = path,
            .database_path = path,
            .cache_directories = &.{cache},
            .sandbox_user = "nobody",
            .sandbox = .{
                .disable_filesystem = bits & 1 != 0,
                .disable_syscalls = bits & 2 != 0,
                .disable_network = bits & 4 != 0,
            },
        }, &.{});
        defer owner.deinit() catch unreachable;
        const url = try std.fmt.allocPrint(a, "file://{s}", .{source});
        defer a.free(url);
        if (bits == 7) {
            var result = try owner.fetchPackage(io, url);
            defer result.deinit();
            const st = try std.Io.Dir.cwd().statFile(io, result.path, .{});
            try std.testing.expectEqual(0o644, st.permissions.toMode() & 0o777);
            try std.testing.expectEqual(1600000000000000000, st.mtime.nanoseconds);
        } else {
            try std.testing.expectError(error.FileError, owner.fetchPackage(io, url));
            const public_input = try std.Io.Dir.cwd().openFile(io, source, .{});
            defer public_input.close(io);
            try public_input.setPermissions(io, .fromMode(0o644));
            var result = try owner.fetchPackage(io, url);
            defer result.deinit();
            const st = try std.Io.Dir.cwd().statFile(io, result.path, .{});
            try std.testing.expectEqual(0o644, st.permissions.toMode() & 0o777);
            try std.testing.expectEqual(1600000000000000000, st.mtime.nanoseconds);
        }
        try std.testing.expectEqual(0, std.c.getuid());
    }
}
