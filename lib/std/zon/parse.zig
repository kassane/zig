//! The simplest way to parse ZON at runtime is to use `fromSlice`/`fromSliceAlloc`.
//!
//! Note that if you need to parse ZON at compile time, you may use `@import`.
//!
//! Parsing from individual Zoir nodes is also available:
//! * `fromZoir`/`fromZoirAlloc`
//!
//! To update an existing values, see the `updateFrom*` variants.
//!
//! For lower level control over parsing, see `std.zig.Zoir`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Zoir = std.zig.Zoir;
const ZonGen = std.zig.ZonGen;
const TokenIndex = std.zig.Ast.TokenIndex;
const Base = std.zig.number_literal.Base;
const StrLitErr = std.zig.string_literal.Error;
const NumberLiteralError = std.zig.number_literal.Error;
const assert = std.debug.assert;
const ArrayList = std.ArrayList;

/// Rename when adding or removing support for a type.
const valid_types = {};

pub const Error = union(enum) {
    zoir: Zoir.CompileError,
    type_check: Error.TypeCheckFailure,

    pub const Note = union(enum) {
        zoir: Zoir.CompileError.Note,
        type_check: TypeCheckFailure.Note,

        pub const Iterator = struct {
            index: usize = 0,
            err: Error,
            diag: *const Diagnostics,

            pub fn next(self: *@This()) ?Note {
                switch (self.err) {
                    .zoir => |err| {
                        if (self.index >= err.note_count) return null;
                        const note = err.getNotes(self.diag.zoir)[self.index];
                        self.index += 1;
                        return .{ .zoir = note };
                    },
                    .type_check => |err| {
                        if (self.index >= err.getNoteCount()) return null;
                        const note = err.getNote(self.index);
                        self.index += 1;
                        return .{ .type_check = note };
                    },
                }
            }
        };

        fn formatMessage(self: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
            // Just writes the string for now, but we're keeping this behind a formatter so we have
            // the option to extend it in the future to print more advanced messages (like `Error`
            // does) without breaking the API.
            try w.writeAll(self);
        }

        pub fn fmtMessage(self: Note, diag: *const Diagnostics) std.fmt.Alt([]const u8, Note.formatMessage) {
            return .{ .data = switch (self) {
                .zoir => |note| note.msg.get(diag.zoir),
                .type_check => |note| note.msg,
            } };
        }

        pub fn getLocation(self: Note, diag: *const Diagnostics) Ast.Location {
            switch (self) {
                .zoir => |note| return zoirErrorLocation(diag.ast, note.token, note.node_or_offset),
                .type_check => |note| return diag.ast.tokenLocation(note.offset, note.token),
            }
        }
    };

    pub const Iterator = struct {
        index: usize = 0,
        diag: *const Diagnostics,

        pub fn next(self: *@This()) ?Error {
            if (self.index < self.diag.zoir.compile_errors.len) {
                const result: Error = .{ .zoir = self.diag.zoir.compile_errors[self.index] };
                self.index += 1;
                return result;
            }

            if (self.diag.type_check) |err| {
                if (self.index == self.diag.zoir.compile_errors.len) {
                    const result: Error = .{ .type_check = err };
                    self.index += 1;
                    return result;
                }
            }

            return null;
        }
    };

    const TypeCheckFailure = struct {
        const Note = struct {
            token: Ast.TokenIndex,
            offset: u32,
            msg: []const u8,
            owned: bool,

            fn deinit(self: @This(), gpa: Allocator) void {
                if (self.owned) gpa.free(self.msg);
            }
        };

        message: []const u8,
        owned: bool,
        token: Ast.TokenIndex,
        offset: u32,
        note: ?@This().Note,

        fn deinit(self: @This(), gpa: Allocator) void {
            if (self.note) |note| note.deinit(gpa);
            if (self.owned) gpa.free(self.message);
        }

        fn getNoteCount(self: @This()) usize {
            return @intFromBool(self.note != null);
        }

        fn getNote(self: @This(), index: usize) @This().Note {
            assert(index == 0);
            return self.note.?;
        }
    };

    const FormatMessage = struct {
        err: Error,
        diag: *const Diagnostics,
    };

    fn formatMessage(self: FormatMessage, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.err) {
            .zoir => |err| try w.writeAll(err.msg.get(self.diag.zoir)),
            .type_check => |tc| try w.writeAll(tc.message),
        }
    }

    pub fn fmtMessage(self: @This(), diag: *const Diagnostics) std.fmt.Alt(FormatMessage, formatMessage) {
        return .{ .data = .{
            .err = self,
            .diag = diag,
        } };
    }

    pub fn getLocation(self: @This(), diag: *const Diagnostics) Ast.Location {
        return switch (self) {
            .zoir => |err| return zoirErrorLocation(
                diag.ast,
                err.token,
                err.node_or_offset,
            ),
            .type_check => |err| return diag.ast.tokenLocation(err.offset, err.token),
        };
    }

    pub fn iterateNotes(self: @This(), diag: *const Diagnostics) Note.Iterator {
        return .{ .err = self, .diag = diag };
    }

    fn zoirErrorLocation(ast: Ast, maybe_token: Ast.OptionalTokenIndex, node_or_offset: u32) Ast.Location {
        if (maybe_token.unwrap()) |token| {
            var location = ast.tokenLocation(0, token);
            location.column += node_or_offset;
            return location;
        } else {
            const ast_node: Ast.Node.Index = @fromBackingInt(@intCast(node_or_offset));
            const token = ast.nodeMainToken(ast_node);
            return ast.tokenLocation(0, token);
        }
    }
};

/// Information about the success or failure of a parse.
pub const Diagnostics = struct {
    ast: Ast = .{
        .source = "",
        .tokens = .empty,
        .nodes = .empty,
        .extra_data = &.{},
        .mode = .zon,
        .errors = &.{},
    },
    zoir: Zoir = .{
        .nodes = .empty,
        .extra = &.{},
        .limbs = &.{},
        .string_bytes = &.{},
        .compile_errors = &.{},
        .error_notes = &.{},
    },
    type_check: ?Error.TypeCheckFailure = null,

    fn assertEmpty(self: Diagnostics) void {
        assert(self.ast.tokens.len == 0);
        assert(self.zoir.nodes.len == 0);
        assert(self.type_check == null);
    }

    pub fn deinit(self: *Diagnostics, gpa: Allocator) void {
        self.ast.deinit(gpa);
        self.zoir.deinit(gpa);
        if (self.type_check) |tc| tc.deinit(gpa);
        self.* = undefined;
    }

    pub fn iterateErrors(self: *const Diagnostics) Error.Iterator {
        return .{ .diag = self };
    }

    pub fn format(self: *const @This(), w: *std.Io.Writer) std.Io.Writer.Error!void {
        var errors = self.iterateErrors();
        while (errors.next()) |err| {
            const loc = err.getLocation(self);
            const msg = err.fmtMessage(self);
            try w.print("{d}:{d}: error: {f}\n", .{ loc.line + 1, loc.column + 1, msg });

            var notes = err.iterateNotes(self);
            while (notes.next()) |note| {
                const note_loc = note.getLocation(self);
                const note_msg = note.fmtMessage(self);
                try w.print("{d}:{d}: note: {f}\n", .{
                    note_loc.line + 1,
                    note_loc.column + 1,
                    note_msg,
                });
            }
        }
    }
};

pub const FromSliceOptions = struct {
    gpa: Allocator,
    source: [:0]const u8,
    /// Write human readable error messages here.
    diag: ?*Diagnostics,
    /// If true, unknown fields do not error.
    ignore_unknown_fields: bool = false,
    /// If true, the parser cleans up partially parsed values on error. This requires some extra
    /// bookkeeping, so you may want to turn it off if you don't need this feature (e.g. because
    /// you're using arena allocation.)
    free_on_error: bool = true,
};

/// Parses the given slice as ZON.
///
/// Returns `error.OutOfMemory` on allocation failure, or `error.ParseZon` error if the ZON is
/// invalid or can not be deserialized into type `T`.
///
/// When the parser returns `error.ParseZon`, it will also store a human readable explanation in
/// `diag` if non null. If diag is not null, it must be initialized to `.{}`.
///
/// Asserts at compile time that the result type doesn't contain pointers. As such, the result
/// doesn't need to be freed.
///
/// An allocator is still required for temporary allocations made during parsing.
pub fn fromSlice(T: type, options: FromSliceOptions) error{ OutOfMemory, ParseZon }!T {
    comptime assert(!requiresAllocator(T));
    return fromSliceAlloc(T, options);
}

pub fn UpdateFromSliceOptions(T: type) type {
    return struct {
        gpa: Allocator,
        /// The value to update.
        value: *T,
        /// The ZON source.
        source: [:0]const u8,
        /// Write human readable error messages here.
        diag: ?*Diagnostics,
        /// If true, unknown fields do not error.
        ignore_unknown_fields: bool = false,
        /// If true, the old values of overriden fields are freed. You may want to turn this off if you
        /// are updating a value that shouldn't be freed e.g. because it contains Zig string literals.
        /// In this case, you can use arena allocation.
        free_on_write: bool = true,
    };
}

/// Similar to `fromSlice`, but updates an existing value `current`. Fields not specified by ZON are
/// left at their current values. Pointers are replaced with new values not mutated in place. On
/// failure, values that were updated prior to the failure are left updated.
pub fn updateFromSlice(
    T: type,
    options: UpdateFromSliceOptions(T),
) error{ OutOfMemory, ParseZon }!void {
    comptime assert(!requiresAllocator(T));
    try updateFromSliceAlloc(T, options);
}

pub const FromSliceAllocOptions = FromSliceOptions;

/// Like `fromSlice`, but the result may contain pointers. To automatically free the result, see
/// `free`.
pub fn fromSliceAlloc(T: type, options: FromSliceOptions) error{ OutOfMemory, ParseZon }!T {
    var result: T = undefined;
    try parseSliceAlloc(T, &result, options.gpa, options.source, options.diag, .{
        .ignore_unknown_fields = options.ignore_unknown_fields,
        .ignore_missing_fields = false,
        .free_on_error = options.free_on_error,
        .free_on_write = false,
    });
    return result;
}

pub const UpdateFromSliceAllocOptions = UpdateFromSliceOptions;

/// Like updateFromSlice`, but the result may contain pointers.
pub fn updateFromSliceAlloc(
    T: type,
    options: UpdateFromSliceAllocOptions(T),
) error{ OutOfMemory, ParseZon }!void {
    try parseSliceAlloc(
        T,
        options.value,
        options.gpa,
        options.source,
        options.diag,
        .{
            .ignore_unknown_fields = options.ignore_unknown_fields,
            .ignore_missing_fields = true,
            .free_on_error = false,
            .free_on_write = options.free_on_write,
        },
    );
}

fn parseSliceAlloc(
    T: type,
    out: *T,
    gpa: Allocator,
    source: [:0]const u8,
    diag: ?*Diagnostics,
    options: Parser.Options,
) error{ OutOfMemory, ParseZon }!void {
    if (diag) |s| s.assertEmpty();

    var ast = try std.zig.Ast.parse(gpa, source, .{ .mode = .zon });
    defer if (diag == null) ast.deinit(gpa);
    if (diag) |s| s.ast = ast;

    // If there's no diagnostics, Zoir exists for the lifetime of this function. If there is a
    // diagnostics, ownership is transferred to diagnostics.
    var zoir = try ZonGen.generate(gpa, ast, .{ .parse_str_lits = false });
    defer if (diag == null) zoir.deinit(gpa);

    if (diag) |s| s.* = .{};
    try parseZoirAlloc(T, out, gpa, ast, zoir, .root, diag, options);
}

pub const FromZoirOptions = struct {
    /// The AST for this this ZON value.
    ast: Ast,
    /// The zig object intermediate representation of this ZON value.
    zoir: Zoir,
    /// The node to start parsing at.
    node: Zoir.Node.Index = .root,
    /// Write human readable error messages here.
    diag: ?*Diagnostics,
    /// If true, unknown fields do not error.
    ignore_unknown_fields: bool = false,
    /// If true, the parser cleans up partially parsed values on error. This requires some extra
    /// bookkeeping, so you may want to turn it off if you don't need this feature (e.g. because
    /// you're using arena allocation.)
    free_on_error: bool = true,
};

/// Like `fromSlice`, but operates on `Zoir` instead of ZON source.
pub fn fromZoir(T: type, options: FromZoirOptions) error{ParseZon}!T {
    comptime assert(!requiresAllocator(T));
    return fromZoirAlloc(T, .{
        .gpa = .failing,
        .ast = options.ast,
        .zoir = options.zoir,
        .node = options.node,
        .diag = options.diag,
        .ignore_unknown_fields = options.ignore_unknown_fields,
        .free_on_error = options.free_on_error,
    }) catch |err| switch (err) {
        error.OutOfMemory => unreachable, // Checked by comptime assertion above
        else => |e| return e,
    };
}

pub fn UpdateFromZoirOptions(T: type) type {
    return struct {
        value: *T,
        /// The AST for this ZON value.
        ast: Ast,
        /// The zig object intermediate representation of this ZON value.
        zoir: Zoir,
        /// The node to start parsing at.
        node: Zoir.Node.Index = .root,
        /// Write human readable error messages here.
        diag: ?*Diagnostics,
        /// If true, unknown fields do not error.
        ignore_unknown_fields: bool = false,
        /// If true, the old values of overriden fields are freed. You may want to turn this off if you
        /// are updating a value that shouldn't be freed e.g. because it contains Zig string literals.
        /// In this case, you can use arena allocation.
        free_on_write: bool = true,
    };
}

/// Like `updateSlice`, but operates on `Zoir` instead of ZON source.
pub fn updateFromZoir(
    T: type,
    options: UpdateFromZoirOptions(T),
) error{ParseZon}!void {
    comptime assert(!requiresAllocator(T));
    updateFromZoirAlloc(T, .{
        .gpa = .failing,
        .value = options.value,
        .ast = options.ast,
        .zoir = options.zoir,
        .node = options.node,
        .diag = options.diag,
        .ignore_unknown_fields = options.ignore_unknown_fields,
        .free_on_write = options.free_on_write,
    }) catch |err| switch (err) {
        error.OutOfMemory => unreachable, // Checked by comptime assertion above
        else => |e| return e,
    };
}

pub const FromZoirAllocOptions = struct {
    gpa: Allocator,
    /// The AST for this ZON value.
    ast: Ast,
    /// The zig object intermediate representation of this ZON value.
    zoir: Zoir,
    /// The node to start parsing at.
    node: Zoir.Node.Index = .root,
    /// Write human readable error messages here.
    diag: ?*Diagnostics,
    /// If true, unknown fields do not error.
    ignore_unknown_fields: bool = false,
    /// If true, the parser cleans up partially parsed values on error. This requires some extra
    /// bookkeeping, so you may want to turn it off if you don't need this feature (e.g. because
    /// you're using arena allocation.)
    free_on_error: bool = true,
};

/// Like `fromSliceAlloc`, but operates on `Zoir` instead of ZON source.
pub fn fromZoirAlloc(T: type, options: FromZoirAllocOptions) error{ OutOfMemory, ParseZon }!T {
    var out: T = undefined;
    try parseZoirAlloc(
        T,
        &out,
        options.gpa,
        options.ast,
        options.zoir,
        options.node,
        options.diag,
        .{
            .ignore_unknown_fields = options.ignore_unknown_fields,
            .ignore_missing_fields = false,
            .free_on_error = options.free_on_error,
            .free_on_write = false,
        },
    );
    return out;
}

pub fn UpdateFromZoirAllocOptions(T: type) type {
    return struct {
        gpa: Allocator,
        value: *T,
        ast: Ast,
        zoir: Zoir,
        node: Zoir.Node.Index = .root,
        /// Write human readable error messages here.
        diag: ?*Diagnostics,
        /// If true, unknown fields do not error.
        ignore_unknown_fields: bool = false,
        /// If true, the old values of overriden fields are freed. You may want to turn this off if you
        /// are updating a value that shouldn't be freed e.g. because it contains Zig string literals.
        /// In this case, you can use arena allocation.
        free_on_write: bool = true,
    };
}

/// Like updateSliceAlloc`, but operates on `Zoir` instead of ZON source.
pub fn updateFromZoirAlloc(
    T: type,
    options: UpdateFromZoirAllocOptions(T),
) error{ OutOfMemory, ParseZon }!void {
    return parseZoirAlloc(
        T,
        options.value,
        options.gpa,
        options.ast,
        options.zoir,
        options.node,
        options.diag,
        .{
            .ignore_unknown_fields = options.ignore_unknown_fields,
            .ignore_missing_fields = true,
            .free_on_error = false,
            .free_on_write = options.free_on_write,
        },
    );
}

