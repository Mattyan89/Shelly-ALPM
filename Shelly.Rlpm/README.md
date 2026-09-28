# Shelly.Rlpm

RLPM is the native Zig package backend under development. The
[completion plan](../docs/rlpm-libalpm-completion-plan.md) targets libalpm's
functional behavior **including CachyOS extensions**, following the existing
Owner/Database/Package design. M0 and M1 are accepted; M2 is implemented and
awaiting acceptance before M3. RLPM is not yet a replacement for libalpm.

M1 exports an owning `Owner` with copied options, ordered repository registration,
read-only local queries, stable database identity, package cache generations,
typed callbacks, diagnostics and cancellation. Configuration and metadata have
separate arenas; failed configuration replacement retains the previous state.
Group membership uses package IDs. The [options and lifetimes guide](options.md)
contains a usable example and the complete option/consumer inventory.

M2 adds complete metadata shapes, permissive relation parsing/formatting and
satisfaction, archive inventories, file/backup metadata and owned member streams.
The [metadata API guide](metadata.md) covers source provenance, sizes, signatures,
mtree behavior and the explicit arena conversion API. Strict Version construction
remains available alongside permissive metadata ingestion.

CachyOS physical architecture enumeration and independent network-sandbox
configuration are available. Installed-repository provenance survives local
queries. SQLite sync loading, full provenance handling and hook/scriptlet network
isolation remain required later milestones. M7 will reuse PackageManager's
downloader, queue and mirror logic with its Shelly.Http transport, extracting
a shared core with adapters for each caller.

## Build and tests

Use Zig 0.16.0 and libarchive development headers/library. `Shelly.Key` is a local
module dependency. From this directory:

| Command | Scope |
| --- | --- |
| `zig build` | Build the read-only example executable |
| `zig build run -- ROOT DBPATH` | Print local package names/versions using explicit directory paths |
| `zig build run -- --help` | Show example usage |
| `zig build test` | Hermetic unit tests, external API consumer, reference/ledger checks, example compilation |
| `zig build test-public-api` | External Owner and metadata API, ownership, references and failure cases |
| `zig build test-metadata` | M2 relation, archive, metadata and independent reference fixtures |
| `zig build test-compatibility` | Frozen reference integrity, complete API inventory and evidence schema |
| `zig build test-version` | Existing fixed version expectations and ownership tests |
| `zig build test-package` | Package archive/metadata tests, including imported unit tests |
| `zig build test-signature` | Five real detached-signature GPG integration tests |
| `zig build test-host-readonly` | Opt-in smoke reads of `/var/lib/pacman/local` and `sync` |

All test modules honor `-Doptimize=ReleaseSafe` and the other standard optimize
modes. CI runs `test` in Debug and ReleaseSafe and `test-signature` in Debug.
Normal builds/tests do not link, load or call libalpm. Python is only required
for optional reference recording.

`test` uses temporary package/database fixtures; it neither reads the host
package database nor launches GPG. It requires libarchive. GPG integration
requires `gpg`, `gpgconf`, `gpg-agent` and Unix socket access. It uses private
`/tmp/rlpm-gpg-*` homes, ephemeral keys, explicit verifier homes and cleanup of
its own agents/files. Missing tools or blocked agents fail with
`GpgIntegrationUnavailable`; skips cannot satisfy that gate. These five tests
exercise boolean detached verification, not M4's complete trust/policy matrix.

The host smoke suite may skip absent data. Its legacy sync reader only covers
plain/gzip description archives and skips Zstandard; it is not the production
sync backend and is never a parity acceptance gate.

## Current limits and compatibility evidence

Root and database directories must already exist. M1 opens local descriptions
read-only; missing local storage is an empty snapshot. The pinned libalpm
initializer creates a local version file, so format creation/validation remains
an explicit M3 gap. Registered sync databases need not exist, but loading them
returns `UnsupportedDatabaseBackend` until M3. Capability reporting keeps sync
databases, full signature policy, downloads and transactions disabled.

- The [manifest](src/tests/reference/manifest.json) pins the exact upstream,
  CachyOS and packaging revisions, headers, patches and binary identity.
  [Reference documentation](src/tests/reference/README.md) explains attribution,
  corpus provenance and optional capture on disposable roots.
- The [ledger](src/tests/compatibility-ledger.tsv) tracks 493 public symbols and
  25 behavioral contracts. There are 266 missing, 219 partial and 33
  representation-only rows. No row claims verified full compatibility, and
  every CachyOS extension remains required.
- [Owner reference fixtures](src/tests/fixtures/owner-reference.json) capture
  independent libalpm defaults, paths, registration and sandbox controls.
  Allocation failures, stale references, rollback/retry and callback contracts
  also have external consumer tests. Option storage does not close the later
  milestones responsible for consuming those values.
- The 54 fixed version expectations remain unchanged. Vendoring upstream tests
  does not mean they have run against RLPM; later milestones must adapt those
  cases and attach reviewed independent evidence.
- [Metadata reference fixtures](src/tests/fixtures/metadata-reference.json) add
  independent relation, provision, byte-version, archive-mode, signature-decoding
  and local file/provenance expectations. Archive streams are available now;
  installed-package streams and file correlation remain M3. Metadata loading
  does not establish payload or signature integrity.

M2 validation on 2026-09-27: `test` passed all 78 tests in Debug and ReleaseSafe
(47 library, 27 external consumer, four ledger tests). The focused metadata,
version and package targets passed 9/13/25 tests respectively; these overlap the
normal suite. All five real GPG cases and the three host smoke/discovery cases
passed. The installed ReleaseSafe example read permissive metadata without
changing fixture contents, permissions or modification times. No libalpm dynamic
dependency was found in the example or cached test executables. Reference/GPG
fixtures were cleaned up, and formatting, recorder syntax and local links pass.

Historical M1 validation on 2026-09-27: `test` passed 68 tests in both Debug and ReleaseSafe
(47 library, 17 external consumer, four ledger tests), and real GPG integration
passed all five cases. The optional host suite passed its two smoke cases and
discovery test. The installed ReleaseSafe example passed help, empty-database
and populated-database checks; fixture contents, permissions and modification
times were unchanged. The example and cached test executables have no libalpm
dynamic dependency, and GPG fixture homes were cleaned up. Formatting and local
documentation links were checked. M0's historical counts were 54 ordinary tests
and five GPG cases. CI is configured but has not been run remotely. Each milestone
needs user acceptance before implementation proceeds to the next.
