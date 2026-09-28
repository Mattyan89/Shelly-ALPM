const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const shelly_key = b.dependency("shelly_key", .{ .target = target, .optimize = optimize });

    const mod = b.addModule("Shelly_Rlpm", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const action_worker = b.addExecutable(.{
        .name = "shelly-rlpm-action-worker",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/actions/worker.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const action_options = b.addOptions();
    action_options.addOptionPath("worker_path", action_worker.getEmittedBin());
    mod.addOptions("action_worker", action_options);
    b.installArtifact(action_worker);
    const download = b.dependency("shelly_download", .{ .target = target, .optimize = optimize });
    mod.addImport("Shelly_Download", download.module("Shelly_Download"));
    const worker_options = b.addOptions();
    worker_options.addOptionPath("worker_path", download.artifact("shelly-download-worker").getEmittedBin());
    mod.addOptions("download_worker", worker_options);
    b.installArtifact(download.artifact("shelly-download-worker"));
    mod.addImport("Shelly_Key", shelly_key.module("Shelly_Key"));
    mod.linkSystemLibrary("archive", .{});
    mod.linkSystemLibrary("sqlite3", .{});
    mod.addCSourceFile(.{ .file = b.path("src/native/regex.c"), .flags = &.{"-std=c11"} });
    mod.addCSourceFile(.{ .file = b.path("src/native/publication.c"), .flags = &.{"-std=c11"} });
    mod.addCSourceFile(.{ .file = b.path("src/native/lock.c"), .flags = &.{"-std=c11"} });

    const exe = b.addExecutable(.{
        .name = "Shelly_Rlpm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "Shelly_Rlpm", .module = mod }},
        }),
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Read local metadata (arguments: ROOT DBPATH)").dependOn(&run.step);

    const unit = b.addTest(.{ .root_module = mod });
    const test_step = b.step("test", "Run hermetic tests, public API checks, and reference ledger validation");
    test_step.dependOn(&b.addRunArtifact(unit).step);
    // Compile the real read-only example too, rather than an empty test runner.
    test_step.dependOn(&exe.step);

    const public_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/public_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "Shelly_Rlpm", .module = mod }},
    }) });
    const run_public = b.addRunArtifact(public_tests);
    public_tests.root_module.addCSourceFile(.{ .file = b.path("src/tests/lock_process.c"), .flags = &.{"-std=c11"} });
    test_step.dependOn(&run_public.step);
    b.step("test-public-api", "Exercise the exported API from a separate importing module").dependOn(&run_public.step);

    const metadata_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/metadata.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "Shelly_Rlpm", .module = mod }},
    }) });
    b.step("test-metadata", "Run M2 metadata, archive, relation and reference fixtures").dependOn(&b.addRunArtifact(metadata_tests).step);

    const database_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/database.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "Shelly_Rlpm", .module = mod }},
    }) });
    b.step("test-database", "Run M3 local, tar/SQLite, query, reload and allocation fixtures").dependOn(&b.addRunArtifact(database_tests).step);

    const verification_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/verification.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "Shelly_Rlpm", .module = mod }},
    }) });
    b.step("test-verification", "Run M4 integrity, trust, status, import and immutable-file fixtures").dependOn(&b.addRunArtifact(verification_tests).step);

    const resolver_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/resolver.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "Shelly_Rlpm", .module = mod }},
    }) });
    b.step("test-resolver", "Run M5 resolution, removal, system-upgrade and reference fixtures").dependOn(&b.addRunArtifact(resolver_tests).step);

    const executor_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/executor.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "Shelly_Rlpm", .module = mod }},
    }) });
    b.step("test-executor", "Run M10 disposable-root payload and database transactions").dependOn(&b.addRunArtifact(executor_tests).step);
    const hook_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/hooks.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "Shelly_Rlpm", .module = mod }},
    }) });
    b.step("test-hooks", "Run hermetic M9 parser, discovery, matching and ownership fixtures").dependOn(&b.addRunArtifact(hook_tests).step);
    const preflight_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/preflight.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "Shelly_Rlpm", .module = mod }},
    }) });
    b.step("test-preflight", "Run M8 private-root archive, conflict, backup and space fixtures").dependOn(&b.addRunArtifact(preflight_tests).step);
    const sandbox_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/download_sandbox.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "Shelly_Rlpm", .module = mod }},
    }) });
    const sandbox_run = b.addRunArtifact(sandbox_tests);
    sandbox_run.has_side_effects = true;
    b.step("test-download-sandbox", "Opt-in root-only sandbox integration, private /tmp roots").dependOn(&sandbox_run.step);
    b.step("check-download-sandbox", "Compile the root-only integration fixture").dependOn(&sandbox_tests.step);
    const download_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/download.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "Shelly_Rlpm", .module = mod }},
    }) });
    b.step("test-download", "Run M7 private-cache, acquisition, refresh and DOWNLOADONLY fixtures").dependOn(&b.addRunArtifact(download_tests).step);
    const transaction_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/transaction.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "Shelly_Rlpm", .module = mod }},
    }) });
    transaction_tests.root_module.addCSourceFile(.{ .file = b.path("src/tests/lock_process.c"), .flags = &.{"-std=c11"} });
    b.step("test-transaction", "Run M6 private-root lifecycle, lock, ownership, cancellation and reference fixtures").dependOn(&b.addRunArtifact(transaction_tests).step);

    const ledger_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/compatibility.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const run_ledger = b.addRunArtifact(ledger_tests);
    test_step.dependOn(&run_ledger.step);
    b.step("test-compatibility", "Validate the pinned API inventory and coverage ledger (not full behavioral parity)").dependOn(&run_ledger.step);

    const version_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/structs/Version.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    b.step("test-version", "Run hermetic version tests").dependOn(&b.addRunArtifact(version_tests).step);

    const package_mod = b.createModule(.{
        .root_source_file = b.path("src/structs/Package.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    package_mod.linkSystemLibrary("archive", .{});
    const package_tests = b.addTest(.{ .root_module = package_mod });
    b.step("test-package", "Run hermetic package archive tests").dependOn(&b.addRunArtifact(package_tests).step);

    // Native integrations are opt-in and always rerun. Their output includes
    // subprocess diagnostics/previews, which require the terminal test runner.
    const terminal_runner: std.Build.Step.Compile.TestRunner = .{
        .path = .{ .cwd_relative = b.pathJoin(&.{ b.graph.zig_lib_directory.path.?, "compiler/test_runner.zig" }) },
        .mode = .simple,
    };
    const executor_driver = b.addExecutable(.{ .name = "rlpm-executor-fixture", .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/executor_driver.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "Shelly_Rlpm", .module = mod }},
    }) });
    const interop = b.addSystemCommand(&.{ "unshare", "--user", "--map-root-user", "--mount", "python3" });
    interop.addFileArg(b.path("src/tests/reference/check_executor_interop.py"));
    interop.addArg("--driver");
    interop.addArtifactArg(executor_driver);
    interop.stdio = .inherit;
    interop.has_side_effects = true;
    b.step("test-executor-interop", "Alternate RLPM and pinned native libalpm against private databases").dependOn(&interop.step);
    const executor_integration = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/executor_integration.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "Shelly_Rlpm", .module = mod }},
    }), .test_runner = terminal_runner });
    const run_executor = b.addSystemCommand(&.{ "unshare", "--user", "--map-root-user", "--mount" });
    run_executor.addArtifactArg(executor_integration);
    run_executor.stdio = .inherit;
    run_executor.has_side_effects = true;
    b.step("test-executor-integration", "Run full executor processes and attributes in disposable roots").dependOn(&run_executor.step);
    const action_filter = b.addExecutable(.{ .name = "rlpm-action-filter-fixture", .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/action_filter.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    action_filter.root_module.addOptions("worker_path", action_options);
    const action_probe = b.addExecutable(.{ .name = "rlpm-action-probe-fixture", .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/action_probe.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    const action_fixture_options = b.addOptions();
    action_fixture_options.addOptionPath("filter", action_filter.getEmittedBin());
    action_fixture_options.addOptionPath("probe", action_probe.getEmittedBin());
    const action_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/actions.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "Shelly_Rlpm", .module = mod }},
    }), .test_runner = terminal_runner });
    action_tests.root_module.addOptions("action_fixtures", action_fixture_options);
    const run_actions = b.addSystemCommand(&.{ "unshare", "--user", "--map-root-user", "--mount", "env", "BASH_ENV=/injected-startup", "SHLVL=7" });
    run_actions.addArtifactArg(action_tests);
    run_actions.stdio = .inherit;
    run_actions.has_side_effects = true;
    b.step("test-actions", "Run real M9 actions in disposable chroots under a user namespace").dependOn(&run_actions.step);
    b.step("check-actions", "Compile M9 integration without executing it").dependOn(&action_tests.step);
    const signature_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/signature.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "Shelly_Rlpm", .module = mod }},
        }),
        .test_runner = terminal_runner,
    });
    const run_signature = b.addRunArtifact(signature_tests);
    run_signature.stdio = .inherit;
    run_signature.has_side_effects = true;
    b.step("test-signature", "Run real GPG integration; unavailable tools/agent are failures").dependOn(&run_signature.step);

    const host_mod = b.createModule(.{
        .root_source_file = b.path("src/host_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "Shelly_Key", .module = shelly_key.module("Shelly_Key") }},
    });
    host_mod.addCSourceFile(.{ .file = b.path("src/native/publication.c"), .flags = &.{"-std=c11"} });
    host_mod.linkSystemLibrary("archive", .{});
    host_mod.linkSystemLibrary("sqlite3", .{});
    const host_tests = b.addTest(.{
        .root_module = host_mod,
        .filters = &.{"host-readonly:"},
        .test_runner = terminal_runner,
    });
    const run_host = b.addRunArtifact(host_tests);
    run_host.stdio = .inherit;
    run_host.has_side_effects = true;
    b.step("test-host-readonly", "Opt in to reading /var/lib/pacman; never a release parity gate").dependOn(&run_host.step);
}