fn parseZoirAlloc(
    T: type,
    out: *T,
    gpa: Allocator,
    ast: Ast,
    zoir: Zoir,
    node: Zoir.Node.Index,
    diag: ?*Diagnostics,
    options: Parser.Options,
) error{ OutOfMemory, ParseZon }!void {
    comptime assert(canParseType(T));

    if (diag) |s| {
        s.assertEmpty();
        s.ast = ast;
        s.zoir = zoir;
    }

    if (zoir.hasCompileErrors()) {
        return error.ParseZon;
    }

    var parser: Parser = .{
        .gpa = gpa,
        .ast = ast,
        .zoir = zoir,
        .options = options,
        .diag = diag,
    };

    try parser.parseExprInto(node, out);
}

/// Frees ZON values.
///
/// Provided for convenience, you may also free these values on your own using the same allocator
/// passed into the parser.
///
/// Asserts at comptime that sufficient information is available via the type system to free this
/// value. Untagged unions, for example, will fail this assert.
pub fn free(gpa: Allocator, value: anytype) void {
    const Value = @TypeOf(value);

    _ = valid_types;
    switch (@typeInfo(Value)) {
        .bool, .int, .float, .@"enum" => {},
        .pointer => |pointer| {
            switch (pointer.size) {
                .one => {
                    free(gpa, value.*);
                    gpa.destroy(value);
                },
                .slice => {
                    for (value) |item| {
                        free(gpa, item);
                    }
                    gpa.free(value);
                },
                .many, .c => comptime unreachable,
            }
        },
        .array => {
            freeArray(gpa, @TypeOf(value), &value);
        },
        .vector => |vector| {
            const array: [vector.len]vector.child = value;
            freeArray(gpa, @TypeOf(array), &array);
        },
        .@"struct" => |@"struct"| inline for (@"struct".field_names) |field_name| {
            free(gpa, @field(value, field_name));
        },
        .@"union" => |@"union"| if (@"union".tag_type == null) {
            if (comptime requiresAllocator(Value)) unreachable;
        } else switch (value) {
            inline else => |_, tag| {
                free(gpa, @field(value, @tagName(tag)));
            },
        },
        .optional => if (value) |some| {
            free(gpa, some);
        },
        .void => {},
        else => comptime unreachable,
    }
}

fn freeArray(gpa: Allocator, comptime A: type, array: *const A) void {
    for (array) |elem| free(gpa, elem);
}

fn requiresAllocator(T: type) bool {
    _ = valid_types;
    return switch (@typeInfo(T)) {
        .pointer => true,
        .array => |array| return array.len > 0 and requiresAllocator(array.child),
        .@"struct" => |@"struct"| inline for (@"struct".field_types) |field_type| {
            if (requiresAllocator(field_type)) {
                break true;
            }
        } else false,
        .@"union" => |@"union"| inline for (@"union".field_types) |field_type| {
            if (requiresAllocator(field_type)) {
                break true;
            }
        } else false,
        .optional => |optional| requiresAllocator(optional.child),
        .vector => |vector| return vector.len > 0 and requiresAllocator(vector.child),
        else => false,
    };
}

const Parser = struct {
    gpa: Allocator,
    ast: Ast,
    zoir: Zoir,
    diag: ?*Diagnostics,
    options: Parser.Options,
    pointer_depth: usize = 0,

    pub const Options = struct {
        ignore_unknown_fields: bool,
        free_on_error: bool,
        free_on_write: bool,
        ignore_missing_fields: bool,
    };

    const ParseExprError = error{ ParseZon, OutOfMemory };

    fn parseExprInto(self: *@This(), node: Zoir.Node.Index, out: anytype) ParseExprError!void {
        return self.parseExprInnerInto(node, out) catch |err| switch (err) {
            error.WrongType => return self.failExpectedType(@TypeOf(out.*), node),
            else => |e| return e,
        };
    }

    const ParseExprInnerError = error{ ParseZon, OutOfMemory, WrongType };

    fn parseExprInnerInto(
        self: *@This(),
        node: Zoir.Node.Index,
        out: anytype,
    ) ParseExprInnerError!void {
        if (@TypeOf(out.*) == Zoir.Node.Index) {
            self.write(out, node);
            return;
        }

        switch (@typeInfo(@TypeOf(out.*))) {
            .optional => |optional| if (node.get(self.zoir) == .null) {
                self.write(out, null);
            } else {
                var new: optional.child = undefined;
                try self.parseExprInnerInto(node, &new);
                self.write(out, new);
            },
            .bool => self.write(out, try self.parseBool(node)),
            .int => self.write(out, try self.parseInt(@TypeOf(out.*), node)),
            .float => self.write(out, try self.parseFloat(@TypeOf(out.*), node)),
            .@"enum" => self.write(out, try self.parseEnumLiteral(@TypeOf(out.*), node)),
            .pointer => |pointer| switch (pointer.size) {
                .one => {
                    const slice = try self.gpa.alignedAlloc(
                        pointer.child,
                        if (pointer.attrs.@"align") |a| .fromByteUnits(a) else null,
                        1,
                    );
                    errdefer self.gpa.free(slice);
                    const new = &slice[0];
                    {
                        self.pointer_depth += 1;
                        defer self.pointer_depth -= 1;
                        try self.parseExprInnerInto(node, new);
                    }
                    self.write(out, new);
                },
                .slice => {
                    const new = b: {
                        self.pointer_depth += 1;
                        defer self.pointer_depth -= 1;
                        const new = try self.parseSlicePointer(@TypeOf(out.*), node);
                        break :b new;
                    };
                    self.write(out, new);
                },
                else => comptime unreachable,
            },
            .array => try self.parseArrayInto(node, out),
            .vector => try self.parseVectorInto(node, out),
            .@"struct" => |@"struct"| if (@"struct".is_tuple)
                try self.parseTupleInto(node, out)
            else
                try self.parseStructInto(node, out),
            .@"union" => try self.parseUnionInto(node, out),

            else => comptime unreachable,
        }
    }

    /// Prints a message of the form `expected T` where T is first converted to a ZON type. For
    /// example, `**?**u8` becomes `?u8`, and types that involve user specified type names are just
    /// referred to by the type of container.
    fn failExpectedType(
        self: @This(),
        T: type,
        node: Zoir.Node.Index,
    ) error{ ParseZon, OutOfMemory } {
        @branchHint(.cold);
        return self.failExpectedTypeInner(T, false, node);
    }

    fn failExpectedTypeInner(
        self: @This(),
        T: type,
        opt: bool,
        node: Zoir.Node.Index,
    ) error{ ParseZon, OutOfMemory } {
        _ = valid_types;
        switch (@typeInfo(T)) {
            .@"struct" => |@"struct"| if (@"struct".is_tuple) {
                if (opt) {
                    return self.failNode(node, "expected optional tuple");
                } else {
                    return self.failNode(node, "expected tuple");
                }
            } else {
                if (opt) {
                    return self.failNode(node, "expected optional struct");
                } else {
                    return self.failNode(node, "expected struct");
                }
            },
            .@"union" => if (opt) {
                return self.failNode(node, "expected optional union");
            } else {
                return self.failNode(node, "expected union");
            },
            .array => if (opt) {
                return self.failNode(node, "expected optional array");
            } else {
                return self.failNode(node, "expected array");
            },
            .pointer => |pointer| switch (pointer.size) {
                .one => return self.failExpectedTypeInner(pointer.child, opt, node),
                .slice => {
                    if (pointer.child == u8 and
                        pointer.attrs.@"const" and
                        (pointer.sentinel() == null or pointer.sentinel() == 0) and
                        (pointer.attrs.@"align" == null or pointer.attrs.@"align" == 1))
                    {
                        if (opt) {
                            return self.failNode(node, "expected optional string");
                        } else {
                            return self.failNode(node, "expected string");
                        }
                    } else {
                        if (opt) {
                            return self.failNode(node, "expected optional array");
                        } else {
                            return self.failNode(node, "expected array");
                        }
                    }
                },
                else => comptime unreachable,
            },
            .vector, .bool, .int, .float => if (opt) {
                return self.failNodeFmt(node, "expected type '{s}'", .{@typeName(?T)});
            } else {
                return self.failNodeFmt(node, "expected type '{s}'", .{@typeName(T)});
            },
            .@"enum" => if (opt) {
                return self.failNode(node, "expected optional enum literal");
            } else {
                return self.failNode(node, "expected enum literal");
            },
            .optional => |optional| {
                return self.failExpectedTypeInner(optional.child, true, node);
            },
            else => comptime unreachable,
        }
    }

    fn parseBool(self: @This(), node: Zoir.Node.Index) !bool {
        switch (node.get(self.zoir)) {
            .true => return true,
            .false => return false,
            else => return error.WrongType,
        }
    }

    fn parseInt(self: @This(), T: type, node: Zoir.Node.Index) !T {
        switch (node.get(self.zoir)) {
            .int_literal => |int| switch (int) {
                .small => |val| return std.math.cast(T, val) orelse
                    self.failCannotRepresent(T, node),
                .big => |val| return val.toInt(T) catch
                    self.failCannotRepresent(T, node),
            },
            .float_literal => |val| return intFromFloatExact(T, val) orelse
                self.failCannotRepresent(T, node),

            .char_literal => |val| return std.math.cast(T, val) orelse
                self.failCannotRepresent(T, node),
            else => return error.WrongType,
        }
    }

    fn parseFloat(self: @This(), T: type, node: Zoir.Node.Index) !T {
        switch (node.get(self.zoir)) {
            .int_literal => |int| switch (int) {
                .small => |val| return @floatFromInt(val),
                .big => |val| return val.toFloat(T, .nearest_even)[0],
            },
            .float_literal => |val| return @floatCast(val),
            .pos_inf => return std.math.inf(T),
            .neg_inf => return -std.math.inf(T),
            .nan => return std.math.nan(T),
            .char_literal => |val| return @floatFromInt(val),
            else => return error.WrongType,
        }
    }

    fn parseEnumLiteral(self: @This(), T: type, node: Zoir.Node.Index) !T {
        switch (node.get(self.zoir)) {
            .enum_literal => |field_name| {
                // Create a comptime string map for the enum fields
                const enum_info = @typeInfo(T).@"enum";
                comptime var kvs_list: [enum_info.field_names.len]struct { []const u8, T } = undefined;
                inline for (enum_info.field_names, enum_info.field_values, 0..) |enum_field_name, enum_field_value, i| {
                    kvs_list[i] = .{ enum_field_name, @fromBackingInt(@intCast(enum_field_value)) };
                }
                const enum_tags = std.StaticStringMap(T).initComptime(kvs_list);

                // Get the tag if it exists
                const field_name_str = field_name.get(self.zoir);
                return enum_tags.get(field_name_str) orelse
                    self.failUnexpected(T, "enum literal", node, null, field_name_str);
            },
            else => return error.WrongType,
        }
    }

    fn parseSlicePointer(self: *@This(), T: type, node: Zoir.Node.Index) ParseExprInnerError!T {
        switch (node.get(self.zoir)) {
            .string_literal => return self.parseString(T, node),
            .array_literal => |nodes| return self.parseSlice(T, nodes),
            .empty_literal => return self.parseSlice(T, .{ .start = node, .len = 0 }),
            else => return error.WrongType,
        }
    }

    fn parseString(self: *@This(), T: type, node: Zoir.Node.Index) ParseExprInnerError!T {
        const ast_node = node.getAstNode(self.zoir);
        const pointer = @typeInfo(T).pointer;
        var size_hint = ZonGen.strLitSizeHint(self.ast, ast_node);
        if (pointer.sentinel() != null) size_hint += 1;

        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        try aw.ensureUnusedCapacity(size_hint);
        defer aw.deinit();
        const result = ZonGen.parseStrLit(self.ast, ast_node, &aw.writer) catch return error.OutOfMemory;
        switch (result) {
            .success => {},
            .failure => |err| {
                const token = self.ast.nodeMainToken(ast_node);
                const raw_string = self.ast.tokenSlice(token);
                return self.failTokenFmt(token, @intCast(err.offset()), "{f}", .{err.fmt(raw_string)});
            },
        }

        if (pointer.child != u8 or
            pointer.size != .slice or
            !pointer.attrs.@"const" or
            (pointer.sentinel() != null and pointer.sentinel() != 0) or
            (pointer.attrs.@"align" != null and pointer.attrs.@"align" != 1))
        {
            return error.WrongType;
        }

        if (pointer.sentinel() != null) {
            return aw.toOwnedSliceSentinel(0);
        } else {
            return aw.toOwnedSlice();
        }
    }

    fn parseSlice(self: *@This(), T: type, nodes: Zoir.Node.Index.Range) !T {
        const pointer = @typeInfo(T).pointer;

        // Make sure we're working with a slice
        switch (pointer.size) {
            .slice => {},
            .one, .many, .c => comptime unreachable,
        }

        // Allocate the slice
        const slice = try self.gpa.allocWithOptions(
            pointer.child,
            nodes.len,
            .fromByteUnitsOptional(pointer.attrs.@"align"),
            pointer.sentinel(),
        );
        errdefer self.gpa.free(slice);

        // Parse the elements and return the slice
        for (slice, 0..) |*elem, i| {
            errdefer if (self.options.free_on_error) {
                for (slice[0..i]) |item| {
                    free(self.gpa, item);
                }
            };
            try self.parseExprInto(nodes.at(@intCast(i)), elem);
        }

        return slice;
    }

    fn parseArrayInto(self: *@This(), node: Zoir.Node.Index, out: anytype) !void {
        const nodes: Zoir.Node.Index.Range = switch (node.get(self.zoir)) {
            .array_literal => |nodes| nodes,
            .empty_literal => .{ .start = node, .len = 0 },
            else => return error.WrongType,
        };

        const array = @typeInfo(@TypeOf(out.*)).array;

        // Check if the size matches
        if (nodes.len < array.len) {
            return self.failNodeFmt(
                node,
                "expected {} array elements; found {}",
                .{ array.len, nodes.len },
            );
        } else if (nodes.len > array.len) {
            return self.failNodeFmt(
                nodes.at(array.len),
                "index {} outside of array of length {}",
                .{ array.len, array.len },
            );
        }

        // Parse the elements and return the array
        inline for (out, 0..) |*elem, i| {
            // If we fail to parse this field, free all fields before it
            errdefer if (self.options.free_on_error) {
                for (out[0..i]) |item| {
                    free(self.gpa, item);
                }
            };

            try self.parseExprInto(nodes.at(@intCast(i)), elem);
        }

        if (array.sentinel()) |s| {
            out[array.len] = s;
        }
    }

    fn parseVectorInto(self: *@This(), node: Zoir.Node.Index, out: anytype) !void {
        const vector = @typeInfo(@TypeOf(out.*)).vector;
        var array: [vector.len]vector.child = undefined;
        try self.parseArrayInto(node, &array);
        self.write(out, array);
    }

    fn parseStructInto(self: *@This(), node: Zoir.Node.Index, out: anytype) !void {
        const repr = node.get(self.zoir);
        const fields: @FieldType(Zoir.Node, "struct_literal") = switch (repr) {
            .struct_literal => |nodes| nodes,
            .empty_literal => .{ .names = &.{}, .vals = .{ .start = node, .len = 0 } },
            else => return error.WrongType,
        };

        const info = @typeInfo(@TypeOf(out.*)).@"struct";

        // Build a map from field name to index.
        // The special value `comptime_field` indicates that this is actually a comptime field.
        const comptime_field = std.math.maxInt(usize);
        const field_indices: std.StaticStringMap(usize) = comptime b: {
            var kvs_list: [info.field_names.len]struct { []const u8, usize } = undefined;
            for (&kvs_list, info.field_names, info.field_attrs, 0..) |*kv, field_name, field_attrs, i| {
                kv.* = .{ field_name, if (field_attrs.@"comptime") comptime_field else i };
            }
            break :b .initComptime(kvs_list);
        };

        // Parse the struct
        var field_found: [info.field_names.len]bool = @splat(false);

        // If we fail partway through, free all already initialized fields
        var initialized: usize = 0;
        errdefer if (self.options.free_on_error and info.field_names.len > 0) {
            for (fields.names[0..initialized]) |name_runtime| {
                switch (field_indices.get(name_runtime.get(self.zoir)) orelse continue) {
                    inline 0...(info.field_names.len - 1) => |name_index| {
                        const name = info.field_names[name_index];
                        free(self.gpa, @field(out, name));
                    },
                    else => unreachable, // Can't be out of bounds
                }
            }
        };

        // Fill in the fields we found
        for (0..fields.names.len) |i| {
            const name = fields.names[i].get(self.zoir);
            const field_index = field_indices.get(name) orelse {
                if (self.options.ignore_unknown_fields) continue;
                return self.failUnexpected(@TypeOf(out.*), "field", node, i, name);
            };
            if (field_index == comptime_field) {
                return self.failComptimeField(node, i);
            }

            // Mark the field as found. Assert that the found array is not zero length to satisfy
            // the type checker (it can't be since we made it into an iteration of this loop.)
            if (field_found.len == 0) unreachable;
            field_found[field_index] = true;

            switch (field_index) {
                inline 0...(info.field_names.len - 1) => |j| {
                    if (info.field_attrs[j].@"comptime") unreachable;

                    try self.parseExprInto(
                        fields.vals.at(@intCast(i)),
                        &@field(out, info.field_names[j]),
                    );
                },
                else => unreachable, // Can't be out of bounds
            }

            initialized += 1;
        }

        // Fill in any missing default fields
        if (!self.options.ignore_missing_fields or self.pointer_depth > 0) {
            inline for (field_found, 0..) |found, i| {
                if (!found) {
                    const field_attrs = info.field_attrs[i];
                    if (field_attrs.defaultValue(info.field_types[i])) |default| {
                        @field(out, info.field_names[i]) = default;
                    } else {
                        return self.failNodeFmt(
                            node,
                            "missing required field {s}",
                            .{info.field_names[i]},
                        );
                    }
                }
            }
        }
    }

    fn parseTupleInto(self: *@This(), node: Zoir.Node.Index, out: anytype) !void {
        const nodes: Zoir.Node.Index.Range = switch (node.get(self.zoir)) {
            .array_literal => |nodes| nodes,
            .empty_literal => .{ .start = node, .len = 0 },
            else => return error.WrongType,
        };

        const info = @typeInfo(@TypeOf(out.*)).@"struct";

        if (nodes.len > info.field_names.len) {
            return self.failNodeFmt(
                nodes.at(info.field_names.len),
                "index {} outside of tuple length {}",
                .{ info.field_names.len, info.field_names.len },
            );
        }

        inline for (0..info.field_names.len) |i| {
            // Check if we're out of bounds
            if (i >= nodes.len) {
                if (info.field_attrs[i].defaultValue(info.field_types[i])) |default| {
                    @field(out.*, info.field_names[i]) = default;
                } else {
                    return self.failNodeFmt(node, "missing tuple field with index {}", .{i});
                }
            } else {
                // If we fail to parse this field, free all fields before it
                errdefer if (self.options.free_on_error) {
                    inline for (0..i) |j| {
                        if (j >= i) break;
                        free(self.gpa, out[j]);
                    }
                };

                if (info.field_attrs[i].@"comptime") {
                    return self.failComptimeField(node, i);
                } else {
                    try self.parseExprInto(nodes.at(i), &out[i]);
                }
            }
        }
    }

    fn parseUnionInto(self: *@This(), node: Zoir.Node.Index, out: anytype) !void {
        const @"union" = @typeInfo(@TypeOf(out.*)).@"union";

        if (@"union".field_names.len == 0) comptime unreachable;

        // Gather info on the fields
        const field_indices = b: {
            comptime var kvs_list: [@"union".field_names.len]struct { []const u8, usize } = undefined;
            inline for (@"union".field_names, 0..) |field_name, i| {
                kvs_list[i] = .{ field_name, i };
            }
            break :b std.StaticStringMap(usize).initComptime(kvs_list);
        };

        // Parse the union
        switch (node.get(self.zoir)) {
            .enum_literal => |field_name| {
                // The union must be tagged for an enum literal to coerce to it
                if (@"union".tag_type == null) {
                    return error.WrongType;
                }

                // Get the index of the named field. We don't use `parseEnum` here as
                // the order of the enum and the order of the union might not match!
                const field_index = b: {
                    const field_name_str = field_name.get(self.zoir);
                    break :b field_indices.get(field_name_str) orelse
                        return self.failUnexpected(@TypeOf(out.*), "field", node, null, field_name_str);
                };

                // Initialize the union from the given field.
                switch (field_index) {
                    inline 0...@"union".field_names.len - 1 => |i| {
                        // Fail if the field is not void
                        if (@"union".field_types[i] != void)
                            return self.failNode(node, "expected union");

                        // Instantiate the union
                        self.write(out, @unionInit(@TypeOf(out.*), @"union".field_names[i], {}));
                    },
                    else => unreachable, // Can't be out of bounds
                }
            },
            .struct_literal => |struct_fields| {
                if (struct_fields.names.len != 1) {
                    return error.WrongType;
                }

                // Fill in the field we found
                const field_name = struct_fields.names[0];
                const field_name_str = field_name.get(self.zoir);
                const field_val = struct_fields.vals.at(0);
                const field_index = field_indices.get(field_name_str) orelse
                    return self.failUnexpected(@TypeOf(out.*), "field", node, 0, field_name_str);

                switch (field_index) {
                    inline 0...@"union".field_names.len - 1 => |i| {
                        if (@"union".field_types[i] == void) {
                            return self.failNode(field_val, "expected type 'void'");
                        } else {
                            self.write(out, @unionInit(@TypeOf(out.*), @"union".field_names[i], undefined));
                            try self.parseExprInto(field_val, &@field(out.*, @"union".field_names[i]));
                        }
                    },
                    else => unreachable, // Can't be out of bounds
                }
            },
            else => return error.WrongType,
        }
    }

    fn failTokenFmt(
        self: @This(),
        token: Ast.TokenIndex,
        offset: u32,
        comptime fmt: []const u8,
        args: anytype,
    ) error{ OutOfMemory, ParseZon } {
        @branchHint(.cold);
        return self.failTokenFmtNote(token, offset, fmt, args, null);
    }

    fn failTokenFmtNote(
        self: @This(),
        token: Ast.TokenIndex,
        offset: u32,
        comptime fmt: []const u8,
        args: anytype,
        note: ?Error.TypeCheckFailure.Note,
    ) error{ OutOfMemory, ParseZon } {
        @branchHint(.cold);
        comptime assert(args.len > 0);
        if (self.diag) |s| s.type_check = .{
            .token = token,
            .offset = offset,
            .message = std.fmt.allocPrint(self.gpa, fmt, args) catch |err| {
                if (note) |n| n.deinit(self.gpa);
                return err;
            },
            .owned = true,
            .note = note,
        };
        return error.ParseZon;
    }

    fn failNodeFmt(
        self: @This(),
        node: Zoir.Node.Index,
        comptime fmt: []const u8,
        args: anytype,
    ) error{ OutOfMemory, ParseZon } {
        @branchHint(.cold);
        const token = self.ast.nodeMainToken(node.getAstNode(self.zoir));
        return self.failTokenFmt(token, 0, fmt, args);
    }

    fn failToken(
        self: @This(),
        failure: Error.TypeCheckFailure,
    ) error{ParseZon} {
        @branchHint(.cold);
        if (self.diag) |s| s.type_check = failure;
        return error.ParseZon;
    }

    fn failNode(
        self: @This(),
        node: Zoir.Node.Index,
        message: []const u8,
    ) error{ParseZon} {
        @branchHint(.cold);
        const token = self.ast.nodeMainToken(node.getAstNode(self.zoir));
        return self.failToken(.{
            .token = token,
            .offset = 0,
            .message = message,
            .owned = false,
            .note = null,
        });
    }

    fn failCannotRepresent(
        self: @This(),
        T: type,
        node: Zoir.Node.Index,
    ) error{ OutOfMemory, ParseZon } {
        @branchHint(.cold);
        return self.failNodeFmt(node, "type '{s}' cannot represent value", .{@typeName(T)});
    }

    fn failUnexpected(
        self: @This(),
        T: type,
        item_kind: []const u8,
        node: Zoir.Node.Index,
        field: ?usize,
        name: []const u8,
    ) error{ OutOfMemory, ParseZon } {
        @branchHint(.cold);
        if (self.diag == null) return error.ParseZon;
        const gpa = self.gpa;
        const token = if (field) |f| b: {
            var buf: [2]Ast.Node.Index = undefined;
            const struct_init = self.ast.fullStructInit(&buf, node.getAstNode(self.zoir)).?;
            const field_node = struct_init.ast.fields[f];
            break :b self.ast.firstToken(field_node) - 2;
        } else self.ast.nodeMainToken(node.getAstNode(self.zoir));
        switch (@typeInfo(T)) {
            inline .@"struct", .@"union", .@"enum" => |info| {
                const note: Error.TypeCheckFailure.Note = if (info.field_names.len == 0) b: {
                    break :b .{
                        .token = token,
                        .offset = 0,
                        .msg = "none expected",
                        .owned = false,
                    };
                } else b: {
                    const msg = "supported: ";
                    var buf: std.ArrayList(u8) = try .initCapacity(gpa, 64);
                    defer buf.deinit(gpa);
                    try buf.appendSlice(gpa, msg);
                    inline for (info.field_names, 0..) |field_name, i| {
                        if (i != 0) try buf.appendSlice(gpa, ", ");
                        try buf.print(gpa, "'{f}'", .{std.zig.fmtIdFlags(field_name, .{
                            .allow_primitive = true,
                            .allow_underscore = true,
                        })});
                    }
                    break :b .{
                        .token = token,
                        .offset = 0,
                        .msg = try buf.toOwnedSlice(gpa),
                        .owned = true,
                    };
                };
                return self.failTokenFmtNote(
                    token,
                    0,
                    "unexpected {s} '{s}'",
                    .{ item_kind, name },
                    note,
                );
            },
            else => comptime unreachable,
        }
    }

    // Technically we could do this if we were willing to do a deep equal to verify
    // the value matched, but doing so doesn't seem to support any real use cases
    // so isn't worth the complexity at the moment.
    fn failComptimeField(
        self: @This(),
        node: Zoir.Node.Index,
        field: usize,
    ) error{ OutOfMemory, ParseZon } {
        @branchHint(.cold);
        if (self.diag == null) return error.ParseZon;
        const ast_node = node.getAstNode(self.zoir);
        var buf: [2]Ast.Node.Index = undefined;
        const token = if (self.ast.fullStructInit(&buf, ast_node)) |struct_init| b: {
            const field_node = struct_init.ast.fields[field];
            break :b self.ast.firstToken(field_node);
        } else b: {
            const array_init = self.ast.fullArrayInit(&buf, ast_node).?;
            const value_node = array_init.ast.elements[field];
            break :b self.ast.firstToken(value_node);
        };
        return self.failToken(.{
            .token = token,
            .offset = 0,
            .message = "cannot initialize comptime field",
            .owned = false,
            .note = null,
        });
    }

    /// Write to out, freeing the old value first if necessary.
    fn write(self: *@This(), out: anytype, new: @TypeOf(out.*)) void {
        if (@typeInfo(@TypeOf(out)) == .pointer) {
            if (self.options.free_on_write and self.pointer_depth == 0) {
                free(self.gpa, out.*);
            }
        }
        out.* = new;
    }
};

