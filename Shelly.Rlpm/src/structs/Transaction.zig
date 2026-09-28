//! Owner-owned, address-stable transaction. Borrow this pointer until release.
//! Fields are implementation state; use methods and treat plan() as immutable.
const Transaction = @This();
const std = @import("std");
const Owner = @import("Owner.zig");
const Package = @import("Package.zig");
const Ref = @import("PackageRef.zig");
const Resolver = @import("Resolver.zig");
const Plan = @import("TransactionPlan.zig");
const Snapshot = @import("DatabaseSnapshot.zig");
pub const State = enum { initialized, preparing, prepared, committing, completed, failed, interrupted, released };
pub const Result = struct { state: State, cause: ?anyerror = null, packages_committed: usize = 0 };
const Target = union(enum) { text: []const u8, reference: Ref, archive: *Package };

owner: *Owner,
io: std.Io,
flags: @import("TransactionFlags.zig"),
state: State = .initialized,
cause: ?anyerror = null,
storage: std.heap.ArenaAllocator,
targets: std.ArrayList(Target) = .empty,
removals: std.ArrayList([]const u8) = .empty,
system_upgrade: bool = false,
allow_downgrade: bool = false,
owned_plan: ?Plan = null,
snapshot: [32]u8,
lock: ?@import("DatabaseLock.zig") = null,

pub fn result(self: *const Transaction) Result {
    return .{ .state = self.state, .cause = self.cause };
}
pub fn plan(self: *const Transaction) ?*const Plan {
    return if (self.owned_plan) |*value| value else null;
}

