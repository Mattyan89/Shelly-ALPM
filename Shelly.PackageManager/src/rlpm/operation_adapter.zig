//! RLPM callback adapter used by the selected PackageManager backend.
//! Initialize at its final address before a transaction; release the transaction
//! before deinit. Context and operation outlive the adapter. UI question payloads
//! are owned here through the deferred response, then expire when ask returns.
const Adapter = @This();
const std = @import("std");
const rlpm = @import("Shelly_Rlpm");
const op = @import("operation_context");
owner: *rlpm.Owner,
operation: *op.Operation,
previous: rlpm.Callbacks,
cancellation_subscription: op.SubscriptionId,
failure_handler: ?struct {
    function: *const fn (?*anyopaque, []const u8) void,
    data: ?*anyopaque,
} = null,

pub fn init(self: *Adapter, owner: *rlpm.Owner, operation: *op.Operation) !void {
    const subscription = try operation.context.subscribeCancellation(.{ .function = cancel, .data = owner });
    errdefer {
        _ = operation.context.unsubscribeCancellation(subscription);
        operation.context.waitForCancellationCallbacks();
    }
    const previous = owner.options().callbacks;
    self.* = .{ .owner = owner, .operation = operation, .previous = previous, .cancellation_subscription = subscription };
    var callbacks = previous;
    callbacks.question = null;
    callbacks.question_with_error = question;
    callbacks.question_context = self;
    callbacks.event = event;
    callbacks.event_context = self;
    callbacks.log = log;
    callbacks.log_context = self;
    callbacks.progress = progress;
    callbacks.progress_context = self;
    callbacks.download = download;
    callbacks.download_context = self;
    try owner.setCallbacks(callbacks);
    if (operation.isCancelled()) owner.requestCancellation();
}
pub fn deinit(self: *Adapter) !void {
    try self.owner.setCallbacks(self.previous);
    _ = self.operation.context.unsubscribeCancellation(self.cancellation_subscription);
    self.operation.context.waitForCancellationCallbacks();
    self.* = undefined;
}
fn from(data: ?*anyopaque) *Adapter {
    return @ptrCast(@alignCast(data.?));
}
fn cancel(data: ?*anyopaque) void {
    const owner: *rlpm.Owner = @ptrCast(@alignCast(data.?));
    owner.requestCancellation();
}
fn cancelled(data: ?*anyopaque) bool {
    const owner: *rlpm.Owner = @ptrCast(@alignCast(data.?));
    owner.checkCancelled() catch return true;
    return false;
}
fn name(a: std.mem.Allocator, q: rlpm.Callbacks.Question, ref: rlpm.PackageRef) ![]const u8 {
    switch (q) {
        inline else => |value| if (@hasField(@TypeOf(value), "views")) {
            for (value.views) |view| if (std.meta.eql(view.reference, ref)) return view.package.name;
        },
    }
    return std.fmt.allocPrint(a, "package {d}:{d}:{d}", .{ @intFromEnum(ref.database.id), ref.generation, @intFromEnum(ref.id) });
}
fn question(data: ?*anyopaque, borrowed: *rlpm.Callbacks.Question) !void {
    const self = from(data);
    const allocator = self.operation.context.allocator;
    var owned = try rlpm.OwnedQuestion.init(allocator, borrowed.*);
    defer owned.deinit();
    const a = owned.arena.allocator();
    const q = &owned.question;
    var request: op.QuestionRequest = .{ .kind = .confirmation, .prompt = "", .default_response = .declined, .cancellation = .{ .data = self.owner, .check = cancelled } };
    switch (q.*) {
        .install_ignored => |value| request.prompt = try std.fmt.allocPrint(a, "Install ignored package {s}?", .{try name(a, q.*, value.package)}),
        .replace => |value| request.prompt = try std.fmt.allocPrint(a, "Replace {s} with {s}?", .{ try name(a, q.*, value.old), try name(a, q.*, value.new) }),
        .conflict => |value| {
            request.purpose = .package_conflict;
            request.prompt = try std.fmt.allocPrint(a, "Remove {s}, which conflicts with {s} ({s})?", .{ try name(a, q.*, value.second), try name(a, q.*, value.first), value.reason.name });
        },
        .corrupted => |value| request.prompt = try std.fmt.allocPrint(a, "Remove corrupted package file {s} ({s})?", .{ value.path, @errorName(value.reason) }),
        .remove_packages => |value| {
            request.prompt = "Skip targets whose dependencies cannot be resolved?";
            const arguments = try a.alloc([]const u8, value.packages.len);
            for (arguments, value.packages) |*argument, ref| argument.* = try name(a, q.*, ref);
            request.arguments = arguments;
        },
        .select_provider => |value| {
            request.kind = .select_provider;
            request.prompt = try std.fmt.allocPrint(a, "Select a provider for {s}", .{value.dependency.name});
            request.dependency_name = value.dependency.name;
            const options = try a.alloc(op.QuestionOption, value.candidates.len);
            for (options, value.candidates, 0..) |*option, ref, index| {
                const label = try name(a, q.*, ref);
                option.* = .{ .id = try std.fmt.allocPrint(a, "{d}", .{index}), .label = label, .is_selected = index == value.selected };
            }
            request.options = options;
            request.default_response = .{ .choice = value.selected };
        },
        .import_key => |value| {
            request.kind = .import_pgp_key;
            request.prompt = try std.fmt.allocPrint(a, "Import signing key {s} ({s})?", .{ value.key.fingerprint, value.key.user_id orelse "unknown user" });
            request.pgp_key_import = .{ .package_name = self.operation.envelope.subject orelse "", .fingerprint = value.key.fingerprint };
        },
    }
    var response = try self.operation.ask(request);
    defer response.deinit(allocator);
    try self.operation.checkCancelled();
    try self.owner.checkCancelled();
    const answer = if (response.response == .default) request.default_response else response.response;
    if (q.* == .select_provider) {
        if (answer != .choice) return error.InvalidAnswer;
        q.select_provider.selected = answer.choice;
    } else {
        const accepted = switch (answer) {
            .accepted => true,
            .declined => false,
            else => return error.InvalidAnswer,
        };
        switch (q.*) {
            .install_ignored => |*value| value.install = accepted,
            .replace => |*value| value.replace = accepted,
            .conflict => |*value| value.remove = accepted,
            .corrupted => |*value| value.remove = accepted,
            .remove_packages => |*value| value.skip = accepted,
            .import_key => |*value| value.import = accepted,
            .select_provider => unreachable,
        }
    }
    try rlpm.OwnedQuestion.applyAnswer(borrowed, q.*);
}
fn reportFailure(self: *Adapter, err: anyerror) void {
    var operation = self.operation.*;
    const issue = if (self.owner.transaction()) |tx| blk: {
        const manifest = tx.manifest() orelse break :blk null;
        const failure = manifest.failure orelse break :blk null;
        if (failure.package) |id| if (tx.plan()) |plan| {
            operation.envelope.subject = plan.package(id).name;
        };
        break :blk failure;
    } else null;
    const diagnostics = @import("diagnostics");
    const allocator = operation.context.allocator;
    const message = diagnostics.format(allocator, err, .{
        .operation = diagnostics.operationDescription(operation.envelope.kind),
        .subject = operation.envelope.subject,
        .path = if (issue) |failure| failure.path else null,
    }) catch {
        operation.reportError(err, @errorName(err), "rlpm", null, false);
        if (self.failure_handler) |handler| handler.function(handler.data, @errorName(err));
        return;
    };
    defer allocator.free(message);
    operation.reportError(err, message, "rlpm", null, false);
    if (self.failure_handler) |handler| handler.function(handler.data, message);
}
fn event(data: ?*anyopaque, value: rlpm.Callbacks.Event) void {
    const self = from(data);
    switch (value) {
        .lifecycle => |result| switch (result.state) {
            .completed => self.operation.finish(.success),
            .interrupted => self.operation.finish(.cancelled),
            .failed => {
                if (result.cause) |err| self.reportFailure(err);
                self.operation.finish(.failed);
            },
            .released => self.operation.finish(if (result.cause != null and result.cause.? != error.Cancelled) .failed else .cancelled),
            else => self.operation.status(.information, @tagName(result.state), "rlpm.lifecycle", null),
        },
        .phase => |phase| {
            self.operation.status(if (phase.boundary == .failed) .warning else .information, @tagName(phase.phase), @tagName(phase.boundary), null);
            if (phase.total_packages != null or phase.total_bytes != null) self.operation.progress(.{ .stage = @tagName(phase.phase), .total = phase.total_packages, .bytes_total = phase.total_bytes });
        },
        .package_operation => |package_event| {
            const ref = package_event.new orelse package_event.old;
            var package_name: ?[]const u8 = null;
            if (ref) |identity| for (package_event.views) |view| {
                if (std.meta.eql(view.reference, identity)) {
                    package_name = view.package.name;
                    break;
                }
            };
            self.operation.packageStatus(.information, @tagName(package_event.operation), @tagName(package_event.boundary), null, package_name);
        },
        .hook => |hook| self.operation.status(.information, @tagName(hook.when), @tagName(hook.boundary), null),
        .database_missing => |database| {
            var buffer: [96]u8 = undefined;
            const message = std.fmt.bufPrint(&buffer, "Database {d} is missing", .{@intFromEnum(database.id)}) catch unreachable;
            self.operation.status(.warning, message, "rlpm.database_missing", null);
        },
        .optional_dependency_removed => |dependency| self.operation.status(.warning, dependency.dependency.name, "rlpm.optional_dependency_removed", null),
        .scriptlet_output => |message| self.operation.status(.information, message, "rlpm.scriptlet", null),
        .pacnew_created => |backup| self.operation.status(.warning, backup.path, "rlpm.pacnew", null),
        .pacsave_created => |backup| self.operation.status(.warning, backup.path, "rlpm.pacsave", null),
        .hook_run => |hook| self.operation.status(.information, hook.description orelse hook.name, @tagName(hook.boundary), null),
        .diagnostic => |diagnostic| self.operation.reportError(diagnostic.cause, @errorName(diagnostic.cause), "rlpm", null, false),
    }
    if (self.previous.event) |callback| callback(self.previous.event_context, value);
}
fn log(data: ?*anyopaque, value: rlpm.Callbacks.Log) void {
    const self = from(data);
    self.operation.status(switch (value.level) {
        .err => .warning,
        .warning => .warning,
        else => .information,
    }, value.message, "rlpm.log", null);
    if (self.previous.log) |callback| callback(self.previous.log_context, value);
}
fn progress(data: ?*anyopaque, value: rlpm.Callbacks.Progress) void {
    const self = from(data);
    self.operation.progress(.{ .stage = @tagName(value.phase), .percentage = @floatFromInt(value.percent), .completed = value.position, .total = value.total });
    if (self.previous.progress) |callback| callback(self.previous.progress_context, value);
}
fn download(data: ?*anyopaque, value: rlpm.Callbacks.Download) void {
    const self = from(data);
    switch (value) {
        .progress => |update| self.operation.progress(.{ .stage = "download", .message = update.name, .bytes_completed = update.downloaded, .bytes_total = update.total }),
        inline else => |update| self.operation.status(.information, update.name, @tagName(value), null),
    }
    if (self.previous.download) |callback| callback(self.previous.download_context, value);
}

