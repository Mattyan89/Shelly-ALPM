//! Real payload and local-record mutations confined to disposable roots.
const std = @import("std");
const rlpm = @import("Shelly_Rlpm");
const Fixture = @import("actions_fixture.zig");
const Archive = @import("archive_fixture.zig");
const io = std.testing.io;
const a = std.testing.allocator;
const mtree = "#mtree\n./etc type=dir\n./etc/conf type=file\n./usr/data type=file\n./usr/link type=link link=/usr/data\n./usr/hard type=file\n";
const flags: rlpm.TransactionFlags = .{ .no_hooks = true, .no_scriptlets = true };
fn apply(owner: *rlpm.Owner, path: []const u8, mode: rlpm.TransactionFlags) !void {
    const tx = try owner.initializeTransaction(io, mode);
    defer owner.releaseTransaction() catch unreachable;
    try Fixture.add(tx, path);
    try tx.prepare();
    try tx.commit();
    try std.testing.expectEqual(.completed, tx.state);
    try std.testing.expectEqual(1, tx.result().packages_committed);
}
fn package(version: []const u8, content: []const u8) !Archive {
    const info = try std.fmt.allocPrint(a, "pkgname = demo\npkgver = {s}\narch = any\npkgdesc = executor fixture\nsize = 14\nbackup = etc/conf\nxdata = pkgtype=pkg\n", .{version});
    defer a.free(info);
    return Archive.init(&.{
        .{ .path = ".PKGINFO", .contents = info },
        .{ .path = ".INSTALL", .contents = "post_install() { :; }\n" },
        .{ .path = ".CHANGELOG", .contents = "changes\n" },
        .{ .path = ".MTREE", .contents = mtree },
        .{ .path = "etc/", .kind = .directory },
        .{ .path = "etc/conf", .contents = content },
        .{ .path = "usr/data", .contents = "payload" },
        .{ .path = "usr/link", .kind = .symlink, .target = "/usr/data" },
        .{ .path = "usr/hard", .kind = .hardlink, .target = "usr/data" },
    }, .zstd);
}
test "M10 install query reinstall upgrade downgrade remove persists to fresh Owners" {
    var f = try Fixture.init();
    defer f.deinit();
    var first = try package("1-1", "first");
    defer first.deinit();
    var second = try package("2-1", "second");
    defer second.deinit();
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    for ([_][]const u8{ first.path, first.path, second.path, first.path }) |path| {
        try apply(&owner, path, flags);
        try f.expect("root/usr/data", "payload");
        var fresh = try f.owner();
        defer fresh.deinit() catch unreachable;
        const ref = (try fresh.findPackage(fresh.localDatabase().?, "demo")).?;
        const installed = try fresh.packageMetadata(io, ref, .{ .files = true, .members = true });
        try std.testing.expect(installed.install_date.? > 0);
        try std.testing.expectEqual(.present, installed.members.mtree);
        try std.testing.expectEqual(.explicit, installed.install_reason.?);
        const record = try std.fmt.allocPrint(a, "db/local/demo-{s}/changelog", .{installed.version.raw});
        defer a.free(record);
        try f.expect(record, "changes\n");
    }
    const tx = try owner.initializeTransaction(io, flags);
    defer owner.releaseTransaction() catch unreachable;
    try tx.remove("demo");
    try tx.prepare();
    try tx.commit();
    try std.testing.expectEqual(1, tx.result().packages_committed);
    try std.testing.expect((try owner.findPackage(owner.localDatabase().?, "demo")) == null);
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.access(io, "root/usr/data", .{}));
}

