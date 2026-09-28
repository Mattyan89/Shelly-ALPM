const Database = @This();

const std = @import("std");
const Package = @import("Package.zig");
const Group = @import("Group.zig");
const DatabaseStatus = @import("DatabaseStatus.zig");
const SignaturePolicy = @import("SignaturePolicy.zig");
const DatabaseUsage = @import("DatabaseUsage.zig");
const ParsedDescription = @import("ParsedDescription.zig");
const ShellyKey = @import("Shelly_Key");
const DatabaseConfiguration = @import("DatabaseConfiguration.zig");
const DatabaseRef = @import("DatabaseRef.zig");

pub const PackageId = @import("PackageRef.zig").Id;
pub const Kind = enum { local, sync };

pub const GroupId = enum(u32) {
    _,
};

pub const GroupIndex = struct {
    groups: std.ArrayList(Group) = .empty,
    by_name: std.StringHashMapUnmanaged(GroupId) = .empty,
    ordered: std.ArrayList(GroupId) = .empty,
};

pub const PackageIndex = struct {
    packages: std.ArrayList(Package) = .empty,
    by_name: std.StringHashMapUnmanaged(PackageId) = .empty,
    ordered: std.ArrayList(PackageId) = .empty,
};

allocator: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
cache_arena: std.heap.ArenaAllocator,
kind: Kind = .local,
identity: ?DatabaseRef = null,
generation: u64 = 1,

name: []const u8,
path: []const u8,

packages: PackageIndex = .{},
groups: GroupIndex = .{},

cache_servers: std.ArrayList([]const u8) = .empty,
servers: std.ArrayList([]const u8) = .empty,

status: DatabaseStatus = .{},
signature_policy: SignaturePolicy = .{},
signature_override: ?SignaturePolicy = null,
usage: DatabaseUsage = .{},

pub fn init(
    allocator: std.mem.Allocator,
    name: []const u8,
    path: []const u8,
    signature_policy: SignaturePolicy,
) !Database {
    var result: Database = .{
        .path = "",
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .cache_arena = std.heap.ArenaAllocator.init(allocator),
        .name = undefined,
        .signature_policy = signature_policy,
        .signature_override = signature_policy,
    };
    errdefer result.arena.deinit();

    const database_allocator = result.arena.allocator();
    result.name = try database_allocator.dupe(u8, name);
    result.path = try database_allocator.dupe(u8, path);
    return result;
}

pub fn initSync(
    allocator: std.mem.Allocator,
    configuration: DatabaseConfiguration,
    path: []const u8,
    default_policy: SignaturePolicy,
) !Database {
    try configuration.validate();
    var result = try init(allocator, configuration.database_name, path, configuration.signature_policy orelse default_policy);
    errdefer result.deinit();
    result.kind = .sync;
    result.signature_override = configuration.signature_policy;
    result.usage = configuration.usage;
    const owned = result.arena.allocator();
    for (configuration.servers) |url| try result.servers.append(owned, try copyServer(owned, url));
    for (configuration.cache_servers) |url| try result.cache_servers.append(owned, try copyServer(owned, url));
    return result;
}

fn copyServer(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    // Match the reference's removal of one terminal slash, preserving order.
    return allocator.dupe(u8, if (std.mem.endsWith(u8, url, "/")) url[0 .. url.len - 1] else url);
}

pub fn configurationView(self: *const Database) DatabaseConfiguration {
    return .{
        .database_name = self.name,
        .signature_policy = self.signature_override,
        .servers = self.servers.items,
        .cache_servers = self.cache_servers.items,
        .usage = self.usage,
    };
}

