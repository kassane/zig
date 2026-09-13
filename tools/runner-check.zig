const std = @import("std");
pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    var test_path_arg: ?[]const u8 = null;
    var zig_path_arg: ?[]const u8 = null;
    var lib_path_arg: ?[]const u8 = null;
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
        const Arg = std.zig.Client.Message.Arg;
        var args: std.ArrayList(u8) = .initBuffer(try arena.alloc(u8, 0 +
            @sizeOf(Arg) + @sizeOf(std.Io.File.Handle) +
            @sizeOf(Arg) + "--zig=\x00".len +
            @sizeOf(Arg) + @sizeOf(std.Io.File.Handle) +
            @sizeOf(Arg) + "--lib=\x00".len +
            @sizeOf(Arg) + @sizeOf(std.Io.Dir.Handle) +
            @sizeOf(Arg) + "--src=\x00".len +
            @sizeOf(Arg) + @sizeOf(std.Io.Dir.Handle)));

        args.appendAssumeCapacity(@backingInt(@as(Arg, switch ((try test_file.stat(init.io)).kind) {
            else => unreachable,
            .file => .input_file,
            .directory => .input_dir,
        })));
        args.appendSliceAssumeCapacity(@ptrCast(&test_file.handle));

        args.appendAssumeCapacity(@backingInt(Arg.prefix));
        args.appendSliceAssumeCapacity("--zig=");
        args.appendAssumeCapacity(0);

        args.appendAssumeCapacity(@backingInt(Arg.input_file));
        args.appendSliceAssumeCapacity(@ptrCast(&zig_file.handle));

        args.appendAssumeCapacity(@backingInt(Arg.prefix));
        args.appendSliceAssumeCapacity("--lib=");
        args.appendAssumeCapacity(0);

        args.appendAssumeCapacity(@backingInt(Arg.input_dir));
        args.appendSliceAssumeCapacity(@ptrCast(&lib_dir.handle));

        args.appendAssumeCapacity(@backingInt(Arg.prefix));
        args.appendSliceAssumeCapacity("--src=");
        args.appendAssumeCapacity(0);

        args.appendAssumeCapacity(@backingInt(Arg.output_dir));
        args.appendSliceAssumeCapacity(@ptrCast(&src_dir.handle));

        std.debug.assert(args.unusedCapacitySlice().len == 0);

        try client.serveMessageHeader(.{
            .tag = .args,
            .bytes_len = @intCast(args.items.len),
        });
        try client.out.writeAll(args.items);

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
                    try client.in.discardAll(hdr.bytes_len);
                    try client.serveRunTest(0);
                },
                .test_results => {
                    try client.in.discardAll(hdr.bytes_len);
                    break;
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