test "adapter owns all seven deferred question payloads and copies only answers" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var owner = try rlpm.Owner.init(std.testing.io, std.testing.allocator, .{ .root = path, .database_path = path }, &.{});
    defer owner.deinit() catch unreachable;
    var context = op.OperationContext.init(std.testing.allocator, std.testing.io);
    defer context.deinit();
    var operation = context.begin(.{ .backend = .alpm, .kind = .install });
    defer operation.finish(.success);
    var adapter: Adapter = undefined;
    try adapter.init(&owner, &operation);
    defer adapter.deinit() catch unreachable;
    const Handler = struct {
        fn answer(data: ?*anyopaque, q: op.Question) op.QuestionResponse {
            const ctx: *op.OperationContext = @ptrCast(@alignCast(data.?));
            ctx.respond(q.question_id, if (q.kind == .select_provider) .{ .choice = 0 } else .accepted) catch unreachable;
            return .deferred;
        }
    };
    context.setQuestionHandler(.{ .function = Handler.answer, .data = &context });
    const ref: rlpm.PackageRef = .{ .database = .{ .owner = @enumFromInt(1), .id = .local }, .generation = 1, .id = @enumFromInt(0) };
    var questions = [_]rlpm.Callbacks.Question{
        .{ .install_ignored = .{ .package = ref } },
        .{ .replace = .{ .old = ref, .new = ref, .database = ref.database } },
        .{ .conflict = .{ .first = ref, .second = ref, .reason = try rlpm.PackageRelation.parse("virtual>=1") } },
        .{ .corrupted = .{ .path = "cached.tar", .reason = error.ChecksumMismatch } },
        .{ .remove_packages = .{ .packages = &.{ref} } },
        .{ .select_provider = .{ .dependency = try rlpm.PackageRelation.parse("virtual"), .candidates = &.{ref} } },
        .{ .import_key = .{ .key = .{ .fingerprint = "0123456789" } } },
    };
    for (&questions) |*q| try owner.ask(q);
    try std.testing.expect(questions[0].install_ignored.install and questions[1].replace.replace and questions[2].conflict.remove and questions[3].corrupted.remove and questions[4].remove_packages.skip and questions[6].import_key.import);
    try std.testing.expectEqual(0, questions[5].select_provider.selected);
}