fn intFromFloatExact(T: type, value: anytype) ?T {
    const max: @TypeOf(value) = @floatFromInt(std.math.maxInt(T));
    const min: @TypeOf(value) = @floatFromInt(std.math.minInt(T));
    if (value > max or value < min) {
        return null;
    }

    if (std.math.isNan(value) or std.math.trunc(value) != value) {
        return null;
    }

    return @intFromFloat(value);
}

fn canParseType(T: type) bool {
    comptime return canParseTypeInner(T, &.{}, false);
}

fn canParseTypeInner(
    T: type,
    /// Visited structs and unions, to avoid infinite recursion.
    /// Tracking more types is unnecessary, and a little complex due to optional nesting.
    visited: []const type,
    parent_is_optional: bool,
) bool {
    return switch (@typeInfo(T)) {
        .bool,
        .int,
        .float,
        .null,
        .@"enum",
        => true,

        .noreturn,
        .void,
        .type,
        .undefined,
        .error_union,
        .error_set,
        .@"fn",
        .frame,
        .@"anyframe",
        .@"opaque",
        .spirv,
        .comptime_int,
        .comptime_float,
        .enum_literal,
        => false,

        .pointer => |pointer| switch (pointer.size) {
            .one => canParseTypeInner(pointer.child, visited, parent_is_optional),
            .slice => canParseTypeInner(pointer.child, visited, false),
            .many, .c => false,
        },

        .optional => |optional| if (parent_is_optional)
            false
        else
            canParseTypeInner(optional.child, visited, true),

        .array => |array| canParseTypeInner(array.child, visited, false),
        .vector => |vector| canParseTypeInner(vector.child, visited, false),

        .@"struct" => |@"struct"| {
            for (visited) |V| if (T == V) return true;
            const new_visited = visited ++ .{T};
            for (@"struct".field_types, @"struct".field_attrs) |field_type, field_attrs| {
                if (!field_attrs.@"comptime" and !canParseTypeInner(field_type, new_visited, false)) {
                    return false;
                }
            }
            return true;
        },
        .@"union" => |@"union"| {
            for (visited) |V| if (T == V) return true;
            const new_visited = visited ++ .{T};
            for (@"union".field_types) |field_type| {
                if (field_type != void and !canParseTypeInner(field_type, new_visited, false)) {
                    return false;
                }
            }
            return true;
        },
    };
}

test "std.zon parse canParseType" {
    try std.testing.expect(!comptime canParseType(void));
    try std.testing.expect(!comptime canParseType(struct { f: [*]u8 }));
    try std.testing.expect(!comptime canParseType(struct { error{foo} }));
    try std.testing.expect(!comptime canParseType(union(enum) { a: void, b: [*c]u8 }));
    try std.testing.expect(!comptime canParseType(@Vector(0, [*c]u8)));
    try std.testing.expect(!comptime canParseType(*?[*c]u8));
    try std.testing.expect(comptime canParseType(enum(u8) { _ }));
    try std.testing.expect(comptime canParseType(union { foo: void }));
    try std.testing.expect(comptime canParseType(union(enum) { foo: void }));
    try std.testing.expect(!comptime canParseType(comptime_float));
    try std.testing.expect(!comptime canParseType(comptime_int));
    try std.testing.expect(comptime canParseType(struct { comptime foo: ??u8 = null }));
    try std.testing.expect(!comptime canParseType(@TypeOf(.foo)));
    try std.testing.expect(comptime canParseType(?u8));
    try std.testing.expect(comptime canParseType(*?*u8));
    try std.testing.expect(comptime canParseType(?struct {
        foo: ?struct {
            ?union(enum) {
                a: ?@Vector(0, ?*u8),
            },
            ?struct {
                f: ?[]?u8,
            },
        },
    }));
    try std.testing.expect(!comptime canParseType(??u8));
    try std.testing.expect(!comptime canParseType(?*?u8));
    try std.testing.expect(!comptime canParseType(*?*?*u8));
    try std.testing.expect(!comptime canParseType(struct { x: comptime_int = 2 }));
    try std.testing.expect(!comptime canParseType(struct { x: comptime_float = 2 }));
    try std.testing.expect(comptime canParseType(struct { comptime x: @TypeOf(.foo) = .foo }));
    try std.testing.expect(!comptime canParseType(struct { comptime_int }));
    const Recursive = struct { foo: ?*@This() };
    try std.testing.expect(comptime canParseType(Recursive));

    // Make sure we validate nested optional before we early out due to already having seen
    // a type recursion!
    try std.testing.expect(!comptime canParseType(struct {
        add_to_visited: ?u8,
        retrieve_from_visited: ??u8,
    }));
}

test "std.zon requiresAllocator" {
    try std.testing.expect(!requiresAllocator(u8));
    try std.testing.expect(!requiresAllocator(f32));
    try std.testing.expect(!requiresAllocator(enum { foo }));
    try std.testing.expect(!requiresAllocator(struct { f32 }));
    try std.testing.expect(!requiresAllocator(struct { x: f32 }));
    try std.testing.expect(!requiresAllocator([0][]const u8));
    try std.testing.expect(!requiresAllocator([2]u8));
    try std.testing.expect(!requiresAllocator(union { x: f32, y: f32 }));
    try std.testing.expect(!requiresAllocator(union(enum) { x: f32, y: f32 }));
    try std.testing.expect(!requiresAllocator(?f32));
    try std.testing.expect(!requiresAllocator(void));
    try std.testing.expect(!requiresAllocator(@TypeOf(null)));
    try std.testing.expect(!requiresAllocator(@Vector(3, u8)));
    try std.testing.expect(!requiresAllocator(@Vector(0, *const u8)));

    try std.testing.expect(requiresAllocator([]u8));
    try std.testing.expect(requiresAllocator(*struct { u8, u8 }));
    try std.testing.expect(requiresAllocator([1][]const u8));
    try std.testing.expect(requiresAllocator(struct { x: i32, y: []u8 }));
    try std.testing.expect(requiresAllocator(union { x: i32, y: []u8 }));
    try std.testing.expect(requiresAllocator(union(enum) { x: i32, y: []u8 }));
    try std.testing.expect(requiresAllocator(?[]u8));
    try std.testing.expect(requiresAllocator(@Vector(3, *const u8)));
}