fn string(obj: std.json.Value, name: []const u8) ?[]const u8 {
    const value = obj.object.get(name) orelse return null;
    return if (value == .null) null else value.string;
}
fn boolean(obj: std.json.Value, name: []const u8) bool {
    return if (obj.object.get(name)) |v| v.bool else false;
}
const Events = struct {
    values: std.ArrayList([2]i64) = .empty,
    fn callback(context: ?*anyopaque, event: rlpm.Callbacks.Event) void {
        const self: *Events = @ptrCast(@alignCast(context.?));
        const item: [2]i64 = switch (event) {
            .phase => |phase| blk: {
                if (phase.boundary == .failed) return; // Shelly diagnostic extension.
                const tag: i64 = switch (phase.phase) {
                    .dependencies => 1,
                    .file_conflicts => 3,
                    .resolve_dependencies => 5,
                    .inter_conflicts => 7,
                    .transaction => 9,
                    .integrity => 13,
                    .load_packages => 15,
                    .database_retrieve => 18,
                    .package_retrieve => 21,
                    .disk_space => 24,
                    .keyring => 28,
                    .key_download => 30,
                    else => return,
                };
                break :blk .{ tag + @intFromBool(phase.boundary == .done), 0 };
            },
            .package_operation => |op| .{ if (op.boundary == .start) 11 else 12, switch (op.operation) {
                .install => 1,
                .upgrade => 2,
                .reinstall => 3,
                .downgrade => 4,
                .remove => 5,
            } },
            .pacnew_created => .{ 32, 0 },
            .pacsave_created => .{ 33, 0 },
            else => return,
        };
        self.values.append(a, item) catch @panic("fixture allocation");
    }
};
test "M10 replays pinned native backup flags removal suffix and event oracle" {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, @embedFile("reference/executor.json"), .{});
    defer parsed.deinit();
    for (parsed.value.object.get("cases").?.array.items) |case| {
        errdefer std.debug.print("executor oracle: {s}\n", .{string(case, "name").?});
        var f = try Fixture.init();
        defer f.deinit();
        if (string(case, "old")) |old| {
            try f.installed("demo", "1-1", "conf", null);
            if (boolean(case, "backup") or boolean(case, "oldbackup")) {
                var hash: [16]u8 = undefined;
                std.crypto.hash.Md5.hash(old, &hash, .{});
                const digest = std.fmt.bytesToHex(hash, .lower);
                const bytes = try std.fmt.allocPrint(a, "%FILES%\nconf\n\n%BACKUP%\nconf\t{s}\n\n", .{digest});
                defer a.free(bytes);
                try f.write("db/local/demo-1-1/files", bytes);
            }
        }
        inline for (.{ .{ "local", "root/conf" }, .{ "pacnew", "root/conf.pacnew" }, .{ "pacsave", "root/conf.pacsave" }, .{ "pacsave1", "root/conf.pacsave.1" } }) |pair| if (string(case, pair[0])) |contents| try f.write(pair[1], contents);
        const info = try std.fmt.allocPrint(a, "pkgname = demo\npkgver = 2-1\narch = any\n{s}", .{if (boolean(case, "backup")) "backup = conf\n" else ""});
        defer a.free(info);
        var archive = try Archive.init(&.{ .{ .path = ".PKGINFO", .contents = info }, .{ .path = "conf", .contents = string(case, "new").? } }, .none);
        defer archive.deinit();
        var owner = try f.owner();
        defer owner.deinit() catch unreachable;
        inline for (.{ .{ "noupgrade", rlpm.OwnerConfiguration.StringList.no_upgrade }, .{ "noextract", rlpm.OwnerConfiguration.StringList.no_extract }, .{ "overwrite", rlpm.OwnerConfiguration.StringList.overwrite_files } }) |pair| if (case.object.get(pair[0])) |list| {
            const values = try a.alloc([]const u8, list.array.items.len);
            defer a.free(values);
            for (values, list.array.items) |*value, item| value.* = item.string;
            try owner.setList(io, pair[1], values);
        };
        var events: Events = .{};
        defer events.values.deinit(a);
        try owner.setCallbacks(.{ .event = Events.callback, .event_context = &events });
        var mode = flags;
        mode.database_only = boolean(case, "dbonly");
        mode.download_only = boolean(case, "downloadonly");
        mode.no_save = boolean(case, "nosave");
        mode.no_conflicts = boolean(case, "noconflicts");
        const tx = try owner.initializeTransaction(io, mode);
        defer owner.releaseTransaction() catch unreachable;
        if (boolean(case, "remove")) try tx.remove("demo") else try Fixture.add(tx, archive.path);
        try tx.prepare();
        if (string(case, "error") != null) try std.testing.expectError(error.FileConflicts, tx.commit()) else try tx.commit();
        var contents = case.object.get("contents").?.object.iterator();
        while (contents.next()) |item| {
            const path = try std.fmt.allocPrint(a, "root/{s}", .{item.key_ptr.*});
            defer a.free(path);
            if (item.value_ptr.* == .null) try std.testing.expectError(error.FileNotFound, f.tmp.dir.access(io, path, .{})) else try f.expect(path, item.value_ptr.string);
        }
        if (string(case, "inventory")) |bytes| try f.expect("db/local/demo-2-1/files", bytes) else try std.testing.expectError(error.FileNotFound, f.tmp.dir.access(io, "db/local/demo-2-1/files", .{}));
        const expected = case.object.get("events").?.array.items;
        try std.testing.expectEqual(expected.len, events.values.items.len);
        for (expected, events.values.items) |native, actual| {
            try std.testing.expectEqual(native.array.items[0].integer, actual[0]);
            try std.testing.expectEqual(native.array.items[1].integer, actual[1]);
        }
        try std.testing.expectError(error.FileNotFound, f.tmp.dir.access(io, "db/.rlpm-local-stage", .{}));
    }
}

