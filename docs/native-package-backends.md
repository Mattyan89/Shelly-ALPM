# Native package backends

Shelly builds both libalpm and RLPM by default and initially selects libalpm.
RLPM uses its Owner/Database/Package/Transaction implementation, including the
CachyOS SQLite database, architecture, installed-repository, and action sandbox
extensions. It does not delegate transactions to libalpm.

## Select a backend

```sh
shelly config get NativePackageBackend
shelly config set NativePackageBackend rlpm
shelly config set NativePackageBackend libalpm
```

The setting is stored in `shelly/config.json` under the resolved XDG configuration
directory, separately from `pacman.conf`. It takes effect on the next CLI
invocation. GTK uses the same selection through its CLI commands. Bootstrap
children explicitly receive the selected backend. Existing invoking-user/XDG
resolution also applies to this setting during privilege elevation.

An unknown value or non-string value fails with `InvalidBackend`. Explicit
`libalpm` in an RLPM-only build fails with `BackendUnavailable`, before package
work. There is no fallback after initialization or transaction failure.
`config get/list/set/reset` remain usable to inspect and repair these settings.
`config reset` resets **all** Shelly settings to that build's defaults. A saved
explicit backend survives changing builds; an omitted setting uses the compiled
default.

## Build and package

```sh
# Both backends, with libalpm as the initial selection (also the default).
(cd Shelly.Cli.Zig && zig build -Dlibalpm=true)
# RLPM only, with RLPM as the initial selection.
(cd Shelly.Cli.Zig && zig build -Dlibalpm=false)
```

`Shelly.PackageManager` and `Shelly.Tui` accept the same build option. The disabled
variant omits libalpm imports, header translation, pkg-config discovery, linkage,
and native binding tests. The GUI invokes the CLI and does not link either engine.

Install `shelly-rlpm-action-worker` and `shelly-download-worker` alongside `shelly`.
CLI install targets, release bundles, and the package recipes include both helpers.
PackageManager resolves helpers beside the running executable; source builds and
unit tests otherwise use the matching emitted build artifacts. Library embedders
that relocate their executable must also deploy the workers there.

Source PKGBUILDs accept `SHELLY_LIBALPM=false makepkg`; omitting it builds both.
The shared build needs libarchive, SQLite, curl, Zig, and the existing project
inputs. Default packages retain pacman/libalpm. RLPM-only Shelly binaries do not
link libalpm, but the Arch recipes still retain pacman for external build tools,
isolated-root provisioning tools, and distribution integration. GPG/keyrings
remain needed for signature verification; disabling libalpm does not remove them.

## Library boundary

`PackageManager.Manager.init(allocator, environ, .{ .backend = .rlpm, ... })` selects an
engine explicitly. An omitted backend captures `PackageManager.Manager.defaultBackend()`.
`PackageManager.Manager.Backend.available()`, `PackageManager.Manager.libalpm_enabled`, and `PackageManager.Manager.default_backend`
expose compiled availability. Changing the process default affects future managers;
release the existing manager before switching engines for the same operation.
Both use the database's common `db.lck` transaction lock.

Public flags, events, errors, and package records live in backend-neutral modules.
Callers own query snapshots, including `get_single_installed_package` and
`load_archive` results, and must deinitialize them with the manager's allocator.
Snapshots survive refresh; borrowed satisfier names expire on refresh/deinit.
Use `CacheManager.Options.manager` instead of a raw libalpm handle. Raw C bindings
are confined to the libalpm implementation and its conditional reference tests.
AUR dependency callbacks propagate errors and cancellation separately from missing
packages.

Both mappings accept multiple cache directories/architectures, CacheServer,
AssumeInstalled, ParallelDownloads (1–255), DownloadUser, download timeout and
sandbox controls. `auto` expands using CachyOS runtime CPU/OS capabilities;
mirror `$arch` uses the first configured architecture. The system hook directory
precedes configured hook directories. `root_hooks_only` restricts bootstrap hooks
to the guest. RLPM update previews copy local metadata into a separate database
and reject transactions and aliased preview roots. On the first RLPM update check,
a legacy libalpm cache link to the configured local database is replaced with a
private metadata copy. Other database links are rejected; manual cache removal
is unnecessary when switching from libalpm.

## Verification and acceptance

```sh
scripts/test-native-backends.sh true Debug
scripts/test-native-backends.sh false Debug
scripts/test-native-backends.sh true ReleaseSafe
scripts/test-native-backends.sh false ReleaseSafe
```

The script runs private-root facade transactions and staged-worker tests, CLI
regressions, setting persistence/repair/reset and JSON/UI smoke checks, then ELF
checks on the installed CLI and workers. The default variant tests both engines
and alternates writers against the same disposable root. RLPM-only artifacts must
have no direct/transitive libalpm dependencies or imported `alpm_*` symbols.
A clean local production build also passed in a temporary mount namespace with
libalpm headers, pkg-config metadata and libraries masked by empty files; the CLI
ran there successfully. CI repeats the disabled build after removing libalpm headers, pkg-config metadata,
and shared libraries **inside its disposable container**. Do not remove those
files from a working Arch system.

Local validation on 2026-09-28 (Zig 0.16.0):

| Check | Result |
| --- | --- |
| Dual backend and RLPM-only, Debug and ReleaseSafe | All four script runs passed; 413 CLI tests per run |
| Staged facade/worker fixtures | All 11 scenarios passed in each build variant |
| RLPM core/public API/ledger | 188 tests passed in Debug and ReleaseSafe |
| Additional RLPM metadata/database fixtures | 21 tests passed in Debug |
| TUI with libalpm disabled | 18 tests passed |
| Focused loopback/GPG target outside socket restrictions | Passed with libalpm enabled and disabled |
| Clean production build with libalpm files masked | Built workers/CLI and launched CLI successfully |
| Shell recipes, workflow YAML, whitespace checks | Passed |

These integration checks do not certify the complete libalpm compatibility ledger.
The [completion plan](rlpm-libalpm-completion-plan.md) retains release gates for
privileged actions/sandboxes, independent reference behavior, parser fuzzing,
large-repository performance and full frontend workflows. The broad local PackageManager runs were restricted by socket and GPG permissions.
The loopback download and temporary-keyring signing fixtures subsequently passed
outside that restriction via `zig build native-environment-test`; CI runs that
focused target in both build variants. The broad suite's real AppImage download
remains unverified locally. Run the broad suite and privileged RLPM matrix in the
configured CI/container before release acceptance; do not treat blocked checks as
passes.
