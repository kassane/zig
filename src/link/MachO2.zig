const MachO = @This();

base: link.File,
options: link.File.OpenOptions,
mf: MappedFile,
nodes: std.MultiArrayList(Node),

const_prog_node: std.Progress.Node,
synth_prog_node: std.Progress.Node,
input_prog_node: std.Progress.Node,

const Node = union(enum) {
    macho,
};
fn getNode(macho: *MachO, ni: MappedFile.Node.Index) Node {
    return macho.nodes.get(@backingInt(ni));
}

pub fn open(
    arena: std.mem.Allocator,
    comp: *Compilation,
    path: std.Build.Cache.Path,
    options: link.File.OpenOptions,
) !*MachO {
    return create(arena, comp, path, options);
}
pub fn createEmpty(
    arena: std.mem.Allocator,
    comp: *Compilation,
    path: std.Build.Cache.Path,
    options: link.File.OpenOptions,
) !*MachO {
    return create(arena, comp, path, options);
}
fn create(
    arena: std.mem.Allocator,
    comp: *Compilation,
    path: std.Build.Cache.Path,
    options: link.File.OpenOptions,
) !*MachO {
    const io = comp.io;

    const macho = try arena.create(MachO);
    const file = try path.root_dir.handle.createFile(io, path.sub_path, .{
        .read = true,
        .permissions = link.File.determinePermissions(comp.config.output_mode, comp.config.link_mode),
    });

    macho.* = .{
        .base = .{
            .tag = .macho2,

            .comp = comp,
            .emit = path,

            .file = file,
            .gc_sections = false,
            .print_gc_sections = false,
            .build_id = .none,
            .allow_shlib_undefined = false,
            .stack_size = 0,
        },
        .options = options,
        .mf = try .init(file, comp.gpa, io),
        .nodes = .empty,
        .const_prog_node = .none,
        .synth_prog_node = .none,
        .input_prog_node = .none,
    };
    errdefer macho.deinit();

    try macho.initInner();

    return macho;
}
fn initInner(macho: *MachO) !void {
    const comp = macho.base.comp;
    const gpa = comp.gpa;

    try macho.nodes.append(gpa, .macho); // file root node

    @panic("TODO");
}

pub fn deinit(macho: *MachO) void {
    const gpa = macho.base.comp.gpa;
    macho.mf.deinit(gpa);
    macho.nodes.deinit(gpa);
    macho.* = undefined;
}

pub fn startProgress(macho: *MachO, prog_node: std.Progress.Node) void {
    prog_node.increaseEstimatedTotalItems(4);
    macho.const_prog_node = prog_node.start("Constants", 0);
    macho.synth_prog_node = prog_node.start("Synthetics", 0);
    macho.input_prog_node = prog_node.start("Inputs", 0);
    macho.mf.update_prog_node = prog_node.start("Relocations", macho.mf.updates.items.len);
}
pub fn endProgress(macho: *MachO) void {
    macho.const_prog_node.end();
    macho.const_prog_node = .none;
    macho.synth_prog_node.end();
    macho.synth_prog_node = .none;
    macho.input_prog_node.end();
    macho.input_prog_node = .none;
    macho.mf.update_prog_node.end();
    macho.mf.update_prog_node = .none;
}

pub fn navSymbol(macho: *MachO, nav_id: InternPool.Nav.Index) link.Error!link.File.SymbolId {
    _ = macho;
    _ = nav_id;
    @panic("TODO");
}
pub fn uavSymbol(
    macho: *MachO,
    pt: Zcu.PerThread,
    uav_val: InternPool.Index,
    uav_align: InternPool.Alignment,
) link.Error!link.File.SymbolId {
    _ = macho;
    _ = pt;
    _ = uav_val;
    _ = uav_align;
    @panic("TODO");
}
pub fn relocSymAddr(
    macho: *MachO,
    reloc_info: link.File.RelocInfo,
) link.Error!void {
    _ = macho;
    _ = reloc_info;
    @panic("TODO");
}