test "M10 reason changes persist under lock and invalidate references" {
    var f = try Fixture.init();
    defer f.deinit();
    var archive = try package("1-1", "first");
    defer archive.deinit();
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    try apply(&owner, archive.path, flags);
    const ref = (try owner.findPackage(owner.localDatabase().?, "demo")).?;
    try owner.setInstallReason(io, ref, .dependency);
    try std.testing.expectError(error.StalePackageReference, owner.package(ref));
    try owner.loadDatabase(io, owner.localDatabase().?);
    const new_ref = (try owner.findPackage(owner.localDatabase().?, "demo")).?;
    try std.testing.expectEqual(.dependency, (try owner.packageMetadata(io, new_ref, .{})).install_reason.?);
    try owner.setInstallReason(io, new_ref, .explicit);
    var fresh = try f.owner();
    defer fresh.deinit() catch unreachable;
    const fresh_ref = (try fresh.findPackage(fresh.localDatabase().?, "demo")).?;
    try std.testing.expectEqual(.explicit, (try fresh.packageMetadata(io, fresh_ref, .{})).install_reason.?);
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.access(io, "db/db.lck", .{}));
}

test "M10 boundary failures retain precise partial results and readable database" {
    const E = rlpm.Transaction.Executor;
    inline for (.{ E.Boundary.pre_hooks, .pre_scriptlet, .extract, .database_write, .database_publish, .cache_reload, .post_scriptlet, .post_hooks }) |boundary| {
        var f = try Fixture.init();
        defer f.deinit();
        var archive = try package("1-1", "first");
        defer archive.deinit();
        var owner = try f.owner();
        defer owner.deinit() catch unreachable;
        const tx = try owner.initializeTransaction(io, flags);
        defer owner.releaseTransaction() catch unreachable;
        try Fixture.add(tx, archive.path);
        try tx.prepare();
        E.test_fault = boundary;
        defer E.test_fault = null;
        try std.testing.expectError(error.InjectedExecutionFailure, tx.commit());
        try std.testing.expectEqual(.failed, tx.state);
        try std.testing.expectEqual(boundary, tx.execution.boundary);
        try std.testing.expectEqual(boundary == .cache_reload or boundary == .post_scriptlet or boundary == .post_hooks, tx.execution.database_published);
        var fresh = try f.owner();
        defer fresh.deinit() catch unreachable;
        try std.testing.expectEqual(tx.execution.database_published, (try fresh.findPackage(fresh.localDatabase().?, "demo")) != null);
        try std.testing.expectError(error.FileNotFound, f.tmp.dir.access(io, "db/.rlpm-local-stage", .{}));
    }
}

test "M10 journal recovery restores coherent old records at each interrupted rename" {
    for (0..4) |step| {
        var f = try Fixture.init();
        defer f.deinit();
        const old_path = if (step == 1 or step == 2) "db/.rlpm-local-stage/old/desc" else "db/local/demo-1-1/desc";
        const new_path = if (step == 2) "db/local/demo-2-1/desc" else "db/.rlpm-local-stage/record/desc";
        try f.write(old_path, "%NAME%\ndemo\n\n%VERSION%\n1-1\n\n");
        try f.write(new_path, "%NAME%\ndemo\n\n%VERSION%\n2-1\n\n");
        try f.write("db/.rlpm-local-stage/journal", "demo-1-1\ndemo-2-1\n");
        try std.testing.expectError(error.DatabaseRecoveryRequired, f.owner());
        try rlpm.Owner.recoverLocalDatabase(io, a, f.db);
        try rlpm.Owner.recoverLocalDatabase(io, a, f.db);
        var owner = try f.owner();
        defer owner.deinit() catch unreachable;
        const ref = (try owner.findPackage(owner.localDatabase().?, "demo")).?;
        try std.testing.expectEqualStrings("1-1", (try owner.package(ref)).version.raw);
        try std.testing.expectEqual(1, (try owner.packageIds(owner.localDatabase().?)).len);
        try std.testing.expectError(error.FileNotFound, f.tmp.dir.access(io, "db/.rlpm-local-stage", .{}));
        try std.testing.expectError(error.FileNotFound, f.tmp.dir.access(io, "db/db.lck", .{}));
    }
}