test "deferred answers survive the handler and both cancellation sources wake the wait" {
    const Pending = struct {
        ready: std.Io.Event = .unset,
        question: ?op.Question = null,
        owner: *rlpm.Owner,
        result: ?anyerror = null,
        answer_value: bool = false,
        fn handle(data: ?*anyopaque, q: op.Question) op.QuestionResponse {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.question = q;
            self.ready.set(std.testing.io);
            return .deferred;
        }
        fn run(self: *@This()) void {
            var q: rlpm.Callbacks.Question = .{ .import_key = .{ .key = .{ .fingerprint = "owned-fingerprint", .user_id = "key owner" } } };
            self.owner.ask(&q) catch |err| {
                self.result = err;
                return;
            };
            self.answer_value = q.import_key.import;
        }
    };
    for (0..3) |scenario| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const path = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(path);
        var owner = try rlpm.Owner.init(std.testing.io, std.testing.allocator, .{ .root = path, .database_path = path }, &.{});
        defer owner.deinit() catch unreachable;
        var context = op.OperationContext.init(std.testing.allocator, std.testing.io);
        defer context.deinit();
        var operation = context.begin(.{ .backend = .alpm, .kind = .install });
        defer operation.finish(.cancelled);
        var adapter: Adapter = undefined;
        try adapter.init(&owner, &operation);
        defer adapter.deinit() catch unreachable;
        var pending: Pending = .{ .owner = &owner };
        context.setQuestionHandler(.{ .function = Pending.handle, .data = &pending });
        const worker = try std.Thread.spawn(.{}, Pending.run, .{&pending});
        // Always wake and join the borrower, including on a failed expectation.
        var joined = false;
        defer if (!joined) {
            context.cancel();
            worker.join();
        };
        try pending.ready.wait(std.testing.io);
        const q = pending.question.?;
        try std.testing.expectEqualStrings("owned-fingerprint", q.pgp_key_import.?.fingerprint);
        try std.testing.expect(std.mem.indexOf(u8, q.prompt, "key owner") != null);
        switch (scenario) {
            0 => try context.respond(q.question_id, .accepted),
            1 => context.cancel(),
            2 => owner.requestCancellation(),
            else => unreachable,
        }
        worker.join();
        joined = true;
        if (scenario == 0) {
            try std.testing.expect(pending.result == null and pending.answer_value);
        } else try std.testing.expectEqual(error.Cancelled, pending.result.?);
        try std.testing.expectError(error.UnknownQuestion, context.respond(q.question_id, .accepted));
    }
}

