//! Owner is thread-confined except requestCancellation. It owns its configuration
//! and databases; do not shallow-copy an initialized value or move it after
//! publishing its address. Borrowed views end at the next mutating operation.
const Owner = @This();
const std = @import("std");
const Database = @import("Database.zig");
const DatabaseConfiguration = @import("DatabaseConfiguration.zig");
const OwnerConfiguration = @import("OwnerConfiguration.zig");
const DatabaseRef = @import("DatabaseRef.zig");
const PackageRef = @import("PackageRef.zig");
const Package = @import("Package.zig");
const Group = @import("Group.zig");
const Callbacks = @import("Callbacks.zig");
const Diagnostic = @import("Diagnostic.zig");

allocator: std.mem.Allocator,
configuration_arena: std.heap.ArenaAllocator,
configuration: OwnerConfiguration,
lock_file: []const u8,
id: DatabaseRef.OwnerId,
local: ?Database,
sync_databases: std.ArrayList(Database) = .empty,
next_database_id: u64 = 1,
busy: bool = false,
in_callback: bool = false,
cancelled: std.atomic.Value(bool) = .init(false),
last_diagnostic: ?Diagnostic = null,

var next_owner_id: std.atomic.Value(u64) = .init(1);

/// root/dbpath must already be directories. This stage opens local metadata
/// read-only; an absent local directory yields an empty, missing snapshot.
/// Registration of sync databases never requires their archives or a network.
pub fn init(io: std.Io, allocator: std.mem.Allocator, configuration: OwnerConfiguration, databases: []const DatabaseConfiguration) !Owner {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = try configuration.copy(arena.allocator(), io);
    const local_path = try std.fmt.allocPrint(arena.allocator(), "{s}local/", .{owned.database_path});
    const lock_file = try std.fmt.allocPrint(arena.allocator(), "{s}db.lck", .{owned.database_path});
    const owner_id = try allocateIdentity();
    var local = try Database.init(allocator, "local", local_path, OwnerConfiguration.disabled_signatures);
    local.identity = .{ .owner = owner_id, .id = .local };
    var result: Owner = .{
        .allocator = allocator,
        .configuration_arena = arena,
        .configuration = owned,
        .lock_file = lock_file,
        .id = owner_id,
        .local = local,
    };
    // arena is covered by the outer errdefer; only db/list ownership here.
    errdefer result.destroyDatabases();
    for (databases) |db| _ = try result.registerInternal(db);
    try result.loadInternal(io, result.localDatabase().?);
    return result;
}

fn allocateIdentity() !DatabaseRef.OwnerId {
    var current = next_owner_id.load(.monotonic);
    while (true) {
        const next = std.math.add(u64, current, 1) catch return error.IdentityExhausted;
        if (next_owner_id.cmpxchgWeak(current, next, .monotonic, .monotonic)) |actual| {
            current = actual;
        } else return @enumFromInt(current);
    }
}

pub fn deinit(self: *Owner) !void {
    try self.checkIdle();
    self.destroyDatabases();
    self.configuration_arena.deinit();
    self.* = undefined;
}
fn destroyDatabases(self: *Owner) void {
    if (self.local) |*local| local.deinit();
    for (self.sync_databases.items) |*db| db.deinit();
    self.sync_databases.deinit(self.allocator);
}

