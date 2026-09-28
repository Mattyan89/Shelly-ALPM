const Package = @This();

const std = @import("std");
const Version = @import("Version.zig");
const PackageRelation = @import("PackageRelation.zig");
const ParsedDescription = @import("ParsedDescription.zig");
const c = @cImport({
    @cInclude("archive.h");
    @cInclude("archive_entry.h");
});

pub const InstallReason = enum {
    explicit,
    dependency,
};

pub const Validation = struct {
    none: bool = false,
    sha256: bool = false,
    pgp: bool = false,
};

pub const XData = struct {
    name: []const u8,
    value: []const u8,
};

name: []const u8,
version: Version,
database_name: []const u8,
installed_database: ?[]const u8 = null,
base: ?[]const u8 = null,
description: ?[]const u8 = null,
provides: []const PackageRelation = &.{},
depends: []const PackageRelation = &.{},
optional_depends: []const PackageRelation = &.{},
make_depends: []const PackageRelation = &.{},
check_depends: []const PackageRelation = &.{},
conflicts: []const PackageRelation = &.{},
replaces: []const PackageRelation = &.{},
install_reason: ?InstallReason = null,
validation: Validation = .{},
url: ?[]const u8 = null,
architecture: ?[]const u8 = null,
build_date: ?i64 = null,
install_date: ?i64 = null,
installed_size: ?u64 = null,
packager: ?[]const u8 = null,
groups: []const []const u8 = &.{},
licenses: []const []const u8 = &.{},
xdata: []const XData = &.{},
archive_arena: ?std.heap.ArenaAllocator = null,

/// Reads package metadata without extracting the payload or verifying signatures.
/// The result owns its metadata; call deinit once, including across shallow copies.
/// Archives have no repository association, so database_name is empty.
pub fn initializePackageFromArchive(
    allocator: std.mem.Allocator,
    path: []const u8,
) !Package {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    const sentinel_path = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(sentinel_path);

    const archive = c.archive_read_new() orelse return error.OutOfMemory;
    defer _ = c.archive_read_free(archive);

    if (c.archive_read_support_filter_all(archive) != c.ARCHIVE_OK or
        c.archive_read_support_format_tar(archive) != c.ARCHIVE_OK)
        return error.ArchiveFailed;
    if (c.archive_read_open_filename(archive, sentinel_path.ptr, 64 * 1024) != c.ARCHIVE_OK)
        return error.ArchiveFailed;

    var entry: ?*c.struct_archive_entry = null;
    while (true) {
        const status = c.archive_read_next_header(archive, &entry);
        if (status == c.ARCHIVE_EOF) return error.MissingPkginfo;
        if (status != c.ARCHIVE_OK) return error.ArchiveFailed;

        const raw_name = c.archive_entry_pathname(entry);
        if (raw_name == null) return error.ArchiveFailed;
        var name = std.mem.span(raw_name);
        while (std.mem.startsWith(u8, name, "./")) name = name[2..];
        if (!std.mem.eql(u8, name, ".PKGINFO")) {
            if (c.archive_read_data_skip(archive) != c.ARCHIVE_OK)
                return error.ArchiveFailed;
            continue;
        }

        // Use the POSIX constant because some C translators cannot expand AE_IFREG.
        if (c.archive_entry_filetype(entry) != 0o100000 or
            c.archive_entry_hardlink(entry) != null)
            return error.InvalidPkginfo;
        const declared_size = c.archive_entry_size(entry);
        if (declared_size < 0) return error.InvalidPkginfo;
        if (declared_size > max_pkginfo_size) return error.PkginfoTooLarge;

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const package_allocator = arena.allocator();
        var contents: std.ArrayList(u8) = .empty;
        var buffer: [8192]u8 = undefined;
        while (true) {
            const amount = c.archive_read_data(archive, &buffer, buffer.len);
            if (amount < 0) return error.ArchiveFailed;
            if (amount == 0) break;
            const count: usize = @intCast(amount);
            if (count > max_pkginfo_size - contents.items.len)
                return error.PkginfoTooLarge;
            try contents.appendSlice(package_allocator, buffer[0..count]);
        }

        var package = package: {
            var parsed = try parsePkginfo(package_allocator, contents.items);
            defer parsed.deinit(package_allocator);
            break :package try parsed.intoPackage(package_allocator, "");
        };
        if (c.archive_read_close(archive) != c.ARCHIVE_OK) return error.ArchiveFailed;
        package.archive_arena = arena;
        return package;
    }
}

