//! Validate the resolved graph before downloading or committing a build root.
const std = @import("std");
const rlpm = @import("Shelly_Rlpm");
const Plan = rlpm.TransactionPlan;

fn forbidden(name: []const u8) bool {
    return std.mem.eql(u8, name, "pacman") or
        std.mem.eql(u8, name, "pacman-git") or
        std.mem.eql(u8, name, "pacman-static") or
        std.mem.eql(u8, name, "libalpm") or
        std.mem.eql(u8, name, "libalpm-git") or
        std.mem.eql(u8, name, "pacman-libs") or
        std.mem.startsWith(u8, name, "libalpm.so") or
        std.mem.startsWith(u8, name, "lib:libalpm.so");
}

/// Returns an owned diagnostic identifying a path from a requested package to
/// the unsupported package or ABI requirement. No package state is changed.
pub fn rejection(allocator: std.mem.Allocator, plan: *const Plan) !?[]u8 {
    const parents = try allocator.alloc(?Plan.Id, plan.candidates.len);
    defer allocator.free(parents);
    @memset(parents, null);
    var queue: std.ArrayList(Plan.Id) = .empty;
    defer queue.deinit(allocator);
    for (plan.additions) |addition| if (addition.explicit_target) {
        const index = @intFromEnum(addition.package);
        if (parents[index] != null) continue;
        parents[index] = addition.package;
        try queue.append(allocator, addition.package);
    };
    var cursor: usize = 0;
    while (cursor < queue.items.len) : (cursor += 1) {
        const id = queue.items[cursor];
        const package = plan.package(id);
        if (forbidden(package.name)) return try diagnostic(allocator, plan, parents, id, null);
        for (package.provides) |provision| {
            if (forbidden(provision.name)) return try diagnostic(allocator, plan, parents, id, provision.name);
        }
        for (plan.edges) |edge| {
            if (edge.requiring != id) continue;
            if (forbidden(edge.dependency.name)) return try diagnostic(allocator, plan, parents, id, edge.dependency.name);
            switch (edge.satisfier) {
                .package => |next| if (parents[@intFromEnum(next)] == null) {
                    parents[@intFromEnum(next)] = id;
                    try queue.append(allocator, next);
                },
                .assumed => {},
            }
        }
    }
    return null;
}

fn diagnostic(allocator: std.mem.Allocator, plan: *const Plan, parents: []const ?Plan.Id, last: Plan.Id, requirement: ?[]const u8) ![]u8 {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    if (requirement) |name| try names.append(allocator, name);
    var id = last;
    while (true) {
        try names.append(allocator, plan.package(id).name);
        const parent = parents[@intFromEnum(id)].?;
        if (parent == id) break;
        id = parent;
    }
    std.mem.reverse([]const u8, names.items);
    const chain = try std.mem.join(allocator, " -> ", names.items);
    defer allocator.free(chain);
    return std.fmt.allocPrint(allocator, "The RLPM-only build root cannot install a pacman/libalpm requirement: {s}", .{chain});
}

test "build root policy reports transitive ABI requirements through cycles and providers" {
    const a = std.testing.allocator;
    var candidates = [_]Plan.Candidate{
        .{ .reference = undefined, .package = .{ .name = "recipe", .version = .{ .raw = "1", .epoch = "0", .pkgver = "1", .pkgrel = null }, .database_name = "test" } },
        .{ .reference = undefined, .package = .{ .name = "tool", .version = .{ .raw = "1", .epoch = "0", .pkgver = "1", .pkgrel = null }, .database_name = "test" } },
        .{ .reference = undefined, .package = .{ .name = "provider", .version = .{ .raw = "1", .epoch = "0", .pkgver = "1", .pkgrel = null }, .database_name = "test" } },
    };
    var plan: Plan = .{
        .arena = .init(a),
        .candidates = &candidates,
        .additions = &.{.{ .package = @enumFromInt(0), .old = null, .action = .install, .selection_reason = .explicit, .reason = .explicit, .explicit_target = true, .installed_database = null }},
        .edges = &.{
            .{ .requiring = @enumFromInt(0), .dependency = try rlpm.PackageRelation.parse("tool"), .satisfier = .{ .package = @enumFromInt(1) } },
            .{ .requiring = @enumFromInt(1), .dependency = try rlpm.PackageRelation.parse("recipe"), .satisfier = .{ .package = @enumFromInt(0) } },
            .{ .requiring = @enumFromInt(1), .dependency = try rlpm.PackageRelation.parse("lib:libalpm.so=16-64"), .satisfier = .{ .package = @enumFromInt(2) } },
        },
    };
    defer plan.arena.deinit();
    const message = (try rejection(a, &plan)).?;
    defer a.free(message);
    try std.testing.expect(std.mem.endsWith(u8, message, "recipe -> tool -> lib:libalpm.so"));
    plan.edges = plan.edges[0..2];
    try std.testing.expectEqual(null, try rejection(a, &plan));
    candidates[1].package.provides = &.{try rlpm.PackageRelation.parse("pacman=7")};
    const provision = (try rejection(a, &plan)).?;
    defer a.free(provision);
    try std.testing.expect(std.mem.endsWith(u8, provision, "recipe -> tool -> pacman"));
}