pub fn options(self: *const Owner) OwnerConfiguration {
    return self.configuration;
}
pub fn localDatabase(self: *const Owner) ?DatabaseRef {
    return if (self.local) |local| local.identity else null;
}
pub fn findDatabase(self: *const Owner, name: []const u8) ?DatabaseRef {
    if (self.local) |local| if (std.mem.eql(u8, name, local.name)) return local.identity;
    for (self.sync_databases.items) |db| if (std.mem.eql(u8, name, db.name)) return db.identity;
    return null;
}
/// Registration order is repository priority. The slice is borrowed.
pub fn syncDatabases(self: *const Owner) []const Database {
    return self.sync_databases.items;
}
pub fn database(self: *const Owner, reference: DatabaseRef) !*const Database {
    try self.checkIdle();
    return self.resolveDatabase(reference);
}
fn resolveDatabase(self: *const Owner, reference: DatabaseRef) !*const Database {
    if (reference.owner != self.id) return error.ForeignOwner;
    if (reference.id == .local) return if (self.local) |*local| local else error.StaleDatabaseReference;
    for (self.sync_databases.items) |*db| if (db.identity.?.id == reference.id) return db;
    return error.StaleDatabaseReference;
}
fn mutableDatabase(self: *Owner, reference: DatabaseRef) !*Database {
    return @constCast(try self.resolveDatabase(reference));
}

pub fn registerDatabase(self: *Owner, configuration: DatabaseConfiguration) !DatabaseRef {
    try self.begin(.register_database);
    defer self.busy = false;
    return self.registerInternal(configuration) catch |err| return self.fail(.register_database, err, null);
}
fn registerInternal(self: *Owner, configuration: DatabaseConfiguration) !DatabaseRef {
    try configuration.validate();
    if (self.findDatabase(configuration.database_name) != null) return error.DuplicateDatabase;
    const next = std.math.add(u64, self.next_database_id, 1) catch return error.IdentityExhausted;
    const path = try self.syncPath(self.allocator, self.configuration, configuration.database_name);
    defer self.allocator.free(path);
    var db = try Database.initSync(self.allocator, configuration, path, self.configuration.default_signature_policy);
    errdefer db.deinit();
    const reference: DatabaseRef = .{ .owner = self.id, .id = @enumFromInt(self.next_database_id) };
    db.identity = reference;
    try self.sync_databases.append(self.allocator, db);
    self.next_database_id = next;
    return reference;
}
fn syncPath(_: *const Owner, allocator: std.mem.Allocator, configuration: OwnerConfiguration, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}sync/{s}{s}", .{ configuration.database_path, name, configuration.database_extension });
}

pub fn unregisterDatabase(self: *Owner, reference: DatabaseRef) !void {
    try self.begin(.unregister_database);
    defer self.busy = false;
    _ = self.resolveDatabase(reference) catch |err| return self.fail(.unregister_database, err, reference);
    if (reference.id == .local) {
        self.local.?.deinit();
        self.local = null;
        return;
    }
    for (self.sync_databases.items, 0..) |db, index| {
        if (db.identity.?.id == reference.id) {
            var removed = self.sync_databases.orderedRemove(index);
            removed.deinit();
            return;
        }
    }
    unreachable;
}
pub fn unregisterSyncDatabases(self: *Owner) !void {
    try self.begin(.unregister_database);
    defer self.busy = false;
    for (self.sync_databases.items) |*db| db.deinit();
    self.sync_databases.clearRetainingCapacity();
}

/// Atomic replacement: copies input before releasing any borrowed old values.
/// Root/dbpath are immutable. Sync cache generations change; local metadata is
/// retained. M3 will refine invalidation for individual operational options.
pub fn setOptions(self: *Owner, io: std.Io, configuration: OwnerConfiguration) !void {
    try self.begin(.configure);
    defer self.busy = false;
    self.replaceOptions(io, configuration) catch |err| return self.fail(.configure, err, null);
}
fn replaceOptions(self: *Owner, io: std.Io, configuration: OwnerConfiguration) !void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    errdefer arena.deinit();
    const owned = try configuration.copy(arena.allocator(), io);
    if (!std.mem.eql(u8, owned.root, self.configuration.root) or !std.mem.eql(u8, owned.database_path, self.configuration.database_path)) return error.ImmutablePath;
    const lock_file = try std.fmt.allocPrint(arena.allocator(), "{s}db.lck", .{owned.database_path});
    var databases: std.ArrayList(Database) = .empty;
    errdefer {
        for (databases.items) |*db| db.deinit();
        databases.deinit(self.allocator);
    }
    for (self.sync_databases.items) |*old| {
        const path = try self.syncPath(arena.allocator(), owned, old.name);
        var replacement = try old.copyRegistration(path, owned.default_signature_policy);
        errdefer replacement.deinit();
        try databases.append(self.allocator, replacement);
    }
    for (self.sync_databases.items) |*db| db.deinit();
    self.sync_databases.deinit(self.allocator);
    self.configuration_arena.deinit();
    self.configuration_arena = arena;
    self.configuration = owned;
    self.lock_file = lock_file;
    self.sync_databases = databases;
}