fn begin(self: *Transaction, expected: State) !void {
    try self.owner.beginTransactionOperation(self);
    errdefer self.owner.busy = false;
    if (self.state != expected) return self.owner.transactionFailure(error.InvalidTransactionState);
}
fn recordFailure(self: *Transaction, err: anyerror) void {
    self.owner.last_diagnostic = @import("Diagnostic.zig").init(.transaction, err, null);
}
fn mutable(self: *Transaction) !void {
    try self.begin(.initialized);
    errdefer self.owner.busy = false;
    self.owner.checkCancelled() catch |err| return self.owner.transactionFailure(err);
}
/// Frontend name/relation syntax is resolved during prepare. Exact repeated
/// text is rejected; package identity duplicates are also checked by Resolver.
pub fn addTarget(self: *Transaction, text: []const u8) !void {
    try self.mutable();
    defer self.owner.busy = false;
    errdefer |err| self.recordFailure(err);
    if (text.len == 0 or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidOption;
    for (self.targets.items) |target| if (target == .text and std.mem.eql(u8, target.text, text)) return error.DuplicateTarget;
    const owned = try self.storage.allocator().dupe(u8, text);
    try self.targets.append(self.owner.allocator, .{ .text = owned });
}
pub fn addPackage(self: *Transaction, reference: Ref) !void {
    try self.mutable();
    defer self.owner.busy = false;
    errdefer |err| self.recordFailure(err);
    const package = try self.owner.transactionPackage(reference);
    if (package.origin != .sync) return error.UnsupportedPackageOrigin;
    for (self.targets.items) |target| if (target == .reference and std.meta.eql(target.reference, reference)) return;
    try self.checkName(package.name);
    try self.targets.append(self.owner.allocator, .{ .reference = reference });
}
fn checkName(self: *Transaction, name: []const u8) !void {
    for (self.targets.items) |target| {
        const existing = switch (target) {
            .text => continue,
            .archive => |pkg| pkg,
            .reference => |ref| try self.owner.transactionPackage(ref),
        };
        if (std.mem.eql(u8, existing.name, name)) return error.DuplicateTarget;
    }
}
/// On success the caller is reset to null. On every rejection/allocation error
/// the caller retains the complete package, including its sealed descriptor.
pub fn takeArchive(self: *Transaction, input: *?Package) !void {
    try self.mutable();
    defer self.owner.busy = false;
    errdefer |err| self.recordFailure(err);
    const package = &(input.* orelse return error.InvalidPackageOwnership);
    if (package.origin != .archive or package.archive_arena == null) return error.InvalidPackageOwnership;
    try self.checkName(package.name);
    const owned = try self.owner.allocator.create(Package);
    errdefer self.owner.allocator.destroy(owned);
    try self.targets.append(self.owner.allocator, .{ .archive = owned });
    owned.* = package.*;
    input.* = null;
}
pub fn remove(self: *Transaction, name: []const u8) !void {
    try self.mutable();
    defer self.owner.busy = false;
    errdefer |err| self.recordFailure(err);
    for (self.removals.items) |existing| if (std.mem.eql(u8, existing, name)) return;
    if (!self.owner.local.?.packages.by_name.contains(name)) return error.TargetNotFound;
    const owned = try self.storage.allocator().dupe(u8, name);
    try self.removals.append(self.owner.allocator, owned);
}
pub fn systemUpgrade(self: *Transaction, allow_downgrade: bool) !void {
    try self.mutable();
    defer self.owner.busy = false;
    self.system_upgrade = true;
    self.allow_downgrade = allow_downgrade;
}
pub fn prepare(self: *Transaction) !void {
    try self.begin(.initialized);
    defer self.owner.busy = false;
    self.transition(.preparing, null);
    self.prepareInternal() catch |err| return self.failed(err);
    // libalpm leaves an initially empty transaction initialized.
    self.transition(if (self.owned_plan != null and self.owned_plan.?.had_prepare_targets) .prepared else .initialized, null);
    self.owner.checkCancelled() catch |err| return self.failed(err);
}
fn prepareInternal(self: *Transaction) !void {
    try self.checkSnapshot();
    if (self.owned_plan) |*previous| previous.deinit();
    self.owned_plan = null;
    if (self.targets.items.len == 0 and self.removals.items.len == 0 and !self.system_upgrade) return;
    var targets: std.ArrayList(Resolver.Target) = .empty;
    defer targets.deinit(self.owner.allocator);
    for (self.targets.items) |target| try targets.append(self.owner.allocator, switch (target) {
        .text => |value| .{ .text = value },
        .reference => |value| .{ .reference = value },
        .archive => |value| .{ .archive = value },
    });
    self.owned_plan = try self.owner.resolveTransaction(self, .{ .install = targets.items, .remove = self.removals.items, .system_upgrade = self.system_upgrade, .allow_downgrade = self.allow_downgrade, .flags = self.flags });
    try self.owned_plan.?.check();
    try self.checkSnapshot();
}
pub fn commit(self: *Transaction) !void {
    try self.begin(.prepared);
    defer self.owner.busy = false;
    if (self.flags.no_lock) return self.owner.transactionFailure(error.TransactionNotLocked);
    if (self.lock == null) return self.failed(error.LockNotHeld);
    self.checkSnapshot() catch |err| return self.failed(err);
    const reviewed = &self.owned_plan.?;
    // M7–M10 supply acquisition, preflight, hooks, and the mutation executor.
    // Preserve the review/lock on this recoverable capability error.
    if (reviewed.additions.len != 0 or reviewed.removals.len != 0) return self.owner.transactionFailure(error.CommitUnavailable);
    self.transition(.committing, null);
    self.owner.checkCancelled() catch |err| return self.failed(err);
    self.transition(.completed, null);
}
/// Native interrupt is valid only during commit. requestCancellation on Owner
/// is the cross-thread/any-phase operation, including callback question waits.
pub fn interrupt(self: *Transaction) !void {
    try self.owner.beginTransactionOperation(self);
    defer self.owner.busy = false;
    if (self.state != .committing and self.state != .interrupted) return self.owner.transactionFailure(error.InvalidTransactionState);
    self.owner.requestCancellation();
    self.transition(.interrupted, error.Cancelled);
}
fn checkSnapshot(self: *Transaction) !void {
    try self.owner.checkCancelled();
    if (self.lock) |*lock| try lock.validate();
    if (!std.mem.eql(u8, &self.snapshot, &try Snapshot.capture(self.owner, self.io))) return error.StaleDatabaseState;
}
fn failed(self: *Transaction, err: anyerror) anyerror {
    self.transition(if (err == error.Cancelled) .interrupted else .failed, err);
    return self.owner.transactionFailure(err);
}
pub fn transition(self: *Transaction, state: State, cause: ?anyerror) void {
    self.state = state;
    self.cause = cause;
    self.owner.transactionEvent(.{ .lifecycle = self.result() });
}
/// Internal: Owner releases even failed/cancelled transactions. Always cleans
/// resources, then reports a lock ownership/unlink error if one occurred.
pub fn destroy(self: *Transaction) !void {
    self.transition(.released, self.cause);
    const allocator = self.owner.allocator;
    defer allocator.destroy(self);
    defer self.storage.deinit();
    defer self.targets.deinit(allocator);
    defer self.removals.deinit(allocator);
    if (self.owned_plan) |*value| value.deinit();
    for (self.targets.items) |target| if (target == .archive) {
        target.archive.deinit();
        allocator.destroy(target.archive);
    };
    if (self.lock) |*lock| try lock.release(allocator);
}