pub fn loadInput(macho: *MachO, input: link.Input) link.Error!void {
    _ = macho;
    _ = input;
    @panic("TODO");
}
pub fn prelink(macho: *MachO, prog_node: std.Progress.Node) link.Error!void {
    _ = macho;
    _ = prog_node;
    @panic("TODO");
}
pub fn flush(
    macho: *MachO,
    arena: std.mem.Allocator,
    tid: Zcu.PerThread.Id,
    prog_node: std.Progress.Node,
) link.Error!void {
    _ = macho;
    _ = arena;
    _ = tid;
    _ = prog_node;
    @panic("TODO");
}
pub fn updateErrorData(macho: *MachO, pt: Zcu.PerThread) link.Error!void {
    _ = macho;
    _ = pt;
    @panic("TODO");
}
pub fn idle(macho: *MachO, tid: Zcu.PerThread.Id) link.Error!bool {
    _ = macho;
    _ = tid;
    @panic("TODO");
}

pub fn updateFunc(
    macho: *MachO,
    pt: Zcu.PerThread,
    func_index: InternPool.Index,
    mir: *const codegen.AnyMir,
) link.Error!void {
    _ = macho;
    _ = pt;
    _ = func_index;
    _ = mir;
    @panic("TODO");
}
pub fn updateNav(macho: *MachO, pt: Zcu.PerThread, nav_index: InternPool.Nav.Index) link.Error!void {
    _ = macho;
    _ = pt;
    _ = nav_index;
    @panic("TODO");
}
pub fn updateExports(
    macho: *MachO,
    pt: Zcu.PerThread,
    export_indices: []const Zcu.Export.Index,
) link.Error!void {
    _ = macho;
    _ = pt;
    _ = export_indices;
    @panic("TODO");
}

pub fn dump(macho: *MachO, w: *Io.Writer, tid: Zcu.PerThread.Id) !link.File.DumpResult {
    if (macho.options.enable_link_snapshots) {
        try macho.printNode(tid, w, .root, 0);
        return .enabled;
    }
    return .disabled;
}
fn printNode(
    macho: *MachO,
    tid: Zcu.PerThread.Id,
    w: *Io.Writer,
    ni: MappedFile.Node.Index,
    indent: usize,
) Io.Writer.Error!void {
    const node = macho.getNode(ni);
    try w.splatByteAll(' ', indent);
    switch (node) {
        .macho => try w.writeAll("macho"),
    }
    {
        const mf_node = &macho.mf.nodes.items[@backingInt(ni)];
        const off, const size = mf_node.location().resolve(&macho.mf);
        try w.print(" index={d} offset=0x{x} size=0x{x} align=0x{x} {t}{s}{s}{s}{s}{s}{s}\n", .{
            @backingInt(ni),
            off,
            size,
            mf_node.flags.alignment.toByteUnits(),
            mf_node.flags.position,
            if (mf_node.flags.bubbles_moved) " bubbles_moved" else "",
            if (mf_node.flags.resized) " moved" else "",
            if (mf_node.flags.resized) " resized" else "",
            if (mf_node.flags.enable_next_moved) " enable_next_moved" else "",
            if (mf_node.flags.next_moved) " next_moved" else "",
            if (mf_node.flags.has_content) " has_content" else "",
        });
    }
    if (ni.first(&macho.mf).unwrap()) |first_ni| {
        // non-leaf, just print children
        var child_ni = first_ni;
        while (true) {
            try macho.printNode(tid, w, child_ni, indent + 1);
            child_ni = child_ni.next(&macho.mf).unwrap() orelse break;
        }
        return;
    }
    const file_loc = ni.fileLocation(&macho.mf, false);
    var address = file_loc.offset;
    if (file_loc.size == 0) {
        try w.splatByteAll(' ', indent + 1);
        try w.print("{x:0>8}\n", .{address});
        return;
    }
    const line_len = 0x10;
    var line_it = std.mem.window(
        u8,
        macho.mf.memory_map.memory[@intCast(file_loc.offset)..][0..@intCast(file_loc.size)],
        line_len,
        line_len,
    );
    while (line_it.next()) |line_bytes| : (address += line_len) {
        try w.splatByteAll(' ', indent + 1);
        try w.print("{x:0>8}  ", .{address});
        for (line_bytes) |byte| try w.print("{x:0>2} ", .{byte});
        try w.splatByteAll(' ', 3 * (line_len - line_bytes.len) + 1);
        for (line_bytes) |byte| try w.writeByte(if (std.ascii.isPrint(byte)) byte else '.');
        try w.writeByte('\n');
    }
}

const std = @import("std");
const Io = std.Io;

const link = @import("../link.zig");
const codegen = @import("../codegen.zig");
const Compilation = @import("../Compilation.zig");
const InternPool = @import("../InternPool.zig");
const MappedFile = @import("MappedFile.zig");
const Zcu = @import("../Zcu.zig");
