const std = @import("std");
const Zigalpm = @import("Zigalpm");
const model = @import("model.zig");
const runtime = @import("../runtime/context.zig");
pub fn fromConfig(config: *const model.Config) !Zigalpm.alpm.Backend {
    const value = config.values.get("NativePackageBackend") orelse return Zigalpm.alpm.default_backend;
    if (value != .string) return error.InvalidBackend;
    const backend = try Zigalpm.alpm.Backend.parse(value.string);
    try backend.validate();
    return backend;
}
pub fn apply(context: *runtime.RuntimeContext) !void {
    const config = try @import("manager.zig").Manager.init(context).read();
    try Zigalpm.AlpmManager.setDefaultBackend(try fromConfig(&config));
}
test "native backend setting validates saved values and compiled availability" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var config = try model.Config.defaults(arena.allocator());
    try std.testing.expectEqual(Zigalpm.alpm.default_backend, try fromConfig(&config));
    try std.testing.expect(try config.set(arena.allocator(), "NativePackageBackend", "rlpm"));
    try std.testing.expectEqual(Zigalpm.alpm.Backend.rlpm, try fromConfig(&config));
    try config.values.put(arena.allocator(), "NativePackageBackend", .{ .string = "unknown" });
    try std.testing.expectError(error.InvalidBackend, fromConfig(&config));
    try config.values.put(arena.allocator(), "NativePackageBackend", .{ .string = "libalpm" });
    if (Zigalpm.alpm.libalpm_enabled) try std.testing.expectEqual(Zigalpm.alpm.Backend.libalpm, try fromConfig(&config)) else try std.testing.expectError(error.BackendUnavailable, fromConfig(&config));
}