test "lifecycle completion reports failures and abandonment once" {
    const Capture = struct {
        completions: usize = 0,
        status: ?op.CompletionStatus = null,
        fn event(data: ?*anyopaque, value: op.Event) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            if (value == .completed) {
                self.completions += 1;
                self.status = value.completed.status;
            }
        }
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var owner = try rlpm.Owner.init(std.testing.io, std.testing.allocator, .{ .root = path, .database_path = path }, &.{});
    defer owner.deinit() catch unreachable;
    var context = op.OperationContext.init(std.testing.allocator, std.testing.io);
    defer context.deinit();
    var capture: Capture = .{};
    _ = try context.subscribe(.{ .function = Capture.event, .data = &capture });
    for (0..2) |scenario| {
        var operation = context.begin(.{ .backend = .alpm, .kind = .install });
        defer operation.finish(.cancelled);
        var adapter: Adapter = undefined;
        try adapter.init(&owner, &operation);
        defer adapter.deinit() catch unreachable;
        const tx = try owner.initializeTransaction(std.testing.io, .{});
        if (scenario == 0) {
            try tx.addTarget("missing");
            try std.testing.expectError(error.TargetNotFound, tx.prepare());
        }
        try owner.releaseTransaction();
        try std.testing.expectEqual(scenario + 1, capture.completions);
        try std.testing.expectEqual(if (scenario == 0) op.CompletionStatus.failed else .cancelled, capture.status.?);
    }
}

