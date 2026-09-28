# Package execution and local persistence

M0–M10 are accepted. M10 implements normal `Transaction.commit()`;
`capabilities().transactions` is enabled. PackageManager still uses libalpm.
M11 implements runtime selection between libalpm and RLPM, both enabled in default
builds, plus an optional libalpm-disabled build that defaults to RLPM. See the
[M11 contract](../docs/rlpm-libalpm-completion-plan.md#m11--configure-both-backends-and-complete-production-acceptance).
The Owner/Database/Package/Transaction ownership model and CachyOS extensions
remain intact.

```zig
const tx = try owner.initializeTransaction(io, .{});
defer owner.releaseTransaction() catch unreachable;
try tx.addTarget("example");
try tx.prepare();
// Review tx.plan(); optional tx.preflight() leaves the transaction prepared.
try tx.commit();
const result = tx.result();
// Inspect result.warnings, tx.execution and tx.actions() before release.
```

Commit verifies the reviewed database snapshot and held lock, acquires packages,
loads sealed archives, checks filesystem effects, then starts pre-transaction
hooks. It processes resolved removals followed by additions. Package-operation
start precedes the pre-scriptlet. Removal's post-scriptlet and operation-done event
precede deletion of its old local record. Additions publish the new local record
and cache before their post-scriptlet and operation-done event. Upgrade,
reinstall and downgrade use the incoming script with new/old version arguments.
Successful package work is followed by ldconfig and post-transaction hooks.

The complete native event sequence for the 26 inert executor oracle cases is
replayed, excluding RLPM lifecycle and failed-phase diagnostic extensions.
Acquisition verifies sealed bytes before publishing the accepted batch's keyring
and integrity boundaries. Filesystem failure or cancellation does not produce a
transaction-done event or run post hooks. Action failures that libalpm treats as
nonfatal remain in `actions().outcomes` and contribute to `result().warnings`.
Configured audit files receive timestamped ALPM transaction/package records;
`use_syslog` enables audit forwarding. Audit failures are retained as warnings.

## Filesystem operations

Archive names are validated by preflight. Mutation resolves immediate parents
with `openat2(IN_ROOT | NO_MAGICLINKS)` and uses held directory descriptors.
Regular data, sparse extents, symlinks, directories and supported special entries
are extracted with libarchive into private sibling staging directories, then
published with descriptor-relative rename. Hardlinks use a held source inode.
No archive-controlled pathname reaches libarchive's disk writer. The parent
process's working directory and umask never change.

Extraction preserves native modes, ownership, times and extended attributes,
including file capabilities. The pinned add.c enables XATTR but **does not enable
ACL extraction**; RLPM uses the same flags. Sparse data blocks retain their offsets.
Device-node creation obeys kernel privileges. Existing shared directories retain
their attributes. Removal uses unlink/rmdir and preserves nonempty directories;
it never recursively removes payload trees. Transferred files are left for their
incoming owner. Root and database identities are checked at mutation boundaries.

Backup decisions use the current filesystem after hooks and pre-scriptlets, the
old recorded hash, and the actual extracted incoming hash. `.pacnew` creation,
refresh/removal of existing suffixes, `.pacsave` rotation, NoUpgrade, NoExtract
and NOSAVE follow the native fixtures. Backup hashes reflect actual extraction,
including hardlink and symlink targets. NoExtract retains inventory but leaves
its backup hash unset. Space estimates use serialized desc/files lengths,
block-rounded archive members, and staging/journal directories.

| Mode | Effects |
| --- | --- |
| Normal | Payload, records, scripts, hooks and linker maintenance |
| DBONLY | Record/member publication; no payload/conflict work; native scripts/hooks still run |
| DOWNLOADONLY with additions | Verified cache acquisition; no package/record/action execution |
| DOWNLOADONLY with only removals | Native removal path, including payload and record deletion |
| NOHOOKS / NOSCRIPTLET | Independent suppression; linker maintenance still applies |
| NOLOCK | Commit rejected |
| Read-only local database | Installed-state mutation and reason changes rejected |

## Durable local records and cache lifetime

Local format 9 records include compatible desc/files data, backup hashes,
validation, dates, reasons, install/changelog/mtree members and CachyOS
`INSTALLED_DB`. Newly serialized files are mode 0644 and record directories 0755.
Archive members retain their metadata with the native 0644 permission override.
`Owner.setInstallReason(io, reference, reason)` atomically persists a reason under
`db.lck` and invalidates local references; load the database again before querying
that Owner. A fresh Owner immediately sees the persisted reason.

A new record is fully staged outside `local/`, with files fsynced before
publication. Cooperating readers share the local directory flock; the publisher
holds it exclusively. A durable journal names the old/new records. The old record
moves into staging, the new record moves into local, and both directories are
synced before journal removal is synced as the commit point. Ordinary publication
errors attempt record rollback. Native clients continue to coordinate through
`db.lck`; readers ignoring that lock are outside the atomic publication contract.

An interrupted journal makes RLPM readers return `DatabaseRecoveryRequired`.
`Owner.recoverLocalDatabase(io, allocator, database_path)` acquires the normal
writer lock and restores the old coherent record idempotently. It also removes
abandoned staging with no journal. It never removes a foreign/stale `db.lck`;
resolve a dead writer's lock explicitly before recovery. This recovery concerns
local records, not package payload rollback.

Each successful publication rebuilds local identities. On failure the cache is
invalidated/reloaded from disk; a failed reload cannot advertise old cached
packages. Plan and manifest metadata are independent copies and remain valid
until release. Post hooks resolve dependencies against the new local state.

## Partial failure and evidence

`tx.execution` retains completed and remaining package IDs, current package,
boundary, path, mutation count, publication confirmation, cause, native extraction
message/errno and cleanup failures. `packages_committed` counts fully completed
package operations. `database_published` confirms the current record's successful
publication; it is not a payload rollback indicator. A failed fsync/recovery can
require journal inspection even if some files are already visible.

RLPM deliberately stops at a failed mutation instead of continuing to advertise
an extracted package after an error. Cancellation checks between data blocks and
operation boundaries can stop within a package sooner than native libalpm's
between-package interruption checks. The result remains failed/interrupted,
with partial work retained. Locks/resources are released by `releaseTransaction`.
No full filesystem rollback or crash-safe payload transaction is claimed.

- `zig build test-executor`: full package cycle, 26 pinned native state/event
  cases, flags/backups, persisted reasons/provenance, transfers, recovery,
  cancellation, root replacement, audit, operation-boundary fault injection and
  real filesystem write failures. Included in `test`.
- `zig build test-executor-integration`: real chroot commits replay all 19 M9
  native traces, attributes/capabilities/sparse/ACL behavior, script-modified
  backup inputs, post-hook dependencies, private-tmpfs ENOSPC and device creation
  or its kernel denial. Missing namespace/mount support fails, never skips.
- `zig build test-executor-interop`: requires the pinned libalpm binary and
  alternates both implementations against generated private databases. It checks
  both directions, upgrades/downgrades/removal, exact local record contents
  (normalizing install time), attributes and backup outcomes. No host package
  database, hooks or services are used.

Run each in Debug and ReleaseSafe. CI runs the hermetic and namespace suites;
the pinned-binary interoperability gate is explicit because stock Arch CI does
not carry the frozen CachyOS build. These are M10 evidence, not a declaration of
complete public libalpm parity: the overall ledger and M11 acceptance remain open.