pub fn setList(self: *Owner, io: std.Io, comptime field: OwnerConfiguration.StringList, values: []const []const u8) !void {
    var updated = self.options();
    @field(updated, @tagName(field)) = values;
    try self.setOptions(io, updated);
}
pub fn addListValue(self: *Owner, io: std.Io, comptime field: OwnerConfiguration.StringList, value: []const u8) !void {
    try self.checkIdle();
    const old = self.configuration.list(field);
    const updated = try self.allocator.alloc([]const u8, old.len + 1);
    defer self.allocator.free(updated);
    @memcpy(updated[0..old.len], old);
    updated[old.len] = value;
    try self.setList(io, field, updated);
}
/// Removes the first equal item. Directory comparisons include trailing slash
/// normalization, as with their setter. Duplicate list entries remain ordered.
pub fn removeListValue(self: *Owner, io: std.Io, comptime field: OwnerConfiguration.StringList, value: []const u8) !bool {
    try self.checkIdle();
    const directories = field == .cache_directories or field == .hook_directories;
    const normalized = if (directories) try OwnerConfiguration.directoryString(self.allocator, value) else try self.allocator.dupe(u8, value);
    defer self.allocator.free(normalized);
    const old = self.configuration.list(field);
    for (old, 0..) |item, index| {
        if (!std.mem.eql(u8, item, normalized)) continue;
        const updated = try self.allocator.alloc([]const u8, old.len - 1);
        defer self.allocator.free(updated);
        @memcpy(updated[0..index], old[0..index]);
        @memcpy(updated[index..], old[index + 1 ..]);
        try self.setList(io, field, updated);
        return true;
    }
    return false;
}

pub fn loadDatabase(self: *Owner, io: std.Io, reference: DatabaseRef) !void {
    try self.begin(.load_database);
    defer self.busy = false;
    self.loadInternal(io, reference) catch |err| return self.fail(.load_database, err, reference);
}
fn loadInternal(self: *Owner, io: std.Io, reference: DatabaseRef) !void {
    try self.checkCancelled();
    const db = try self.mutableDatabase(reference);
    db.loadDatabase(io, self.configuration.gpg_directory) catch |err| {
        if (err != error.FileNotFound or db.kind != .local or db.status.presence != .missing) return err;
        db.status.markMissing();
        db.status.package_cache_loaded = true;
        db.status.group_cache_loaded = true;
    };
    try self.checkCancelled();
}
pub fn invalidateDatabase(self: *Owner, reference: DatabaseRef) !void {
    try self.begin(.invalidate_database);
    defer self.busy = false;
    const db = self.mutableDatabase(reference) catch |err| return self.fail(.invalidate_database, err, reference);
    db.invalidateCache() catch |err| return self.fail(.invalidate_database, err, reference);
}
fn loadedDatabase(self: *const Owner, reference: DatabaseRef) !*const Database {
    const result = try self.database(reference);
    if (!result.status.package_cache_loaded) return error.DatabaseNotLoaded;
    return result;
}
pub fn packageIds(self: *const Owner, reference: DatabaseRef) ![]const Database.PackageId {
    return (try self.loadedDatabase(reference)).packages.ordered.items;
}
pub fn findPackage(self: *const Owner, reference: DatabaseRef, name: []const u8) !?PackageRef {
    const db = try self.loadedDatabase(reference);
    const id = db.packages.by_name.get(name) orelse return null;
    return .{ .database = reference, .generation = db.generation, .id = id };
}
pub fn packageReference(self: *const Owner, reference: DatabaseRef, id: Database.PackageId) !PackageRef {
    const db = try self.loadedDatabase(reference);
    if (@intFromEnum(id) >= db.packages.packages.items.len) return error.StalePackageReference;
    return .{ .database = reference, .generation = db.generation, .id = id };
}
pub fn package(self: *const Owner, reference: PackageRef) !*const Package {
    const db = try self.database(reference.database);
    if (reference.generation != db.generation or !db.status.package_cache_loaded or @intFromEnum(reference.id) >= db.packages.packages.items.len) return error.StalePackageReference;
    return &db.packages.packages.items[@intFromEnum(reference.id)];
}
pub fn findGroup(self: *const Owner, reference: DatabaseRef, name: []const u8) !?*const Group {
    const db = try self.loadedDatabase(reference);
    const id = db.groups.by_name.get(name) orelse return null;
    return &db.groups.groups.items[@intFromEnum(id)];
}

