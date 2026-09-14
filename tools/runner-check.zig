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
    std.debug.assert(arg_it.skip());
    while (arg_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--zig")) {
            zig_path_arg = arg_it.next() orelse fail("missing arg after '{s}'", .{arg});
        } else if (std.mem.cutPrefix(u8, arg, "--zig=")) |zig_path| {
            zig_path_arg = zig_path;
        } else if (std.mem.eql(u8, arg, "--lib")) {
            lib_path_arg = arg_it.next() orelse fail("missing arg after '{s}'", .{arg});
        } else if (std.mem.cutPrefix(u8, arg, "--lib=")) |lib_path| {
            lib_path_arg = lib_path;
        } else if (std.mem.eql(u8, arg, "--target")) {
            try target_args.append(
                init.gpa,
                try arena.dupe(u8, arg_it.next() orelse fail("missing arg after '{s}'", .{arg})),
            );
        } else if (std.mem.cutPrefix(u8, arg, "--target=")) |target| {
            try target_args.append(init.gpa, try arena.dupe(u8, target));
        } else if (std.mem.eql(u8, arg, "--keep-src")) {
            keep_src = true;
        } else {
            if (test_path_arg) |_| fail("unknown arg '{s}'", .{arg});
            test_path_arg = arg;
        }
    }

    const test_path = test_path_arg orelse fail("missing 'path/to/test'", .{});
    const zig_path = zig_path_arg orelse fail("missing '--zig=path/to/zig'", .{});
    const lib_path = lib_path_arg orelse fail("missing '--lib=path/to/lib'", .{});

    const test_file = try std.Io.Dir.cwd().openFile(init.io, test_path, .{
        .allow_directory = true,
    });
    const zig_file = try std.Io.Dir.cwd().openFile(init.io, zig_path, .{});
    defer zig_file.close(init.io);
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
            std.log.warn("failed to delete tree '{s}': {t}", .{ src_dir_path, err });
        };
    }

    var child = try std.process.spawn(init.io, .{
        .argv = &.{
            zig_path,
            "run",
            try std.fs.path.resolveAlloc(arena, &.{ lib_path, "..", "test", "src", "runner.zig" }),
        },
        .stdin = .pipe,
        .stdout = .pipe,
        .inherit_dirs = &.{ lib_dir, src_dir },
        .inherit_files = &.{ zig_file, test_file },
    });

    var stdout_buffer: [512]u8 = undefined;
    var stdout_reader = child.stdout.?.readerStreaming(init.io, &stdout_buffer);
    var stdin_buffer: [512]u8 = undefined;
    var stdin_writer = child.stdin.?.writerStreaming(init.io, &stdin_buffer);
    var client: std.zig.Client = .{
        .in = &stdout_reader.interface,
        .out = &stdin_writer.interface,
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
        try args.appendSlice(init.gpa, @ptrCast(&zig_file.handle));

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

            fn next(m: *@This()) ?u32 {
                if (m.len - m.index == 0) return null;
                defer m.index += 1;
                return m.index;
            }
        } = .{ .index = 0, .len = 0 };
        try client.serveBodylessMessage(.query_test_metadata);
        while (true) {
            const hdr = try client.receiveMessage();
            switch (hdr.tag) {
                else => try client.in.discardAll(hdr.bytes_len),
                .zig_version => {
                    const body = try arena.alloc(u8, hdr.bytes_len);
                    try client.in.readSliceAll(body);
                    if (!std.mem.eql(u8, @import("builtin").zig_version_string, body)) return fail(
                        "zig version mismatch build runner vs compiler: '{s}' vs '{s}'",
                        .{ @import("builtin").zig_version_string, body },
                    );
                },
                .test_metadata => {
                    const tm_hdr =
                        try client.in.takeStruct(std.zig.Server.Message.TestMetadata, .little);
                    try client.in.discardAll(
                        hdr.bytes_len - @sizeOf(std.zig.Server.Message.TestMetadata),
                    );
                    metadata = .{ .index = 0, .len = tm_hdr.tests_len };
                    try client.serveRunTest(metadata.next() orelse break);
                },
                .test_results => {
                    try client.in.discardAll(hdr.bytes_len);
                    try client.serveRunTest(metadata.next() orelse break);
                },
            }
        }
        try client.serveBodylessMessage(.exit);
    }
    _ = try child.wait(init.io);
}
fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(1);
}