test "M10 file-directory transitions retain unowned and shared contents" {
    var f = try Fixture.init();
    defer f.deinit();
    var old = try Archive.init(&.{ .{ .path = ".PKGINFO", .contents = "pkgname = demo\npkgver = 1-1\narch = any\n" }, .{ .path = "path", .contents = "file" } }, .none);
    defer old.deinit();
    var new = try Archive.init(&.{ .{ .path = ".PKGINFO", .contents = "pkgname = demo\npkgver = 2-1\narch = any\n" }, .{ .path = "path/", .kind = .directory }, .{ .path = "path/child", .contents = "child" } }, .none);
    defer new.deinit();
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    try apply(&owner, old.path, flags);
    try apply(&owner, new.path, flags);
    try f.expect("root/path/child", "child");
    try apply(&owner, old.path, flags);
    try f.expect("root/path", "file");
    try apply(&owner, new.path, flags);
    try f.write("root/path/foreign", "preserved");
    const tx = try owner.initializeTransaction(io, flags);
    defer owner.releaseTransaction() catch unreachable;
    try tx.remove("demo");
    try tx.prepare();
    try tx.commit();
    try f.expect("root/path/foreign", "preserved");
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.access(io, "root/path/child", .{}));
}

test "M10 cancellation after one package keeps plan views completed remaining and fresh state" {
    var f = try Fixture.init();
    defer f.deinit();
    var one = try Archive.init(&.{ .{ .path = ".PKGINFO", .contents = "pkgname = one\npkgver = 1-1\narch = any\n" }, .{ .path = "one", .contents = "one" } }, .none);
    defer one.deinit();
    var two = try Archive.init(&.{ .{ .path = ".PKGINFO", .contents = "pkgname = two\npkgver = 1-1\narch = any\n" }, .{ .path = "two", .contents = "two" } }, .none);
    defer two.deinit();
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    const Cancel = struct {
        fn event(context: ?*anyopaque, value: rlpm.Callbacks.Event) void {
            const target: *rlpm.Owner = @ptrCast(@alignCast(context.?));
            if (value == .package_operation and value.package_operation.boundary == .done) target.requestCancellation();
        }
    };
    try owner.setCallbacks(.{ .event = Cancel.event, .event_context = &owner });
    const tx = try owner.initializeTransaction(io, flags);
    defer owner.releaseTransaction() catch unreachable;
    try Fixture.add(tx, one.path);
    try Fixture.add(tx, two.path);
    try tx.prepare();
    const first = tx.plan().?.additions[0].package;
    const last = tx.plan().?.additions[1].package;
    try std.testing.expectError(error.Cancelled, tx.commit());
    try std.testing.expectEqual(.interrupted, tx.state);
    try std.testing.expectEqual(1, tx.execution.completed.items.len);
    try std.testing.expectEqual(last, tx.execution.remaining[0]);
    var fresh = try f.owner();
    defer fresh.deinit() catch unreachable;
    try std.testing.expect((try fresh.findPackage(fresh.localDatabase().?, tx.plan().?.package(first).name)) != null);
    try std.testing.expect((try fresh.findPackage(fresh.localDatabase().?, tx.plan().?.package(last).name)) == null);
}