test "std.zon ast errors" {
    const gpa = std.testing.allocator;
    var diag: Diagnostics = .{};
    defer diag.deinit(gpa);
    try std.testing.expectError(
        error.ParseZon,
        fromSlice(struct {}, .{ .gpa = gpa, .source = ".{.x = 1 .y = 2}", .diag = &diag }),
    );
    try std.testing.expectFmt("1:13: error: expected ',' after initializer\n", "{f}", .{diag});
}

test "std.zon comments" {
    const gpa = std.testing.allocator;

    try std.testing.expectEqual(@as(u8, 10), fromSlice(u8, .{
        .gpa = gpa,
        .source =
        \\// comment
        \\10 // comment
        \\// comment
        ,
        .diag = null,
    }));

    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(error.ParseZon, fromSlice(u8, .{
            .gpa = gpa,
            .source =
            \\//! comment
            \\10 // comment
            \\// comment
            ,
            .diag = &diag,
        }));
        try std.testing.expectFmt(
            "1:1: error: expected expression, found 'a document comment'\n",
            "{f}",
            .{diag},
        );
    }
}

test "std.zon failure/oom formatting" {
    const gpa = std.testing.allocator;
    var diag: Diagnostics = .{};
    defer diag.deinit(gpa);
    try std.testing.expectError(error.OutOfMemory, fromSliceAlloc([]const u8, .{
        .gpa = .failing,
        .source = "\"foo\"",
        .diag = &diag,
    }));
    try std.testing.expectFmt("", "{f}", .{diag});
}

test "std.zon fromSliceAlloc syntax error" {
    try std.testing.expectError(
        error.ParseZon,
        fromSlice(u8, .{
            .gpa = std.testing.allocator,
            .source = ".{",
            .diag = null,
        }),
    );
}

test "std.zon optional" {
    const gpa = std.testing.allocator;

    // Basic usage
    {
        const none = try fromSlice(?u32, .{
            .gpa = gpa,
            .source = "null",
            .diag = null,
        });
        try std.testing.expect(none == null);
        const some = try fromSlice(?u32, .{
            .gpa = gpa,
            .source = "1",
            .diag = null,
        });
        try std.testing.expect(some.? == 1);
    }

    // Deep free
    {
        const none = try fromSliceAlloc(?[]const u8, .{
            .gpa = gpa,
            .source = "null",
            .diag = null,
        });
        try std.testing.expect(none == null);
        const some = try fromSliceAlloc(?[]const u8, .{
            .gpa = gpa,
            .source = "\"foo\"",
            .diag = null,
        });
        defer free(gpa, some);
        try std.testing.expectEqualStrings("foo", some.?);
    }
}

test "std.zon unions" {
    const gpa = std.testing.allocator;

    // Unions
    {
        const Tagged = union(enum) { x: f32, @"y y": bool, z, @"z z" };
        const Untagged = union { x: f32, @"y y": bool, z: void, @"z z": void };

        const tagged_x = try fromSlice(Tagged, .{
            .gpa = gpa,
            .source = ".{.x = 1.5}",
            .diag = null,
        });
        try std.testing.expectEqual(Tagged{ .x = 1.5 }, tagged_x);
        const tagged_y = try fromSlice(Tagged, .{
            .gpa = gpa,
            .source = ".{.@\"y y\" = true}",
            .diag = null,
        });
        try std.testing.expectEqual(Tagged{ .@"y y" = true }, tagged_y);
        const tagged_z_shorthand = try fromSlice(Tagged, .{
            .gpa = gpa,
            .source = ".z",
            .diag = null,
        });
        try std.testing.expectEqual(@as(Tagged, .z), tagged_z_shorthand);
        const tagged_zz_shorthand = try fromSlice(Tagged, .{
            .gpa = gpa,
            .source = ".@\"z z\"",
            .diag = null,
        });
        try std.testing.expectEqual(@as(Tagged, .@"z z"), tagged_zz_shorthand);

        const untagged_x = try fromSlice(Untagged, .{
            .gpa = gpa,
            .source = ".{.x = 1.5}",
            .diag = null,
        });
        try std.testing.expect(untagged_x.x == 1.5);
        const untagged_y = try fromSlice(Untagged, .{
            .gpa = gpa,
            .source = ".{.@\"y y\" = true}",
            .diag = null,
        });
        try std.testing.expect(untagged_y.@"y y");
    }

    // Deep free
    {
        const Union = union(enum) { bar: []const u8, baz: bool };

        const noalloc = try fromSliceAlloc(Union, .{
            .gpa = gpa,
            .source = ".{.baz = false}",
            .diag = null,
        });
        try std.testing.expectEqual(Union{ .baz = false }, noalloc);

        const alloc = try fromSliceAlloc(Union, .{
            .gpa = gpa,
            .source = ".{.bar = \"qux\"}",
            .diag = null,
        });
        defer free(gpa, alloc);
        try std.testing.expectEqualDeep(Union{ .bar = "qux" }, alloc);
    }

    // Unknown field
    {
        const Union = union { x: f32, y: f32 };
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSliceAlloc(Union, .{ .gpa = gpa, .source = ".{.z=2.5}", .diag = &diag }),
        );
        try std.testing.expectFmt(
            \\1:4: error: unexpected field 'z'
            \\1:4: note: supported: 'x', 'y'
            \\
        ,
            "{f}",
            .{diag},
        );
    }

    // Explicit void field
    {
        const Union = union(enum) { x: void };
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSliceAlloc(Union, .{ .gpa = gpa, .source = ".{.x=1}", .diag = &diag }),
        );
        try std.testing.expectFmt("1:6: error: expected type 'void'\n", "{f}", .{diag});
    }

    // Extra field
    {
        const Union = union { x: f32, y: bool };
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSliceAlloc(Union, .{
                .gpa = gpa,
                .source = ".{.x = 1.5, .y = true}",
                .diag = &diag,
            }),
        );
        try std.testing.expectFmt("1:2: error: expected union\n", "{f}", .{diag});
    }

    // No fields
    {
        const Union = union { x: f32, y: bool };
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSliceAlloc(Union, .{ .gpa = gpa, .source = ".{}", .diag = &diag }),
        );
        try std.testing.expectFmt("1:2: error: expected union\n", "{f}", .{diag});
    }

    // Enum literals cannot coerce into untagged unions
    {
        const Union = union { x: void };
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(error.ParseZon, fromSliceAlloc(Union, .{
            .gpa = gpa,
            .source = ".x",
            .diag = &diag,
        }));
        try std.testing.expectFmt("1:2: error: expected union\n", "{f}", .{diag});
    }

    // Unknown field for enum literal coercion
    {
        const Union = union(enum) { x: void };
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(error.ParseZon, fromSliceAlloc(Union, .{
            .gpa = gpa,
            .source = ".y",
            .diag = &diag,
        }));
        try std.testing.expectFmt(
            \\1:2: error: unexpected field 'y'
            \\1:2: note: supported: 'x'
            \\
        ,
            "{f}",
            .{diag},
        );
    }

    // Non void field for enum literal coercion
    {
        const Union = union(enum) { x: f32 };
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(error.ParseZon, fromSliceAlloc(Union, .{
            .gpa = gpa,
            .source = ".x",
            .diag = &diag,
        }));
        try std.testing.expectFmt("1:2: error: expected union\n", "{f}", .{diag});
    }
}

test "std.zon structs" {
    const gpa = std.testing.allocator;

    // Structs (various sizes tested since they're parsed differently)
    {
        const Vec0 = struct {};
        const Vec1 = struct { x: f32 };
        const Vec2 = struct { x: f32, y: f32 };
        const Vec3 = struct { x: f32, y: f32, z: f32 };

        const zero = try fromSlice(Vec0, .{
            .gpa = gpa,
            .source = ".{}",
            .diag = null,
        });
        try std.testing.expectEqual(Vec0{}, zero);

        const one = try fromSlice(Vec1, .{
            .gpa = gpa,
            .source = ".{.x = 1.2}",
            .diag = null,
        });
        try std.testing.expectEqual(Vec1{ .x = 1.2 }, one);

        const two = try fromSlice(Vec2, .{
            .gpa = gpa,
            .source = ".{.x = 1.2, .y = 3.4}",
            .diag = null,
        });
        try std.testing.expectEqual(Vec2{ .x = 1.2, .y = 3.4 }, two);

        const three = try fromSlice(Vec3, .{
            .gpa = gpa,
            .source = ".{.x = 1.2, .y = 3.4, .z = 5.6}",
            .diag = null,
        });
        try std.testing.expectEqual(Vec3{ .x = 1.2, .y = 3.4, .z = 5.6 }, three);
    }

    // Deep free (structs and arrays)
    {
        const Foo = struct { bar: []const u8, baz: []const []const u8 };

        const parsed = try fromSliceAlloc(Foo, .{
            .gpa = gpa,
            .source = ".{.bar = \"qux\", .baz = .{\"a\", \"b\"}}",
            .diag = null,
        });
        defer free(gpa, parsed);
        try std.testing.expectEqualDeep(Foo{ .bar = "qux", .baz = &.{ "a", "b" } }, parsed);
    }

    // Unknown field
    {
        const Vec2 = struct { x: f32, y: f32 };
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSlice(Vec2, .{ .gpa = gpa, .source = ".{.x=1.5, .z=2.5}", .diag = &diag }),
        );
        try std.testing.expectFmt(
            \\1:12: error: unexpected field 'z'
            \\1:12: note: supported: 'x', 'y'
            \\
        ,
            "{f}",
            .{diag},
        );
    }

    // Duplicate field
    {
        const Vec2 = struct { x: f32, y: f32 };
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSlice(Vec2, .{ .gpa = gpa, .source = ".{.x=1.5, .x=2.5, .x=3.5}", .diag = &diag }),
        );
        try std.testing.expectFmt(
            \\1:4: error: duplicate struct field name
            \\1:12: note: duplicate name here
            \\
        , "{f}", .{diag});
    }

    // Ignore unknown fields
    {
        const Vec2 = struct { x: f32, y: f32 = 2.0 };
        const parsed = try fromSlice(Vec2, .{
            .gpa = gpa,
            .source = ".{ .x = 1.0, .z = 3.0 }",
            .ignore_unknown_fields = true,
            .diag = null,
        });
        try std.testing.expectEqual(Vec2{ .x = 1.0, .y = 2.0 }, parsed);
    }

    // Unknown field when struct has no fields (regression test)
    {
        const Vec2 = struct {};
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSlice(Vec2, .{ .gpa = gpa, .source = ".{.x=1.5, .z=2.5}", .diag = &diag }),
        );
        try std.testing.expectFmt(
            \\1:4: error: unexpected field 'x'
            \\1:4: note: none expected
            \\
        , "{f}", .{diag});
    }

    // Missing field
    {
        const Vec2 = struct { x: f32, y: f32 };
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSlice(Vec2, .{ .gpa = gpa, .source = ".{.x=1.5}", .diag = &diag }),
        );
        try std.testing.expectFmt("1:2: error: missing required field y\n", "{f}", .{diag});
    }

    // Default field
    {
        const Vec2 = struct { x: f32, y: f32 = 1.5 };
        const parsed = try fromSlice(Vec2, .{ .gpa = gpa, .source = ".{.x = 1.2}", .diag = null });
        try std.testing.expectEqual(Vec2{ .x = 1.2, .y = 1.5 }, parsed);
    }

    // Comptime field
    {
        const Vec2 = struct { x: f32, comptime y: f32 = 1.5 };
        const parsed = try fromSlice(Vec2, .{ .gpa = gpa, .source = ".{.x = 1.2}", .diag = null });
        try std.testing.expectEqual(Vec2{ .x = 1.2, .y = 1.5 }, parsed);
    }

    // Comptime field assignment
    {
        const Vec2 = struct { x: f32, comptime y: f32 = 1.5 };
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        const parsed = fromSlice(Vec2, .{
            .gpa = gpa,
            .source = ".{.x = 1.2, .y = 1.5}",
            .diag = &diag,
        });
        try std.testing.expectError(error.ParseZon, parsed);
        try std.testing.expectFmt(
            \\1:18: error: cannot initialize comptime field
            \\
        , "{f}", .{diag});
    }

    // Enum field (regression test, we were previously getting the field name in an
    // incorrect way that broke for enum values)
    {
        const Vec0 = struct { x: enum { x } };
        const parsed = try fromSlice(Vec0, .{
            .gpa = gpa,
            .source = ".{ .x = .x }",
            .diag = null,
        });
        try std.testing.expectEqual(Vec0{ .x = .x }, parsed);
    }

    // Enum field and struct field with @
    {
        const Vec0 = struct { @"x x": enum { @"x x" } };
        const parsed = try fromSlice(Vec0, .{
            .gpa = gpa,
            .source = ".{ .@\"x x\" = .@\"x x\" }",
            .diag = null,
        });
        try std.testing.expectEqual(Vec0{ .@"x x" = .@"x x" }, parsed);
    }

    // Type expressions are not allowed
    {
        // Structs
        {
            var diag: Diagnostics = .{};
            defer diag.deinit(gpa);
            const parsed = fromSlice(struct {}, .{
                .gpa = gpa,
                .source = "Empty{}",
                .diag = &diag,
            });
            try std.testing.expectError(error.ParseZon, parsed);
            try std.testing.expectFmt(
                \\1:1: error: types are not available in ZON
                \\1:1: note: replace the type with '.'
                \\
            , "{f}", .{diag});
        }

        // Arrays
        {
            var diag: Diagnostics = .{};
            defer diag.deinit(gpa);
            const parsed = fromSlice([3]u8, .{
                .gpa = gpa,
                .source = "[3]u8{1, 2, 3}",
                .diag = &diag,
            });
            try std.testing.expectError(error.ParseZon, parsed);
            try std.testing.expectFmt(
                \\1:1: error: types are not available in ZON
                \\1:1: note: replace the type with '.'
                \\
            , "{f}", .{diag});
        }

        // Slices
        {
            var diag: Diagnostics = .{};
            defer diag.deinit(gpa);
            const parsed = fromSliceAlloc([]u8, .{
                .gpa = gpa,
                .source = "[]u8{1, 2, 3}",
                .diag = &diag,
            });
            try std.testing.expectError(error.ParseZon, parsed);
            try std.testing.expectFmt(
                \\1:1: error: types are not available in ZON
                \\1:1: note: replace the type with '.'
                \\
            , "{f}", .{diag});
        }

        // Tuples
        {
            var diag: Diagnostics = .{};
            defer diag.deinit(gpa);
            const parsed = fromSlice(struct { u8, u8, u8 }, .{
                .gpa = gpa,
                .source = "Tuple{1, 2, 3}",
                .diag = &diag,
            });
            try std.testing.expectError(error.ParseZon, parsed);
            try std.testing.expectFmt(
                \\1:1: error: types are not available in ZON
                \\1:1: note: replace the type with '.'
                \\
            , "{f}", .{diag});
        }

        // Nested
        {
            var diag: Diagnostics = .{};
            defer diag.deinit(gpa);
            const parsed = fromSlice(struct {}, .{
                .gpa = gpa,
                .source = ".{ .x = Tuple{1, 2, 3} }",
                .diag = &diag,
            });
            try std.testing.expectError(error.ParseZon, parsed);
            try std.testing.expectFmt(
                \\1:9: error: types are not available in ZON
                \\1:9: note: replace the type with '.'
                \\
            , "{f}", .{diag});
        }
    }
}