/// Rebuild registration storage without repeatedly normalizing stored URLs.
pub fn copyRegistration(self: *const Database, path: []const u8, default_policy: SignaturePolicy) !Database {
    var result = try init(self.allocator, self.name, path, self.signature_override orelse default_policy);
    errdefer result.deinit();
    result.kind = self.kind;
    result.identity = self.identity;
    result.generation = std.math.add(u64, self.generation, 1) catch return error.IdentityExhausted;
    result.signature_override = self.signature_override;
    result.usage = self.usage;
    const owned = result.arena.allocator();
    for (self.servers.items) |url| try result.servers.append(owned, try owned.dupe(u8, url));
    for (self.cache_servers.items) |url| try result.cache_servers.append(owned, try owned.dupe(u8, url));
    return result;
}

pub fn deinit(self: *Database) void {
    self.cache_arena.deinit();
    self.arena.deinit();
    self.* = undefined;
}

/// Invalidates PackageRef generations; registration/configuration remain owned.
pub fn invalidateCache(self: *Database) !void {
    const next = std.math.add(u64, self.generation, 1) catch return error.IdentityExhausted;
    self.resetCacheStorage();
    self.generation = next;
    self.status = .{};
}

fn resetCacheStorage(self: *Database) void {
    self.cache_arena.deinit();
    self.cache_arena = std.heap.ArenaAllocator.init(self.allocator);
    self.packages = .{};
    self.groups = .{};
    self.status.clearCaches();
}

pub fn loadDatabase(
    self: *Database,
    io: std.Io,
    gnupg_path: ?[]const u8,
) !void {
    if (self.kind == .sync) return error.UnsupportedDatabaseBackend;
    if (self.status.package_cache_loaded) return error.DatabaseAlreadyLoaded;
    const allocator = self.cache_arena.allocator();
    errdefer self.resetCacheStorage();

    var root_dir = std.Io.Dir.cwd().openDir(io, self.path, .{
        .iterate = true,
        .access_sub_paths = true,
    }) catch |err| {
        if (err == error.FileNotFound) self.status.markMissing();
        return err;
    };
    defer root_dir.close(io);
    self.status.presence = .exists;

    var iterator = root_dir.iterate();

    while (try iterator.next(io)) |entry| {
        // Only consider top-level directories.
        if (entry.kind != .directory and entry.kind != .unknown) continue;

        var package_dir = root_dir.openDir(io, entry.name, .{}) catch |err| switch (err) {
            error.NotDir => continue,
            else => return err,
        };
        defer package_dir.close(io);

        // Look for "desc" inside this directory.
        const contents = package_dir.readFileAlloc(
            io,
            "desc",
            allocator,
            .limited(1024 * 1024),
        ) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.FileNotFound => {
                std.log.warn("package directory {s} has no desc file", .{entry.name});
                continue;
            },
            else => {
                std.log.warn("could not read {s}/desc: {}", .{ entry.name, err });
                continue;
            },
        };

        // The arena retains contents because Package fields borrow slices from it.
        var parsed = parseDescription(allocator, contents) catch |err| {
            if (err == error.OutOfMemory) return err;
            std.log.warn("could not parse {s}/desc: {}", .{ entry.name, err });
            continue;
        };
        defer parsed.deinit(allocator);

        const package = parsed.intoPackage(&self.cache_arena, .{ .origin = .local, .database_name = self.name }) catch |err| {
            if (err == error.OutOfMemory) return err;
            std.log.warn("could not create package from {s}/desc: {}", .{ entry.name, err });
            continue;
        };

        if (!entryMatchesPackage(entry.name, package)) {
            std.log.warn(
                "local database entry {s} does not match {s}-{s}",
                .{ entry.name, package.name, package.version.raw },
            );
            continue;
        }
        if (self.packages.by_name.contains(package.name)) {
            std.log.warn("duplicate local database package: {s}", .{package.name});
            continue;
        }

        const package_id: PackageId = @enumFromInt(
            @as(u32, @intCast(self.packages.packages.items.len)),
        );
        try self.packages.packages.append(allocator, package);
        try self.packages.by_name.put(allocator, package.name, package_id);
        try self.packages.ordered.append(allocator, package_id);
    }

    std.mem.sort(PackageId, self.packages.ordered.items, self, struct {
        fn lessThan(db: *Database, a: PackageId, b: PackageId) bool {
            return std.mem.lessThan(u8, db.packages.packages.items[@intFromEnum(a)].name, db.packages.packages.items[@intFromEnum(b)].name);
        }
    }.lessThan);
    try self.buildGroupIndex(allocator);
    if (self.signature_policy.database == .required and !try self.validateSignature(
        io,
        gnupg_path,
    ))
        return error.InvalidSignature;
    self.status.markValid();
    self.status.package_cache_loaded = true;
    self.status.group_cache_loaded = true;
}

