//! Stored diagnostics contain values only; they never retain caller-owned strings.
const Diagnostic = @This();
const std = @import("std");
const DatabaseRef = @import("DatabaseRef.zig");

pub const Operation = enum {
    configure,
    register_database,
    unregister_database,
    load_database,
    invalidate_database,
    query,
    callback,
};
pub const Category = enum {
    memory,
    invalid_argument,
    database,
    stale_reference,
    busy,
    cancelled,
    unsupported,
    io,
};
operation: Operation,
category: Category,
cause: anyerror,
database: ?DatabaseRef = null,

pub fn init(operation: Operation, cause: anyerror, database: ?DatabaseRef) Diagnostic {
    return .{ .operation = operation, .cause = cause, .database = database, .category = switch (cause) {
        error.OutOfMemory => .memory,
        error.InvalidPath, error.InvalidOption, error.InvalidVersion, error.InvalidCharacter, error.InvalidPackageRelation, error.InvalidDatabaseName, error.ReservedDatabaseName, error.ImmutablePath, error.InvalidAnswer => .invalid_argument,
        error.DuplicateDatabase, error.DatabaseNotLoaded, error.DatabaseAlreadyLoaded => .database,
        error.ForeignOwner, error.StaleDatabaseReference, error.StalePackageReference => .stale_reference,
        error.CallbackReentry, error.OwnerBusy => .busy,
        error.Cancelled => .cancelled,
        error.UnsupportedDatabaseBackend => .unsupported,
        else => .io,
    } };
}

pub fn format(self: Diagnostic, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("{t}: {s}", .{ self.operation, @errorName(self.cause) });
    if (self.database) |reference| try writer.print(" (database {d})", .{@intFromEnum(reference.id)});
}