test "std.zon tuples" {
    const gpa = std.testing.allocator;

    // Structs (various sizes tested since they're parsed differently)
    {
        const Tuple0 = struct {};
        const Tuple1 = struct { f32 };
        const Tuple2 = struct { f32, bool };
        const Tuple3 = struct { f32, bool, u8 };

        const zero = try fromSlice(Tuple0, .{
            .gpa = gpa,
            .source = ".{}",
            .diag = null,
        });
        try std.testing.expectEqual(Tuple0{}, zero);

        const one = try fromSlice(Tuple1, .{
            .gpa = gpa,
            .source = ".{1.2}",
            .diag = null,
        });
        try std.testing.expectEqual(Tuple1{1.2}, one);

        const two = try fromSlice(Tuple2, .{
            .gpa = gpa,
            .source = ".{1.2, true}",
            .diag = null,
        });
        try std.testing.expectEqual(Tuple2{ 1.2, true }, two);

        const three = try fromSlice(Tuple3, .{
            .gpa = gpa,
            .source = ".{1.2, false, 3}",
            .diag = null,
        });
        try std.testing.expectEqual(Tuple3{ 1.2, false, 3 }, three);
    }

    // Deep free
    {
        const Tuple = struct { []const u8, []const u8 };
        const parsed = try fromSliceAlloc(Tuple, .{
            .gpa = gpa,
            .source = ".{\"hello\", \"world\"}",
            .diag = null,
        });
        defer free(gpa, parsed);
        try std.testing.expectEqualDeep(Tuple{ "hello", "world" }, parsed);
    }

    // Extra field
    {
        const Tuple = struct { f32, bool };
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSlice(Tuple, .{ .gpa = gpa, .source = ".{0.5, true, 123}", .diag = &diag }),
        );
        try std.testing.expectFmt("1:14: error: index 2 outside of tuple length 2\n", "{f}", .{diag});
    }

    // Extra field
    {
        const Tuple = struct { f32, bool };
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSlice(Tuple, .{ .gpa = gpa, .source = ".{0.5}", .diag = &diag }),
        );
        try std.testing.expectFmt(
            "1:2: error: missing tuple field with index 1\n",
            "{f}",
            .{diag},
        );
    }

    // Tuple with unexpected field names
    {
        const Tuple = struct { f32 };
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSlice(Tuple, .{ .gpa = gpa, .source = ".{.foo = 10.0}", .diag = &diag }),
        );
        try std.testing.expectFmt("1:2: error: expected tuple\n", "{f}", .{diag});
    }

    // Struct with missing field names
    {
        const Struct = struct { foo: f32 };
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSlice(Struct, .{ .gpa = gpa, .source = ".{10.0}", .diag = &diag }),
        );
        try std.testing.expectFmt("1:2: error: expected struct\n", "{f}", .{diag});
    }

    // Comptime field
    {
        const Vec2 = struct { f32, comptime f32 = 1.5 };
        const parsed = try fromSlice(Vec2, .{ .gpa = gpa, .source = ".{ 1.2 }", .diag = null });
        try std.testing.expectEqual(Vec2{ 1.2, 1.5 }, parsed);
    }

    // Comptime field assignment
    {
        const Vec2 = struct { f32, comptime f32 = 1.5 };
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        const parsed = fromSlice(Vec2, .{ .gpa = gpa, .source = ".{ 1.2, 1.5}", .diag = &diag });
        try std.testing.expectError(error.ParseZon, parsed);
        try std.testing.expectFmt(
            \\1:9: error: cannot initialize comptime field
            \\
        , "{f}", .{diag});
    }
}

// Test sizes 0 to 3 since small sizes get parsed differently
test "std.zon arrays and slices" {
    const gpa = std.testing.allocator;

    // Literals
    {
        // Arrays
        {
            const zero = try fromSlice([0]u8, .{
                .gpa = gpa,
                .source = ".{}",
                .diag = null,
            });
            try std.testing.expectEqualSlices(u8, &@as([0]u8, .{}), &zero);

            const one = try fromSlice([1]u8, .{
                .gpa = gpa,
                .source = ".{'a'}",
                .diag = null,
            });
            try std.testing.expectEqualSlices(u8, &@as([1]u8, .{'a'}), &one);

            const two = try fromSlice([2]u8, .{
                .gpa = gpa,
                .source = ".{'a', 'b'}",
                .diag = null,
            });
            try std.testing.expectEqualSlices(u8, &@as([2]u8, .{ 'a', 'b' }), &two);

            const two_comma = try fromSlice([2]u8, .{
                .gpa = gpa,
                .source = ".{'a', 'b',}",
                .diag = null,
            });
            try std.testing.expectEqualSlices(u8, &@as([2]u8, .{ 'a', 'b' }), &two_comma);

            const three = try fromSlice([3]u8, .{
                .gpa = gpa,
                .source = ".{'a', 'b', 'c'}",
                .diag = null,
            });
            try std.testing.expectEqualSlices(u8, &.{ 'a', 'b', 'c' }, &three);

            const sentinel = try fromSlice([3:'z']u8, .{
                .gpa = gpa,
                .source = ".{'a', 'b', 'c'}",
                .diag = null,
            });
            const expected_sentinel: [3:'z']u8 = .{ 'a', 'b', 'c' };
            try std.testing.expectEqualSlices(u8, &expected_sentinel, &sentinel);
        }

        // Slice literals
        {
            const zero = try fromSliceAlloc([]const u8, .{
                .gpa = gpa,
                .source = ".{}",
                .diag = null,
            });
            defer free(gpa, zero);
            try std.testing.expectEqualSlices(u8, @as([]const u8, &.{}), zero);

            const one = try fromSliceAlloc([]u8, .{
                .gpa = gpa,
                .source = ".{'a'}",
                .diag = null,
            });
            defer free(gpa, one);
            try std.testing.expectEqualSlices(u8, &.{'a'}, one);

            const two = try fromSliceAlloc([]const u8, .{
                .gpa = gpa,
                .source = ".{'a', 'b'}",
                .diag = null,
            });
            defer free(gpa, two);
            try std.testing.expectEqualSlices(u8, &.{ 'a', 'b' }, two);

            const two_comma = try fromSliceAlloc([]const u8, .{
                .gpa = gpa,
                .source = ".{'a', 'b',}",
                .diag = null,
            });
            defer free(gpa, two_comma);
            try std.testing.expectEqualSlices(u8, &.{ 'a', 'b' }, two_comma);

            const three = try fromSliceAlloc([]u8, .{
                .gpa = gpa,
                .source = ".{'a', 'b', 'c'}",
                .diag = null,
            });
            defer free(gpa, three);
            try std.testing.expectEqualSlices(u8, &.{ 'a', 'b', 'c' }, three);

            const sentinel = try fromSliceAlloc([:'z']const u8, .{
                .gpa = gpa,
                .source = ".{'a', 'b', 'c'}",
                .diag = null,
            });
            defer free(gpa, sentinel);
            const expected_sentinel: [:'z']const u8 = &.{ 'a', 'b', 'c' };
            try std.testing.expectEqualSlices(u8, expected_sentinel, sentinel);
        }
    }

    // Deep free
    {
        // Arrays
        {
            const parsed = try fromSliceAlloc([1][]const u8, .{
                .gpa = gpa,
                .source = ".{\"abc\"}",
                .diag = null,
            });
            defer free(gpa, parsed);
            const expected: [1][]const u8 = .{"abc"};
            try std.testing.expectEqualDeep(expected, parsed);
        }

        // Slice literals
        {
            const parsed = try fromSliceAlloc([]const []const u8, .{
                .gpa = gpa,
                .source = ".{\"abc\"}",
                .diag = null,
            });
            defer free(gpa, parsed);
            const expected: []const []const u8 = &.{"abc"};
            try std.testing.expectEqualDeep(expected, parsed);
        }
    }

    // Sentinels and alignment
    {
        // Arrays
        {
            const sentinel = try fromSlice([1:2]u8, .{
                .gpa = gpa,
                .source = ".{1}",
                .diag = null,
            });
            try std.testing.expectEqual(@as(usize, 1), sentinel.len);
            try std.testing.expectEqual(@as(u8, 1), sentinel[0]);
            try std.testing.expectEqual(@as(u8, 2), sentinel[1]);
        }

        // Slice literals
        {
            const sentinel = try fromSliceAlloc([:2]align(4) u8, .{
                .gpa = gpa,
                .source = ".{1}",
                .diag = null,
            });
            defer free(gpa, sentinel);
            try std.testing.expectEqual(@as(usize, 1), sentinel.len);
            try std.testing.expectEqual(@as(u8, 1), sentinel[0]);
            try std.testing.expectEqual(@as(u8, 2), sentinel[1]);
        }
    }

    // Expect 0 find 3
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSlice([0]u8, .{ .gpa = gpa, .source = ".{'a', 'b', 'c'}", .diag = &diag }),
        );
        try std.testing.expectFmt(
            "1:3: error: index 0 outside of array of length 0\n",
            "{f}",
            .{diag},
        );
    }

    // Expect 1 find 2
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSlice([1]u8, .{ .gpa = gpa, .source = ".{'a', 'b'}", .diag = &diag }),
        );
        try std.testing.expectFmt(
            "1:8: error: index 1 outside of array of length 1\n",
            "{f}",
            .{diag},
        );
    }

    // Expect 2 find 1
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSlice([2]u8, .{ .gpa = gpa, .source = ".{'a'}", .diag = &diag }),
        );
        try std.testing.expectFmt(
            "1:2: error: expected 2 array elements; found 1\n",
            "{f}",
            .{diag},
        );
    }

    // Expect 3 find 0
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSlice([3]u8, .{ .gpa = gpa, .source = ".{}", .diag = &diag }),
        );
        try std.testing.expectFmt(
            "1:2: error: expected 3 array elements; found 0\n",
            "{f}",
            .{diag},
        );
    }

    // Wrong inner type
    {
        // Array
        {
            var diag: Diagnostics = .{};
            defer diag.deinit(gpa);
            try std.testing.expectError(
                error.ParseZon,
                fromSlice([3]bool, .{ .gpa = gpa, .source = ".{'a', 'b', 'c'}", .diag = &diag }),
            );
            try std.testing.expectFmt("1:3: error: expected type 'bool'\n", "{f}", .{diag});
        }

        // Slice
        {
            var diag: Diagnostics = .{};
            defer diag.deinit(gpa);
            try std.testing.expectError(
                error.ParseZon,
                fromSliceAlloc([]bool, .{
                    .gpa = gpa,
                    .source = ".{'a', 'b', 'c'}",
                    .diag = &diag,
                }),
            );
            try std.testing.expectFmt("1:3: error: expected type 'bool'\n", "{f}", .{diag});
        }
    }

    // Complete wrong type
    {
        // Array
        {
            var diag: Diagnostics = .{};
            defer diag.deinit(gpa);
            try std.testing.expectError(
                error.ParseZon,
                fromSlice([3]u8, .{ .gpa = gpa, .source = "'a'", .diag = &diag }),
            );
            try std.testing.expectFmt("1:1: error: expected array\n", "{f}", .{diag});
        }

        // Slice
        {
            var diag: Diagnostics = .{};
            defer diag.deinit(gpa);
            try std.testing.expectError(
                error.ParseZon,
                fromSliceAlloc([]u8, .{ .gpa = gpa, .source = "'a'", .diag = &diag }),
            );
            try std.testing.expectFmt("1:1: error: expected array\n", "{f}", .{diag});
        }
    }

    // Address of is not allowed (indirection for slices in ZON is implicit)
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSliceAlloc([]u8, .{ .gpa = gpa, .source = "  &.{'a', 'b', 'c'}", .diag = &diag }),
        );
        try std.testing.expectFmt(
            "1:3: error: pointers are not available in ZON\n",
            "{f}",
            .{diag},
        );
    }
}

test "std.zon string literal" {
    const gpa = std.testing.allocator;

    // Basic string literal
    {
        const parsed = try fromSliceAlloc([]const u8, .{
            .gpa = gpa,
            .source = "\"abc\"",
            .diag = null,
        });
        defer free(gpa, parsed);
        try std.testing.expectEqualStrings(@as([]const u8, "abc"), parsed);
    }

    // String literal with escape characters
    {
        const parsed = try fromSliceAlloc([]const u8, .{
            .gpa = gpa,
            .source = "\"ab\\nc\"",
            .diag = null,
        });
        defer free(gpa, parsed);
        try std.testing.expectEqualStrings(@as([]const u8, "ab\nc"), parsed);
    }

    // String literal with embedded null
    {
        const parsed = try fromSliceAlloc([]const u8, .{
            .gpa = gpa,
            .source = "\"ab\\x00c\"",
            .diag = null,
        });
        defer free(gpa, parsed);
        try std.testing.expectEqualStrings(@as([]const u8, "ab\x00c"), parsed);
    }

    // Passing string literal to a mutable slice
    {
        {
            var diag: Diagnostics = .{};
            defer diag.deinit(gpa);
            try std.testing.expectError(
                error.ParseZon,
                fromSliceAlloc([]u8, .{ .gpa = gpa, .source = "\"abcd\"", .diag = &diag }),
            );
            try std.testing.expectFmt("1:1: error: expected array\n", "{f}", .{diag});
        }

        {
            var diag: Diagnostics = .{};
            defer diag.deinit(gpa);
            try std.testing.expectError(
                error.ParseZon,
                fromSliceAlloc([]u8, .{ .gpa = gpa, .source = "\\\\abcd", .diag = &diag }),
            );
            try std.testing.expectFmt("1:1: error: expected array\n", "{f}", .{diag});
        }
    }

    // Passing string literal to a array
    {
        {
            var ast = try std.zig.Ast.parse(gpa, "\"abcd\"", .{ .mode = .zon });
            defer ast.deinit(gpa);
            var zoir = try ZonGen.generate(gpa, ast, .{ .parse_str_lits = false });
            defer zoir.deinit(gpa);
            var diag: Diagnostics = .{};
            defer diag.deinit(gpa);
            try std.testing.expectError(
                error.ParseZon,
                fromSlice([4:0]u8, .{ .gpa = gpa, .source = "\"abcd\"", .diag = &diag }),
            );
            try std.testing.expectFmt("1:1: error: expected array\n", "{f}", .{diag});
        }

        {
            var diag: Diagnostics = .{};
            defer diag.deinit(gpa);
            try std.testing.expectError(
                error.ParseZon,
                fromSlice([4:0]u8, .{ .gpa = gpa, .source = "\\\\abcd", .diag = &diag }),
            );
            try std.testing.expectFmt("1:1: error: expected array\n", "{f}", .{diag});
        }
    }

    // Zero terminated slices
    {
        {
            const parsed: [:0]const u8 = try fromSliceAlloc([:0]const u8, .{
                .gpa = gpa,
                .source = "\"abc\"",
                .diag = null,
            });
            defer free(gpa, parsed);
            try std.testing.expectEqualStrings("abc", parsed);
            try std.testing.expectEqual(@as(u8, 0), parsed[3]);
        }

        {
            const parsed: [:0]const u8 = try fromSliceAlloc([:0]const u8, .{
                .gpa = gpa,
                .source = "\\\\abc",
                .diag = null,
            });
            defer free(gpa, parsed);
            try std.testing.expectEqualStrings("abc", parsed);
            try std.testing.expectEqual(@as(u8, 0), parsed[3]);
        }
    }

    // Other value terminated slices
    {
        {
            var diag: Diagnostics = .{};
            defer diag.deinit(gpa);
            try std.testing.expectError(
                error.ParseZon,
                fromSliceAlloc([:1]const u8, .{ .gpa = gpa, .source = "\"foo\"", .diag = &diag }),
            );
            try std.testing.expectFmt("1:1: error: expected array\n", "{f}", .{diag});
        }

        {
            var diag: Diagnostics = .{};
            defer diag.deinit(gpa);
            try std.testing.expectError(
                error.ParseZon,
                fromSliceAlloc([:1]const u8, .{ .gpa = gpa, .source = "\\\\foo", .diag = &diag }),
            );
            try std.testing.expectFmt("1:1: error: expected array\n", "{f}", .{diag});
        }
    }

    // Expecting string literal, getting something else
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSliceAlloc([]const u8, .{ .gpa = gpa, .source = "true", .diag = &diag }),
        );
        try std.testing.expectFmt("1:1: error: expected string\n", "{f}", .{diag});
    }

    // Expecting string literal, getting an incompatible tuple
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSliceAlloc([]const u8, .{ .gpa = gpa, .source = ".{false}", .diag = &diag }),
        );
        try std.testing.expectFmt("1:3: error: expected type 'u8'\n", "{f}", .{diag});
    }

    // Invalid string literal
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSliceAlloc([]const i8, .{ .gpa = gpa, .source = "\"\\a\"", .diag = &diag }),
        );
        try std.testing.expectFmt("1:3: error: invalid escape character: 'a'\n", "{f}", .{diag});
    }

    // Slice wrong child type
    {
        {
            var diag: Diagnostics = .{};
            defer diag.deinit(gpa);
            try std.testing.expectError(
                error.ParseZon,
                fromSliceAlloc([]const i8, .{ .gpa = gpa, .source = "\"a\"", .diag = &diag }),
            );
            try std.testing.expectFmt("1:1: error: expected array\n", "{f}", .{diag});
        }

        {
            var diag: Diagnostics = .{};
            defer diag.deinit(gpa);
            try std.testing.expectError(
                error.ParseZon,
                fromSliceAlloc([]const i8, .{ .gpa = gpa, .source = "\\\\a", .diag = &diag }),
            );
            try std.testing.expectFmt("1:1: error: expected array\n", "{f}", .{diag});
        }
    }

    // Bad alignment
    {
        {
            var diag: Diagnostics = .{};
            defer diag.deinit(gpa);
            try std.testing.expectError(
                error.ParseZon,
                fromSliceAlloc([]align(2) const u8, .{
                    .gpa = gpa,
                    .source = "\"abc\"",
                    .diag = &diag,
                }),
            );
            try std.testing.expectFmt("1:1: error: expected array\n", "{f}", .{diag});
        }

        {
            var diag: Diagnostics = .{};
            defer diag.deinit(gpa);
            try std.testing.expectError(
                error.ParseZon,
                fromSliceAlloc([]align(2) const u8, .{
                    .gpa = gpa,
                    .source = "\\\\abc",
                    .diag = &diag,
                }),
            );
            try std.testing.expectFmt("1:1: error: expected array\n", "{f}", .{diag});
        }
    }

    // Multi line strings
    inline for (.{ []const u8, [:0]const u8 }) |String| {
        // Nested
        {
            const S = struct {
                message: String,
                message2: String,
                message3: String,
            };
            const parsed = try fromSliceAlloc(S, .{
                .gpa = gpa,
                .source =
                \\.{
                \\    .message =
                \\        \\hello, world!
                \\
                \\        \\this is a multiline string!
                \\        \\
                \\        \\...
                \\
                \\    ,
                \\    .message2 =
                \\        \\this too...sort of.
                \\    ,
                \\    .message3 =
                \\        \\
                \\        \\and this.
                \\}
                ,
                .diag = null,
            });
            defer free(gpa, parsed);
            try std.testing.expectEqualStrings(
                "hello, world!\nthis is a multiline string!\n\n...",
                parsed.message,
            );
            try std.testing.expectEqualStrings("this too...sort of.", parsed.message2);
            try std.testing.expectEqualStrings("\nand this.", parsed.message3);
        }
    }
}