pub fn setCallbacks(self: *Owner, callbacks: Callbacks) !void {
    try self.checkIdle();
    self.configuration.callbacks = callbacks;
}
pub fn emit(self: *Owner, event: Callbacks.Event) !void {
    try self.begin(.callback);
    defer self.busy = false;
    self.checkCancelled() catch |err| return self.fail(.callback, err, null);
    if (self.configuration.callbacks.event) |callback| {
        self.in_callback = true;
        defer self.in_callback = false;
        callback(self.configuration.callbacks.event_context, event);
    }
    self.checkCancelled() catch |err| return self.fail(.callback, err, null);
}
pub fn ask(self: *Owner, question: *Callbacks.Question) !void {
    try self.begin(.callback);
    defer self.busy = false;
    const original = question.*;
    errdefer question.* = original;
    self.askInternal(question) catch |err| return self.fail(.callback, err, null);
    if (std.meta.activeTag(original) != std.meta.activeTag(question.*)) return self.fail(.callback, error.InvalidAnswer, null);
    if (question.* == .select_provider and question.select_provider.selected >= question.select_provider.candidates.len) return self.fail(.callback, error.InvalidAnswer, null);
}
fn askInternal(self: *Owner, question: *Callbacks.Question) !void {
    try self.checkCancelled();
    if (self.configuration.callbacks.question) |callback| {
        self.in_callback = true;
        defer self.in_callback = false;
        callback(self.configuration.callbacks.question_context, question);
    }
    try self.checkCancelled();
}
/// The only method callable from another thread or from an active callback.
pub fn requestCancellation(self: *Owner) void {
    self.cancelled.store(true, .release);
}
pub fn resetCancellation(self: *Owner) !void {
    try self.checkIdle();
    self.cancelled.store(false, .release);
}
pub fn checkCancelled(self: *const Owner) !void {
    if (self.cancelled.load(.acquire)) return error.Cancelled;
}
pub fn diagnostic(self: *const Owner) ?Diagnostic {
    return self.last_diagnostic;
}
fn checkIdle(self: *const Owner) !void {
    if (self.in_callback) return error.CallbackReentry;
    if (self.busy) return error.OwnerBusy;
}
fn begin(self: *Owner, operation: Diagnostic.Operation) !void {
    self.checkIdle() catch |err| return self.fail(operation, err, null);
    self.last_diagnostic = null;
    self.busy = true;
}
fn fail(self: *Owner, operation: Diagnostic.Operation, cause: anyerror, db: ?DatabaseRef) anyerror {
    self.last_diagnostic = Diagnostic.init(operation, cause, db);
    return cause;
}
