//! Independent native package metadata and lifecycle API. Operational capability
//! reporting is intentionally narrower than the eventual libalpm target.
pub const Owner = @import("structs/Owner.zig");
pub const OwnerConfiguration = @import("structs/OwnerConfiguration.zig");
pub const Database = @import("structs/Database.zig");
pub const DatabaseConfiguration = @import("structs/DatabaseConfiguration.zig");
pub const DatabaseRef = @import("structs/DatabaseRef.zig");
pub const PackageRef = @import("structs/PackageRef.zig");
pub const Package = @import("structs/Package.zig");
pub const PackageFile = @import("structs/PackageFile.zig");
pub const BackupFile = @import("structs/BackupFile.zig");
pub const MtreeIterator = @import("structs/MtreeIterator.zig");
pub const PackageRelation = @import("structs/PackageRelation.zig");
pub const Version = @import("structs/Version.zig");
pub const ParsedDescription = @import("structs/ParsedDescription.zig");
pub const Group = @import("structs/Group.zig");
pub const SignaturePolicy = @import("structs/SignaturePolicy.zig");
pub const DatabaseUsage = @import("structs/DatabaseUsage.zig");
pub const DatabaseStatus = @import("structs/DatabaseStatus.zig");
pub const Callbacks = @import("structs/Callbacks.zig");
pub const Diagnostic = @import("structs/Diagnostic.zig");
pub const PhysicalArchitectures = @import("structs/PhysicalArchitectures.zig");
pub const version = "0.0.0";

pub const Capabilities = struct {
    local_metadata: bool = true,
    archive_metadata: bool = true,
    version_comparison: bool = true,
    detached_signature_verification: bool = true,
    physical_architectures: bool = @import("builtin").os.tag == .linux,
    sync_databases: bool = false,
    sqlite_sync_databases: bool = false,
    signature_policy_enforcement: bool = false,
    downloads: bool = false,
    transactions: bool = false,
    localization: bool = false,
};
pub fn capabilities() Capabilities {
    return .{};
}

test {
    _ = Owner;
    _ = OwnerConfiguration;
    _ = DatabaseConfiguration;
    _ = Version;
    _ = PackageRelation;
    _ = Package;
    _ = ParsedDescription;
    _ = Group;
    _ = DatabaseStatus;
    _ = DatabaseUsage;
    _ = SignaturePolicy;
    _ = Database;
    _ = PhysicalArchitectures;
    _ = @import("structs/DatabaseValidationTests.zig");
}