fn entryMatchesPackage(entry_name: []const u8, package: Package) bool {
    const separator_index = package.name.len;
    return entry_name.len == package.name.len + 1 + package.version.raw.len and
        std.mem.eql(u8, entry_name[0..separator_index], package.name) and
        entry_name[separator_index] == '-' and
        std.mem.eql(u8, entry_name[separator_index + 1 ..], package.version.raw);
}

fn buildGroupIndex(self: *Database, allocator: std.mem.Allocator) !void {
    for (self.packages.ordered.items) |package_id| {
        const package = self.packages.packages.items[@intFromEnum(package_id)];
        for (package.groups) |group_name| {
            const group_id = self.groups.by_name.get(group_name) orelse create: {
                const id: GroupId = @enumFromInt(
                    @as(u32, @intCast(self.groups.groups.items.len)),
                );
                try self.groups.groups.append(allocator, .{
                    .name = group_name,
                    .packages = .empty,
                });
                try self.groups.by_name.put(allocator, group_name, id);
                try self.groups.ordered.append(allocator, id);
                break :create id;
            };
            try self.groups.groups.items[@intFromEnum(group_id)].packages.append(allocator, package_id);
        }
    }
    std.mem.sort(GroupId, self.groups.ordered.items, self, struct {
        fn lessThan(db: *Database, a: GroupId, b: GroupId) bool {
            return std.mem.lessThan(u8, db.groups.groups.items[@intFromEnum(a)].name, db.groups.groups.items[@intFromEnum(b)].name);
        }
    }.lessThan);
}

fn parseDescription(allocator: std.mem.Allocator, contents: []const u8) !ParsedDescription {
    return ParsedDescription.parse(allocator, contents);
}

fn freeStrings(
    allocator: std.mem.Allocator,
    strings: *std.ArrayList([]u8),
) void {
    for (strings.items) |string| {
        allocator.free(string);
    }
    strings.deinit(allocator);
    strings.* = .empty;
}

pub fn validateSignature(
    self: *Database,
    io: std.Io,
    gnupg_path: ?[]const u8,
) !bool {
    const gpg_path = if (gnupg_path) |path| path else "/etc/pacman.d/gnupg";
    const gpg: ShellyKey.gpg.Gpg = .{
        .io = io,
        .homedir = gpg_path,
    };
    const db_name = try std.fmt.allocPrint(self.allocator, "{s}.db", .{self.name});
    defer self.allocator.free(db_name);
    const db_path = try std.fs.path.join(self.allocator, &.{ self.path, db_name });
    defer self.allocator.free(db_path);
    const sig_path = try std.fmt.allocPrint(self.allocator, "{s}.sig", .{db_path});
    defer self.allocator.free(sig_path);

    const status = gpg.runCapture(self.allocator, &.{
        "--batch",
        "--no-auto-check-trustdb",
        "--status-fd",
        "1",
        "--verify",
        sig_path,
        db_path,
    }) catch |err| switch (err) {
        error.GpgFailed => return false,
        else => return err,
    };
    defer self.allocator.free(status);
    return true;
}

