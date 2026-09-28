const std = @import("std");
const Database = @import("database");

const SignatureFixture = struct {
    temporary: TemporaryHome,
    arena: std.heap.ArenaAllocator,
    path: []const u8,
    signer_home: []const u8,
    verifier_home: []const u8,
    unknown_home: []const u8,

    const contents = "Shelly database signature fixture\n\x00\x01\x02\xff";
    const identity = "Shelly Signature Tests <signature-tests@example.invalid>";

    fn init() !SignatureFixture {
        // An explicitly requested integration target must fail when tools are absent.
        for ([_][]const u8{ "gpg", "gpgconf", "gpg-agent" }) |executable| {
            runCommand(&.{ executable, "--version" }, .inherit) catch |err| switch (err) {
                error.FileNotFound => {
                    std.debug.print("integration test requires {s}\n", .{executable});
                    return error.GpgIntegrationUnavailable;
                },
                else => return err,
            };
        }

        var temporary = try TemporaryHome.init();
        errdefer cleanupTemporary(&temporary) catch |err| {
            std.log.err("failed to remove signature fixture: {t}", .{err});
        };
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        const path = try temporary.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        const signer_home = try std.fs.path.join(allocator, &.{ path, "signer" });
        const verifier_home = try std.fs.path.join(allocator, &.{ path, "verifier" });
        const unknown_home = try std.fs.path.join(allocator, &.{ path, "unknown" });
        for ([_][]const u8{ "signer", "verifier", "unknown" }) |name| {
            try temporary.dir.createDir(std.testing.io, name, .fromMode(0o700));
            // Verification cannot fetch keys or start extra agents.
            if (!std.mem.eql(u8, name, "signer")) {
                const config_path = try std.fs.path.join(allocator, &.{ name, "gpg.conf" });
                try temporary.dir.writeFile(std.testing.io, .{
                    .sub_path = config_path,
                    .data = "no-auto-key-retrieve\nno-auto-key-import\nno-autostart\n",
                });
            }
        }

        const fixture: SignatureFixture = .{
            .temporary = temporary,
            .arena = arena,
            .path = path,
            .signer_home = signer_home,
            .verifier_home = verifier_home,
            .unknown_home = unknown_home,
        };
        // Also stop agents if key generation or any later setup operation fails.
        errdefer fixture.stopAgents() catch |err| {
            std.log.err("failed to stop fixture GPG agents: {t}", .{err});
        };

        runCommand(&.{ "gpgconf", "--homedir", signer_home, "--launch", "gpg-agent" }, .inherit) catch {
            std.debug.print("GPG integration requires permission to start an agent and bind its Unix sockets\n", .{});
            return error.GpgIntegrationUnavailable;
        };

        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = "test.db",
            .data = contents,
        });
        try fixture.runGpg(signer_home, &.{
            "--pinentry-mode",      "loopback", "--passphrase", "",
            "--quick-generate-key", identity,   "ed25519",      "sign",
            "0",
        });
        try fixture.runGpg(signer_home, &.{
            "--pinentry-mode", "loopback", "--passphrase", "",
            "--local-user",    identity,   "--output",     "test.db.sig",
            "--detach-sign",   "test.db",
        });
        try fixture.runGpg(signer_home, &.{ "--output", "public-key.gpg", "--export", identity });
        try fixture.runGpg(verifier_home, &.{ "--no-autostart", "--import", "public-key.gpg" });
        return fixture;
    }

    fn runGpg(self: SignatureFixture, homedir: []const u8, extra: []const []const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(std.testing.allocator);
        try argv.appendSlice(std.testing.allocator, &.{
            "gpg", "--no-options", "--homedir", homedir, "--batch", "--yes",
        });
        try argv.appendSlice(std.testing.allocator, extra);
        try runCommand(argv.items, .{ .dir = self.temporary.dir });
    }

    fn stopAgents(self: SignatureFixture) !void {
        var failure: ?anyerror = null;
        for ([_][]const u8{ self.signer_home, self.verifier_home, self.unknown_home }) |homedir| {
            runCommand(&.{ "gpgconf", "--homedir", homedir, "--kill", "all" }, .inherit) catch |err| {
                failure = err;
            };
        }
        if (failure) |err| return err;
    }

    fn deinit(self: *SignatureFixture) !void {
        defer self.arena.deinit();
        const stopped = self.stopAgents();
        // Attempt file cleanup even if stopping an agent failed, and report errors.
        try cleanupTemporary(&self.temporary);
        try stopped;
    }
};

