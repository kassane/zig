const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    var test_path_arg: ?[]const u8 = null;
    var zig_path_arg: ?[]const u8 = null;
    var lib_path_arg: ?[]const u8 = null;
    var target_args: std.ArrayList([]const u8) = .empty;
    defer target_args.deinit(init.gpa);
    var keep_src = false;

    var arg_it = try init.minimal.args.iterateAllocator(arena);
    const self = arg_it.next().?;
    while (arg_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--listen=-")) {
            return protocol(init.gpa, init.arena, init.io);
        } else if (std.mem.eql(u8, arg, "--zig")) {
            zig_path_arg = arg_it.next() orelse fatal("missing arg after '{s}'", .{arg});
        } else if (std.mem.cutPrefix(u8, arg, "--zig=")) |zig_path| {
            zig_path_arg = zig_path;
        } else if (std.mem.eql(u8, arg, "--lib")) {
            lib_path_arg = arg_it.next() orelse fatal("missing arg after '{s}'", .{arg});
        } else if (std.mem.cutPrefix(u8, arg, "--lib=")) |lib_path| {
            lib_path_arg = lib_path;
        } else if (std.mem.eql(u8, arg, "--target")) {
            try target_args.append(
                init.gpa,
                try arena.dupe(u8, arg_it.next() orelse fatal("missing arg after '{s}'", .{arg})),
            );
        } else if (std.mem.cutPrefix(u8, arg, "--target=")) |target| {
            try target_args.append(init.gpa, try arena.dupe(u8, target));
        } else if (std.mem.eql(u8, arg, "--keep-src")) {
            keep_src = true;
        } else {
            if (test_path_arg) |_| fatal("unknown arg '{s}'", .{arg});
            test_path_arg = arg;
        }
    }

    const test_path = test_path_arg orelse fatal("missing 'path/to/test'", .{});
    const zig_path = zig_path_arg orelse fatal("missing '--zig=path/to/zig'", .{});
    const lib_path = lib_path_arg orelse fatal("missing '--lib=path/to/lib'", .{});

    const test_file = try std.Io.Dir.cwd().openFile(init.io, test_path, .{
        .allow_directory = true,
    });
    const zig_exe = try std.Io.Dir.cwd().openFile(init.io, zig_path, .{});
    defer zig_exe.close(init.io);
    const lib_dir = try std.Io.Dir.cwd().openDir(init.io, lib_path, .{});
    defer lib_dir.close(init.io);

    const src_dir_path = "src_" ++ std.fmt.hex(rand_int: {
        var rand_int: u64 = undefined;
        init.io.random(@ptrCast(&rand_int));
        break :rand_int rand_int;
    });
    var src_dir = try std.Io.Dir.cwd().createDirPathOpen(init.io, src_dir_path, .{});
    defer {
        src_dir.close(init.io);
        if (!keep_src) std.Io.Dir.cwd().deleteTree(init.io, src_dir_path) catch |err| {
            std.log.warn("fataled to delete tree '{s}': {t}", .{ src_dir_path, err });
        };
    }

    var stdout_buffer: [512]u8 = undefined;
    var stdout_fw: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_fw.interface;

    var child = try std.process.spawn(init.io, .{
        .argv = &.{ self, "--listen=-" },
        .stdin = .pipe,
        .stdout = .pipe,
        .inherit_dirs = &.{ lib_dir, src_dir },
        .inherit_files = &.{ zig_exe, test_file },
    });

    var child_reader_buffer: [512]u8 = undefined;
    var child_reader = child.stdout.?.readerStreaming(init.io, &child_reader_buffer);
    var child_writer_buffer: [512]u8 = undefined;
    var child_writer = child.stdin.?.writerStreaming(init.io, &child_writer_buffer);
    var client: std.zig.Client = .{
        .in = &child_reader.interface,
        .out = &child_writer.interface,
    };
    {
        var args: std.ArrayList(u8) = .empty;
        defer args.deinit(init.gpa);
        const Arg = std.zig.Client.Message.Arg;

        try args.append(init.gpa, @backingInt(@as(Arg, switch ((try test_file.stat(init.io)).kind) {
            else => unreachable,
            .file => .input_file,
            .directory => .input_dir,
        })));
        try args.appendSlice(init.gpa, @ptrCast(&test_file.handle));

        try args.append(init.gpa, @backingInt(Arg.prefix));
        try args.appendSlice(init.gpa, "--zig=");
        try args.append(init.gpa, 0);

        try args.append(init.gpa, @backingInt(Arg.input_file));
        try args.appendSlice(init.gpa, @ptrCast(&zig_exe.handle));

        try args.append(init.gpa, @backingInt(Arg.prefix));
        try args.appendSlice(init.gpa, "--lib=");
        try args.append(init.gpa, 0);

        try args.append(init.gpa, @backingInt(Arg.input_dir));
        try args.appendSlice(init.gpa, @ptrCast(&lib_dir.handle));

        try args.append(init.gpa, @backingInt(Arg.prefix));
        try args.appendSlice(init.gpa, "--src=");
        try args.append(init.gpa, 0);

        try args.append(init.gpa, @backingInt(Arg.output_dir));
        try args.appendSlice(init.gpa, @ptrCast(&src_dir.handle));

        for (target_args.items) |target_arg| {
            try args.append(init.gpa, @backingInt(Arg.string));
            try args.appendSlice(init.gpa, "--target");
            try args.append(init.gpa, 0);

            try args.append(init.gpa, @backingInt(Arg.string));
            try args.appendSlice(init.gpa, target_arg);
            try args.append(init.gpa, 0);
        }

        try client.serveMessageHeader(.{
            .tag = .args,
            .bytes_len = @intCast(args.items.len),
        });
        try client.out.writeAll(args.items);

        var metadata: struct {
            index: u32,
            len: u32,
            names: []u32,
            expected_panic_msgs: []u32,
            string_bytes: []u8,

            fn name(m: *@This()) []const u8 {
                return std.mem.sliceTo(m.string_bytes[m.names[m.index - 1]..], 0);
            }

            fn expectedPanicMsg(m: *@This()) ?[:0]const u8 {
                return switch (m.expected_panic_msgs[m.index - 1]) {
                    0 => null,
                    else => |offset| m.string_bytes[offset..std.mem.findScalarPos(
                        u8,
                        m.string_bytes,
                        offset,
                        0,
                    ).? :0],
                };
            }

            fn next(m: *@This()) ?u32 {
                if (m.len - m.index == 0) return null;
                defer m.index += 1;
                return m.index;
            }
        } = .{ .index = 0, .len = 0, .names = &.{}, .expected_panic_msgs = &.{}, .string_bytes = &.{} };
        try client.serveBodylessMessage(.query_test_metadata);
        while (true) {
            const hdr = try client.receiveMessage();
            switch (hdr.tag) {
                else => try client.in.discardAll(hdr.bytes_len),
                .zig_version => {
                    const body = try arena.alloc(u8, hdr.bytes_len);
                    try client.in.readSliceAll(body);
                    if (!std.mem.eql(u8, @import("builtin").zig_version_string, body)) return fatal(
                        "zig version mismatch build runner vs compiler: '{s}' vs '{s}'",
                        .{ @import("builtin").zig_version_string, body },
                    );
                },
                .test_metadata => {
                    const tm_hdr =
                        try client.in.takeStruct(std.zig.Server.Message.TestMetadata, .little);
                    metadata = .{
                        .index = 0,
                        .len = tm_hdr.tests_len,
                        .names = try arena.alloc(u32, tm_hdr.tests_len),
                        .expected_panic_msgs = try arena.alloc(u32, tm_hdr.tests_len),
                        .string_bytes = try arena.alloc(u8, tm_hdr.string_bytes_len),
                    };
                    try client.in.readSliceEndian(u32, metadata.names, .little);
                    try client.in.readSliceEndian(u32, metadata.expected_panic_msgs, .little);
                    try client.in.readSliceAll(metadata.string_bytes);
                    try client.serveRunTest(metadata.next() orelse break);
                },
                .test_results => {
                    const tr = try client.in.takeStruct(std.zig.Server.Message.TestResults, .little);
                    try stdout.print("[{t}] {s}\n", .{ tr.flags.status, metadata.name() });
                    try stdout.flush();
                    try client.serveRunTest(metadata.next() orelse break);
                },
            }
        }
        try client.serveBodylessMessage(.exit);
    }
    _ = try child.wait(init.io);
}
fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(1);
}