test "parseDescription parses a local database desc entry" {
    const contents =
        \\%NAME%
        \\demo
        \\
        \\%VERSION%
        \\1.2.3-4
        \\
        \\%DESC%
        \\Demo package
        \\
        \\%INSTALLED_DB%
        \\extra
        \\
        \\%SIZE%
        \\4096
        \\
        \\%REASON%
        \\1
        \\
        \\%DEPENDS%
        \\glibc>=2.39
        \\
        \\%OPTDEPENDS%
        \\docs: documentation support
        \\
        \\%XDATA%
        \\pkgtype=pkg
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var parsed = try parseDescription(allocator, contents);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("demo", parsed.name.?);
    try std.testing.expectEqualStrings("extra", parsed.installed_database.?);
    try std.testing.expectEqualStrings("glibc>=2.39", parsed.depends.items[0]);

    const package = try parsed.intoPackage(&arena, .{ .origin = .local, .database_name = "local" });
    try std.testing.expectEqualStrings("demo", package.name);
    try std.testing.expectEqualStrings("extra", package.installed_database.?);
    try std.testing.expectEqualStrings("glibc", package.depends[0].name);
    try std.testing.expectEqualStrings("documentation support", package.optional_depends[0].description.?);
}

test "parseDescription covers every supported local database field" {
    const contents =
        \\%NAME%
        \\demo
        \\
        \\%VERSION%
        \\2:1.2.3-4
        \\
        \\%BASE%
        \\demo-base
        \\
        \\%DESC%
        \\A complete parser fixture
        \\
        \\%GROUPS%
        \\base
        \\tools
        \\
        \\%URL%
        \\https://example.test/demo
        \\
        \\%LICENSE%
        \\MIT
        \\Apache-2.0
        \\
        \\%ARCH%
        \\x86_64
        \\
        \\%BUILDDATE%
        \\1700000000
        \\
        \\%INSTALLDATE%
        \\1700000100
        \\
        \\%PACKAGER%
        \\Shelly Tests <tests@example.test>
        \\
        \\%INSTALLED_DB%
        \\extra
        \\
        \\%SIZE%
        \\8192
        \\
        \\%REASON%
        \\0
        \\
        \\%VALIDATION%
        \\none
        \\sha256
        \\pgp
        \\
        \\%DEPENDS%
        \\glibc>=2.39
        \\zlib
        \\
        \\%OPTDEPENDS%
        \\docs: documentation support
        \\
        \\%MAKEDEPENDS%
        \\cmake>=3
        \\
        \\%CHECKDEPENDS%
        \\pytest
        \\
        \\%CONFLICTS%
        \\demo-old<2
        \\
        \\%PROVIDES%
        \\virtual-demo=2:1.2.3
        \\
        \\%REPLACES%
        \\old-demo<=1
        \\
        \\%XDATA%
        \\pkgtype=pkg
        \\detail=value=containing=equals
        \\
        \\%FUTURE_FIELD%
        \\ignored value
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var parsed = try parseDescription(allocator, contents);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("demo", parsed.name.?);
    try std.testing.expectEqualStrings("2:1.2.3-4", parsed.version.?);
    try std.testing.expectEqualStrings("demo-base", parsed.base.?);
    try std.testing.expectEqualStrings("A complete parser fixture", parsed.description.?);
    try std.testing.expectEqual(@as(usize, 2), parsed.groups.items.len);
    try std.testing.expectEqual(@as(usize, 2), parsed.licenses.items.len);
    try std.testing.expectEqual(@as(i64, 1700000000), parsed.build_date.?);
    try std.testing.expectEqual(@as(i64, 1700000100), parsed.install_date.?);
    try std.testing.expectEqual(@as(u64, 8192), parsed.installed_size.?);
    try std.testing.expect(parsed.validation.none);
    try std.testing.expect(parsed.validation.sha256);
    try std.testing.expect(parsed.validation.pgp);
    try std.testing.expectEqual(@as(usize, 2), parsed.xdata.items.len);
    try std.testing.expectEqualStrings("value=containing=equals", parsed.xdata.items[1].value);

    const package = try parsed.intoPackage(&arena, .{ .origin = .local, .database_name = "local" });
    try std.testing.expectEqualStrings("demo", package.name);
    try std.testing.expectEqualStrings("2", package.version.epoch);
    try std.testing.expectEqualStrings("1.2.3", package.version.pkgver);
    try std.testing.expectEqualStrings("4", package.version.pkgrel.?);
    try std.testing.expectEqualStrings("extra", package.installed_database.?);
    try std.testing.expectEqual(Package.InstallReason.explicit, package.install_reason.?);
    try std.testing.expectEqualStrings("https://example.test/demo", package.url.?);
    try std.testing.expectEqualStrings("x86_64", package.architecture.?);
    try std.testing.expectEqualStrings("Shelly Tests <tests@example.test>", package.packager.?);
    try std.testing.expectEqualStrings("MIT", package.licenses[0]);
    try std.testing.expectEqualStrings("tools", package.groups[1]);

    try std.testing.expectEqualStrings("glibc", package.depends[0].name);
    switch (package.depends[0].constraint) {
        .greater_equal => |version| try std.testing.expectEqualStrings("2.39", version),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("zlib", package.depends[1].name);
    try std.testing.expect(package.depends[1].constraint == .any);
    try std.testing.expectEqualStrings("documentation support", package.optional_depends[0].description.?);
    try std.testing.expectEqualStrings("cmake", package.make_depends[0].name);
    try std.testing.expectEqualStrings("pytest", package.check_depends[0].name);
    try std.testing.expectEqualStrings("demo-old", package.conflicts[0].name);
    try std.testing.expectEqualStrings("virtual-demo", package.provides[0].name);
    switch (package.provides[0].constraint) {
        .equal => |version| try std.testing.expectEqualStrings("2:1.2.3", version),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("old-demo", package.replaces[0].name);
}

test "parseDescription accepts CRLF and ignores unknown sections" {
    const contents =
        "%NAME%\r\ndemo\r\n\r\n" ++
        "%UNKNOWN%\r\nignored\r\n\r\n" ++
        "%VERSION%\r\n1.0-1\r\n";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var parsed = try parseDescription(allocator, contents);
    defer parsed.deinit(allocator);
    const package = try parsed.intoPackage(&arena, .{ .origin = .local, .database_name = "local" });

    try std.testing.expectEqualStrings("demo", package.name);
    try std.testing.expectEqualStrings("0", package.version.epoch);
    try std.testing.expectEqualStrings("1.0", package.version.pkgver);
    try std.testing.expectEqualStrings("1", package.version.pkgrel.?);
}

test "parseDescription rejects malformed scalar values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(
        error.ValueOutsideSection,
        parseDescription(allocator, "orphan value\n"),
    );
    try std.testing.expectError(
        error.DuplicateValue,
        parseDescription(allocator, "%NAME%\ndemo\nduplicate\n"),
    );
    try std.testing.expectError(
        error.InvalidCharacter,
        parseDescription(allocator, "%BUILDDATE%\nnot-a-number\n"),
    );
    var unknown_reason = try parseDescription(allocator, "%REASON%\n9\n");
    defer unknown_reason.deinit(allocator);
    try std.testing.expectEqual(.unknown, unknown_reason.reason.?);
    try std.testing.expectError(
        error.InvalidXData,
        parseDescription(allocator, "%XDATA%\nmissing-equals\n"),
    );
}