test "M10 actual write failure records path and never publishes a partial package" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.createDirPath(io, "root/conf.pacnew");
    // Inject a destination type conflict after successful preflight.
    var archive = try package("1-1", "data");
    defer archive.deinit();
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    const Conflict = struct {
        fn event(context: ?*anyopaque, value: rlpm.Callbacks.Event) void {
            const fixture: *Fixture = @ptrCast(@alignCast(context.?));
            if (value == .package_operation and value.package_operation.boundary == .start) fixture.tmp.dir.createDirPath(io, "root/usr/data") catch unreachable;
        }
    };
    try owner.setCallbacks(.{ .event = Conflict.event, .event_context = &f });
    const tx = try owner.initializeTransaction(io, flags);
    defer owner.releaseTransaction() catch unreachable;
    try Fixture.add(tx, archive.path);
    try tx.prepare();
    try tx.preflight();
    try std.testing.expectError(error.PathTypeConflict, tx.commit());
    try std.testing.expectEqual(.extract, tx.execution.boundary);
    try std.testing.expectEqualStrings("usr/data", tx.execution.path.?);
    try std.testing.expect(tx.execution.mutations > 0);
    try std.testing.expect(!tx.execution.database_published);
    var fresh = try f.owner();
    defer fresh.deinit() catch unreachable;
    try std.testing.expect((try fresh.findPackage(fresh.localDatabase().?, "demo")) == null);
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.access(io, "db/.rlpm-local-stage", .{}));
}

test "M10 confined executor rejects replaced roots before any mutation" {
    var f = try Fixture.init();
    defer f.deinit();
    var archive = try package("1-1", "data");
    defer archive.deinit();
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    const Replace = struct {
        fn event(context: ?*anyopaque, value: rlpm.Callbacks.Event) void {
            const fixture: *Fixture = @ptrCast(@alignCast(context.?));
            if (value == .package_operation and value.package_operation.boundary == .start) {
                fixture.tmp.dir.rename("root", fixture.tmp.dir, "old-root", io) catch unreachable;
                fixture.tmp.dir.createDir(io, "root", .default_dir) catch unreachable;
            }
        }
    };
    try owner.setCallbacks(.{ .event = Replace.event, .event_context = &f });
    const tx = try owner.initializeTransaction(io, flags);
    defer owner.releaseTransaction() catch unreachable;
    try Fixture.add(tx, archive.path);
    try tx.prepare();
    try std.testing.expectError(error.StaleFilesystemState, tx.commit());
    try std.testing.expectEqual(0, tx.execution.mutations);
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.access(io, "old-root/etc/conf", .{}));
}

test "M10 repository commit retains CachyOS installed database validation and install reason" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.createDirPath(io, "cache");
    try f.tmp.dir.createDirPath(io, "db/sync");
    var archive = try package("1-1", "first");
    defer archive.deinit();
    try std.Io.Dir.cwd().copyFile(archive.path, f.tmp.dir, "cache/demo.pkg.tar.zst", io, .{});
    const stat = try std.Io.Dir.cwd().statFile(io, archive.path, .{});
    const metadata = try std.fmt.allocPrint(a, "%NAME%\ndemo\n\n%VERSION%\n1-1\n\n%FILENAME%\ndemo.pkg.tar.zst\n\n%CSIZE%\n{d}\n\n%ISIZE%\n14\n\n%ARCH%\nany\n\n", .{stat.size});
    defer a.free(metadata);
    var repository = try Archive.init(&.{.{ .path = "demo-1-1/desc", .contents = metadata }}, .none);
    defer repository.deinit();
    try std.Io.Dir.cwd().copyFile(repository.path, f.tmp.dir, "db/sync/cachyos.db", io, .{});
    const cache = try f.tmp.dir.realPathFileAlloc(io, "cache", a);
    defer a.free(cache);
    var owner = try rlpm.Owner.init(io, a, .{ .root = f.root, .database_path = f.db, .cache_directories = &.{cache} }, &.{.{ .database_name = "cachyos" }});
    defer owner.deinit() catch unreachable;
    var mode = flags;
    mode.all_dependencies = true;
    mode.all_explicit = true;
    const tx = try owner.initializeTransaction(io, mode);
    defer owner.releaseTransaction() catch unreachable;
    try tx.addTarget("demo");
    try tx.prepare();
    try tx.commit();
    var fresh = try f.owner();
    defer fresh.deinit() catch unreachable;
    const ref = (try fresh.findPackage(fresh.localDatabase().?, "demo")).?;
    const installed = try fresh.packageMetadata(io, ref, .{});
    try std.testing.expectEqualStrings("cachyos", installed.installed_database.?);
    try std.testing.expectEqual(.dependency, installed.install_reason.?); // ALLDEPS wins
    try std.testing.expect(installed.validation.none);
}