const Args = struct {
    @"test": ?struct {
        input_dir: std.zig.Server.Message.InputDir,
        dir: std.Io.Dir,
    },
    manifest_file: ?std.Io.File,
    zig_exe: ?std.Io.File,
    lib_dir: ?std.Io.Dir,
    src_dir: ?std.Io.Dir,
    targets: std.ArrayList(u32),
    target_bytes: std.ArrayList(u8),

    fn deinit(args: *Args, gpa: std.mem.Allocator) void {
        args.targets.deinit(gpa);
        args.target_bytes.deinit(gpa);
    }

    fn addTarget(args: *Args, gpa: std.mem.Allocator, target: []const u8) std.mem.Allocator.Error!void {
        try args.target_bytes.ensureUnusedCapacity(gpa, target.len + 1);
        try args.targets.append(gpa, @intCast(args.target_bytes.items.len));
        args.target_bytes.appendSliceAssumeCapacity(target);
        args.target_bytes.appendAssumeCapacity(0);
    }
};
pub fn protocol(gpa: std.mem.Allocator, arena_impl: *std.heap.ArenaAllocator, io: std.Io) !void {
    const prog_node = std.Progress.start(io, .{});
    defer prog_node.end();

    var stdin_buffer: [512]u8 = undefined;
    var stdout_buffer: [512]u8 = undefined;
    var stdin: std.Io.File.Reader = .initStreaming(.stdin(), io, &stdin_buffer);
    var stdout: std.Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buffer);
    var server: std.zig.Server = .{
        .in = &stdin.interface,
        .out = &stdout.interface,
    };

    var args: Args = .{
        .@"test" = null,
        .manifest_file = null,
        .zig_exe = null,
        .lib_dir = null,
        .src_dir = null,
        .targets = .empty,
        .target_bytes = .empty,
    };
    defer args.deinit(gpa);

    try server.serveStringMessage(.zig_version, @import("builtin").zig_version_string);
    while (true) {
        _ = arena_impl.reset(.retain_capacity);
        const arena = arena_impl.allocator();
        const hdr = try server.receiveMessage();
        switch (hdr.tag) {
            else => {
                std.debug.print("unsupported message: {t}\n", .{hdr.tag});
                std.process.exit(1);
            },
            .exit => std.process.exit(0),
            .args => {
                const args_body = try arena.alloc(u8, hdr.bytes_len);
                try server.in.readSliceAll(args_body);
                var state: enum { positional, zig, lib, src, target } = .positional;
                var input_dir: std.zig.Server.Message.InputDir = .cwd;
                var args_body_offset: usize = 0;
                while (args_body.len - args_body_offset > 0) {
                    const arg: std.zig.Client.Message.Arg =
                        @fromBackingInt(args_body[args_body_offset]);
                    args_body_offset += 1;
                    arg: switch (arg) {
                        .string => {
                            const end = std.mem.findScalarPos(u8, args_body, args_body_offset, 0).?;
                            const string = args_body[args_body_offset..end];
                            args_body_offset = end + 1;
                            switch (state) {
                                .positional => if (std.mem.eql(u8, string, "--target")) {
                                    state = .target;
                                    continue;
                                } else if (std.mem.cutPrefix(u8, string, "--target=")) |target| {
                                    try args.addTarget(gpa, target);
                                },
                                .zig => unreachable,
                                .lib => unreachable,
                                .src => unreachable,
                                .target => try args.addTarget(gpa, string),
                            }
                        },
                        .prefix => {
                            const end = std.mem.findScalarPos(u8, args_body, args_body_offset, 0).?;
                            const string = args_body[args_body_offset..end];
                            args_body_offset = end + 1;
                            state = if (std.mem.eql(u8, string, "--zig="))
                                .zig
                            else if (std.mem.eql(u8, string, "--lib="))
                                .lib
                            else if (std.mem.eql(u8, string, "--src="))
                                .src
                            else
                                unreachable;
                            continue;
                        },
                        .suffix => unreachable,
                        .input_dir => {
                            input_dir = @fromBackingInt(@backingInt(input_dir) + 1);
                            continue :arg .output_dir;
                        },
                        .output_dir => {
                            const dir_handle: *align(1) const std.Io.Dir.Handle = @ptrCast(
                                args_body[args_body_offset..][0..@sizeOf(std.Io.Dir.Handle)],
                            );
                            args_body_offset += @sizeOf(std.Io.Dir.Handle);
                            const dir: std.Io.Dir = .{
                                .handle = dir_handle.*,
                            };
                            switch (state) {
                                .positional => {
                                    std.debug.assert(args.@"test" == null);
                                    args.@"test" = .{ .input_dir = input_dir, .dir = dir };
                                    std.debug.assert(args.manifest_file == null);
                                    const manifest_path = "manifest";
                                    args.manifest_file = try dir.openFile(io, manifest_path, .{});

                                    try server.serveMessageHeader(.{
                                        .tag = .discovered_inputs,
                                        .bytes_len = @sizeOf(std.zig.Server.Message.InputDir) +
                                            manifest_path.len + 1,
                                    });
                                    try server.out.writeInt(u32, @backingInt(input_dir), .little);
                                    try server.out.writeAll(manifest_path);
                                    try server.out.writeByte(0);
                                    try server.out.flush();
                                },
                                .zig => unreachable,
                                .lib => {
                                    std.debug.assert(args.lib_dir == null);
                                    args.lib_dir = dir;
                                },
                                .src => {
                                    std.debug.assert(args.src_dir == null);
                                    args.src_dir = dir;
                                },
                                .target => unreachable,
                            }
                        },
                        .input_file, .input_file_content, .output_file => {
                            const file_handle: *align(1) const std.Io.File.Handle = @ptrCast(
                                args_body[args_body_offset..][0..@sizeOf(std.Io.File.Handle)],
                            );
                            args_body_offset += @sizeOf(std.Io.File.Handle);
                            const file: std.Io.File = .{
                                .handle = file_handle.*,
                                .flags = .{ .nonblocking = false },
                            };
                            switch (state) {
                                .positional => {
                                    std.debug.assert(args.manifest_file == null);
                                    args.manifest_file = file;
                                },
                                .zig => {
                                    std.debug.assert(args.zig_exe == null);
                                    args.zig_exe = file;
                                },
                                .lib => unreachable,
                                .src => unreachable,
                                .target => unreachable,
                            }
                        },
                    }
                    state = .positional;
                }
            },
            .query_test_metadata => {
                const expected_panic_msgs = try arena.alloc(u32, args.targets.items.len);
                @memset(expected_panic_msgs, 0);
                try server.serveTestMetadata(.{
                    .names = args.targets.items,
                    .expected_panic_msgs = expected_panic_msgs,
                    .string_bytes = args.target_bytes.items,
                });
            },
            .run_test => {
                const test_index = try server.receiveBody_u32();
                const target_query =
                    std.mem.sliceTo(args.target_bytes.items[args.targets.items[test_index]..], 0);
                try server.serveBodylessMessage(.test_started);
                const test_result =
                    runTest(gpa, arena, io, prog_node, &server, &args, target_query);
                try server.serveTestResults(.{
                    .index = test_index,
                    .flags = .{
                        .status = if (test_result) .pass else |err| switch (err) {
                            else => status: {
                                std.debug.print("{t}\n", .{err});
                                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
                                break :status .fail;
                            },
                            error.SkipZigTest => .skip,
                        },
                        .fuzz = false,
                        .log_err_count = 0,
                        .leak_count = 0,
                    },
                });
            },
        }
    }
}
fn runTest(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    prog_node: std.Progress.Node,
    server: *std.zig.Server,
    args: *const Args,
    target_string: []const u8,
) !void {
    const manifest_file = args.manifest_file orelse return error.MissingManifestArg;
    const src_dir = args.src_dir orelse return error.MissingSrcDir;
    const target: Compiler.Target = target: {
        const backend_split = std.mem.findScalarLast(u8, target_string, '-') orelse
            return error.TargetMissingBackend;
        const mode_split =
            std.mem.findScalarLast(u8, target_string[0..backend_split], '-') orelse
            return error.TargetMissingMode;
        const triple = target_string[0..mode_split];
        const backend = std.meta.stringToEnum(
            Compiler.Target.Backend,
            target_string[backend_split + 1 ..],
        ) orelse return error.TargetMissingBackend;
        const mode = std.meta.stringToEnum(
            Compiler.Target.Mode,
            target_string[mode_split + 1 .. backend_split],
        ) orelse return error.TargetMissingMode;
        break :target .{
            .triple = triple,
            .resolved = try std.zig.system.resolveTargetQuery(io, try std.Build.parseTargetQuery(.{
                .arch_os_abi = triple,
                .object_format = switch (backend) {
                    .sema, .selfhosted, .llvm => null,
                    .cbe => "c",
                },
            })),
            .mode = mode,
            .backend = backend,
        };
    };
    var manifest_buffer: [512]u8 = undefined;
    var manifest_fr = manifest_file.reader(io, &manifest_buffer);
    var allow_skip = true;
    var skip_delimiter = false;
    var compiler: ?Compiler = null;
    var update_mtime = std.Io.Clock.real.now(io);
    var update_num: usize = 0;
    while (manifest_fr.interface.takeSentinel('\n')) |untrimmed_line| {
        const line = std.mem.trimEnd(u8, untrimmed_line, "\r");
        var line_it = std.mem.tokenizeScalar(u8, line, ' ');
        const cmd_str = std.mem.cutPrefix(u8, line_it.next() orelse continue, "#").?;
        if (skip_delimiter) {
            std.debug.assert(std.mem.eql(u8, cmd_str, "}"));
            skip_delimiter = false;
            continue;
        }
        const cmd = std.meta.stringToEnum(
            enum { skip, exe, lib, obj, write, delete, update, check },
            cmd_str,
        ) orelse return error.UnknownCommand;
        var maybe_arg = line_it.next();
        var contents_file: ?std.Io.File = null;
        defer if (contents_file) |file| file.close(io);
        var contents_buffer: [512]u8 = undefined;
        var contents_impl: union {
            dr: DelimitedReader,
            fr: std.Io.File.Reader,
        } = undefined;
        const contents_r: *std.Io.Reader = contents_r: switch (cmd) {
            .skip, .delete => {
                if (line_it.next()) |_| return error.UnexpectedArg;
                break :contents_r .ending;
            },
            else => {
                const contents_path = contents_path: {
                    const line_rest = line_it.rest();
                    if (line_rest.len > 0) break :contents_path line_rest;
                    const contents_path = maybe_arg orelse break :contents_r .ending;
                    maybe_arg = null;
                    break :contents_path contents_path;
                };
                if (std.mem.eql(u8, contents_path, "{")) {
                    contents_impl = .{ .dr = .init(&manifest_fr.interface, "#}", &contents_buffer) };
                    skip_delimiter = true;
                    break :contents_r &contents_impl.dr.interface;
                }

                const @"test" = args.@"test" orelse return error.ContentsFileInFileTest;
                try server.serveMessageHeader(.{
                    .tag = .discovered_inputs,
                    .bytes_len = @intCast(@sizeOf(std.zig.Server.Message.InputDir) +
                        contents_path.len + 1),
                });
                try server.out.writeInt(u32, @backingInt(@"test".input_dir), .little);
                try server.out.writeAll(contents_path);
                try server.out.writeByte(0);
                try server.out.flush();

                contents_file = try @"test".dir.openFile(io, contents_path, .{});
                contents_impl = .{ .fr = contents_file.?.reader(io, &contents_buffer) };
                break :contents_r &contents_impl.fr.interface;
            },
        };
        const cmd_prog_node = cmd_prog_node: {
            var cmd_name_buffer: [std.Progress.Node.max_name_len]u8 = undefined;
            break :cmd_prog_node prog_node.start(std.mem.print(&cmd_name_buffer, "#{t} {s}", .{
                cmd, maybe_arg orelse "",
            }) catch &cmd_name_buffer, 0);
        };
        defer cmd_prog_node.end();
        cmd: switch (cmd) {
            .skip => if (!allow_skip)
                return error.NonInitialSkipCommand // #skip must appear first
            else if (std.mem.eql(u8, target_string, maybe_arg orelse return error.MissingArg))
                return error.SkipZigTest,
            .exe, .lib, .obj => {
                if (compiler) |*comp| {
                    try comp.exit(io);
                    compiler = null;
                }
                var argv: std.ArrayList([]const u8) = .empty;
                defer argv.deinit(gpa);
                try argv.appendSlice(gpa, &.{
                    "zig",
                    switch (cmd) {
                        else => unreachable,
                        .obj => "build-obj",
                        .exe => "build-exe",
                        .lib => "build-lib",
                    },
                    "-target",
                    target.triple,
                });
                switch (target.mode) {
                    .whole => {},
                    .incremental => try argv.append(gpa, "-fincremental"),
                }
                switch (target.backend) {
                    .sema => try argv.append(gpa, "-fno-emit-bin"),
                    .selfhosted => try argv.append(gpa, "-fno-llvm"),
                    .llvm => try argv.append(gpa, "-fllvm"),
                    .cbe => try argv.append(gpa, "-ofmt=c"),
                }
                try argv.append(gpa, "--listen=-");
                var need: usize = 1;
                var root_name: ?[]const u8 = null;
                while (contents_r.peekGreedy(need)) |buffered| {
                    const start = std.mem.findNone(u8, buffered, "\n ") orelse buffered.len;
                    if (std.mem.findAnyPos(u8, buffered, start, "\n ")) |end| {
                        const arg = try arena.dupe(u8, buffered[start..end]);
                        if (std.mem.cutPrefix(u8, arg, "-M")) |module| {
                            var module_name_it = std.mem.splitScalar(u8, module, '=');
                            const module_name = module_name_it.next().?;
                            root_name = root_name orelse module_name;
                        }
                        try argv.append(gpa, arg);
                        contents_r.toss(end);
                        need = 1;
                    } else {
                        contents_r.toss(start);
                        need = buffered.len - start + 1;
                    }
                } else |err| switch (err) {
                    else => |e| return e,
                    error.EndOfStream => {},
                }
                const compile_prog_node = prog_node.start("initial update", 0);
                const child = try std.process.spawn(io, .{
                    .exe = .{ .file = args.zig_exe orelse return error.MissingZigExe },
                    .argv = argv.items,
                    .cwd = .{ .dir = src_dir },
                    .progress_node = compile_prog_node,
                    .stdin = .pipe,
                    .stdout = .pipe,
                    .stderr = .pipe,
                });
                compiler = .{
                    .prog_node = compile_prog_node,
                    .allow_compiler_stderr = true,
                    .output_mode = switch (cmd) {
                        else => unreachable,
                        .exe => .Exe,
                        .lib => .Lib,
                        .obj => .Obj,
                    },
                    .root_name = root_name orelse return error.MissingRootModule,
                    .state = .idle,
                    .child = child,
                    .fw = undefined,
                    .mr_buffer = undefined,
                    .mr = undefined,
                    .client = undefined,
                };
                const comp = &compiler.?;
                comp.fw = child.stdin.?.writerStreaming(io, &.{});
                comp.mr.init(gpa, io, comp.mr_buffer.toStreams(), &.{
                    child.stdout.?, child.stderr.?,
                });
                comp.client = .{ .in = comp.mr.reader(0), .out = &comp.fw.interface };
            },
            .write => {
                const file =
                    try src_dir.createFile(io, maybe_arg orelse return error.MissingFileArg, .{});
                defer file.close(io);
                var fw = file.writer(io, &.{});
                _ = try contents_r.streamRemaining(&fw.interface);
                try file.setTimestamps(io, .{ .modify_timestamp = .{ .new = update_mtime } });
            },
            .delete => try src_dir.deleteFile(io, maybe_arg orelse return error.MissingFileArg),
            .update => {
                const comp = &(compiler orelse return error.MissingCompiler);
                name: {
                    var name_buffer: [std.Progress.Node.max_name_len]u8 = undefined;
                    comp.prog_node.setName(switch (try contents_r.readSliceShort(&name_buffer)) {
                        0 => switch (update_num) {
                            0 => break :name,
                            else => |num| std.mem.print(&name_buffer, "update {d}", .{num}) catch
                                &name_buffer,
                        },
                        else => |name_len| name_buffer[0..name_len],
                    });
                }
                _ = try contents_r.discardRemaining();
                if (comp.state != .idle) return error.MissingCheck;
                try comp.client.serveBodylessMessage(.update);
                comp.state = .update;
                update_mtime = update_mtime.addDuration(.fromSeconds(2));
                update_num += 1;
            },
            .check => {
                const expected = try contents_r.allocRemaining(gpa, .unlimited);
                defer gpa.free(expected);
                const check = std.meta.stringToEnum(
                    enum { errors, stdout, exit, lldb },
                    maybe_arg orelse return error.MissingCheckArg,
                ) orelse return error.UnknownCheck;

                const comp = &(compiler orelse return error.MissingCompiler);
                if (comp.state != .update) return error.MissingUpdate;
                const stderr = comp.mr.reader(1);
                while (true) {
                    const header = comp.client.receiveMessageWithMultiReader(
                        &comp.mr,
                        .none,
                    ) catch |err| switch (err) {
                        error.Timeout => unreachable,
                        error.EndOfStream => break,
                        else => |e| return e,
                    };
                    const body = comp.client.in.take(header.bytes_len) catch unreachable;
                    switch (header.tag) {
                        .error_bundle => {
                            const error_bundle = try std.zig.Server.allocErrorBundle(arena, body);
                            if (stderr.bufferedLen() > 0) {
                                if (comp.allow_compiler_stderr) {
                                    std.log.info("error_bundle stderr:\n{s}", .{stderr.buffered()});
                                } else {
                                    fatal("error_bundle unexpected stderr:\n{s}", .{stderr.buffered()});
                                }
                                stderr.tossBuffered();
                            }
                            switch (check) {
                                .errors => if (error_bundle.errorMessageCount() != 0) {
                                    @panic("TODO");
                                } else fatal("expected compile errors", .{}),
                                .stdout, .exit, .lldb => if (error_bundle.errorMessageCount() != 0) {
                                    try error_bundle.renderToStderr(io, .{}, .auto);
                                    fatal("unexpected compile errors", .{});
                                },
                            }
                            comp.state = .idle;
                            break :cmd;
                        },
                        .emit_digest => {
                            var r: std.Io.Reader = .fixed(body);
                            _ = r.takeStruct(std.zig.Server.Message.EmitDigest, .little) catch
                                unreachable;

                            if (stderr.bufferedLen() > 0) {
                                if (comp.allow_compiler_stderr) {
                                    std.log.info("emit_digest stderr:\n{s}", .{stderr.buffered()});
                                } else {
                                    fatal("emit_digest unexpected stderr:\n{s}", .{stderr.buffered()});
                                }
                                stderr.tossBuffered();
                            }
                            switch (target.backend) {
                                .sema => continue,
                                .selfhosted, .llvm, .cbe => {},
                            }
                            switch (check) {
                                .errors => continue,
                                .stdout, .exit, .lldb => {},
                            }
                            const digest = r.takeArray(std.Build.Cache.bin_digest_len) catch
                                unreachable;
                            const result_dir = ".zig-cache" ++ std.Io.Dir.path.sep_str ++
                                "o" ++ std.Io.Dir.path.sep_str ++ std.Build.Cache.binToHex(digest.*);
                            const bin_name = try std.zig.EmitArtifact.bin.cacheName(arena, .{
                                .root_name = comp.root_name,
                                .cpu_arch = target.resolved.cpu.arch,
                                .os_tag = target.resolved.os.tag,
                                .ofmt = target.resolved.ofmt,
                                .abi = target.resolved.abi,
                                .output_mode = comp.output_mode,
                            });
                            const bin_path =
                                try std.Io.Dir.path.join(arena, &.{ result_dir, bin_name });
                            const bin_file = try std.Io.Dir.cwd().openFile(io, bin_path, .{});
                            defer bin_file.close(io);
                            switch (check) {
                                .errors => unreachable,
                                .stdout, .exit => {
                                    const result = std.process.run(arena, io, .{
                                        .exe = .{ .file = bin_file },
                                        .argv = &.{bin_path},
                                    }) catch continue;
                                    switch (result.term) {
                                        .exited => |code| switch (check) {
                                            .errors, .lldb => unreachable,
                                            .stdout => {
                                                if (code != 0) fatal("generated executable '{s}' failed with code {d}", .{ bin_path, code });
                                                try std.testing.expectEqualStrings(expected, result.stdout);
                                            },
                                            .exit => {
                                                var actual_code_buffer: [std.fmt.count("{d}", .{std.math.maxInt(u8)})]u8 = undefined;
                                                try std.testing.expectEqualStrings(
                                                    expected,
                                                    std.mem.print(&actual_code_buffer, "{d}", .{code}) catch unreachable,
                                                );
                                            },
                                        },
                                        .signal => |sig| fatal("generated executable '{s}' terminated with signal {t}", .{ bin_path, sig }),
                                        .stopped => |sig| fatal("generated executable '{s}' stopped with signal {t}", .{ bin_path, sig }),
                                        .unknown => fatal("generated executable '{s}' terminated unexpectedly", .{bin_path}),
                                    }
                                },
                                .lldb => {},
                            }
                        },
                        else => {}, // Ignore other messages,
                    }
                }

                const buffered_stderr = stderr.buffered();
                if (buffered_stderr.len > 0) {
                    if (comp.allow_compiler_stderr) {
                        std.log.info("stderr:\n{s}", .{buffered_stderr});
                    } else {
                        fatal("unexpected stderr:\n{s}", .{buffered_stderr});
                    }
                }

                try comp.exit(io);
                fatal("compiler failed to send terminating error_bundle", .{});
            },
        }
        std.debug.assert(try contents_r.discardRemaining() == 0);
        if (cmd != .skip) allow_skip = false;
    } else |err| switch (err) {
        else => |e| return e,
        error.EndOfStream => if (skip_delimiter) return error.MissingDelimiter,
    }
    if (compiler) |*comp| try comp.exit(io);
}
const DelimitedReader = struct {
    const Io = std.Io;

    unlimited: *Io.Reader,
    remaining: Io.Limit,
    delimiter: []const u8,
    interface: Io.Reader,

    pub fn init(reader: *Io.Reader, delimiter: []const u8, buffer: []u8) DelimitedReader {
        return .{
            .unlimited = reader,
            .remaining = .nothing,
            .delimiter = delimiter,
            .interface = .{
                .vtable = &.{
                    .stream = stream,
                    .discard = discard,
                },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }
    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const d: *DelimitedReader = @fieldParentPtr("interface", r);
        const block = try d.unlimited.peekGreedy(d.delimiter.len);
        d.remaining = .limited(std.mem.findPos(u8, block, d.remaining.toInt().?, d.delimiter) orelse
            block.len - d.delimiter.len + 1);
        if (d.remaining == .nothing) return error.EndOfStream;
        const n = try d.unlimited.stream(w, limit.min(d.remaining));
        d.remaining = d.remaining.subtract(n).?;
        return n;
    }
    fn discard(r: *Io.Reader, limit: Io.Limit) Io.Reader.Error!usize {
        const d: *DelimitedReader = @fieldParentPtr("interface", r);
        const block = try d.unlimited.peekGreedy(d.delimiter.len);
        d.remaining = .limited(std.mem.findPos(u8, block, d.remaining.toInt().?, d.delimiter) orelse
            block.len - d.delimiter.len + 1);
        if (d.remaining == .nothing) return error.EndOfStream;
        const n = try d.unlimited.discard(limit.min(d.remaining));
        d.remaining = d.remaining.subtract(n).?;
        return n;
    }
};
const Compiler = struct {
    prog_node: std.Progress.Node,
    allow_compiler_stderr: bool,
    output_mode: std.lang.OutputMode,
    root_name: []const u8,
    state: enum { idle, update },
    child: std.process.Child,
    fw: std.Io.File.Writer,
    mr_buffer: std.Io.File.MultiReader.Buffer(2),
    mr: std.Io.File.MultiReader,
    client: std.zig.Client,

    const Target = struct {
        triple: []const u8,
        resolved: std.Target,
        mode: Mode,
        backend: Backend,

        const Mode = enum {
            whole,
            incremental,
        };

        const Backend = enum {
            /// Run semantic analysis only. Runtime output will not be tested, but we still verify
            /// that compilation succeeds. Corresponds to `-fno-emit-bin`.
            sema,
            /// Use the self-hosted code generation backend for this target.
            /// Corresponds to `-fno-llvm -fno-lld`.
            selfhosted,
            /// Use the LLVM backend.
            /// Corresponds to `-fllvm -flld`.
            llvm,
            /// Use the C backend. The output is compiled with `zig cc`.
            /// Corresponds to `-ofmt=c`.
            cbe,
        };
    };

    fn update(comp: *Compiler, io: std.Io) !void {
        comp.client.serveBodylessMessage(.update) catch |err| switch (err) {
            error.WriteFailed => return comp.fw.err.?,
        };
        while (true) {
            const header = comp.client.receiveMessageWithMultiReader(
                &comp.mr,
                .none,
            ) catch |err| switch (err) {
                error.Timeout => unreachable,
                error.EndOfStream => break,
                else => |e| return e,
            };
            const body = comp.client.in.take(header.bytes_len) catch unreachable;
            switch (header.tag) {
                .error_bundle => {
                    return;
                },
                .emit_digest => {
                    _ = body;
                },
                else => {}, // Ignore other messages,
            }
        }

        const buffered_stderr = comp.mr.reader(1).buffered();
        if (buffered_stderr.len > 0) {
            if (comp.allow_compiler_stderr) {
                std.log.info("stderr:\n{s}", .{buffered_stderr});
            } else {
                fatal("unexpected stderr:\n{s}", .{buffered_stderr});
            }
        }

        try comp.exit(io);
        fatal("compiler failed to send terminating error_bundle", .{});
    }

    fn exit(comp: *Compiler, io: std.Io) !void {
        comp.client.serveBodylessMessage(.exit) catch |err| switch (err) {
            error.WriteFailed => switch (comp.fw.err.?) {
                error.BrokenPipe => {},
                else => |e| fatal("failed to send exit: {t}", .{e}),
            },
        };
        comp.child.stdin.?.close(io);
        comp.child.stdin = null;
        while (true) {
            const header = comp.client.receiveMessageWithMultiReader(
                &comp.mr,
                .none,
            ) catch |err| switch (err) {
                error.Timeout => unreachable,
                error.EndOfStream => |e| {
                    if (comp.client.in.bufferedLen() == 0) break;
                    return e;
                },
                else => |e| return e,
            };
            try comp.client.in.discardAll(header.bytes_len);
        }
        const term = comp.child.wait(io) catch |err| fatal("child process failed: {t}", .{err});
        comp.prog_node.end();
        switch (term) {
            .exited => |code| if (code != 0) fatal("compiler failed with code {d}", .{code}),
            .signal => |sig| fatal("compiler terminated with signal {t}", .{sig}),
            .stopped => |sig| fatal("compiler stopped unexpectedly with signal {t}", .{sig}),
            .unknown => fatal("compiler terminated unexpectedly", .{}),
        }
    }
};