test "ParsedDescription requires package identity and valid relations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var missing_name = try parseDescription(allocator, "%VERSION%\n1.0-1\n");
    defer missing_name.deinit(allocator);
    try std.testing.expectError(
        error.MissingPackageName,
        missing_name.intoPackage(&arena, .{ .origin = .local, .database_name = "local" }),
    );

    var missing_version = try parseDescription(allocator, "%NAME%\ndemo\n");
    defer missing_version.deinit(allocator);
    try std.testing.expectError(
        error.MissingPackageVersion,
        missing_version.intoPackage(&arena, .{ .origin = .local, .database_name = "local" }),
    );

    var invalid_relation = try parseDescription(
        allocator,
        "%NAME%\ndemo\n\n%VERSION%\n1.0-1\n\n%DEPENDS%\ninvalid\x00relation\n",
    );
    defer invalid_relation.deinit(allocator);
    try std.testing.expectError(
        error.InvalidPackageRelation,
        invalid_relation.intoPackage(&arena, .{ .origin = .local, .database_name = "local" }),
    );
}

test "loadDatabase owns and indexes parsed packages" {
    const contents =
        \\%NAME%
        \\demo
        \\
        \\%VERSION%
        \\1.2.3-4
        \\
        \\%DESC%
        \\Demo package
        \\
        \\%GROUPS%
        \\base
        \\
        \\%DEPENDS%
        \\glibc
    ;

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(std.testing.io, "demo-1.2.3-4", .default_dir);
    var package_dir = try temporary.dir.openDir(std.testing.io, "demo-1.2.3-4", .{});
    defer package_dir.close(std.testing.io);
    try package_dir.writeFile(std.testing.io, .{
        .sub_path = "desc",
        .data = contents,
    });

    const path = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);

    var database = try Database.init(std.testing.allocator, "local", path, .{});
    defer database.deinit();
    database.signature_policy.database = .disabled;
    try database.loadDatabase(std.testing.io, null);

    try std.testing.expect(database.status.package_cache_loaded);
    try std.testing.expectEqual(@as(usize, 1), database.packages.packages.items.len);
    const package_id = database.packages.by_name.get("demo") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(package_id));
    const package = database.packages.packages.items[@intFromEnum(package_id)];
    try std.testing.expectEqualStrings("demo", package.name);
    try std.testing.expectEqualStrings("1.2.3-4", package.version.raw);
    try std.testing.expectEqualStrings("glibc", package.depends[0].name);
    const group_id = database.groups.by_name.get("base") orelse return error.TestUnexpectedResult;
    const group = database.groups.groups.items[@intFromEnum(group_id)];
    try std.testing.expectEqual(@as(usize, 1), group.packages.items.len);
    try std.testing.expectEqual(package_id, group.packages.items[0]);
    try std.testing.expectError(
        error.DatabaseAlreadyLoaded,
        database.loadDatabase(std.testing.io, null),
    );
}