test "std.zon enum literals" {
    const gpa = std.testing.allocator;

    const Enum = enum {
        foo,
        bar,
        baz,
        @"ab\nc",
    };

    // Tags that exist
    try std.testing.expectEqual(Enum.foo, try fromSlice(Enum, .{
        .gpa = gpa,
        .source = ".foo",
        .diag = null,
    }));
    try std.testing.expectEqual(Enum.bar, try fromSlice(Enum, .{
        .gpa = gpa,
        .source = ".bar",
        .diag = null,
    }));
    try std.testing.expectEqual(Enum.baz, try fromSlice(Enum, .{
        .gpa = gpa,
        .source = ".baz",
        .diag = null,
    }));
    try std.testing.expectEqual(
        Enum.@"ab\nc",
        try fromSlice(Enum, .{ .gpa = gpa, .source = ".@\"ab\\nc\"", .diag = null }),
    );

    // Bad tag
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSlice(Enum, .{ .gpa = gpa, .source = ".qux", .diag = &diag }),
        );
        try std.testing.expectFmt(
            \\1:2: error: unexpected enum literal 'qux'
            \\1:2: note: supported: 'foo', 'bar', 'baz', '@"ab\nc"'
            \\
        ,
            "{f}",
            .{diag},
        );
    }

    // Bad tag that's too long for parser
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSlice(Enum, .{ .gpa = gpa, .source = ".@\"foobarbaz\"", .diag = &diag }),
        );
        try std.testing.expectFmt(
            \\1:2: error: unexpected enum literal 'foobarbaz'
            \\1:2: note: supported: 'foo', 'bar', 'baz', '@"ab\nc"'
            \\
        ,
            "{f}",
            .{diag},
        );
    }

    // Bad type
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSlice(Enum, .{ .gpa = gpa, .source = "true", .diag = &diag }),
        );
        try std.testing.expectFmt("1:1: error: expected enum literal\n", "{f}", .{diag});
    }

    // Test embedded nulls in an identifier
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSlice(Enum, .{ .gpa = gpa, .source = ".@\"\\x00\"", .diag = &diag }),
        );
        try std.testing.expectFmt(
            "1:2: error: identifier cannot contain null bytes\n",
            "{f}",
            .{diag},
        );
    }
}

test "std.zon parse bool" {
    const gpa = std.testing.allocator;

    // Correct bools
    try std.testing.expectEqual(true, try fromSlice(bool, .{
        .gpa = gpa,
        .source = "true",
        .diag = null,
    }));
    try std.testing.expectEqual(false, try fromSlice(bool, .{
        .gpa = gpa,
        .source = "false",
        .diag = null,
    }));

    // Errors
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSlice(bool, .{ .gpa = gpa, .source = " foo", .diag = &diag }),
        );
        try std.testing.expectFmt(
            \\1:2: error: invalid expression
            \\1:2: note: ZON allows identifiers 'true', 'false', 'null', 'inf', and 'nan'
            \\1:2: note: precede identifier with '.' for an enum literal
            \\
        , "{f}", .{diag});
    }
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(error.ParseZon, fromSlice(bool, .{
            .gpa = gpa,
            .source = "123",
            .diag = &diag,
        }));
        try std.testing.expectFmt("1:1: error: expected type 'bool'\n", "{f}", .{diag});
    }
}

test "std.zon intFromFloatExact" {
    // Valid conversions
    try std.testing.expectEqual(@as(u8, 10), intFromFloatExact(u8, @as(f32, 10.0)).?);
    try std.testing.expectEqual(@as(i8, -123), intFromFloatExact(i8, @as(f64, @as(f64, -123.0))).?);
    try std.testing.expectEqual(@as(i16, 45), intFromFloatExact(i16, @as(f128, @as(f128, 45.0))).?);
    try std.testing.expectEqual(@as(u128, 67), intFromFloatExact(u128, @as(f128, @as(f128, 67.0))).?);

    // Out of range
    try std.testing.expectEqual(@as(?u4, null), intFromFloatExact(u4, @as(f32, 16.0)));
    try std.testing.expectEqual(@as(?i4, null), intFromFloatExact(i4, @as(f64, -17.0)));
    try std.testing.expectEqual(@as(?u8, null), intFromFloatExact(u8, @as(f128, -2.0)));

    // Not a whole number
    try std.testing.expectEqual(@as(?u8, null), intFromFloatExact(u8, @as(f32, 0.5)));
    try std.testing.expectEqual(@as(?i8, null), intFromFloatExact(i8, @as(f64, 0.01)));

    // Infinity and NaN
    try std.testing.expectEqual(@as(?u8, null), intFromFloatExact(u8, std.math.inf(f32)));
    try std.testing.expectEqual(@as(?u8, null), intFromFloatExact(u8, -std.math.inf(f32)));
    try std.testing.expectEqual(@as(?u8, null), intFromFloatExact(u8, std.math.nan(f32)));
}

test "std.zon parse int" {
    const gpa = std.testing.allocator;

    // Test various numbers and types
    try std.testing.expectEqual(@as(u8, 10), try fromSlice(u8, .{
        .gpa = gpa,
        .source = "10",
        .diag = null,
    }));
    try std.testing.expectEqual(@as(i16, 24), try fromSlice(i16, .{
        .gpa = gpa,
        .source = "24",
        .diag = null,
    }));
    try std.testing.expectEqual(@as(i14, -4), try fromSlice(i14, .{
        .gpa = gpa,
        .source = "-4",
        .diag = null,
    }));
    try std.testing.expectEqual(@as(i32, -123), try fromSlice(i32, .{
        .gpa = gpa,
        .source = "-123",
        .diag = null,
    }));

    // Test limits
    try std.testing.expectEqual(@as(i8, 127), try fromSlice(i8, .{
        .gpa = gpa,
        .source = "127",
        .diag = null,
    }));
    try std.testing.expectEqual(@as(i8, -128), try fromSlice(i8, .{
        .gpa = gpa,
        .source = "-128",
        .diag = null,
    }));

    // Test characters
    try std.testing.expectEqual(@as(u8, 'a'), try fromSlice(u8, .{
        .gpa = gpa,
        .source = "'a'",
        .diag = null,
    }));
    try std.testing.expectEqual(@as(u8, 'z'), try fromSlice(u8, .{
        .gpa = gpa,
        .source = "'z'",
        .diag = null,
    }));

    // Test big integers
    try std.testing.expectEqual(
        @as(u65, 36893488147419103231),
        try fromSlice(u65, .{
            .gpa = gpa,
            .source = "36893488147419103231",
            .diag = null,
        }),
    );
    try std.testing.expectEqual(
        @as(u65, 36893488147419103231),
        try fromSlice(u65, .{
            .gpa = gpa,
            .source = "368934_881_474191032_31",
            .diag = null,
        }),
    );
    try std.testing.expectEqual(
        @as(u128, 340282366920938463463374607431768211455),
        try fromSlice(u128, .{
            .gpa = gpa,
            .source = "340282366920938463463374607431768211455",
            .diag = null,
        }),
    );

    // Test big integer limits
    try std.testing.expectEqual(
        @as(i66, 36893488147419103231),
        try fromSlice(i66, .{
            .gpa = gpa,
            .source = "36893488147419103231",
            .diag = null,
        }),
    );
    try std.testing.expectEqual(
        @as(i66, -36893488147419103232),
        try fromSlice(i66, .{
            .gpa = gpa,
            .source = "-36893488147419103232",
            .diag = null,
        }),
    );
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(error.ParseZon, fromSlice(i66, .{
            .gpa = gpa,
            .source = "36893488147419103232",
            .diag = &diag,
        }));
        try std.testing.expectFmt(
            "1:1: error: type 'i66' cannot represent value\n",
            "{f}",
            .{diag},
        );
    }
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(error.ParseZon, fromSlice(i66, .{
            .gpa = gpa,
            .source = "-36893488147419103233",
            .diag = &diag,
        }));
        try std.testing.expectFmt(
            "1:1: error: type 'i66' cannot represent value\n",
            "{f}",
            .{diag},
        );
    }

    // Test parsing whole number floats as integers
    try std.testing.expectEqual(@as(i8, -1), try fromSlice(i8, .{
        .gpa = gpa,
        .source = "-1.0",
        .diag = null,
    }));
    try std.testing.expectEqual(@as(i8, 123), try fromSlice(i8, .{
        .gpa = gpa,
        .source = "123.0",
        .diag = null,
    }));

    // Test non-decimal integers
    try std.testing.expectEqual(@as(i16, 0xff), try fromSlice(i16, .{
        .gpa = gpa,
        .source = "0xff",
        .diag = null,
    }));
    try std.testing.expectEqual(@as(i16, -0xff), try fromSlice(i16, .{
        .gpa = gpa,
        .source = "-0xff",
        .diag = null,
    }));
    try std.testing.expectEqual(@as(i16, 0o77), try fromSlice(i16, .{
        .gpa = gpa,
        .source = "0o77",
        .diag = null,
    }));
    try std.testing.expectEqual(@as(i16, -0o77), try fromSlice(i16, .{
        .gpa = gpa,
        .source = "-0o77",
        .diag = null,
    }));
    try std.testing.expectEqual(@as(i16, 0b11), try fromSlice(i16, .{
        .gpa = gpa,
        .source = "0b11",
        .diag = null,
    }));
    try std.testing.expectEqual(@as(i16, -0b11), try fromSlice(i16, .{
        .gpa = gpa,
        .source = "-0b11",
        .diag = null,
    }));

    // Test non-decimal big integers
    try std.testing.expectEqual(@as(u65, 0x1ffffffffffffffff), try fromSlice(u65, .{
        .gpa = gpa,
        .source = "0x1ffffffffffffffff",
        .diag = null,
    }));
    try std.testing.expectEqual(@as(i66, 0x1ffffffffffffffff), try fromSlice(i66, .{
        .gpa = gpa,
        .source = "0x1ffffffffffffffff",
        .diag = null,
    }));
    try std.testing.expectEqual(@as(i66, -0x1ffffffffffffffff), try fromSlice(i66, .{
        .gpa = gpa,
        .source = "-0x1ffffffffffffffff",
        .diag = null,
    }));
    try std.testing.expectEqual(@as(u65, 0x1ffffffffffffffff), try fromSlice(u65, .{
        .gpa = gpa,
        .source = "0o3777777777777777777777",
        .diag = null,
    }));
    try std.testing.expectEqual(@as(i66, 0x1ffffffffffffffff), try fromSlice(i66, .{
        .gpa = gpa,
        .source = "0o3777777777777777777777",
        .diag = null,
    }));
    try std.testing.expectEqual(@as(i66, -0x1ffffffffffffffff), try fromSlice(i66, .{
        .gpa = gpa,
        .source = "-0o3777777777777777777777",
        .diag = null,
    }));
    try std.testing.expectEqual(@as(u65, 0x1ffffffffffffffff), try fromSlice(u65, .{
        .gpa = gpa,
        .source = "0b11111111111111111111111111111111111111111111111111111111111111111",
        .diag = null,
    }));
    try std.testing.expectEqual(@as(i66, 0x1ffffffffffffffff), try fromSlice(i66, .{
        .gpa = gpa,
        .source = "0b11111111111111111111111111111111111111111111111111111111111111111",
        .diag = null,
    }));
    try std.testing.expectEqual(@as(i66, -0x1ffffffffffffffff), try fromSlice(i66, .{
        .gpa = gpa,
        .source = "-0b11111111111111111111111111111111111111111111111111111111111111111",
        .diag = null,
    }));

    // Number with invalid character in the middle
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(error.ParseZon, fromSlice(u8, .{
            .gpa = gpa,
            .source = "32a32",
            .diag = &diag,
        }));
        try std.testing.expectFmt(
            "1:3: error: invalid digit 'a' for decimal base\n",
            "{f}",
            .{diag},
        );
    }

    // Failing to parse as int
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(error.ParseZon, fromSlice(u8, .{
            .gpa = gpa,
            .source = "true",
            .diag = &diag,
        }));
        try std.testing.expectFmt("1:1: error: expected type 'u8'\n", "{f}", .{diag});
    }

    // Failing because an int is out of range
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(error.ParseZon, fromSlice(u8, .{
            .gpa = gpa,
            .source = "256",
            .diag = &diag,
        }));
        try std.testing.expectFmt(
            "1:1: error: type 'u8' cannot represent value\n",
            "{f}",
            .{diag},
        );
    }

    // Failing because a negative int is out of range
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(error.ParseZon, fromSlice(i8, .{
            .gpa = gpa,
            .source = "-129",
            .diag = &diag,
        }));
        try std.testing.expectFmt(
            "1:1: error: type 'i8' cannot represent value\n",
            "{f}",
            .{diag},
        );
    }

    // Failing because an unsigned int is negative
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(error.ParseZon, fromSlice(u8, .{
            .gpa = gpa,
            .source = "-1",
            .diag = &diag,
        }));
        try std.testing.expectFmt(
            "1:1: error: type 'u8' cannot represent value\n",
            "{f}",
            .{diag},
        );
    }

    // Failing because a float is non-whole
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(error.ParseZon, fromSlice(u8, .{
            .gpa = gpa,
            .source = "1.5",
            .diag = &diag,
        }));
        try std.testing.expectFmt(
            "1:1: error: type 'u8' cannot represent value\n",
            "{f}",
            .{diag},
        );
    }

    // Failing because a float is negative
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(error.ParseZon, fromSlice(u8, .{
            .gpa = gpa,
            .source = "-1.0",
            .diag = &diag,
        }));
        try std.testing.expectFmt(
            "1:1: error: type 'u8' cannot represent value\n",
            "{f}",
            .{diag},
        );
    }

    // Negative integer zero
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(error.ParseZon, fromSlice(i8, .{
            .gpa = gpa,
            .source = "-0",
            .diag = &diag,
        }));
        try std.testing.expectFmt(
            \\1:2: error: integer literal '-0' is ambiguous
            \\1:2: note: use '0' for an integer zero
            \\1:2: note: use '-0.0' for a floating-point signed zero
            \\
        , "{f}", .{diag});
    }

    // Negative integer zero casted to float
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(error.ParseZon, fromSlice(f32, .{
            .gpa = gpa,
            .source = "-0",
            .diag = &diag,
        }));
        try std.testing.expectFmt(
            \\1:2: error: integer literal '-0' is ambiguous
            \\1:2: note: use '0' for an integer zero
            \\1:2: note: use '-0.0' for a floating-point signed zero
            \\
        , "{f}", .{diag});
    }

    // Negative float 0 is allowed
    try std.testing.expect(
        std.math.isNegativeZero(try fromSlice(f32, .{
            .gpa = gpa,
            .source = "-0.0",
            .diag = null,
        })),
    );
    try std.testing.expect(std.math.isPositiveZero(try fromSlice(f32, .{
        .gpa = gpa,
        .source = "0.0",
        .diag = null,
    })));

    // Double negation is not allowed
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(error.ParseZon, fromSlice(i8, .{
            .gpa = gpa,
            .source = "--2",
            .diag = &diag,
        }));
        try std.testing.expectFmt(
            "1:1: error: expected number or 'inf' after '-'\n",
            "{f}",
            .{diag},
        );
    }

    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSlice(f32, .{ .gpa = gpa, .source = "--2.0", .diag = &diag }),
        );
        try std.testing.expectFmt(
            "1:1: error: expected number or 'inf' after '-'\n",
            "{f}",
            .{diag},
        );
    }

    // Invalid int literal
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(error.ParseZon, fromSlice(u8, .{
            .gpa = gpa,
            .source = "0xg",
            .diag = &diag,
        }));
        try std.testing.expectFmt("1:3: error: invalid digit 'g' for hex base\n", "{f}", .{diag});
    }

    // Notes on invalid int literal
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(error.ParseZon, fromSlice(u8, .{
            .gpa = gpa,
            .source = "0123",
            .diag = &diag,
        }));
        try std.testing.expectFmt(
            \\1:1: error: number '0123' has leading zero
            \\1:1: note: use '0o' prefix for octal literals
            \\
        , "{f}", .{diag});
    }
}