test "M10 ownership transfer and shared directories survive an ordered multi-package upgrade" {
    var f = try Fixture.init();
    defer f.deinit();
    var old = try Archive.init(&.{ .{ .path = ".PKGINFO", .contents = "pkgname = old\npkgver = 1-1\narch = any\n" }, .{ .path = "shared/", .kind = .directory }, .{ .path = "shared/data", .contents = "old" } }, .none);
    defer old.deinit();
    var replacement = try Archive.init(&.{ .{ .path = ".PKGINFO", .contents = "pkgname = new\npkgver = 1-1\narch = any\n" }, .{ .path = "shared/", .kind = .directory }, .{ .path = "shared/data", .contents = "new" } }, .none);
    defer replacement.deinit();
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    try apply(&owner, old.path, flags);
    const tx = try owner.initializeTransaction(io, flags);
    defer owner.releaseTransaction() catch unreachable;
    try tx.remove("old");
    try Fixture.add(tx, replacement.path);
    try tx.prepare();
    try tx.commit();
    try f.expect("root/shared/data", "new");
    try std.testing.expectEqual(2, tx.result().packages_committed);
    var fresh = try f.owner();
    defer fresh.deinit() catch unreachable;
    try std.testing.expect((try fresh.findPackage(fresh.localDatabase().?, "old")) == null);
    try std.testing.expect((try fresh.findPackage(fresh.localDatabase().?, "new")) != null);
}

test "M10 removal failure retains installed record and pending work" {
    var f = try Fixture.init();
    defer f.deinit();
    var archive = try package("1-1", "first");
    defer archive.deinit();
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    try apply(&owner, archive.path, flags);
    const tx = try owner.initializeTransaction(io, flags);
    defer owner.releaseTransaction() catch unreachable;
    try tx.remove("demo");
    try tx.prepare();
    rlpm.Transaction.Executor.test_fault = .remove;
    defer rlpm.Transaction.Executor.test_fault = null;
    try std.testing.expectError(error.InjectedExecutionFailure, tx.commit());
    try std.testing.expectEqual(0, tx.result().packages_committed);
    try std.testing.expectEqual(1, tx.execution.remaining.len);
    try std.testing.expect(tx.execution.path != null);
    try f.expect("root/etc/conf", "first");
    var fresh = try f.owner();
    defer fresh.deinit() catch unreachable;
    try std.testing.expect((try fresh.findPackage(fresh.localDatabase().?, "demo")) != null);
}

test "M10 audit writes configured log and absolute symlinks cannot alter external attributes" {
    const c = @cImport({
        @cInclude("sys/stat.h");
    });
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("outside", "external sentinel");
    const outside = try f.tmp.dir.realPathFileAlloc(io, "outside", a);
    defer a.free(outside);
    var before: c.struct_stat = undefined;
    try std.testing.expectEqual(0, c.stat(outside, &before));
    var archive = try Archive.init(&.{ .{ .path = ".PKGINFO", .contents = "pkgname = demo\npkgver = 1-1\narch = any\n" }, .{ .path = "external", .kind = .symlink, .target = outside, .mtime = 42 } }, .none);
    defer archive.deinit();
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    const logfile = try std.fmt.allocPrint(a, "{s}/audit.log", .{f.db});
    defer a.free(logfile);
    var options = owner.options();
    options.log_file = logfile;
    try owner.setOptions(io, options);
    try apply(&owner, archive.path, flags);
    const log = try f.read("db/audit.log");
    defer a.free(log);
    const started = std.mem.indexOf(u8, log, "[ALPM] transaction started\n").?;
    const installed = std.mem.indexOf(u8, log, "[ALPM] installed demo (1-1)\n").?;
    const done = std.mem.indexOf(u8, log, "[ALPM] transaction completed\n").?;
    try std.testing.expect(started < installed and installed < done);
    var after: c.struct_stat = undefined;
    try std.testing.expectEqual(0, c.stat(outside, &after));
    try std.testing.expectEqual(before.st_mtim.tv_sec, after.st_mtim.tv_sec);
    try std.testing.expectEqual(before.st_mode, after.st_mode);
    try f.expect("outside", "external sentinel");
}