test "loadDatabase skips missing and malformed package descriptions" {
    const previous_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = previous_log_level;

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    try temporary.dir.createDir(std.testing.io, "valid-1.0-1", .default_dir);
    try temporary.dir.createDir(std.testing.io, "malformed-1.0-1", .default_dir);
    try temporary.dir.createDir(std.testing.io, "missing-1.0-1", .default_dir);

    {
        var valid_dir = try temporary.dir.openDir(std.testing.io, "valid-1.0-1", .{});
        defer valid_dir.close(std.testing.io);
        try valid_dir.writeFile(std.testing.io, .{
            .sub_path = "desc",
            .data = "%NAME%\nvalid\n\n%VERSION%\n1.0-1\n",
        });
    }
    {
        var malformed_dir = try temporary.dir.openDir(std.testing.io, "malformed-1.0-1", .{});
        defer malformed_dir.close(std.testing.io);
        try malformed_dir.writeFile(std.testing.io, .{
            .sub_path = "desc",
            .data = "%NAME%\nmalformed\n",
        });
    }

    const path = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);

    var database = try Database.init(std.testing.allocator, "local", path, .{});
    defer database.deinit();
    database.signature_policy.database = .disabled;
    try database.loadDatabase(std.testing.io, null);

    try std.testing.expectEqual(@as(usize, 1), database.packages.packages.items.len);
    try std.testing.expect(database.packages.by_name.contains("valid"));
    try std.testing.expect(!database.packages.by_name.contains("malformed"));
    try std.testing.expect(!database.packages.by_name.contains("missing"));
}