test "std.zon negative char" {
    const gpa = std.testing.allocator;

    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(error.ParseZon, fromSlice(f32, .{
            .gpa = gpa,
            .source = "-'a'",
            .diag = &diag,
        }));
        try std.testing.expectFmt(
            "1:1: error: expected number or 'inf' after '-'\n",
            "{f}",
            .{diag},
        );
    }
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(error.ParseZon, fromSlice(i16, .{
            .gpa = gpa,
            .source = "-'a'",
            .diag = &diag,
        }));
        try std.testing.expectFmt(
            "1:1: error: expected number or 'inf' after '-'\n",
            "{f}",
            .{diag},
        );
    }
}

test "std.zon parse float" {
    const gpa = std.testing.allocator;

    // Test decimals
    try std.testing.expectEqual(@as(f16, 0.5), try fromSlice(f16, .{
        .gpa = gpa,
        .source = "0.5",
        .diag = null,
    }));
    try std.testing.expectEqual(
        @as(f32, 123.456),
        try fromSlice(f32, .{ .gpa = gpa, .source = "123.456", .diag = null }),
    );
    try std.testing.expectEqual(
        @as(f64, -123.456),
        try fromSlice(f64, .{ .gpa = gpa, .source = "-123.456", .diag = null }),
    );
    try std.testing.expectEqual(@as(f128, 42.5), try fromSlice(f128, .{
        .gpa = gpa,
        .source = "42.5",
        .diag = null,
    }));

    // Test whole numbers with and without decimals
    try std.testing.expectEqual(@as(f16, 5.0), try fromSlice(f16, .{
        .gpa = gpa,
        .source = "5.0",
        .diag = null,
    }));
    try std.testing.expectEqual(@as(f16, 5.0), try fromSlice(f16, .{
        .gpa = gpa,
        .source = "5",
        .diag = null,
    }));
    try std.testing.expectEqual(@as(f32, -102), try fromSlice(f32, .{
        .gpa = gpa,
        .source = "-102.0",
        .diag = null,
    }));
    try std.testing.expectEqual(@as(f32, -102), try fromSlice(f32, .{
        .gpa = gpa,
        .source = "-102",
        .diag = null,
    }));

    // Test characters and negated characters
    try std.testing.expectEqual(@as(f32, 'a'), try fromSlice(f32, .{
        .gpa = gpa,
        .source = "'a'",
        .diag = null,
    }));
    try std.testing.expectEqual(@as(f32, 'z'), try fromSlice(f32, .{
        .gpa = gpa,
        .source = "'z'",
        .diag = null,
    }));

    // Test big integers
    try std.testing.expectEqual(
        @as(f32, 36893488147419103231.0),
        try fromSlice(f32, .{
            .gpa = gpa,
            .source = "36893488147419103231",
            .diag = null,
        }),
    );
    try std.testing.expectEqual(
        @as(f32, -36893488147419103231.0),
        try fromSlice(f32, .{
            .gpa = gpa,
            .source = "-36893488147419103231",
            .diag = null,
        }),
    );
    try std.testing.expectEqual(@as(f128, 0x1ffffffffffffffff), try fromSlice(f128, .{
        .gpa = gpa,
        .source = "0x1ffffffffffffffff",
        .diag = null,
    }));
    try std.testing.expectEqual(@as(f32, @floatFromInt(0x1ffffffffffffffff)), try fromSlice(f32, .{
        .gpa = gpa,
        .source = "0x1ffffffffffffffff",
        .diag = null,
    }));

    // Exponents, underscores
    try std.testing.expectEqual(
        @as(f32, 123.0E+77),
        try fromSlice(f32, .{
            .gpa = gpa,
            .source = "12_3.0E+77",
            .diag = null,
        }),
    );

    // Hexadecimal
    try std.testing.expectEqual(
        @as(f32, 0x103.70p-5),
        try fromSlice(f32, .{
            .gpa = gpa,
            .source = "0x103.70p-5",
            .diag = null,
        }),
    );
    try std.testing.expectEqual(
        @as(f32, -0x103.70),
        try fromSlice(f32, .{
            .gpa = gpa,
            .source = "-0x103.70",
            .diag = null,
        }),
    );
    try std.testing.expectEqual(
        @as(f32, 0x1234_5678.9ABC_CDEFp-10),
        try fromSlice(f32, .{
            .gpa = gpa,
            .source = "0x1234_5678.9ABC_CDEFp-10",
            .diag = null,
        }),
    );

    // inf, nan
    try std.testing.expect(std.math.isPositiveInf(try fromSlice(f32, .{
        .gpa = gpa,
        .source = "inf",
        .diag = null,
    })));
    try std.testing.expect(std.math.isNegativeInf(try fromSlice(f32, .{
        .gpa = gpa,
        .source = "-inf",
        .diag = null,
    })));
    try std.testing.expect(std.math.isNan(try fromSlice(f32, .{
        .gpa = gpa,
        .source = "nan",
        .diag = null,
    })));

    // Negative nan not allowed
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(error.ParseZon, fromSlice(f32, .{
            .gpa = gpa,
            .source = "-nan",
            .diag = &diag,
        }));
        try std.testing.expectFmt(
            "1:1: error: expected number or 'inf' after '-'\n",
            "{f}",
            .{diag},
        );
    }

    // nan as int not allowed
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(error.ParseZon, fromSlice(i8, .{
            .gpa = gpa,
            .source = "nan",
            .diag = &diag,
        }));
        try std.testing.expectFmt("1:1: error: expected type 'i8'\n", "{f}", .{diag});
    }

    // nan as int not allowed
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(error.ParseZon, fromSlice(i8, .{
            .gpa = gpa,
            .source = "nan",
            .diag = &diag,
        }));
        try std.testing.expectFmt("1:1: error: expected type 'i8'\n", "{f}", .{diag});
    }

    // inf as int not allowed
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(error.ParseZon, fromSlice(i8, .{
            .gpa = gpa,
            .source = "inf",
            .diag = &diag,
        }));
        try std.testing.expectFmt("1:1: error: expected type 'i8'\n", "{f}", .{diag});
    }

    // -inf as int not allowed
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(error.ParseZon, fromSlice(i8, .{
            .gpa = gpa,
            .source = "-inf",
            .diag = &diag,
        }));
        try std.testing.expectFmt("1:1: error: expected type 'i8'\n", "{f}", .{diag});
    }

    // Bad identifier as float
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(error.ParseZon, fromSlice(f32, .{
            .gpa = gpa,
            .source = "foo",
            .diag = &diag,
        }));
        try std.testing.expectFmt(
            \\1:1: error: invalid expression
            \\1:1: note: ZON allows identifiers 'true', 'false', 'null', 'inf', and 'nan'
            \\1:1: note: precede identifier with '.' for an enum literal
            \\
        , "{f}", .{diag});
    }

    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(error.ParseZon, fromSlice(f32, .{
            .gpa = gpa,
            .source = "-foo",
            .diag = &diag,
        }));
        try std.testing.expectFmt(
            "1:1: error: expected number or 'inf' after '-'\n",
            "{f}",
            .{diag},
        );
    }

    // Non float as float
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSlice(f32, .{ .gpa = gpa, .source = "\"foo\"", .diag = &diag }),
        );
        try std.testing.expectFmt("1:1: error: expected type 'f32'\n", "{f}", .{diag});
    }
}

test "std.zon free on error" {
    // Test freeing partially allocated structs
    {
        const Struct = struct {
            x: []const u8,
            y: []const u8,
            z: bool,
        };
        try std.testing.expectError(error.ParseZon, fromSliceAlloc(Struct, .{
            .gpa = std.testing.allocator,
            .source =
            \\.{
            \\    .x = "hello",
            \\    .y = "world",
            \\    .z = "fail",
            \\}
            ,
            .diag = null,
        }));
    }

    // Test freeing partially allocated tuples
    {
        const Struct = struct {
            []const u8,
            []const u8,
            bool,
        };
        try std.testing.expectError(error.ParseZon, fromSliceAlloc(Struct, .{
            .gpa = std.testing.allocator,
            .source =
            \\.{
            \\    "hello",
            \\    "world",
            \\    "fail",
            \\}
            ,
            .diag = null,
        }));
    }

    // Test freeing structs with missing fields
    {
        const Struct = struct {
            x: []const u8,
            y: bool,
        };
        try std.testing.expectError(error.ParseZon, fromSliceAlloc(Struct, .{
            .gpa = std.testing.allocator,
            .source =
            \\.{
            \\    .x = "hello",
            \\}
            ,
            .diag = null,
        }));
    }

    // Test freeing partially allocated arrays
    {
        try std.testing.expectError(error.ParseZon, fromSliceAlloc([3][]const u8, .{
            .gpa = std.testing.allocator,
            .source =
            \\.{
            \\    "hello",
            \\    false,
            \\    false,
            \\}
            ,
            .diag = null,
        }));
    }

    // Test freeing partially allocated slices
    {
        try std.testing.expectError(error.ParseZon, fromSliceAlloc([][]const u8, .{
            .gpa = std.testing.allocator,
            .source =
            \\.{
            \\    "hello",
            \\    "world",
            \\    false,
            \\}
            ,
            .diag = null,
        }));
    }

    // We can parse types that can't be freed, as long as they contain no allocations, e.g. untagged
    // unions.
    try std.testing.expectEqual(
        @as(f32, 1.5),
        (try fromSlice(union { x: f32 }, .{
            .gpa = std.testing.allocator,
            .source = ".{ .x = 1.5 }",
            .diag = null,
        })).x,
    );

    // We can also parse types that can't be freed if it's impossible for an error to occur after
    // the allocation, as is the case here.
    {
        const result = try fromSliceAlloc(union { x: []const u8 }, .{
            .gpa = std.testing.allocator,
            .source = ".{ .x = \"foo\" }",
            .diag = null,
        });
        defer free(std.testing.allocator, result.x);
        try std.testing.expectEqualStrings("foo", result.x);
    }

    // However, if it's possible we could get an error requiring we free the value, but the value
    // cannot be freed (e.g. untagged unions) then we need to turn off `free_on_error` for it to
    // compile.
    {
        const S = struct {
            union { x: []const u8 },
            bool,
        };
        const result = try fromSliceAlloc(S, .{
            .gpa = std.testing.allocator,
            .source = ".{ .{ .x = \"foo\" }, true }",
            .free_on_error = false,
            .diag = null,
        });
        defer free(std.testing.allocator, result[0].x);
        try std.testing.expectEqualStrings("foo", result[0].x);
        try std.testing.expect(result[1]);
    }

    // Again but for structs.
    {
        const S = struct {
            a: union { x: []const u8 },
            b: bool,
        };
        const result = try fromSliceAlloc(S, .{
            .gpa = std.testing.allocator,
            .source = ".{ .a = .{ .x = \"foo\" }, .b = true }",
            .free_on_error = false,
            .diag = null,
        });
        defer free(std.testing.allocator, result.a.x);
        try std.testing.expectEqualStrings("foo", result.a.x);
        try std.testing.expect(result.b);
    }

    // Again but for arrays.
    {
        const S = [2]union { x: []const u8 };
        const result = try fromSliceAlloc(S, .{
            .gpa = std.testing.allocator,
            .source = ".{ .{ .x = \"foo\" }, .{ .x = \"bar\" } }",
            .free_on_error = false,
            .diag = null,
        });
        defer free(std.testing.allocator, result[0].x);
        defer free(std.testing.allocator, result[1].x);
        try std.testing.expectEqualStrings("foo", result[0].x);
        try std.testing.expectEqualStrings("bar", result[1].x);
    }

    // Again but for slices.
    {
        const S = []union { x: []const u8 };
        const result = try fromSliceAlloc(S, .{
            .gpa = std.testing.allocator,
            .source = ".{ .{ .x = \"foo\" }, .{ .x = \"bar\" } }",
            .free_on_error = false,
            .diag = null,
        });
        defer std.testing.allocator.free(result);
        defer free(std.testing.allocator, result[0].x);
        defer free(std.testing.allocator, result[1].x);
        try std.testing.expectEqualStrings("foo", result[0].x);
        try std.testing.expectEqualStrings("bar", result[1].x);
    }
}

test "std.zon vector" {
    const builtin = @import("builtin");
    if (builtin.zig_backend == .stage2_llvm and builtin.cpu.arch == .s390x) return error.SkipZigTest; // https://github.com/ziglang/zig/issues/25957

    const gpa = std.testing.allocator;

    // Passing cases
    try std.testing.expectEqual(
        @Vector(0, bool){},
        try fromSlice(@Vector(0, bool), .{ .gpa = gpa, .source = ".{}", .diag = null }),
    );
    try std.testing.expectEqual(
        @Vector(3, bool){ true, false, true },
        try fromSlice(@Vector(3, bool), .{
            .gpa = gpa,
            .source = ".{true, false, true}",
            .diag = null,
        }),
    );

    try std.testing.expectEqual(
        @Vector(0, f32){},
        try fromSlice(@Vector(0, f32), .{ .gpa = gpa, .source = ".{}", .diag = null }),
    );
    try std.testing.expectEqual(
        @Vector(3, f32){ 1.5, 2.5, 3.5 },
        try fromSlice(@Vector(3, f32), .{
            .gpa = gpa,
            .source = ".{1.5, 2.5, 3.5}",
            .diag = null,
        }),
    );

    try std.testing.expectEqual(
        @Vector(0, u8){},
        try fromSlice(@Vector(0, u8), .{ .gpa = gpa, .source = ".{}", .diag = null }),
    );
    try std.testing.expectEqual(
        @Vector(3, u8){ 2, 4, 6 },
        try fromSlice(@Vector(3, u8), .{ .gpa = gpa, .source = ".{2, 4, 6}", .diag = null }),
    );

    {
        try std.testing.expectEqual(
            @Vector(0, *const u8){},
            try fromSliceAlloc(@Vector(0, *const u8), .{
                .gpa = gpa,
                .source = ".{}",
                .diag = null,
            }),
        );
        const pointers = try fromSliceAlloc(@Vector(3, *const u8), .{
            .gpa = gpa,
            .source = ".{2, 4, 6}",
            .diag = null,
        });
        defer free(gpa, pointers);
        try std.testing.expectEqualDeep(@Vector(3, *const u8){ &2, &4, &6 }, pointers);
    }

    {
        try std.testing.expectEqual(
            @Vector(0, ?*const u8){},
            try fromSliceAlloc(@Vector(0, ?*const u8), .{
                .gpa = gpa,
                .source = ".{}",
                .diag = null,
            }),
        );
        const pointers = try fromSliceAlloc(@Vector(3, ?*const u8), .{
            .gpa = gpa,
            .source = ".{2, null, 6}",
            .diag = null,
        });
        defer free(gpa, pointers);
        try std.testing.expectEqualDeep(@Vector(3, ?*const u8){ &2, null, &6 }, pointers);
    }

    // Too few fields
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSlice(@Vector(2, f32), .{
                .gpa = gpa,
                .source = ".{0.5}",
                .diag = &diag,
            }),
        );
        try std.testing.expectFmt(
            "1:2: error: expected 2 array elements; found 1\n",
            "{f}",
            .{diag},
        );
    }

    // Too many fields
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSlice(@Vector(2, f32), .{
                .gpa = gpa,
                .source = ".{0.5, 1.5, 2.5}",
                .diag = &diag,
            }),
        );
        try std.testing.expectFmt(
            "1:13: error: index 2 outside of array of length 2\n",
            "{f}",
            .{diag},
        );
    }

    // Wrong type fields
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSlice(@Vector(3, f32), .{
                .gpa = gpa,
                .source = ".{0.5, true, 2.5}",
                .diag = &diag,
            }),
        );
        try std.testing.expectFmt(
            "1:8: error: expected type 'f32'\n",
            "{f}",
            .{diag},
        );
    }

    // Wrong type
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSlice(@Vector(3, u8), .{ .gpa = gpa, .source = "true", .diag = &diag }),
        );
        try std.testing.expectFmt("1:1: error: expected type '@Vector(3, u8)'\n", "{f}", .{diag});
    }

    // Elements should get freed on error
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSliceAlloc(@Vector(3, *u8), .{
                .gpa = gpa,
                .source = ".{1, true, 3}",
                .diag = &diag,
            }),
        );
        try std.testing.expectFmt("1:6: error: expected type 'u8'\n", "{f}", .{diag});
    }
}