/// Releases archive-owned storage. Database packages remain owned by their database.
pub fn deinit(self: *Package) void {
    if (self.archive_arena) |*arena| arena.deinit();
    self.* = undefined;
}

const max_pkginfo_size = 1 << 20;

fn parsePkginfo(allocator: std.mem.Allocator, contents: []const u8) !ParsedDescription {
    if (std.mem.indexOfScalar(u8, contents, 0) != null) return error.InvalidPkginfo;
    var parsed: ParsedDescription = .{};
    errdefer parsed.deinit(allocator);
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const separator = std.mem.indexOfScalar(u8, line, '=') orelse
            return error.InvalidPkginfo;
        const key = std.mem.trim(u8, line[0..separator], " \t");
        const value = std.mem.trim(u8, line[separator + 1 ..], " \t");
        if (key.len == 0) return error.InvalidPkginfo;

        const strings = .{
            .{ "pkgname", "name" },      .{ "pkgver", "version" },
            .{ "pkgbase", "base" },      .{ "pkgdesc", "description" },
            .{ "url", "url" },           .{ "arch", "architecture" },
            .{ "packager", "packager" },
        };
        inline for (strings) |field| {
            if (std.mem.eql(u8, key, field[0])) {
                if (@field(parsed, field[1]) != null) return error.DuplicateValue;
                @field(parsed, field[1]) = value;
            }
        }
        const lists = .{
            .{ "group", "groups" },            .{ "license", "licenses" },
            .{ "depend", "depends" },          .{ "optdepend", "optional_depends" },
            .{ "makedepend", "make_depends" }, .{ "checkdepend", "check_depends" },
            .{ "conflict", "conflicts" },      .{ "provides", "provides" },
            .{ "replaces", "replaces" },
        };
        inline for (lists) |field| {
            if (std.mem.eql(u8, key, field[0]))
                try @field(parsed, field[1]).append(allocator, value);
        }
        if (std.mem.eql(u8, key, "builddate")) {
            if (parsed.build_date != null) return error.DuplicateValue;
            parsed.build_date = try std.fmt.parseInt(i64, value, 10);
        } else if (std.mem.eql(u8, key, "size")) {
            if (parsed.installed_size != null) return error.DuplicateValue;
            parsed.installed_size = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, key, "xdata")) {
            const equals = std.mem.indexOfScalar(u8, value, '=') orelse
                return error.InvalidXData;
            if (equals == 0) return error.InvalidXData;
            try parsed.xdata.append(allocator, .{
                .name = value[0..equals],
                .value = value[equals + 1 ..],
            });
        }
        // Unknown keys are ignored for compatibility with newer metadata formats.
    }
    return parsed;
}

test "Package stores version, database, and package relations" {
    var version = try Version.init("0:1.27.0-2", std.testing.allocator);
    defer version.deinit(std.testing.allocator);

    var provides = [_]PackageRelation{
        .{ .name = "go", .constraint = .any },
    };
    var depends = [_]PackageRelation{
        .{ .name = "glibc", .constraint = .any },
    };
    var no_relations = [_]PackageRelation{};

    const package: Package = .{
        .name = "go",
        .version = version,
        .database_name = "core",
        .provides = provides[0..],
        .depends = depends[0..],
        .make_depends = no_relations[0..],
        .conflicts = no_relations[0..],
        .replaces = no_relations[0..],
    };

    try std.testing.expectEqualStrings("go", package.name);
    try std.testing.expectEqualStrings("0:1.27.0-2", package.version.raw);
    try std.testing.expectEqualStrings("core", package.database_name);
    try std.testing.expectEqualStrings("go", package.provides[0].name);
    try std.testing.expectEqualStrings("glibc", package.depends[0].name);
    try std.testing.expectEqual(@as(usize, 0), package.conflicts.len);
}