test "archive inventory failures report the package and mismatched path" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "fixture.pkg.tar" });
    defer a.free(path);
    {
        var file = try temporary.dir.createFile(io, "fixture.pkg.tar", .{});
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &buffer);
        var tar: std.tar.Writer = .{ .underlying_writer = &writer.interface };
        try tar.writeFileBytes(".PKGINFO", "pkgname = archive-fixture\npkgver = 1-1\narch = any\n", .{ .mode = 0o644 });
        try tar.writeFileBytes(".MTREE", "#mtree\n./missing type=file\n", .{ .mode = 0o644 });
        try tar.writeFileBytes("present", "payload", .{ .mode = 0o644 });
        try tar.finishPedantically();
        try writer.interface.flush();
    }
    var owner = try rlpm.Owner.init(io, a, .{ .root = root, .database_path = root }, &.{});
    defer owner.deinit() catch unreachable;
    var context = op.OperationContext.init(a, io);
    defer context.deinit();
    const Capture = struct {
        failures: usize = 0,
        package: bool = false,
        path: bool = false,
        explanation: bool = false,
        fn event(data: ?*anyopaque, value: op.Event) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            if (value == .failure and value.failure.err == error.ArchiveInventoryMismatch) {
                self.failures += 1;
                self.package = std.mem.eql(u8, value.failure.envelope.subject orelse "", "archive-fixture");
                self.path = std.mem.indexOf(u8, value.failure.message, "Path: missing") != null;
                self.explanation = std.mem.indexOf(u8, value.failure.message, "file list does not match") != null;
            }
        }
    };
    var capture: Capture = .{};
    _ = try context.subscribe(.{ .function = Capture.event, .data = &capture });
    var operation = context.begin(.{ .backend = .alpm, .kind = .update, .subject = "rlpm" });
    defer operation.finish(.failed);
    var adapter: Adapter = undefined;
    try adapter.init(&owner, &operation);
    defer adapter.deinit() catch unreachable;
    const tx = try owner.initializeTransaction(io, .{});
    defer owner.releaseTransaction() catch unreachable;
    var package: ?rlpm.Package = try owner.loadPackage(io, path, .local_file, .{});
    defer if (package) |*value| value.deinit();
    try tx.takeArchive(&package);
    try tx.prepare();
    try std.testing.expectError(error.ArchiveInventoryMismatch, tx.preflight());
    try std.testing.expectEqual(1, capture.failures);
    try std.testing.expect(capture.package and capture.path and capture.explanation);
}

test "payload finishing log and progress reach operation subscribers" {
    const Capture = struct {
        status_seen: bool = false,
        progress_seen: bool = false,
        fn event(data: ?*anyopaque, value: op.Event) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            switch (value) {
                .status => |status| {
                    if (status.level == .information and std.mem.eql(u8, status.message, "Finishing writes for headers")) self.status_seen = true;
                },
                .progress => |update| {
                    if (update.update.percentage == 99) self.progress_seen = true;
                },
                else => {},
            }
        }
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var owner = try rlpm.Owner.init(std.testing.io, std.testing.allocator, .{ .root = path, .database_path = path }, &.{});
    defer owner.deinit() catch unreachable;
    var context = op.OperationContext.init(std.testing.allocator, std.testing.io);
    defer context.deinit();
    var capture: Capture = .{};
    _ = try context.subscribe(.{ .function = Capture.event, .data = &capture });
    var operation = context.begin(.{ .backend = .alpm, .kind = .install });
    defer operation.finish(.cancelled);
    var adapter: Adapter = undefined;
    try adapter.init(&owner, &operation);
    defer adapter.deinit() catch unreachable;
    const callbacks = owner.configuration.callbacks;
    callbacks.log.?(callbacks.log_context, .{ .level = .function, .message = "Finishing writes for headers" });
    callbacks.progress.?(callbacks.progress_context, .{ .phase = .transaction, .package = null, .percent = 99, .position = 1, .total = 1 });
    try std.testing.expect(capture.status_seen and capture.progress_seen);
}