test "std.zon add pointers" {
    const gpa = std.testing.allocator;

    // Primitive with varying levels of pointers
    {
        const result = try fromSliceAlloc(*u32, .{
            .gpa = gpa,
            .source = "10",
            .diag = null,
        });
        defer free(gpa, result);
        try std.testing.expectEqual(@as(u32, 10), result.*);
    }

    {
        const result = try fromSliceAlloc(**u32, .{
            .gpa = gpa,
            .source = "10",
            .diag = null,
        });
        defer free(gpa, result);
        try std.testing.expectEqual(@as(u32, 10), result.*.*);
    }

    {
        const result = try fromSliceAlloc(***u32, .{
            .gpa = gpa,
            .source = "10",
            .diag = null,
        });
        defer free(gpa, result);
        try std.testing.expectEqual(@as(u32, 10), result.*.*.*);
    }

    // Primitive optional with varying levels of pointers
    {
        const some = try fromSliceAlloc(?*u32, .{
            .gpa = gpa,
            .source = "10",
            .diag = null,
        });
        defer free(gpa, some);
        try std.testing.expectEqual(@as(u32, 10), some.?.*);

        const none = try fromSliceAlloc(?*u32, .{
            .gpa = gpa,
            .source = "null",
            .diag = null,
        });
        defer free(gpa, none);
        try std.testing.expectEqual(null, none);
    }

    {
        const some = try fromSliceAlloc(*?u32, .{
            .gpa = gpa,
            .source = "10",
            .diag = null,
        });
        defer free(gpa, some);
        try std.testing.expectEqual(@as(u32, 10), some.*.?);

        const none = try fromSliceAlloc(*?u32, .{
            .gpa = gpa,
            .source = "null",
            .diag = null,
        });
        defer free(gpa, none);
        try std.testing.expectEqual(null, none.*);
    }

    {
        const some = try fromSliceAlloc(?**u32, .{
            .gpa = gpa,
            .source = "10",
            .diag = null,
        });
        defer free(gpa, some);
        try std.testing.expectEqual(@as(u32, 10), some.?.*.*);

        const none = try fromSliceAlloc(?**u32, .{
            .gpa = gpa,
            .source = "null",
            .diag = null,
        });
        defer free(gpa, none);
        try std.testing.expectEqual(null, none);
    }

    {
        const some = try fromSliceAlloc(*?*u32, .{
            .gpa = gpa,
            .source = "10",
            .diag = null,
        });
        defer free(gpa, some);
        try std.testing.expectEqual(@as(u32, 10), some.*.?.*);

        const none = try fromSliceAlloc(*?*u32, .{
            .gpa = gpa,
            .source = "null",
            .diag = null,
        });
        defer free(gpa, none);
        try std.testing.expectEqual(null, none.*);
    }

    {
        const some = try fromSliceAlloc(**?u32, .{
            .gpa = gpa,
            .source = "10",
            .diag = null,
        });
        defer free(gpa, some);
        try std.testing.expectEqual(@as(u32, 10), some.*.*.?);

        const none = try fromSliceAlloc(**?u32, .{
            .gpa = gpa,
            .source = "null",
            .diag = null,
        });
        defer free(gpa, none);
        try std.testing.expectEqual(null, none.*.*);
    }

    // Pointer to an array
    {
        const result = try fromSliceAlloc(*[3]u8, .{
            .gpa = gpa,
            .source = ".{ 1, 2, 3 }",
            .diag = null,
        });
        defer free(gpa, result);
        try std.testing.expectEqual([3]u8{ 1, 2, 3 }, result.*);
    }

    // A complicated type with nested internal pointers and string allocations
    {
        const Inner = struct {
            f1: *const ?*const []const u8,
            f2: *const ?*const []const u8,
        };
        const Outer = struct {
            f1: *const ?*const Inner,
            f2: *const ?*const Inner,
        };
        const expected: Outer = .{
            .f1 = &&.{
                .f1 = &null,
                .f2 = &&"foo",
            },
            .f2 = &null,
        };

        const found = try fromSliceAlloc(?*Outer, .{
            .gpa = gpa,
            .source =
            \\.{
            \\    .f1 = .{
            \\        .f1 = null,
            \\        .f2 = "foo",
            \\    },
            \\    .f2 = null,
            \\}
            ,
            .diag = null,
        });
        defer free(gpa, found);

        try std.testing.expectEqualDeep(expected, found.?.*);
    }

    // Test that optional types are flattened correctly in errors
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSliceAlloc(*const ?*const u8, .{ .gpa = gpa, .source = "true", .diag = &diag }),
        );
        try std.testing.expectFmt("1:1: error: expected type '?u8'\n", "{f}", .{diag});
    }

    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSliceAlloc(*const ?*const f32, .{ .gpa = gpa, .source = "true", .diag = &diag }),
        );
        try std.testing.expectFmt("1:1: error: expected type '?f32'\n", "{f}", .{diag});
    }

    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSliceAlloc(*const ?*const @Vector(3, u8), .{
                .gpa = gpa,
                .source = "true",
                .diag = &diag,
            }),
        );
        try std.testing.expectFmt("1:1: error: expected type '?@Vector(3, u8)'\n", "{f}", .{diag});
    }

    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSliceAlloc(*const ?*const bool, .{ .gpa = gpa, .source = "10", .diag = &diag }),
        );
        try std.testing.expectFmt("1:1: error: expected type '?bool'\n", "{f}", .{diag});
    }

    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSliceAlloc(*const ?*const struct { a: i32 }, .{ .gpa = gpa, .source = "true", .diag = &diag }),
        );
        try std.testing.expectFmt("1:1: error: expected optional struct\n", "{f}", .{diag});
    }

    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSliceAlloc(*const ?*const struct { i32 }, .{ .gpa = gpa, .source = "true", .diag = &diag }),
        );
        try std.testing.expectFmt("1:1: error: expected optional tuple\n", "{f}", .{diag});
    }

    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSliceAlloc(*const ?*const union { x: void }, .{ .gpa = gpa, .source = "true", .diag = &diag }),
        );
        try std.testing.expectFmt("1:1: error: expected optional union\n", "{f}", .{diag});
    }

    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSliceAlloc(*const ?*const [3]u8, .{ .gpa = gpa, .source = "true", .diag = &diag }),
        );
        try std.testing.expectFmt("1:1: error: expected optional array\n", "{f}", .{diag});
    }

    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSliceAlloc(?[3]u8, .{ .gpa = gpa, .source = "true", .diag = &diag }),
        );
        try std.testing.expectFmt("1:1: error: expected optional array\n", "{f}", .{diag});
    }

    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSliceAlloc(*const ?*const []u8, .{ .gpa = gpa, .source = "true", .diag = &diag }),
        );
        try std.testing.expectFmt("1:1: error: expected optional array\n", "{f}", .{diag});
    }

    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSliceAlloc(?[]u8, .{ .gpa = gpa, .source = "true", .diag = &diag }),
        );
        try std.testing.expectFmt("1:1: error: expected optional array\n", "{f}", .{diag});
    }

    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSliceAlloc(*const ?*const []const u8, .{ .gpa = gpa, .source = "true", .diag = &diag }),
        );
        try std.testing.expectFmt("1:1: error: expected optional string\n", "{f}", .{diag});
    }

    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(
            error.ParseZon,
            fromSliceAlloc(*const ?*const enum { foo }, .{ .gpa = gpa, .source = "true", .diag = &diag }),
        );
        try std.testing.expectFmt("1:1: error: expected optional enum literal\n", "{f}", .{diag});
    }
}

test "std.zon stop on node" {
    const gpa = std.testing.allocator;

    {
        const Vec2 = struct {
            x: Zoir.Node.Index,
            y: f32,
        };

        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        const result = try fromSlice(Vec2, .{
            .gpa = gpa,
            .source = ".{ .x = 1.5, .y = 2.5 }",
            .diag = &diag,
        });
        try std.testing.expectEqual(result.y, 2.5);
        try std.testing.expectEqual(Zoir.Node{ .float_literal = 1.5 }, result.x.get(diag.zoir));
    }

    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        const result = try fromSlice(Zoir.Node.Index, .{
            .gpa = gpa,
            .source = "1.23",
            .diag = &diag,
        });
        try std.testing.expectEqual(Zoir.Node{ .float_literal = 1.23 }, result.get(diag.zoir));
    }
}

test "std.zon no alloc" {
    const gpa = std.testing.allocator;

    try std.testing.expectEqual(
        [3]u8{ 1, 2, 3 },
        try fromSlice([3]u8, .{
            .gpa = gpa,
            .source = ".{ 1, 2, 3 }",
            .diag = null,
        }),
    );

    const Nested = struct { u8, u8, struct { u8, u8 } };

    var ast = try std.zig.Ast.parse(gpa, ".{ 1, 2, .{ 3, 4 } }", .{ .mode = .zon });
    defer ast.deinit(gpa);

    var zoir = try ZonGen.generate(gpa, ast, .{ .parse_str_lits = false });
    defer zoir.deinit(gpa);

    try std.testing.expectEqual(
        Nested{ 1, 2, .{ 3, 4 } },
        try fromZoir(Nested, .{ .ast = ast, .zoir = zoir, .diag = null }),
    );
}

test "std.zon errors without diagnostics" {
    const gpa = std.testing.allocator;

    const Enum = enum {
        foo,
        bar,
        baz,
    };
    try std.testing.expectError(error.ParseZon, fromSliceAlloc(Enum, .{
        .gpa = gpa,
        .source = ".nothing",
        .diag = null,
    }));

    const Struct = struct {
        name: []const u8,
    };
    try std.testing.expectError(error.ParseZon, fromSliceAlloc(Struct, .{
        .gpa = gpa,
        .source = ".{ .name = \"Alice\", .age = 25 }",
        .diag = null,
    }));

    const Union = union(enum) {
        x,
        y: u32,
    };
    try std.testing.expectError(error.ParseZon, fromSliceAlloc(Union, .{
        .gpa = gpa,
        .source = ".a",
        .diag = null,
    }));
    try std.testing.expectError(error.ParseZon, fromSliceAlloc(Union, .{
        .gpa = gpa,
        .source = ".{ .b = 8 }",
        .diag = null,
    }));
}

test "std.zon aligned pointers" {
    const gpa = std.testing.allocator;

    const n: u8 align(8) = 10;
    const Foo = struct {
        inner: *align(8) const u8,
    };

    const expected: Foo = .{
        .inner = &n,
    };
    const found = try fromSliceAlloc(Foo, .{
        .gpa = gpa,
        .source = ".{ .inner = 10 }",
        .diag = null,
    });
    defer free(gpa, found);
    try std.testing.expectEqualDeep(expected.inner, found.inner);
}

test "std.zon update" {
    const gpa = std.testing.allocator;

    const Vector = struct { x: f32, y: f32, z: f32 };
    const MyStruct = struct {
        foo: u32 = 123,
        bar: bool,
        baz: struct {
            a: [2]u32,
            b: enum { c, d } = .d,
        },
        ptr: *Vector,
        optional: ?u32 = null,
        str: []const u8,
    };

    var expected: MyStruct = .{
        .foo = 10,
        .bar = true,
        .baz = .{ .a = .{ 1, 2 }, .b = .c },
        .ptr = b: {
            const v = gpa.create(Vector) catch @panic("oom");
            v.* = .{ .x = 1, .y = 2, .z = 3 };
            break :b v;
        },
        .str = gpa.dupe(u8, "hello, world") catch @panic("oom"),
    };
    defer free(gpa, expected);
    var found: MyStruct = .{
        .foo = 10,
        .bar = true,
        .baz = .{ .a = .{ 1, 2 }, .b = .c },
        .ptr = b: {
            const v = gpa.create(Vector) catch @panic("oom");
            v.* = .{ .x = 1, .y = 2, .z = 3 };
            break :b v;
        },
        .str = gpa.dupe(u8, "hello, world") catch @panic("oom"),
    };
    defer free(gpa, found);

    try updateFromSliceAlloc(MyStruct, .{
        .gpa = gpa,
        .value = &found,
        .source = ".{}",
        .diag = null,
    });
    try std.testing.expectEqualDeep(expected, found);

    try updateFromSliceAlloc(MyStruct, .{
        .gpa = gpa,
        .value = &found,
        .source = ".{ .bar = false }",
        .diag = null,
    });
    expected.bar = false;
    try std.testing.expectEqualDeep(expected, found);

    try updateFromSliceAlloc(MyStruct, .{
        .gpa = gpa,
        .value = &found,
        .source = ".{ .baz = .{ .a = .{ 2, 4 } } }",
        .diag = null,
    });
    expected.baz.a[0] = 2;
    expected.baz.a[1] = 4;
    try std.testing.expectEqualDeep(expected, found);

    try updateFromSliceAlloc(MyStruct, .{
        .gpa = gpa,
        .value = &found,
        .source = ".{ .foo = 11, .baz = .{ .b = .d } }",
        .diag = null,
    });
    expected.foo = 11;
    expected.baz.b = .d;
    try std.testing.expectEqualDeep(expected, found);

    try updateFromSliceAlloc(MyStruct, .{
        .gpa = gpa,
        .value = &found,
        .source = ".{ .optional = 10 }",
        .diag = null,
    });
    expected.optional = 10;
    try std.testing.expectEqualDeep(expected, found);

    try updateFromSliceAlloc(MyStruct, .{
        .gpa = gpa,
        .value = &found,
        .source = ".{ .optional = null }",
        .diag = null,
    });
    expected.optional = null;
    try std.testing.expectEqualDeep(expected, found);

    try updateFromSliceAlloc(MyStruct, .{
        .gpa = gpa,
        .value = &found,
        .source = ".{ .ptr = .{ .x = 10, .y = 20, .z = 30 } }",
        .diag = null,
    });
    expected.ptr.x = 10;
    expected.ptr.y = 20;
    expected.ptr.z = 30;
    try std.testing.expectEqualDeep(expected, found);

    try updateFromSliceAlloc(MyStruct, .{
        .gpa = gpa,
        .value = &found,
        .source = ".{ .str = \"foo\" }",
        .diag = null,
    });
    gpa.free(expected.str);
    expected.str = gpa.dupe(u8, "foo") catch @panic("oom");
    try std.testing.expectEqualDeep(expected, found);
}

test "std.zon variants" {
    // Just a smoke test, we don't need to test each variant thoroughly because they all call into
    // the same code.

    const gpa = std.testing.allocator;

    const Struct = struct { a: u32, b: u32 };
    const start: Struct = .{ .a = 10, .b = 20 };
    const end: Struct = .{ .a = 100, .b = 20 };

    // Update
    {
        var ast = try std.zig.Ast.parse(gpa, ".{ .a = 100 }", .{ .mode = .zon });
        defer ast.deinit(gpa);
        const zoir = try ZonGen.generate(gpa, ast, .{ .parse_str_lits = false });
        defer zoir.deinit(gpa);

        var curr = start;
        try updateFromSlice(Struct, .{
            .gpa = gpa,
            .value = &curr,
            .source = ".{ .a = 100 }",
            .diag = null,
        });
        try std.testing.expectEqual(end, curr);

        curr = start;
        try updateFromSliceAlloc(Struct, .{
            .gpa = gpa,
            .value = &curr,
            .source = ".{ .a = 100 }",
            .diag = null,
        });
        try std.testing.expectEqual(end, curr);

        curr = start;
        try updateFromZoir(Struct, .{
            .ast = ast,
            .value = &curr,
            .zoir = zoir,
            .diag = null,
        });
        try std.testing.expectEqual(end, curr);

        curr = start;
        try updateFromZoirAlloc(Struct, .{
            .gpa = gpa,
            .value = &curr,
            .ast = ast,
            .zoir = zoir,
            .diag = null,
        });
        try std.testing.expectEqual(end, curr);
    }

    // From
    {
        var ast = try std.zig.Ast.parse(gpa, ".{ .a = 100, .b = 20 }", .{ .mode = .zon });
        defer ast.deinit(gpa);
        const zoir = try ZonGen.generate(gpa, ast, .{ .parse_str_lits = false });
        defer zoir.deinit(gpa);

        try std.testing.expectEqual(
            end,
            try fromSlice(Struct, .{
                .gpa = gpa,
                .source = ".{ .a = 100, .b = 20 }",
                .diag = null,
            }),
        );
        try std.testing.expectEqual(
            end,
            try fromSliceAlloc(Struct, .{
                .gpa = gpa,
                .source = ".{ .a = 100, .b = 20 }",
                .diag = null,
            }),
        );
        try std.testing.expectEqual(
            try fromZoir(Struct, .{
                .ast = ast,
                .zoir = zoir,
                .diag = null,
            }),
            end,
        );
        try std.testing.expectEqual(
            try fromZoirAlloc(Struct, .{
                .gpa = gpa,
                .ast = ast,
                .zoir = zoir,
                .diag = null,
            }),
            end,
        );
    }
}