const ArchiveFixture = struct {
    temporary: std.testing.TmpDir,
    path: [:0]u8,

    const Entry = struct {
        path: [:0]const u8 = ".PKGINFO",
        contents: []const u8 = "",
        kind: c_uint = 0o100000,
        size: ?usize = null,
    };

    fn init(entries: []const Entry, compressed: bool) !ArchiveFixture {
        var temporary = std.testing.tmpDir(.{});
        errdefer temporary.cleanup();
        const allocator = std.testing.allocator;
        const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        defer allocator.free(directory);
        const path = try std.fmt.allocPrintSentinel(allocator, "{s}/package.tar", .{directory}, 0);
        errdefer allocator.free(path);

        const writer = c.archive_write_new() orelse return error.OutOfMemory;
        defer _ = c.archive_write_free(writer);
        if (compressed) try std.testing.expectEqual(c.ARCHIVE_OK, c.archive_write_add_filter_zstd(writer));
        try std.testing.expectEqual(c.ARCHIVE_OK, c.archive_write_set_format_pax_restricted(writer));
        try std.testing.expectEqual(c.ARCHIVE_OK, c.archive_write_open_filename(writer, path.ptr));
        for (entries) |item| {
            const entry = c.archive_entry_new() orelse return error.OutOfMemory;
            defer c.archive_entry_free(entry);
            c.archive_entry_set_pathname(entry, item.path.ptr);
            c.archive_entry_set_filetype(entry, item.kind);
            c.archive_entry_set_perm(entry, 0o644);
            c.archive_entry_set_size(entry, @intCast(item.size orelse item.contents.len));
            try std.testing.expectEqual(c.ARCHIVE_OK, c.archive_write_header(writer, entry));
            if (item.contents.len != 0) {
                try std.testing.expectEqual(
                    @as(isize, @intCast(item.contents.len)),
                    c.archive_write_data(writer, item.contents.ptr, item.contents.len),
                );
            }
            try std.testing.expectEqual(c.ARCHIVE_OK, c.archive_write_finish_entry(writer));
        }
        try std.testing.expectEqual(c.ARCHIVE_OK, c.archive_write_close(writer));
        return .{ .temporary = temporary, .path = path };
    }

    fn deinit(self: *ArchiveFixture) void {
        std.testing.allocator.free(self.path);
        self.temporary.cleanup();
    }
};

const archive_pkginfo_fixture =
    "# Generated package metadata\r\n" ++
    "pkgname = demo\r\n" ++
    "pkgver = 2:1.2.3-4\n" ++
    "pkgbase = demo-base\npkgdesc = Demo = package\n" ++
    "url = https://example.invalid/demo\narch = x86_64\n" ++
    "builddate = 1720000000\nsize = 4096\npackager = Example Builder\n" ++
    "group = utilities\ngroup = tools\nlicense = MIT\nlicense = BSD\n" ++
    "depend = glibc>=2.39\ndepend = runtime\n" ++
    "optdepend = docs>=1:2.0: documentation support\n" ++
    "makedepend = compiler\ncheckdepend = tester\n" ++
    "conflict = old-demo<1.0\nprovides = virtual-demo=2:1.2.3\n" ++
    "replaces = old-demo<=0.9\nxdata = pkgtype=pkg\n" ++
    "xdata = custom=a=b\nfuturekey = ignored\n";

test "archive package reads metadata and relations with owned storage" {
    for ([_]bool{ false, true }) |compressed| {
        var fixture = try ArchiveFixture.init(&.{
            .{ .path = "usr/bin/demo", .contents = "payload skipped" },
            .{ .path = "./.PKGINFO", .contents = archive_pkginfo_fixture },
        }, compressed);
        defer fixture.deinit();
        // Pass a non-sentinel-terminated slice; only the requested path is opened.
        const longer_path = try std.fmt.allocPrint(std.testing.allocator, "{s}suffix", .{fixture.path});
        defer std.testing.allocator.free(longer_path);
        var package = try initializePackageFromArchive(std.testing.allocator, longer_path[0..fixture.path.len]);
        defer package.deinit();

        try std.testing.expectEqualStrings("demo", package.name);
        try std.testing.expectEqualStrings("2:1.2.3-4", package.version.raw);
        try std.testing.expectEqualStrings("", package.database_name);
        try std.testing.expectEqualStrings("demo-base", package.base.?);
        try std.testing.expectEqualStrings("Demo = package", package.description.?);
        try std.testing.expectEqualStrings("https://example.invalid/demo", package.url.?);
        try std.testing.expectEqualStrings("x86_64", package.architecture.?);
        try std.testing.expectEqualStrings("Example Builder", package.packager.?);
        try std.testing.expectEqual(@as(i64, 1720000000), package.build_date.?);
        try std.testing.expectEqual(@as(u64, 4096), package.installed_size.?);
        try std.testing.expectEqual(@as(usize, 2), package.groups.len);
        try std.testing.expectEqualStrings("tools", package.groups[1]);
        try std.testing.expectEqualStrings("BSD", package.licenses[1]);
        try std.testing.expectEqual(@as(usize, 2), package.depends.len);
        try std.testing.expectEqualStrings("2.39", package.depends[0].constraint.greater_equal.raw);
        try std.testing.expect(package.depends[1].constraint == .any);
        try std.testing.expectEqualStrings("docs", package.optional_depends[0].name);
        try std.testing.expectEqualStrings("1:2.0", package.optional_depends[0].constraint.greater_equal.raw);
        try std.testing.expectEqualStrings("documentation support", package.optional_depends[0].description.?);
        try std.testing.expectEqualStrings("compiler", package.make_depends[0].name);
        try std.testing.expectEqualStrings("tester", package.check_depends[0].name);
        try std.testing.expectEqualStrings("1.0", package.conflicts[0].constraint.less.raw);
        try std.testing.expectEqualStrings("2:1.2.3", package.provides[0].constraint.equal.raw);
        try std.testing.expectEqualStrings("0.9", package.replaces[0].constraint.less_equal.raw);
        try std.testing.expectEqualStrings("pkgtype", package.xdata[0].name);
        try std.testing.expectEqualStrings("a=b", package.xdata[1].value);
        try std.testing.expect(package.install_reason == null);
        try std.testing.expect(package.installed_database == null);
        try std.testing.expect(package.install_date == null);
        try std.testing.expect(!package.validation.pgp and !package.validation.sha256);
    }
}