// Short, private homes avoid Unix socket path limits in deeply nested checkouts.
// Atomic creation rejects collisions; cleanup removes only the directory we created.
const TemporaryHome = struct {
    dir: std.Io.Dir,
    parent_dir: std.Io.Dir,
    sub_path: [25]u8,

    fn init() !TemporaryHome {
        var random: [12]u8 = undefined;
        std.testing.io.random(&random);
        var name: [25]u8 = undefined;
        @memcpy(name[0..9], "rlpm-gpg-");
        _ = std.base64.url_safe.Encoder.encode(name[9..], &random);
        var parent = try std.Io.Dir.openDirAbsolute(std.testing.io, "/tmp", .{});
        errdefer parent.close(std.testing.io);
        try parent.createDir(std.testing.io, &name, .fromMode(0o700));
        errdefer parent.deleteTree(std.testing.io, &name) catch {};
        const dir = try parent.openDir(std.testing.io, &name, .{});
        return .{ .dir = dir, .parent_dir = parent, .sub_path = name };
    }
};

fn cleanupTemporary(temporary: *TemporaryHome) !void {
    temporary.dir.close(std.testing.io);
    defer temporary.parent_dir.close(std.testing.io);
    try temporary.parent_dir.deleteTree(std.testing.io, &temporary.sub_path);
}

fn runCommand(argv: []const []const u8, cwd: std.process.Child.Cwd) !void {
    const result = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = argv,
        .cwd = cwd,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(30) } },
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    std.debug.print("fixture command {s} failed ({any}):\n{s}\n{s}\n", .{
        argv[0], result.term, result.stdout, result.stderr,
    });
    return error.GpgFixtureCommandFailed;
}

test "signature: validateSignature accepts a real detached signature" {
    var fixture = try SignatureFixture.init();
    defer fixture.deinit() catch |err| {
        std.debug.panic("signature fixture cleanup failed: {t}", .{err});
    };
    var database = try Database.init(std.testing.allocator, "test", fixture.path, .{});
    defer database.deinit();

    try std.testing.expect(try database.validateSignature(std.testing.io, fixture.verifier_home));
}

test "signature: validateSignature rejects tampered database contents" {
    var fixture = try SignatureFixture.init();
    defer fixture.deinit() catch |err| {
        std.debug.panic("signature fixture cleanup failed: {t}", .{err});
    };
    var database = try Database.init(std.testing.allocator, "test", fixture.path, .{});
    defer database.deinit();

    try std.testing.expect(try database.validateSignature(std.testing.io, fixture.verifier_home));
    var tampered = SignatureFixture.contents.*;
    tampered[0] ^= 1;
    try fixture.temporary.dir.writeFile(std.testing.io, .{ .sub_path = "test.db", .data = &tampered });
    try std.testing.expect(!try database.validateSignature(std.testing.io, fixture.verifier_home));
}

test "signature: validateSignature rejects a missing detached signature" {
    var fixture = try SignatureFixture.init();
    defer fixture.deinit() catch |err| {
        std.debug.panic("signature fixture cleanup failed: {t}", .{err});
    };
    var database = try Database.init(std.testing.allocator, "test", fixture.path, .{});
    defer database.deinit();

    try std.testing.expect(try database.validateSignature(std.testing.io, fixture.verifier_home));
    try fixture.temporary.dir.deleteFile(std.testing.io, "test.db.sig");
    try std.testing.expect(!try database.validateSignature(std.testing.io, fixture.verifier_home));
}

test "signature: validateSignature rejects a corrupted detached signature" {
    var fixture = try SignatureFixture.init();
    defer fixture.deinit() catch |err| {
        std.debug.panic("signature fixture cleanup failed: {t}", .{err});
    };
    var database = try Database.init(std.testing.allocator, "test", fixture.path, .{});
    defer database.deinit();

    try std.testing.expect(try database.validateSignature(std.testing.io, fixture.verifier_home));
    const signature = try fixture.temporary.dir.readFileAlloc(
        std.testing.io,
        "test.db.sig",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(signature);
    try std.testing.expect(signature.len > 0);
    signature[signature.len - 1] ^= 1;
    try fixture.temporary.dir.writeFile(std.testing.io, .{ .sub_path = "test.db.sig", .data = signature });
    try std.testing.expect(!try database.validateSignature(std.testing.io, fixture.verifier_home));
}

test "signature: validateSignature rejects an unknown signing key" {
    var fixture = try SignatureFixture.init();
    defer fixture.deinit() catch |err| {
        std.debug.panic("signature fixture cleanup failed: {t}", .{err});
    };
    var database = try Database.init(std.testing.allocator, "test", fixture.path, .{});
    defer database.deinit();

    try std.testing.expect(try database.validateSignature(std.testing.io, fixture.verifier_home));
    try std.testing.expect(!try database.validateSignature(std.testing.io, fixture.unknown_home));
}
