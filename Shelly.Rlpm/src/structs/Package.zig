const Package = @This();

const std = @import("std");
const Version = @import("Version.zig");
const PackageRelation = @import("PackageRelation.zig");
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

pub fn initializePackageFromArchive(
    allocator: std.mem.Allocator,
    path: []const u8,
) !Package {
    const sentinenl_path = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(sentinenl_path);

    const archive = c.archive_read_new() orelse return error.OutOfMemory;
    defer _ = c.archive_read_free(archive);

    //confirm actually correct package type
    if (try c.archive_read_support_filter_zstd(archive) != c.ARCHIVE_OK) return error.ArchiveFailed;
    if (try c.archive_read_support_format_tar(archive) != c.ARCHIVE_OK) return error.ArchiveFailed;
    if (try c.archive_read_open_filename(archive, path.ptr, 64 * 1024)) return error.ArchiveFailed;

    const flags = c.ARCHIVE_EXTRACT_TIME | c.ARCHIVE_EXTRACT_SECURE_NODOTDOT | c.ARCHIVE_EXTRACT_SECURE_NOABSOLUTEPATHS | c.ARCHIVE_EXTRACT_SECURE_SYMLINKS;

    var entry: ?*c.struct_archive_entry = null;
    _ = flags;
    _ = entry;
    return .{};
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