test "archive package rejects missing invalid and oversized metadata" {
    const cases = [_]struct { entry: ArchiveFixture.Entry, expected: anyerror }{
        .{ .entry = .{ .path = "nested/.PKGINFO" }, .expected = error.MissingPkginfo },
        .{ .entry = .{ .kind = 0o040000 }, .expected = error.MissingPkginfo },
        .{ .entry = .{ .size = max_pkginfo_size + 1 }, .expected = error.PkginfoTooLarge },
        .{ .entry = .{ .contents = "pkgver = 1\n" }, .expected = error.MissingPackageName },
        .{ .entry = .{ .contents = "pkgname = demo\n" }, .expected = error.MissingPackageVersion },
        .{ .entry = .{ .contents = "pkgname = demo\npkgver =\n" }, .expected = error.InvalidVersion },
        .{ .entry = .{ .contents = "pkgname = demo\npkgname = duplicate\n" }, .expected = error.DuplicateValue },
        .{ .entry = .{ .contents = "invalid line\n" }, .expected = error.InvalidPkginfo },
        .{ .entry = .{ .contents = "pkgname = demo\x00\n" }, .expected = error.InvalidPkginfo },
        .{ .entry = .{ .contents = "size = -1\n" }, .expected = error.Overflow },
        .{ .entry = .{ .contents = "xdata = missing-equals\n" }, .expected = error.InvalidXData },
        .{ .entry = .{ .contents = archive_pkginfo_fixture ++ "depend = broken>=\n" }, .expected = error.InvalidPackageRelation },
    };
    for (cases) |case| {
        var fixture = try ArchiveFixture.init(&.{case.entry}, true);
        defer fixture.deinit();
        try std.testing.expectError(case.expected, initializePackageFromArchive(std.testing.allocator, fixture.path));
    }
}

test "archive package rejects invalid paths and unreadable archives" {
    try std.testing.expectError(error.InvalidPath, initializePackageFromArchive(std.testing.allocator, "bad\x00path"));
    var fixture = try ArchiveFixture.init(&.{}, false);
    defer fixture.deinit();
    try fixture.temporary.dir.writeFile(std.testing.io, .{ .sub_path = "package.tar", .data = "not an archive" });
    try std.testing.expectError(error.ArchiveFailed, initializePackageFromArchive(std.testing.allocator, fixture.path));
    try fixture.temporary.dir.deleteFile(std.testing.io, "package.tar");
    try std.testing.expectError(error.ArchiveFailed, initializePackageFromArchive(std.testing.allocator, fixture.path));
}

test "archive package rejects truncated metadata" {
    var fixture = try ArchiveFixture.init(&.{.{ .contents = archive_pkginfo_fixture }}, false);
    defer fixture.deinit();
    const contents = try fixture.temporary.dir.readFileAlloc(std.testing.io, "package.tar", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(contents);
    // Retain the tar header but cut off the metadata body.
    try fixture.temporary.dir.writeFile(std.testing.io, .{ .sub_path = "package.tar", .data = contents[0..520] });
    try std.testing.expectError(error.ArchiveFailed, initializePackageFromArchive(std.testing.allocator, fixture.path));
}

fn checkArchiveAllocationFailures(allocator: std.mem.Allocator, path: []const u8) !void {
    var package = try initializePackageFromArchive(allocator, path);
    defer package.deinit();
}

test "archive package cleans up after allocation failures" {
    var fixture = try ArchiveFixture.init(&.{.{ .contents = archive_pkginfo_fixture }}, true);
    defer fixture.deinit();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkArchiveAllocationFailures, .{fixture.path});
}
