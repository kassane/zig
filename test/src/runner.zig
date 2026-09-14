const std = @import("std");
const Args = struct {
    @"test": ?struct {
        input_dir: std.zig.Server.Message.InputDir,
        dir: std.Io.Dir,
    },
    manifest_file: ?std.Io.File,
    zig_file: ?std.Io.File,
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
pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    var stdin_buffer: [512]u8 = undefined;
    var stdout_buffer: [512]u8 = undefined;
    var stderr_buffer: [512]u8 = undefined;
    var stdin: std.Io.File.Reader = .initStreaming(.stdin(), init.io, &stdin_buffer);
    var stdout: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &stdout_buffer);
    var stderr: std.Io.File.Writer = .initStreaming(.stderr(), init.io, &stderr_buffer);
    var server: std.zig.Server = .{
        .in = &stdin.interface,
        .out = &stdout.interface,
    };

    var args: Args = .{
        .@"test" = null,
        .manifest_file = null,
        .zig_file = null,
        .lib_dir = null,
        .src_dir = null,
        .targets = .empty,
        .target_bytes = .empty,
    };
    defer args.deinit(init.gpa);

    try server.serveStringMessage(.zig_version, @import("builtin").zig_version_string);
    while (true) {
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
                                    try args.addTarget(init.gpa, target);
                                },
                                .zig => unreachable,
                                .lib => unreachable,
                                .src => unreachable,
                                .target => try args.addTarget(init.gpa, string),
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
                                    args.manifest_file = try dir.openFile(init.io, manifest_path, .{});

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
                                    std.debug.assert(args.zig_file == null);
                                    args.zig_file = file;
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
                const target =
                    std.mem.sliceTo(args.target_bytes.items[args.targets.items[test_index]..], 0);
                try server.serveBodylessMessage(.test_started);
                const test_result = runTest(init.io, &stderr.interface, &server, &args, target);
                try stderr.flush();
                try server.serveTestResults(.{
                    .index = test_index,
                    .flags = .{
                        .status = if (test_result) .pass else |err| switch (err) {
                            else => status: {
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
    io: std.Io,
    stderr: *std.Io.Writer,
    server: *std.zig.Server,
    args: *const Args,
    target: []const u8,
) !void {
    const manifest_file = args.manifest_file orelse return error.MissingManifestArg;
    const src_dir = args.src_dir orelse return error.MissingSrcDir;
    var manifest_buffer: [512]u8 = undefined;
    var manifest_fr = manifest_file.reader(io, &manifest_buffer);
    var allow_skip = true;
    var skip_delimiter = false;
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
            enum { skip, obj, exe, lib, write, delete, update, check },
            cmd_str,
        ) orelse return error.UnknownCommand;
        var maybe_arg = line_it.next();
        var contents_file: ?std.Io.File = null;
        defer if (contents_file) |file| file.close(io);
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
                    contents_impl = .{ .dr = .init(&manifest_fr.interface, "#}", &.{}) };
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
                contents_impl = .{ .fr = contents_file.?.reader(io, &.{}) };
                break :contents_r &contents_impl.fr.interface;
            },
        };
        switch (cmd) {
            else => {
                try stderr.print("{t} {s} {{\n", .{ cmd, maybe_arg orelse "" });
                _ = try contents_r.streamRemaining(stderr);
                try stderr.writeAll("\n}\n");
            },
            .skip => if (!allow_skip)
                return error.NonInitialSkipCommand // #skip must appear first
            else if (std.mem.eql(u8, target, maybe_arg orelse return error.MissingArg))
                return error.SkipZigTest,
            .write => {
                const file = try src_dir.createFile(io, maybe_arg orelse return error.MissingArg, .{});
                defer file.close(io);
                var fw = file.writer(io, &.{});
                _ = try contents_r.streamRemaining(&fw.interface);
                try file.setTimestamps(io, .{ .modify_timestamp = .{ .new = update_mtime } });
            },
            .delete => try src_dir.deleteFile(io, maybe_arg orelse return error.MissingArg),
            .update => {
                var name_buffer: [std.Progress.Node.max_name_len]u8 = undefined;
                const name = switch (try contents_r.readSliceShort(&name_buffer)) {
                    0 => switch (update_num) {
                        0 => "initial update",
                        else => |num| std.mem.print(&name_buffer, "update {d}", .{num}) catch
                            &name_buffer,
                    },
                    else => |name_len| name_buffer[0..name_len],
                };
                _ = try contents_r.discardRemaining();
                try stderr.print("update({q})\n", .{name});
                update_mtime = update_mtime.addDuration(.fromSeconds(2));
                update_num += 1;
            },
        }
        std.debug.assert(try contents_r.discardRemaining() == 0);
        if (cmd != .skip) allow_skip = false;
    } else |err| switch (err) {
        else => |e| return e,
        error.EndOfStream => if (skip_delimiter) return error.MissingDelimiter,
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
