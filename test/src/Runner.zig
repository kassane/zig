const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    var test_path_arg: ?[]const u8 = null;
    var zig_path_arg: ?[]const u8 = null;
    var lib_path_arg: ?[]const u8 = null;
    var target_args: std.ArrayList([]const u8) = .empty;
    defer target_args.deinit(init.gpa);
    var keep_src = false;
    var enable_qemu = false;
    var enable_wine = false;
    var enable_wasmtime = false;
    var enable_darling = false;

    var arg_it = try init.minimal.args.iterateAllocator(arena);
    const self = arg_it.next().?;
    while (arg_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--listen=-")) {
            var stdin_buffer: [512]u8 = undefined;
            var stdin: std.Io.File.Reader = .initStreaming(.stdin(), init.io, &stdin_buffer);
            var stdout_buffer: [512]u8 = undefined;
            var stdout: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &stdout_buffer);
            var runner: Runner = .{
                .gpa = init.gpa,
                .arena = init.arena,
                .io = init.io,
                .prog_node = std.Progress.start(init.io, .{}),
                .args = .{
                    .@"test" = null,
                    .manifest_file = null,
                    .zig_exe = null,
                    .lib_dir = null,
                    .src_dir = null,
                    .targets = .empty,
                    .target_bytes = .empty,
                    .enable_qemu = false,
                    .enable_wine = false,
                    .enable_wasmtime = false,
                    .enable_darling = false,
                },
                .host = try std.zig.system.resolveTargetQuery(init.io, .{}),
                .server = .{
                    .in = &stdin.interface,
                    .out = &stdout.interface,
                },
            };
            defer runner.deinit();
            return runner.protocol();
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
        } else if (std.mem.eql(u8, arg, "-fqemu")) {
            enable_qemu = true;
        } else if (std.mem.eql(u8, arg, "-fwine")) {
            enable_wine = true;
        } else if (std.mem.eql(u8, arg, "-fwasmtime")) {
            enable_wasmtime = true;
        } else if (std.mem.eql(u8, arg, "-fdarling")) {
            enable_darling = true;
        } else {
            if (test_path_arg) |_| fatal("unknown arg '{s}'", .{arg});
            test_path_arg = arg;
        }
    }

    const test_path = test_path_arg orelse fatal("missing 'path/to/test'", .{});
    const zig_path = zig_path_arg orelse fatal("missing '--zig=path/to/zig'", .{});
    const lib_path = lib_path_arg orelse fatal("missing '--lib=path/to/lib'", .{});

    const cwd: std.Io.Dir = .cwd();
    const test_file = try cwd.openFile(init.io, test_path, .{
        .allow_directory = true,
    });
    const zig_exe = try cwd.openFile(init.io, zig_path, .{});
    defer zig_exe.close(init.io);
    const lib_dir = try cwd.openDir(init.io, lib_path, .{});
    defer lib_dir.close(init.io);

    const src_dir_path = "src_" ++ std.fmt.hex(rand_int: {
        var rand_int: u64 = undefined;
        init.io.random(@ptrCast(&rand_int));
        break :rand_int rand_int;
    });
    var src_dir = try cwd.createDirPathOpen(init.io, src_dir_path, .{});
    defer {
        src_dir.close(init.io);
        if (!keep_src) cwd.deleteTree(init.io, src_dir_path) catch |err| {
            std.log.warn("failed to delete tree '{s}': {t}", .{ src_dir_path, err });
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

        if (enable_qemu) {
            try args.append(init.gpa, @backingInt(Arg.string));
            try args.appendSlice(init.gpa, "-fqemu");
            try args.append(init.gpa, 0);
        }
        if (enable_wine) {
            try args.append(init.gpa, @backingInt(Arg.string));
            try args.appendSlice(init.gpa, "-fwine");
            try args.append(init.gpa, 0);
        }
        if (enable_wasmtime) {
            try args.append(init.gpa, @backingInt(Arg.string));
            try args.appendSlice(init.gpa, "-fwasmtime");
            try args.append(init.gpa, 0);
        }
        if (enable_darling) {
            try args.append(init.gpa, @backingInt(Arg.string));
            try args.appendSlice(init.gpa, "-fdarling");
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

const Runner = @This();

gpa: std.mem.Allocator,
arena: *std.heap.ArenaAllocator,
io: std.Io,
prog_node: std.Progress.Node,
args: Args,
host: std.Target,
server: std.zig.Server,

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
    enable_qemu: bool,
    enable_wine: bool,
    enable_wasmtime: bool,
    enable_darling: bool,

    fn deinit(args: *Args, gpa: std.mem.Allocator) void {
        args.targets.deinit(gpa);
        args.target_bytes.deinit(gpa);
        args.* = undefined;
    }

    fn addTarget(args: *Args, gpa: std.mem.Allocator, target: []const u8) std.mem.Allocator.Error!void {
        try args.target_bytes.ensureUnusedCapacity(gpa, target.len + 1);
        try args.targets.append(gpa, @intCast(args.target_bytes.items.len));
        args.target_bytes.appendSliceAssumeCapacity(target);
        args.target_bytes.appendAssumeCapacity(0);
    }
};

fn deinit(runner: *Runner) void {
    runner.prog_node.end();
    runner.args.deinit(runner.gpa);
    runner.* = undefined;
}

pub fn protocol(runner: *Runner) !void {
    try runner.server.serveStringMessage(.zig_version, @import("builtin").zig_version_string);
    while (true) {
        _ = runner.arena.reset(.retain_capacity);
        const arena = runner.arena.allocator();
        const hdr = try runner.server.receiveMessage();
        switch (hdr.tag) {
            else => {
                std.log.warn("unsupported message: {t}\n", .{hdr.tag});
                std.process.exit(1);
            },
            .exit => std.process.exit(0),
            .args => {
                const args_body = try arena.alloc(u8, hdr.bytes_len);
                try runner.server.in.readSliceAll(args_body);
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
                                    try runner.args.addTarget(runner.gpa, target);
                                } else if (std.mem.eql(u8, string, "-fqemu")) {
                                    runner.args.enable_qemu = true;
                                } else if (std.mem.eql(u8, string, "-fwine")) {
                                    runner.args.enable_wine = true;
                                } else if (std.mem.eql(u8, string, "-fwasmtime")) {
                                    runner.args.enable_wasmtime = true;
                                } else if (std.mem.eql(u8, string, "-fdarling")) {
                                    runner.args.enable_darling = true;
                                },
                                .zig => unreachable,
                                .lib => unreachable,
                                .src => unreachable,
                                .target => try runner.args.addTarget(runner.gpa, string),
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
                                    std.debug.assert(runner.args.@"test" == null);
                                    runner.args.@"test" = .{ .input_dir = input_dir, .dir = dir };
                                    std.debug.assert(runner.args.manifest_file == null);
                                    const manifest_path = "manifest";
                                    runner.args.manifest_file =
                                        try dir.openFile(runner.io, manifest_path, .{});

                                    try runner.server.serveMessageHeader(.{
                                        .tag = .discovered_inputs,
                                        .bytes_len = @sizeOf(std.zig.Server.Message.InputDir) +
                                            manifest_path.len + 1,
                                    });
                                    try runner.server.out.writeInt(u32, @backingInt(
                                        input_dir,
                                    ), .little);
                                    try runner.server.out.writeAll(manifest_path);
                                    try runner.server.out.writeByte(0);
                                    try runner.server.out.flush();
                                },
                                .zig => unreachable,
                                .lib => {
                                    std.debug.assert(runner.args.lib_dir == null);
                                    runner.args.lib_dir = dir;
                                },
                                .src => {
                                    std.debug.assert(runner.args.src_dir == null);
                                    runner.args.src_dir = dir;
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
                                    std.debug.assert(runner.args.manifest_file == null);
                                    runner.args.manifest_file = file;
                                },
                                .zig => {
                                    std.debug.assert(runner.args.zig_exe == null);
                                    runner.args.zig_exe = file;
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
                const expected_panic_msgs = try arena.alloc(u32, runner.args.targets.items.len);
                @memset(expected_panic_msgs, 0);
                try runner.server.serveTestMetadata(.{
                    .names = runner.args.targets.items,
                    .expected_panic_msgs = expected_panic_msgs,
                    .string_bytes = runner.args.target_bytes.items,
                });
            },
            .run_test => {
                const test_index = try runner.server.receiveBody_u32();
                try runner.server.serveBodylessMessage(.test_started);
                try runner.server.serveTestResults(.{
                    .index = test_index,
                    .flags = .{
                        .status = if (runner.testOne(test_index)) .pass else |err| switch (err) {
                            else => status: {
                                std.log.err("{t}\n", .{err});
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

fn testOne(runner: *const Runner, test_index: u32) !void {
    const target_query =
        std.mem.sliceTo(runner.args.target_bytes.items[runner.args.targets.items[test_index]..], 0);
    const src_dir = try (runner.args.src_dir orelse return error.MissingSrcDir).createDirPathOpen(
        runner.io,
        target_query,
        .{},
    );
    const manifest_file = runner.args.manifest_file orelse return error.MissingManifestArg;
    var manifest_buffer: [512]u8 = undefined;
    var manifest_fr = manifest_file.reader(runner.io, &manifest_buffer);
    var allow_skip = true;
    var skip_delimiter = false;
    var compiler: ?Compiler = null;
    var update_prog_node: std.Progress.Node = .none;
    defer update_prog_node.end();
    var update_mtime = std.Io.Clock.real.now(runner.io);
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
            enum { todo, skip, exe, lib, obj, write, delete, update, check },
            cmd_str,
        ) orelse return error.UnknownCommand;
        var maybe_arg = line_it.next();
        var contents_file: ?std.Io.File = null;
        defer if (contents_file) |file| file.close(runner.io);
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

                const args_test = runner.args.@"test" orelse return error.ContentsFileInFileTest;
                try runner.server.serveMessageHeader(.{
                    .tag = .discovered_inputs,
                    .bytes_len = @intCast(@sizeOf(std.zig.Server.Message.InputDir) +
                        contents_path.len + 1),
                });
                try runner.server.out.writeInt(u32, @backingInt(args_test.input_dir), .little);
                try runner.server.out.writeAll(contents_path);
                try runner.server.out.writeByte(0);
                try runner.server.out.flush();

                contents_file = try args_test.dir.openFile(runner.io, contents_path, .{});
                contents_impl = .{ .fr = contents_file.?.reader(runner.io, &contents_buffer) };
                break :contents_r &contents_impl.fr.interface;
            },
        };

        var name_buffer: [std.Progress.Node.max_name_len]u8 = undefined;
        const cmd_prog_node = runner.prog_node.start(std.mem.print(&name_buffer, "#{t} {s}", .{
            cmd, maybe_arg orelse "",
        }) catch &name_buffer, 0);
        defer cmd_prog_node.end();

        cmd: switch (cmd) {
            .todo => _ = try contents_r.discardRemaining(),
            .skip => if (!allow_skip)
                return error.NonInitialSkipCommand // #skip must appear first
            else if (std.mem.eql(u8, target_query, maybe_arg orelse return error.MissingArg))
                return error.SkipZigTest,
            .exe, .lib, .obj => try runner.spawnCompiler(&compiler, src_dir, switch (cmd) {
                else => unreachable,
                .exe => .Exe,
                .lib => .Lib,
                .obj => .Obj,
            }, contents_r, target: {
                const backend_split = std.mem.findScalarLast(u8, target_query, '-') orelse
                    return error.TargetMissingBackend;
                const mode_split =
                    std.mem.findScalarLast(u8, target_query[0..backend_split], '-') orelse
                    return error.TargetMissingMode;
                const triple = target_query[0..mode_split];
                const backend = std.meta.stringToEnum(
                    Compiler.Target.Backend,
                    target_query[backend_split + 1 ..],
                ) orelse return error.TargetMissingBackend;
                const mode = std.meta.stringToEnum(
                    Compiler.Target.Mode,
                    target_query[mode_split + 1 .. backend_split],
                ) orelse return error.TargetMissingMode;
                break :target .{
                    .triple = triple,
                    .resolved = try std.zig.system.resolveTargetQuery(
                        runner.io,
                        try std.Build.parseTargetQuery(.{
                            .arch_os_abi = triple,
                            .object_format = switch (backend) {
                                .sema, .selfhosted, .llvm => null,
                                .cbe => "c",
                            },
                        }),
                    ),
                    .mode = mode,
                    .backend = backend,
                };
            }),
            .write => {
                const file = try src_dir.createFile(
                    runner.io,
                    maybe_arg orelse return error.MissingFileArg,
                    .{},
                );
                defer file.close(runner.io);
                var fw = file.writer(runner.io, &.{});
                _ = try contents_r.streamRemaining(&fw.interface);
                try file.setTimestamps(runner.io, .{ .modify_timestamp = .{ .new = update_mtime } });
            },
            .delete => try src_dir.deleteFile(
                runner.io,
                maybe_arg orelse return error.MissingFileArg,
            ),
            .update => {
                const comp = &(compiler orelse return error.MissingCompiler);
                update_prog_node.end();
                update_prog_node = runner.prog_node.start(
                    switch (try contents_r.readSliceShort(&name_buffer)) {
                        0 => switch (update_num) {
                            0 => "initial update",
                            else => |num| std.mem.print(&name_buffer, "update {d}", .{num}) catch
                                &name_buffer,
                        },
                        else => |name_len| name_buffer[0..name_len],
                    },
                    0,
                );
                _ = try contents_r.discardRemaining();
                if (comp.state != .idle) return error.MissingCheck;
                try comp.client.serveBodylessMessage(.update);
                comp.state = .update;
                update_mtime = update_mtime.addDuration(.fromSeconds(2));
                update_num += 1;
            },
            .check => {
                const check = std.meta.stringToEnum(
                    Compiler.Check,
                    maybe_arg orelse return error.MissingCheckArg,
                ) orelse return error.UnknownCheck;
                const expected = try contents_r.allocRemaining(runner.gpa, .unlimited);
                defer runner.gpa.free(expected);

                const comp = &(compiler orelse return error.MissingCompiler);
                if (comp.state != .update) return error.MissingUpdate;
                const stderr = comp.mr.reader(1);
                while (try comp.receiveMessage()) |message| switch (message.tag) {
                    .config => {
                        var body_r: std.Io.Reader = .fixed(message.body);
                        comp.config = body_r.takeStruct(std.zig.Server.Message.Config, .little) catch
                            unreachable;
                    },
                    .emit_digest => {
                        var body_r: std.Io.Reader = .fixed(message.body);
                        _ = body_r.takeStruct(std.zig.Server.Message.EmitDigest, .little) catch
                            unreachable;
                        const digest = body_r.takeArray(std.Build.Cache.bin_digest_len) catch
                            unreachable;
                        try comp.checkSuccess(check, expected, src_dir, digest);
                    },
                    .error_bundle => {
                        const error_bundle =
                            try std.zig.Server.allocErrorBundle(runner.arena.allocator(), message.body);
                        switch (check) {
                            .errors => {
                                var error_aw: std.Io.Writer.Allocating = .init(runner.gpa);
                                defer error_aw.deinit();
                                try error_bundle.renderToWriter(.{
                                    .include_reference_trace = false,
                                    .include_source_line = false,
                                    .include_log_text = true,
                                }, &error_aw.writer);
                                try std.testing.expectEqualStrings(expected, error_aw.written());
                            },
                            .stdout, .exit, .lldb => if (error_bundle.errorMessageCount() > 0) {
                                try error_bundle.renderToStderr(runner.io, .{}, .auto);
                                fatal("unexpected compile errors", .{});
                            },
                        }
                        comp.state = .idle;
                        break :cmd;
                    },
                    else => {}, // Ignore other messages,
                };

                const buffered_stderr = stderr.buffered();
                if (buffered_stderr.len > 0) {
                    if (comp.allow_compiler_stderr) {
                        std.log.info("stderr:\n{s}", .{buffered_stderr});
                    } else {
                        fatal("unexpected stderr:\n{s}", .{buffered_stderr});
                    }
                }

                try comp.exit();
                fatal("compiler failed to send terminating error_bundle", .{});
            },
        }
        std.debug.assert(try contents_r.discardRemaining() == 0);
        switch (cmd) {
            .todo, .skip => {},
            else => allow_skip = false,
        }
    } else |err| switch (err) {
        else => |e| return e,
        error.EndOfStream => if (skip_delimiter) return error.MissingDelimiter,
    }
    if (compiler) |*comp| {
        if (comp.state != .idle) return error.MissingCheck;
        try comp.exit();
    }
}

fn spawnCompiler(
    runner: *const Runner,
    compiler: *?Compiler,
    src_dir: std.Io.Dir,
    output_mode: std.lang.OutputMode,
    args_r: *std.Io.Reader,
    target: Compiler.Target,
) !void {
    const gpa = runner.gpa;
    const arena = runner.arena.allocator();
    if (compiler.*) |*comp| {
        try comp.exit();
        compiler.* = null;
    }

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{
        "zig",
        switch (output_mode) {
            .Obj => "build-obj",
            .Exe => "build-exe",
            .Lib => "build-lib",
        },
        "-target",
        target.triple,
        "--cache-dir",
        ".zig-cache",
    });
    switch (target.mode) {
        .whole => {},
        .incremental => try argv.append(gpa, "-fincremental"),
    }
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (target.backend) |b| switch (b) {
        .sema => try argv.append(gpa, "-fno-emit-bin"),
        .selfhosted => try argv.append(gpa, "-fno-llvm"),
        .llvm => try argv.append(gpa, "-fllvm"),
        .cbe => try argv.append(gpa, "-ofmt=c"),
    } else try argv.appendSlice(gpa, &.{ "-I", path_buffer[0..try std.Io.Dir.readLinkAbsolute(
        runner.io,
        try arena.print("/proc/self/fd/{d}", .{
            (runner.args.lib_dir orelse return error.MissingLibDir).handle,
        }),
        &path_buffer,
    )] });
    var need: usize = 1;
    var root_name: ?[]const u8 = null;
    while (true) {
        const done = if (args_r.fill(need)) false else |err| switch (err) {
            else => |e| return e,
            error.EndOfStream => true,
        };
        const buffered = args_r.buffered();
        const start = std.mem.findNone(u8, buffered, "\n ") orelse buffered.len;
        const end = std.mem.findAnyPos(u8, buffered, start, "\n ") orelse buffered.len;
        if (end - start > 0) {
            const arg = try arena.dupe(u8, buffered[start..end]);
            if (std.mem.cutPrefix(u8, arg, "-M")) |module| {
                var module_name_it = std.mem.splitScalar(u8, module, '=');
                const module_name = module_name_it.next().?;
                root_name = root_name orelse module_name;
            }
            try argv.append(gpa, arg);
            args_r.toss(end);
            need = 1;
        } else {
            args_r.toss(start);
            need = buffered.len - start + 1;
        }
        if (done) break;
    }
    try argv.append(gpa, "--listen=-");

    const out_name = try std.zig.EmitArtifact.bin.cacheName(arena, .{
        .root_name = root_name orelse "root",
        .cpu_arch = target.resolved.cpu.arch,
        .os_tag = target.resolved.os.tag,
        .ofmt = target.resolved.ofmt,
        .abi = target.resolved.abi,
        .output_mode = output_mode,
    });

    var name_buffer: [std.Progress.Node.max_name_len]u8 = undefined;
    const comp_prog_node = runner.prog_node.start(std.mem.print(&name_buffer, "compile {s}", .{
        out_name,
    }) catch &name_buffer, 0);
    errdefer comp_prog_node.end();

    const child = try std.process.spawn(runner.io, .{
        .exe = .{ .file = runner.args.zig_exe orelse return error.MissingZigExe },
        .argv = argv.items,
        .cwd = .{ .dir = src_dir },
        .progress_node = comp_prog_node,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    compiler.* = .{
        .runner = runner,
        .prog_node = comp_prog_node,
        .allow_compiler_stderr = true,
        .output_mode = output_mode,
        .state = .idle,
        .child = child,
        .fw = undefined,
        .mr_buffer = undefined,
        .mr = undefined,
        .client = undefined,
        .target = target,
        .out_name = out_name,
        .config = null,
    };
    const comp = &compiler.*.?;
    comp.fw = child.stdin.?.writerStreaming(runner.io, &.{});
    comp.mr.init(gpa, runner.io, comp.mr_buffer.toStreams(), &.{
        child.stdout.?, child.stderr.?,
    });
    comp.client = .{ .in = comp.mr.reader(0), .out = &comp.fw.interface };
}
const Compiler = struct {
    runner: *const Runner,
    prog_node: std.Progress.Node,
    allow_compiler_stderr: bool,
    output_mode: std.lang.OutputMode,
    state: enum { idle, update },
    child: std.process.Child,
    fw: std.Io.File.Writer,
    mr_buffer: std.Io.File.MultiReader.Buffer(2),
    mr: std.Io.File.MultiReader,
    client: std.zig.Client,
    target: Target,
    out_name: []const u8,
    config: ?std.zig.Server.Message.Config,

    const Target = struct {
        triple: []const u8,
        resolved: std.Target,
        mode: Mode,
        backend: ?Backend,

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

    fn receiveMessage(comp: *Compiler) !?struct {
        tag: std.zig.Server.Message.Tag,
        body: []const u8,
    } {
        const header = comp.client.receiveMessageWithMultiReader(
            &comp.mr,
            .none,
        ) catch |err| switch (err) {
            error.Timeout => unreachable,
            error.EndOfStream => return null,
            else => |e| return e,
        };
        const body = comp.client.in.take(header.bytes_len) catch unreachable;
        const stderr = comp.mr.reader(1);
        if (stderr.bufferedLen() > 0) {
            if (comp.allow_compiler_stderr) {
                std.log.info("{t} stderr:\n{s}", .{ header.tag, stderr.buffered() });
            } else {
                fatal("{t} unexpected stderr:\n{s}", .{ header.tag, stderr.buffered() });
            }
            stderr.tossBuffered();
        }
        return .{ .tag = header.tag, .body = body };
    }

    const Check = enum { errors, stdout, exit, lldb };
    fn checkSuccess(
        comp: *Compiler,
        check: Check,
        expected: []const u8,
        src_dir: std.Io.Dir,
        digest: *const std.Build.Cache.BinDigest,
    ) !void {
        const runner = comp.runner;
        const gpa = runner.gpa;
        const arena = runner.arena.allocator();
        const io = runner.io;
        const config = &comp.config.?;
        const out_dir = ".zig-cache" ++ std.Io.Dir.path.sep_str ++
            "o" ++ std.Io.Dir.path.sep_str ++ std.Build.Cache.binToHex(digest.*);
        const out_path = try std.Io.Dir.path.join(arena, &.{ out_dir, comp.out_name });
        const bin_path = switch (comp.target.backend.?) {
            .sema => return,
            .selfhosted, .llvm => out_path,
            .cbe => try comp.compileC(src_dir, out_path),
        };
        switch (check) {
            .errors => return,
            .stdout, .exit, .lldb => {},
        }

        const executor = executor: switch (std.zig.system.getExternalExecutor(
            io,
            &comp.target.resolved,
            .{
                .host_cpu_arch = runner.host.cpu.arch,
                .host_os_tag = runner.host.os.tag,
                .link_mode = config.flags.link_mode,
                .link_libc = config.flags.link_libc,
            },
        )) {
            .bad_dl, .bad_os_or_cpu => {
                // This binary cannot be executed on this host.
                std.log.warn("skipping execution because host '{s}' cannot execute binaries for " ++
                    "foreign target '{s}'", .{
                    try runner.host.zigTriple(arena), comp.target.triple,
                });
                return;
            },
            .native, .rosetta => null,
            .qemu => |executor| if (runner.args.enable_qemu)
                executor
            else
                continue :executor .bad_os_or_cpu,
            .wine => |executor| if (runner.args.enable_wine)
                executor
            else
                continue :executor .bad_os_or_cpu,
            .wasmtime => |executor| if (runner.args.enable_wasmtime)
                executor
            else
                continue :executor .bad_os_or_cpu,
            .darling => |executor| if (runner.args.enable_darling)
                executor
            else
                continue :executor .bad_os_or_cpu,
        };

        var name_buffer: [std.Progress.Node.max_name_len]u8 = undefined;
        const run_prog_node = runner.prog_node.start(std.mem.print(&name_buffer, "run {s}", .{
            comp.out_name,
        }) catch &name_buffer, 0);
        defer run_prog_node.end();

        const bin_file = try src_dir.openFile(io, bin_path, .{});
        defer bin_file.close(io);
        switch (check) {
            .errors => unreachable,
            .stdout, .exit => {
                const result = std.process.run(gpa, io, .{
                    .exe = if (executor) |_| .search else .{ .file = bin_file },
                    .argv = if (executor) |e| &.{ e, bin_path } else &.{bin_path},
                    .cwd = .{ .dir = src_dir },
                    .progress_node = run_prog_node,
                }) catch |err| if (executor) |_| {
                    // Chances are the foreign executor isn't available. Skip this evaluation.
                    std.log.warn("skipping execution of '{s}' via executor for foreign target '{s}': {t}", .{
                        bin_path,
                        comp.target.triple,
                        err,
                    });
                    return;
                } else fatal("failed to run the generated executable '{s}': {t}", .{ bin_path, err });
                defer {
                    gpa.free(result.stdout);
                    gpa.free(result.stderr);
                }
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
                if (executor == null and result.stderr.len > 0) {
                    std.log.err("generated executable '{s}' had unexpected stderr:\n{s}", .{
                        bin_path, result.stderr,
                    });
                }
            },
            .lldb => {},
        }
    }

    fn compileC(parent_comp: *Compiler, src_dir: std.Io.Dir, c_path: []const u8) ![]const u8 {
        const runner = parent_comp.runner;
        const arena = runner.arena.allocator();
        var compiler: ?Compiler = null;
        var args_r: std.Io.Reader = .fixed(c_path);
        try parent_comp.runner.spawnCompiler(&compiler, src_dir, parent_comp.output_mode, &args_r, .{
            .triple = parent_comp.target.triple,
            .resolved = resolved: {
                var resolved = parent_comp.target.resolved;
                resolved.ofmt = .default(resolved.os.tag, resolved.cpu.arch);
                break :resolved resolved;
            },
            .mode = .whole,
            .backend = null,
        });
        const comp = &compiler.?;
        try comp.client.serveBodylessMessage(.update);
        comp.state = .update;
        var out_path: ?[]const u8 = null;
        while (try comp.receiveMessage()) |message| switch (message.tag) {
            .config => {
                var body_r: std.Io.Reader = .fixed(message.body);
                comp.config =
                    body_r.takeStruct(std.zig.Server.Message.Config, .little) catch unreachable;
            },
            .emit_digest => {
                var body_r: std.Io.Reader = .fixed(message.body);
                _ = body_r.takeStruct(std.zig.Server.Message.EmitDigest, .little) catch unreachable;
                const digest = body_r.takeArray(std.Build.Cache.bin_digest_len) catch unreachable;

                const out_dir = ".zig-cache" ++ std.Io.Dir.path.sep_str ++
                    "o" ++ std.Io.Dir.path.sep_str ++ std.Build.Cache.binToHex(digest.*);
                out_path = try std.Io.Dir.path.join(arena, &.{ out_dir, comp.out_name });
            },
            .error_bundle => {
                const error_bundle = try std.zig.Server.allocErrorBundle(arena, message.body);

                if (error_bundle.errorMessageCount() > 0) {
                    try error_bundle.renderToStderr(runner.io, .{}, .auto);
                    fatal("unexpected compile errors", .{});
                }
                comp.state = .idle;
                break;
            },
            else => {}, // Ignore other messages,
        };
        try comp.exit();
        return out_path.?;
    }

    fn exit(comp: *Compiler) !void {
        const io = comp.runner.io;
        comp.client.serveBodylessMessage(.exit) catch |err| switch (err) {
            error.WriteFailed => switch (comp.fw.err.?) {
                error.BrokenPipe => {},
                else => |e| fatal("failed to send exit: {t}", .{e}),
            },
        };
        comp.child.stdin.?.close(io);
        comp.child.stdin = null;
        while (try comp.receiveMessage()) |_| {}
        if (comp.client.in.bufferedLen() > 0) return error.EndOfStream;
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