/// Opt-in host smoke tests; never referenced by the ordinary test root.
pub const HostTests = struct {
    test "host-readonly: parses the actual local package database" {
        const local_database_path = "/var/lib/pacman/local";
        var probe = std.Io.Dir.cwd().openDir(std.testing.io, local_database_path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied => return error.SkipZigTest,
            else => return err,
        };
        probe.close(std.testing.io);

        const previous_log_level = std.testing.log_level;
        std.testing.log_level = .err;
        defer std.testing.log_level = previous_log_level;

        var database = try Database.init(std.testing.allocator, "local", local_database_path, .{});
        defer database.deinit();
        database.signature_policy.database = .disabled;
        try database.loadDatabase(std.testing.io, null);

        try std.testing.expect(database.status.package_cache_loaded);
        try std.testing.expect(database.packages.packages.items.len > 0);
        try std.testing.expectEqual(
            database.packages.packages.items.len,
            database.packages.ordered.items.len,
        );
        try std.testing.expectEqual(
            database.packages.packages.items.len,
            database.packages.by_name.count(),
        );

        const preview_count = @min(database.packages.ordered.items.len, 5);
        std.debug.print(
            "\nlocal database preview ({d} of {d} packages):\n",
            .{ preview_count, database.packages.packages.items.len },
        );
        for (database.packages.ordered.items[0..preview_count]) |package_id| {
            const package = database.packages.packages.items[@intFromEnum(package_id)];
            std.debug.print("  {s} {s}\n", .{ package.name, package.version.raw });
        }

        for (database.packages.ordered.items) |package_id| {
            const package = database.packages.packages.items[@intFromEnum(package_id)];
            try std.testing.expect(package.name.len > 0);
            try std.testing.expect(package.version.raw.len > 0);
            try std.testing.expectEqual(
                package_id,
                database.packages.by_name.get(package.name).?,
            );
        }
    }

    test "host-readonly: parses descriptions from actual sync databases" {
        const sync_database_path = "/var/lib/pacman/sync";
        var sync_dir = std.Io.Dir.cwd().openDir(std.testing.io, sync_database_path, .{
            .iterate = true,
            .access_sub_paths = true,
        }) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied => return error.SkipZigTest,
            else => return err,
        };
        defer sync_dir.close(std.testing.io);

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var parsed_databases: usize = 0;
        var parsed_packages: usize = 0;
        var preview_remaining: usize = 10;
        std.debug.print("\nsync database preview (up to {d} packages):\n", .{preview_remaining});

        var iterator = sync_dir.iterate();
        while (try iterator.next(std.testing.io)) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".db")) continue;
            if (entry.kind != .file and entry.kind != .sym_link and entry.kind != .unknown) continue;

            var file = sync_dir.openFile(std.testing.io, entry.name, .{}) catch continue;
            defer file.close(std.testing.io);

            var magic: [4]u8 = undefined;
            const magic_length = try file.readPositionalAll(std.testing.io, &magic, 0);
            if (magic_length < 2) continue;

            const archive_contents: []const u8 = archive: {
                if (magic[0] == 0x1f and magic[1] == 0x8b) {
                    var read_buffer: [64 * 1024]u8 = undefined;
                    var file_reader = file.reader(std.testing.io, &read_buffer);
                    var decompression_buffer: [std.compress.flate.max_window_len]u8 = undefined;
                    var decompressor: std.compress.flate.Decompress = .init(
                        &file_reader.interface,
                        .gzip,
                        &decompression_buffer,
                    );
                    break :archive try decompressor.reader.allocRemaining(
                        allocator,
                        .limited(256 * 1024 * 1024),
                    );
                }

                // Zstandard-compressed repository databases need a different
                // decoder. Skip them rather than mistaking them for a tar stream.
                if (magic_length == magic.len and std.mem.eql(u8, &magic, "\x28\xb5\x2f\xfd")) {
                    continue;
                }

                var read_buffer: [64 * 1024]u8 = undefined;
                var file_reader = file.reader(std.testing.io, &read_buffer);
                break :archive try file_reader.interface.allocRemaining(
                    allocator,
                    .limited(256 * 1024 * 1024),
                );
            };

            const database_name = entry.name[0 .. entry.name.len - ".db".len];
            const package_count = try parseSyncTarDescriptions(
                &arena,
                database_name,
                archive_contents,
                &preview_remaining,
            );
            try std.testing.expect(package_count > 0);
            std.debug.print("  [{s}: {d} packages parsed]\n", .{ database_name, package_count });
            parsed_databases += 1;
            parsed_packages += package_count;
        }

        if (parsed_databases == 0) return error.SkipZigTest;
        try std.testing.expect(parsed_packages >= parsed_databases);
    }

    fn parseSyncTarDescriptions(
        arena: *std.heap.ArenaAllocator,
        database_name: []const u8,
        archive_contents: []const u8,
        preview_remaining: *usize,
    ) !usize {
        const allocator = arena.allocator();
        const tar_block_size = 512;
        var offset: usize = 0;
        var package_count: usize = 0;

        while (offset + tar_block_size <= archive_contents.len) {
            const header = archive_contents[offset .. offset + tar_block_size];
            if (isZeroTarBlock(header)) break;

            const file_size = try parseTarOctal(header[124..136]);
            const data_start = offset + tar_block_size;
            if (file_size > archive_contents.len - data_start) return error.TruncatedTarArchive;
            const data_end = data_start + file_size;

            const entry_name = tarString(header[0..100]);
            const type_flag = header[156];
            if ((type_flag == 0 or type_flag == '0') and std.mem.endsWith(u8, entry_name, "/desc")) {
                var parsed = try parseDescription(allocator, archive_contents[data_start..data_end]);
                defer parsed.deinit(allocator);
                const package = try parsed.intoPackage(arena, .{ .origin = .sync, .database_name = database_name });
                if (preview_remaining.* > 0) {
                    std.debug.print(
                        "  {s}/{s} {s}\n",
                        .{ database_name, package.name, package.version.raw },
                    );
                    preview_remaining.* -= 1;
                }
                package_count += 1;
            }

            const remainder = file_size % tar_block_size;
            const padded_size = if (remainder == 0)
                file_size
            else
                file_size + (tar_block_size - remainder);
            if (padded_size > archive_contents.len - data_start) return error.TruncatedTarArchive;
            offset = data_start + padded_size;
        }

        return package_count;
    }

    fn isZeroTarBlock(block: []const u8) bool {
        for (block) |byte| {
            if (byte != 0) return false;
        }
        return true;
    }

    fn tarString(field: []const u8) []const u8 {
        const end = std.mem.indexOfScalar(u8, field, 0) orelse field.len;
        return std.mem.trimEnd(u8, field[0..end], " ");
    }

    fn parseTarOctal(field: []const u8) !usize {
        const digits = std.mem.trim(u8, field, " \x00");
        if (digits.len == 0) return 0;

        var value: usize = 0;
        for (digits) |digit| {
            if (digit < '0' or digit > '7') return error.InvalidTarHeader;
            const numeric_digit: usize = digit - '0';
            if (value > (std.math.maxInt(usize) - numeric_digit) / 8) {
                return error.InvalidTarHeader;
            }
            value = value * 8 + numeric_digit;
        }
        return value;
    }
};

test "freeStrings frees each string and the list storage" {
    const allocator = std.testing.allocator;
    var strings: std.ArrayList([]u8) = .empty;
    defer {
        for (strings.items) |string| allocator.free(string);
        strings.deinit(allocator);
    }

    const first = try allocator.dupe(u8, "https://mirror-one.example");
    strings.append(allocator, first) catch |err| {
        allocator.free(first);
        return err;
    };

    const second = try allocator.dupe(u8, "https://mirror-two.example");
    strings.append(allocator, second) catch |err| {
        allocator.free(second);
        return err;
    };

    freeStrings(allocator, &strings);

    try std.testing.expectEqual(@as(usize, 0), strings.items.len);
    try std.testing.expectEqual(@as(usize, 0), strings.capacity);
}
