//! Resolve through the owning Owner; a cache invalidation makes this reference stale.
pub const Id = enum(u32) { _ };
database: @import("DatabaseRef.zig"),
generation: u64,
id: Id,
