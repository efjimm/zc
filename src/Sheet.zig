// TODO:
// Experiment with O(n^2) node splitting
const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils.zig");
const Position = @import("Position.zig");
const Range = Position.Range;
const Ast = @import("Ast.zig");
const ArrayMemoryPool = @import("array_memory_pool.zig").ArrayMemoryPool;
const MultiArrayList = @import("multi_array_list.zig").MultiArrayList;
const RTree = @import("tree.zig").RTree;
const DependentTree = @import("tree.zig").DependentTree;

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Sheet = @This();
const NodeList = std.ArrayList(Position);
const NodeListUnmanaged = std.ArrayListUnmanaged(Position);

const log = std.log.scoped(.sheet);

const CellMap = std.ArrayHashMapUnmanaged(Position, Cell, ArrayPositionContext, false);
const CellSet = std.HashMapUnmanaged(Position, void, PositionContext, 80);

/// List of cells that need to be re-evaluated.
queued_cells: std.ArrayListUnmanaged(Position) = .{},

/// ArrayHashMap mapping spreadsheet positions to cells.
cells: CellMap = .{},

strings: std.HashMapUnmanaged(Position, []const u8, PositionContext, 80) = .{},

/// Maps column indexes (0 - 65535) to `Column` structs containing info about that column.
columns: std.AutoArrayHashMapUnmanaged(u16, Column) = .{},
filepath: std.BoundedArray(u8, std.fs.MAX_PATH_BYTES) = .{}, // TODO: Heap allocate this

/// True if there have been any changes since the last save
has_changes: bool = false,

undos: UndoList = .{},
redos: UndoList = .{},

undo_end_markers: std.AutoHashMapUnmanaged(u32, Marker) = .{},

/// Stores Asts and strings used for undoing text cells.
undo_asts: ArrayMemoryPool(
    struct {
        ast: Ast,
        strings: []const u8,
    },
    u32,
) = .{},

// TODO: Find optimal values for these
/// Range tree mapping ranges to a list of ranges that depend on the first.
/// Used to query whether a cell belongs to a range and then update the cells
/// that depend on that range.
rtree: DependentTree(64) = .{},
/// Range tree containing just the positions of extant cells.
/// Used for quick lookup of all extant cells in a ranges.
cell_tree: RTree(void, 64) = .{},

allocator: Allocator,

const SheetRange = struct {
    range: Range,
    dependent_cells: RangeList,
};
const RangeList = std.ArrayListUnmanaged(Range);

const Marker = packed struct(u2) {
    undo: bool = false,
    redo: bool = false,
};

pub fn isUndoMarker(sheet: *Sheet, index: u32) bool {
    return if (sheet.undo_end_markers.get(index)) |marker| marker.undo else false;
}

pub fn isRedoMarker(sheet: *Sheet, index: u32) bool {
    return if (sheet.undo_end_markers.get(index)) |marker| marker.redo else false;
}

pub const UndoList = MultiArrayList(Undo);
pub const AstMap = std.AutoArrayHashMapUnmanaged(u32, Ast);

pub const UndoType = enum { undo, redo };

pub const Undo = union(enum) {
    set_cell: struct {
        pos: Position,
        index: u32,
    },
    delete_cell: Position,

    set_column_width: struct {
        col: u16,
        width: u16,
    },
    set_column_precision: struct {
        col: u16,
        precision: u8,
    },

    comptime {
        assert(@sizeOf(std.meta.Tag(Undo)) == 1);
        inline for (std.meta.fields(Undo)) |field| {
            assert(@sizeOf(field.type) <= 8);
        }
    }
};

pub fn init(allocator: Allocator) Sheet {
    return .{
        .allocator = allocator,
    };
}

pub fn deinit(sheet: *Sheet) void {
    for (sheet.cells.values()) |*cell| {
        cell.deinit(sheet.allocator);
    }

    var strings_iter = sheet.strings.iterator();
    while (strings_iter.next()) |kv| {
        sheet.allocator.free(kv.value_ptr.*);
    }
    sheet.strings.deinit(sheet.allocator);

    sheet.clearAndFreeUndos(.undo);
    sheet.clearAndFreeUndos(.redo);
    sheet.rtree.deinit(sheet.allocator);
    sheet.cell_tree.deinit(sheet.allocator);

    sheet.queued_cells.deinit(sheet.allocator);
    sheet.undo_end_markers.deinit(sheet.allocator);
    sheet.undos.deinit(sheet.allocator);
    sheet.redos.deinit(sheet.allocator);
    sheet.undo_asts.deinit(sheet.allocator);
    sheet.cells.deinit(sheet.allocator);
    sheet.columns.deinit(sheet.allocator);
    sheet.* = undefined;
}

pub fn clearRetainingCapacity(sheet: *Sheet, context: anytype) void {
    for (sheet.cells.values()) |cell| context.destroyAst(cell.ast);

    var strings_iter = sheet.strings.valueIterator();
    while (strings_iter.next()) |string_ptr| {
        sheet.allocator.free(string_ptr.*);
    }

    const undo_slice = sheet.undos.slice();
    for (undo_slice.items(.tags), undo_slice.items(.data)) |tag, data| {
        switch (tag) {
            .set_cell => {
                const index = data.set_cell.index;
                const t = sheet.undo_asts.get(index);
                sheet.allocator.free(t.strings);
                context.destroyAst(t.ast);
            },
            .delete_cell,
            .set_column_width,
            .set_column_precision,
            => {},
        }
    }

    const redo_slice = sheet.redos.slice();
    for (redo_slice.items(.tags), redo_slice.items(.data)) |tag, data| {
        switch (tag) {
            .set_cell => {
                const index = data.set_cell.index;
                const t = sheet.undo_asts.get(index);
                sheet.allocator.free(t.strings);
                context.destroyAst(t.ast);
            },
            .delete_cell,
            .set_column_width,
            .set_column_precision,
            => {},
        }
    }

    sheet.undos.len = 0;
    sheet.redos.len = 0;
    sheet.cells.clearRetainingCapacity();
    sheet.undo_end_markers.clearRetainingCapacity();
    sheet.strings.clearRetainingCapacity();
}

pub fn loadFile(sheet: *Sheet, ast_allocator: Allocator, filepath: []const u8, context: anytype) !void {
    const file = std.fs.cwd().openFile(filepath, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            sheet.setFilePath(filepath);
            sheet.has_changes = false;
            return;
        },
        else => return err,
    };
    defer file.close();

    sheet.setFilePath(filepath);
    defer sheet.has_changes = false;

    var buf = std.io.bufferedReader(file.reader());
    const reader = buf.reader();
    log.debug("Loading file {s}", .{filepath});

    var sfa = std.heap.stackFallback(8192, sheet.allocator);
    var allocator = sfa.get();
    defer sheet.endUndoGroup();
    while (try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', std.math.maxInt(u30))) |line| {
        defer {
            allocator.free(line);
            allocator = sfa.get();
        }

        var ast = context.createAst();
        errdefer context.destroyAst(ast);
        ast.parse(ast_allocator, line) catch |err| switch (err) {
            error.UnexpectedToken,
            error.InvalidCellAddress,
            => {
                context.destroyAst(ast);
                continue;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };

        const data = ast.nodes.items(.data);
        const assignment = data[ast.rootNodeIndex()].assignment;
        const pos = data[assignment.lhs].cell;
        ast.splice(assignment.rhs);

        try sheet.setCell(pos, line, ast, .{});
    }
}

pub fn writeFile(
    sheet: *Sheet,
    opts: struct {
        filepath: ?[]const u8 = null,
    },
) !void {
    const filepath = opts.filepath orelse sheet.filepath.slice();
    if (filepath.len == 0) {
        return error.EmptyFileName;
    }

    var atomic_file = try std.fs.cwd().atomicFile(filepath, .{});
    defer atomic_file.deinit();

    var buf = std.io.bufferedWriter(atomic_file.file.writer());
    const writer = buf.writer();

    for (sheet.cells.keys()) |pos| {
        try writer.print("let {} = ", .{pos});
        try sheet.printCellExpression(pos, writer);
        try writer.writeByte('\n');
    }

    try buf.flush();
    try atomic_file.finish();

    if (opts.filepath) |path| {
        sheet.setFilePath(path);
    }
}

/// Iterator over all the positions referenced in an expression.
const ExprPosIterator = struct {
    range_iter: ExprRangeIterator,
    pos_iter: Range.Iterator,

    fn init(ast: Ast) ExprPosIterator {
        var ret = ExprPosIterator{
            .range_iterator = ExprRangeIterator.init(ast),
            .pos_iterator = undefined,
        };

        if (ret.range_iter.next()) |range| {
            ret.pos_iterator = range.iterator();
        } else {
            ret.pos_iterator = Range.Iterator{
                .range = std.mem.zeroes(Range.Iterator),
                .y = 1,
                .x = 0,
            };
        }

        return ret;
    }

    fn next(it: *ExprPosIterator) ?Position {
        if (it.pos_iter.next()) |p| return p;
        const new_range = it.range_iter.next() orelse return null;
        it.pos_iter = new_range.iterator();
        return it.pos_iter.next();
    }
};

/// Iterator over the cells referenced by an expression, as ranges.
/// Singular cell references are treated as a single-celled range.
const ExprRangeIterator = struct {
    ast: Ast.Slice,
    i: u32,

    fn init(ast: Ast) ExprRangeIterator {
        return .{
            .ast = ast.toSlice(),
            .i = ast.nodes.len,
        };
    }

    fn next(it: *ExprRangeIterator) ?Range {
        if (it.i == 0) return null;

        const slice = it.ast.nodes;
        const data = slice.items(.data);

        var iter = std.mem.reverseIterator(slice.items(.tags)[0..it.i]);
        defer it.i = @intCast(iter.index);

        return while (iter.next()) |tag| switch (tag) {
            .cell => {
                const pos = data[iter.index].cell;
                break Range.initSinglePos(pos);
            },
            .range => {
                const r = data[iter.index].range;
                const p1 = data[r.lhs].cell;
                const p2 = data[r.rhs].cell;
                iter.index -= 2;
                break Range.initPos(p1, p2);
            },
            else => continue,
        } else null;
    }
};

/// Adds `dependent_range` as a dependent of all cells in `range`.
fn addRangeDependents(
    sheet: *Sheet,
    dependent_range: Range,
    range: Range,
) Allocator.Error!void {
    return sheet.rtree.put(sheet.allocator, range, dependent_range);
}

/// Adds `dependent_range` as a dependent of all cells referenced by `expr`.
fn addExpressionDependents(
    sheet: *Sheet,
    dependent_range: Range,
    expr: Ast,
) Allocator.Error!void {
    var iter = ExprRangeIterator.init(expr);
    while (iter.next()) |range| {
        try sheet.addRangeDependents(dependent_range, range);
    }
}

/// Removes `dependent_range` as a dependent of all cells in `range`
fn removeRangeDependents(
    sheet: *Sheet,
    dependent_range: Range,
    range: Range,
) Allocator.Error!void {
    return sheet.rtree.removeValue(sheet.allocator, range, dependent_range);
}

/// Removes `dependent_range` as a dependent of the cells referenced by `expr`.
fn removeExprDependents(
    sheet: *Sheet,
    dependent_range: Range,
    expr: Ast,
) Allocator.Error!void {
    var iter = ExprRangeIterator.init(expr);
    while (iter.next()) |range| {
        try sheet.removeRangeDependents(dependent_range, range);
    }
}

pub fn firstCellInRow(sheet: *Sheet, row: u16) ?Position {
    return for (sheet.cells.keys()) |pos| {
        if (pos.y < row) continue;
        if (pos.y == row) break pos;
        break null;
    } else null;
}

pub fn lastCellInRow(sheet: *Sheet, row: u16) ?Position {
    var ret: ?Position = null;

    for (sheet.cells.keys()) |pos| {
        if (pos.y > row) break;
        ret = pos;
    }

    return ret;
}

pub fn firstCellInColumn(sheet: *Sheet, col: u16) ?Position {
    return for (sheet.cells.keys()) |pos| {
        if (pos.x == col) break pos;
    } else null;
}

pub fn lastCellInColumn(sheet: *Sheet, col: u16) ?Position {
    var iter = std.mem.reverseIterator(sheet.cells.keys());
    return while (iter.next()) |pos| {
        if (pos.x == col) break pos;
    } else null;
}

pub const UndoOpts = struct {
    undo_type: UndoType = .undo,
    clear_redos: bool = true,
};

fn createUndoAst(sheet: *Sheet, ast: Ast, strings: []const u8) Allocator.Error!u32 {
    const ret = try sheet.undo_asts.createWithInit(sheet.allocator, .{
        .ast = ast,
        .strings = strings,
    });
    return ret;
}

fn freeUndoAst(sheet: *Sheet, index: u32) void {
    var t = sheet.undo_asts.get(index);
    t.ast.deinit(sheet.allocator);
    sheet.allocator.free(t.strings);
    sheet.undo_asts.destroy(index);
}

pub fn clearAndFreeUndos(sheet: *Sheet, comptime kind: UndoType) void {
    const list = switch (kind) {
        .undo => &sheet.undos,
        .redo => &sheet.redos,
    };

    const slice = list.slice();
    const data = slice.items(.data);

    for (slice.items(.tags), 0..) |tag, i| {
        switch (tag) {
            .set_cell => sheet.freeUndoAst(data[i].set_cell.index),
            .delete_cell,
            .set_column_width,
            .set_column_precision,
            => {},
        }
    }
    list.len = 0;
    var iter = sheet.undo_end_markers.iterator();
    while (iter.next()) |entry| {
        switch (kind) {
            .undo => entry.value_ptr.undo = false,
            .redo => entry.value_ptr.redo = false,
        }
        if (@as(u2, @bitCast(entry.value_ptr.*)) == 0) {
            sheet.undo_end_markers.removeByPtr(entry.key_ptr);
        }
    }
}

pub fn endUndoGroup(sheet: *Sheet) void {
    if (sheet.undos.len == 0) return;
    const res = sheet.undo_end_markers.getOrPutAssumeCapacity(sheet.undos.len - 1);
    if (res.found_existing) {
        res.value_ptr.undo = true;
    } else {
        res.value_ptr.* = .{
            .undo = true,
        };
    }
}

fn endRedoGroup(sheet: *Sheet) void {
    if (sheet.redos.len == 0) return;
    const res = sheet.undo_end_markers.getOrPutAssumeCapacity(sheet.redos.len - 1);
    if (res.found_existing) {
        res.value_ptr.redo = true;
    } else {
        res.value_ptr.* = .{
            .redo = true,
        };
    }
}

fn unsetUndoEndMarker(sheet: *Sheet, index: u32) void {
    const ptr = sheet.undo_end_markers.getPtr(index).?;
    if (ptr.redo == false) {
        // Both values are now false, remove it from the map
        _ = sheet.undo_end_markers.remove(index);
    } else {
        ptr.undo = false;
    }
}

fn unsetRedoEndMarker(sheet: *Sheet, index: u32) void {
    const ptr = sheet.undo_end_markers.getPtr(index).?;
    if (ptr.undo == false) {
        // Both values are now false, remove it from the map
        _ = sheet.undo_end_markers.remove(index);
    } else {
        ptr.redo = false;
    }
}

pub fn ensureUndoCapacity(sheet: *Sheet, undo_type: UndoType, n: u32) Allocator.Error!void {
    try sheet.undo_end_markers.ensureUnusedCapacity(sheet.allocator, n);
    switch (undo_type) {
        .undo => try sheet.undos.ensureUnusedCapacity(sheet.allocator, n),
        .redo => try sheet.redos.ensureUnusedCapacity(sheet.allocator, n),
    }
}

pub fn pushUndo(sheet: *Sheet, u: Undo, opts: UndoOpts) Allocator.Error!void {
    // Ensure that we can add a group end marker later without allocating
    try sheet.undo_end_markers.ensureUnusedCapacity(sheet.allocator, 1);

    switch (opts.undo_type) {
        .undo => {
            try sheet.undos.ensureUnusedCapacity(sheet.allocator, 1);
            sheet.undos.appendAssumeCapacity(u);
            if (opts.clear_redos) sheet.clearAndFreeUndos(.redo);
        },
        .redo => {
            try sheet.redos.append(sheet.allocator, u);
        },
    }
}

pub fn doUndo(sheet: *Sheet, u: Undo, opts: UndoOpts) Allocator.Error!void {
    switch (u) {
        .set_cell => |t| {
            // TODO: Is this errdefer correct?
            errdefer sheet.freeUndoAst(t.index);
            const temp = sheet.undo_asts.get(t.index);
            try sheet.insertCell(t.pos, temp.strings, temp.ast, opts);
            sheet.undo_asts.destroy(t.index);
        },
        .delete_cell => |pos| try sheet.deleteCell(pos, opts),
        .set_column_width => |t| try sheet.setWidth(t.col, t.width, opts),
        .set_column_precision => |t| try sheet.setPrecision(t.col, t.precision, opts),
    }
}

pub fn undo(sheet: *Sheet) Allocator.Error!void {
    if (sheet.undos.len == 0) return;
    // All undo groups MUST end with a group marker - so remove it!
    sheet.unsetUndoEndMarker(sheet.undos.len - 1);

    defer sheet.endRedoGroup();

    const opts = .{ .undo_type = .redo };
    while (sheet.undos.popOrNull()) |u| {
        try sheet.doUndo(u, opts);
        if (sheet.undos.len == 0 or sheet.isUndoMarker(sheet.undos.len - 1)) break;
    }
}

pub fn redo(sheet: *Sheet) Allocator.Error!void {
    if (sheet.redos.len == 0) return;
    // All undo groups MUST end with a group marker - so remove it!
    sheet.unsetRedoEndMarker(sheet.redos.len - 1);

    defer sheet.endUndoGroup();

    const opts = .{ .clear_redos = false };
    while (sheet.redos.popOrNull()) |u| {
        try sheet.doUndo(u, opts);
        if (sheet.redos.len == 0 or sheet.isRedoMarker(sheet.redos.len - 1)) break;
    }
}

pub fn setWidth(
    sheet: *Sheet,
    column_index: u16,
    width: u16,
    opts: UndoOpts,
) Allocator.Error!void {
    if (sheet.columns.getPtr(column_index)) |col| {
        try sheet.setColWidth(col, column_index, width, opts);
    }
}

pub fn setColWidth(
    sheet: *Sheet,
    col: *Column,
    index: u16,
    width: u16,
    opts: UndoOpts,
) Allocator.Error!void {
    if (width == col.width) return;
    const old_width = col.width;
    col.width = width;
    try sheet.pushUndo(
        .{
            .set_column_width = .{
                .col = index,
                .width = old_width,
            },
        },
        opts,
    );
    sheet.endUndoGroup();
}

pub fn incWidth(
    sheet: *Sheet,
    column_index: u16,
    n: u16,
    opts: UndoOpts,
) Allocator.Error!void {
    if (sheet.columns.getPtr(column_index)) |col| {
        try sheet.setColWidth(col, column_index, col.width +| n, opts);
    }
}

pub fn decWidth(
    sheet: *Sheet,
    column_index: u16,
    n: u16,
    opts: UndoOpts,
) Allocator.Error!void {
    if (sheet.columns.getPtr(column_index)) |col| {
        const new_width = @max(col.width -| n, 1);
        try sheet.setColWidth(col, column_index, new_width, opts);
    }
}

pub fn setPrecision(
    sheet: *Sheet,
    column_index: u16,
    precision: u8,
    opts: UndoOpts,
) Allocator.Error!void {
    if (sheet.columns.getPtr(column_index)) |col| {
        try sheet.setColPrecision(col, column_index, precision, opts);
    }
}

pub fn setColPrecision(
    sheet: *Sheet,
    col: *Column,
    index: u16,
    precision: u8,
    opts: UndoOpts,
) Allocator.Error!void {
    if (precision == col.precision) return;
    const old_precision = col.precision;
    col.precision = precision;
    try sheet.pushUndo(
        .{
            .set_column_precision = .{
                .col = index,
                .precision = old_precision,
            },
        },
        opts,
    );
    sheet.endUndoGroup();
}

pub fn incPrecision(
    sheet: *Sheet,
    column_index: u16,
    n: u8,
    opts: UndoOpts,
) Allocator.Error!void {
    if (sheet.columns.getPtr(column_index)) |col| {
        try sheet.setColPrecision(col, column_index, col.precision +| n, opts);
    }
}

pub fn decPrecision(
    sheet: *Sheet,
    column_index: u16,
    n: u8,
    opts: UndoOpts,
) Allocator.Error!void {
    if (sheet.columns.getPtr(column_index)) |col| {
        try sheet.setColPrecision(col, column_index, col.precision -| n, opts);
    }
}

pub fn cellCount(sheet: *Sheet) u32 {
    return @intCast(sheet.cells.entries.len);
}

pub fn colCount(sheet: *Sheet) u32 {
    return @intCast(sheet.columns.entries.len);
}

/// Allocates enough space for `new_capacity` cells
pub fn ensureTotalCapacity(sheet: *Sheet, new_capacity: usize) Allocator.Error!void {
    return sheet.cells.ensureTotalCapacity(sheet.allocator, new_capacity);
}

pub fn needsUpdate(sheet: Sheet) bool {
    return sheet.queued_cells.items.len > 0;
}

pub fn insertCell(
    sheet: *Sheet,
    pos: Position,
    strings: []const u8,
    ast: Ast,
    undo_opts: UndoOpts,
) Allocator.Error!void {
    try sheet.ensureUndoCapacity(undo_opts.undo_type, 1);
    try sheet.queued_cells.ensureUnusedCapacity(sheet.allocator, 1);
    _ = try sheet.columns.getOrPutValue(sheet.allocator, pos.x, Column{});
    try sheet.strings.ensureUnusedCapacity(sheet.allocator, 1);

    const range = Range.initSinglePos(pos);

    try sheet.cell_tree.put(sheet.allocator, range, {});
    errdefer sheet.cell_tree.remove(sheet.allocator, range) catch {};

    // Add cells referenced by the expression as dependents of `pos`
    try sheet.addExpressionDependents(range, ast);
    errdefer {
        var iter = ExprRangeIterator.init(ast);
        while (iter.next()) |r| {
            sheet.removeRangeDependents(r, range) catch {};
        }
    }

    const cell = Cell{ .ast = ast };

    if (!sheet.cells.contains(pos)) {
        // Ensure capacities for cells and strings
        try sheet.cells.ensureUnusedCapacity(sheet.allocator, 1);

        const u = Undo{ .delete_cell = pos };

        for (sheet.cells.keys(), 0..) |key, i| {
            if (key.hash() > pos.hash()) {
                sheet.cells.entries.insertAssumeCapacity(i, .{
                    .hash = {},
                    .key = pos,
                    .value = cell,
                });

                // If this fails with OOM we could potentially end up with the map in an invalid
                // state. All instances of OOM must be recoverable. If we error here we remove the
                // newly inserted entry so that the old index remains correct.
                sheet.cells.reIndex(sheet.allocator) catch |err| {
                    sheet.cells.entries.orderedRemove(i);
                    return err;
                };
                errdefer _ = sheet.cells.orderedRemove(pos);

                sheet.pushUndo(u, undo_opts) catch unreachable;

                sheet.has_changes = true;
                break;
            }
        } else {
            // Found no entries
            sheet.cells.putAssumeCapacity(pos, cell);
            errdefer _ = sheet.cells.orderedRemove(pos);

            sheet.pushUndo(u, undo_opts) catch unreachable;
            sheet.has_changes = true;
        }
        errdefer _ = sheet.cells.orderedRemove(pos);

        if (strings.len > 0) {
            // NoClobber because cell didn't exist in map, so strings shouldn't exist either
            sheet.strings.putAssumeCapacityNoClobber(pos, strings);
        }
        errdefer _ = sheet.strings.remove(pos);
        sheet.enqueueUpdate(pos) catch unreachable;
        return;
    }

    try sheet.undo_asts.ensureUnusedCapacity(sheet.allocator, 1);

    const ptr = sheet.cells.getPtr(pos).?;
    const old_cell = ptr.*;

    try sheet.removeExprDependents(range, old_cell.ast);

    ptr.* = cell;

    const res = sheet.strings.getOrPutAssumeCapacity(pos);
    const old_strings = if (res.found_existing) res.value_ptr.* else "";
    errdefer if (old_strings.len > 0) sheet.strings.putAssumeCapacity(pos, old_strings);

    const index = sheet.createUndoAst(old_cell.ast, old_strings) catch unreachable;
    errdefer sheet.undo_asts.destroy(index);

    if (strings.len > 0) {
        res.value_ptr.* = strings;
    } else {
        sheet.strings.removeByPtr(res.key_ptr);
    }
    errdefer _ = sheet.strings.removeByPtr(res.key_ptr);

    const u = Undo{ .set_cell = .{ .pos = pos, .index = index } };
    sheet.pushUndo(u, undo_opts) catch unreachable;

    sheet.enqueueUpdate(pos) catch unreachable;
    if (old_cell.value == .string) {
        sheet.allocator.free(std.mem.span(old_cell.value.string));
    }
    sheet.has_changes = true;
}

pub fn setCell(
    sheet: *Sheet,
    position: Position,
    source: []const u8,
    ast: Ast,
    undo_opts: UndoOpts,
) Allocator.Error!void {
    const strings = try ast.dupeStrings(sheet.allocator, source);
    errdefer sheet.allocator.free(strings);
    try sheet.insertCell(position, strings, ast, undo_opts);
}

pub fn deleteCell(
    sheet: *Sheet,
    pos: Position,
    undo_opts: UndoOpts,
) Allocator.Error!void {
    var cell = sheet.cells.get(pos) orelse return;

    try sheet.ensureUndoCapacity(undo_opts.undo_type, 1);
    try sheet.enqueueUpdate(pos);
    try sheet.undo_asts.ensureUnusedCapacity(sheet.allocator, 1);
    try sheet.removeExprDependents(Range.initSinglePos(pos), cell.ast);

    // TODO: re-use string buffer
    cell.setError(sheet.allocator);
    _ = sheet.cells.orderedRemove(pos);

    const strings = if (sheet.strings.fetchRemove(pos)) |kv| kv.value else "";

    const index = sheet.createUndoAst(cell.ast, strings) catch |err| {
        cell.deinit(sheet.allocator);
        return err;
    };
    errdefer sheet.freeUndoAst(index);

    sheet.pushUndo(.{ .set_cell = .{ .pos = pos, .index = index } }, undo_opts) catch unreachable;
    sheet.has_changes = true;
}

pub fn deleteCellsInRange(sheet: *Sheet, p1: Position, p2: Position) Allocator.Error!void {
    var i: usize = 0;
    const positions = sheet.cells.keys();
    const tl = Position.topLeft(p1, p2);
    const br = Position.bottomRight(p1, p2);

    defer sheet.endUndoGroup();

    while (i < positions.len) {
        const pos = positions[i];
        if (pos.y > br.y) break;
        if (pos.y >= tl.y and pos.x >= tl.x and pos.x <= br.x) {
            try sheet.deleteCell(pos, .{});
        } else {
            i += 1;
        }
    }
}

pub fn getCell(sheet: Sheet, pos: Position) ?Cell {
    return sheet.cells.get(pos);
}

pub fn getCellPtr(sheet: *Sheet, pos: Position) ?*Cell {
    return sheet.cells.getPtr(pos);
}

pub fn update(sheet: *Sheet) Allocator.Error!void {
    if (!sheet.needsUpdate()) return;

    log.debug("Updating cells...", .{});
    var timer = std.time.Timer.start() catch unreachable;

    defer sheet.queued_cells.clearRetainingCapacity();

    log.debug("Marking dirty cells", .{});
    for (sheet.queued_cells.items) |pos| {
        try sheet.markDirty(pos);
    }

    const context = EvalContext{ .sheet = sheet };
    // All dirty cells are reachable from the cells in queued_cells
    while (sheet.queued_cells.popOrNull()) |pos| {
        // try sheet.eval(pos);
        _ = context.evalCell(pos) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        };
    }

    log.debug("Finished cell update in {d} seconds", .{
        @as(f64, @floatFromInt(timer.read())) / std.time.ns_per_s,
    });
}

/// Marks the cell at `pos` as needing to be updated.
pub fn enqueueUpdate(
    sheet: *Sheet,
    pos: Position,
) Allocator.Error!void {
    try sheet.queued_cells.append(sheet.allocator, pos);
    const cell = sheet.cells.getPtr(pos) orelse return;
    cell.state = .enqueued;
}

/// Marks all of the dependents of `pos` as dirty.
fn markDirty(
    sheet: *Sheet,
    pos: Position,
) Allocator.Error!void {
    const res = try sheet.rtree.search(sheet.allocator, Range.initSinglePos(pos));
    defer sheet.allocator.free(res);

    for (res) |kv| {
        for (kv.value.items) |r| {
            var iter = r.iterator();
            while (iter.next()) |p| {
                const cell = sheet.cells.getPtr(p) orelse continue;
                if (cell.state != .dirty) {
                    cell.state = .dirty;
                    try sheet.markDirty(p);
                }
            }
        }
    }
}

pub fn getFilePath(sheet: Sheet) []const u8 {
    return sheet.filepath.constSlice();
}

// TODO: Allow for renaming sheets.

/// Returns the name of the sheet.
/// Currently this is the basename of the filepath, with the extension
/// stripped.
pub fn getName(sheet: Sheet) []const u8 {
    return std.fs.path.stem(sheet.getFilePath());
}

pub fn setFilePath(sheet: *Sheet, filepath: []const u8) void {
    sheet.filepath.len = 0;
    sheet.filepath.appendSliceAssumeCapacity(filepath);
}

pub const Cell = struct {
    value: Value = .{ .err = error.NotEvaluable },
    ast: Ast = .{},
    state: enum {
        up_to_date,
        dirty,
        enqueued,
        computing,
    } = .up_to_date,

    pub const Value = union(enum) {
        number: f64,
        string: [*:0]const u8,
        err: Error,
    };

    pub const Error = Ast.EvalError;

    pub fn fromExpression(allocator: Allocator, expr: []const u8) !Cell {
        return .{ .ast = try Ast.fromExpression(allocator, expr) };
    }

    pub fn deinit(cell: *Cell, allocator: Allocator) void {
        cell.ast.deinit(allocator);
        if (cell.value == .string) allocator.free(std.mem.span(cell.value.string));
        cell.* = undefined;
    }

    pub fn isError(cell: Cell) bool {
        return cell.value == .err;
    }

    pub fn setError(cell: *Cell, allocator: Allocator) void {
        if (cell.value == .string) {
            allocator.free(std.mem.span(cell.value.string));
        }
        cell.value = .{ .err = error.NotEvaluable };
    }

    pub inline fn getValue(cell: Cell) ?f64 {
        return switch (cell.value) {
            .number => |n| n,
            else => null,
        };
    }
};

pub const EvalContext = struct {
    sheet: *Sheet,

    fn queueDependents(context: EvalContext, pos: Position) Allocator.Error!void {
        const res = try context.sheet.rtree.search(context.sheet.allocator, Range.initSinglePos(pos));
        defer context.sheet.allocator.free(res);

        for (res) |kv| {
            for (kv.value.items) |r| {
                var iter = r.iterator();
                while (iter.next()) |p| {
                    const c = context.sheet.cells.getPtr(p) orelse continue;
                    if (c.state == .dirty) {
                        c.state = .enqueued;
                        try context.sheet.queued_cells.append(context.sheet.allocator, p);
                    }
                }
            }
        }
    }

    /// Evaluates a cell and all of its dependencies.
    pub fn evalCell(context: EvalContext, pos: Position) Ast.EvalError!Ast.EvalResult {
        const cell = context.sheet.cells.getPtr(pos) orelse {
            try context.queueDependents(pos);
            return .none;
        };

        switch (cell.state) {
            .up_to_date => {},
            .computing => return error.CyclicalReference,
            .enqueued, .dirty => {
                cell.state = .computing;

                // Get strings
                const strings = context.sheet.strings.get(pos) orelse "";

                // Evaluate
                const res = cell.ast.eval(context.sheet, strings, context) catch |err| {
                    cell.value = .{ .err = err };
                    return err;
                };
                if (cell.value == .string)
                    context.sheet.allocator.free(std.mem.span(cell.value.string));
                cell.value = switch (res) {
                    .none => .{ .number = 0 },
                    .string => |str| .{ .string = str.ptr },
                    .number => |n| .{ .number = n },
                };
                cell.state = .up_to_date;

                try context.queueDependents(pos);
            },
        }

        return switch (cell.value) {
            .number => |n| .{ .number = n },
            .string => |ptr| .{ .string = std.mem.span(ptr) },
            .err => |err| err,
        };
    }
};

pub fn printCellExpression(sheet: Sheet, pos: Position, writer: anytype) !void {
    const cell = sheet.cells.get(pos) orelse return;
    const strings = sheet.strings.get(pos) orelse "";
    try cell.ast.print(strings, writer);
}

pub const Column = struct {
    const CellMap = std.AutoArrayHashMapUnmanaged(u16, Cell);

    pub const default_width = 10;

    width: u16 = default_width,
    precision: u8 = 2,
};

pub fn getColumn(sheet: Sheet, index: u16) Column {
    return sheet.columns.get(index) orelse Column{};
}

pub fn widthNeededForColumn(
    sheet: Sheet,
    column_index: u16,
    precision: u16,
    max_width: u16,
) u16 {
    var width: u16 = Column.default_width;

    var buf: std.BoundedArray(u8, 512) = .{};
    const writer = buf.writer();
    for (sheet.cells.keys(), sheet.cells.values()) |k, v| {
        if (k.x != column_index) continue;

        switch (v.value) {
            .err => {},
            .number => |n| {
                buf.len = 0;
                writer.print("{d:.[1]}", .{ n, precision }) catch unreachable;
                // Numbers are all ASCII, so 1 byte = 1 column
                const len: u16 = @intCast(buf.len);
                if (len > width) {
                    width = len;
                    if (width >= max_width) return width;
                }
            },
            .string => |ptr| {
                const str = std.mem.span(ptr);
                const w = utils.strWidth(str, max_width);
                if (w > width) {
                    width = w;
                    if (width >= max_width) return width;
                }
            },
        }
    }

    return width;
}

const ArrayPositionContext = struct {
    pub fn eql(_: ArrayPositionContext, p1: Position, p2: Position, _: usize) bool {
        return p1.y == p2.y and p1.x == p2.x;
    }

    pub fn hash(_: ArrayPositionContext, pos: Position) u32 {
        return pos.hash();
    }
};

/// std.HashMap and std.ArrayHashMap require slightly different contexts.
const PositionContext = struct {
    pub fn eql(_: PositionContext, p1: Position, p2: Position) bool {
        return p1.y == p2.y and p1.x == p2.x;
    }

    pub fn hash(_: PositionContext, pos: Position) u64 {
        return pos.hash();
    }
};

// Tests //////////////////////////////////////////////////////////////////////////////////////////

test "Sheet basics" {
    const t = std.testing;

    var sheet = Sheet.init(t.allocator);
    defer sheet.deinit();

    try t.expectEqual(@as(u32, 0), sheet.cellCount());
    try t.expectEqual(@as(u32, 0), sheet.colCount());
    try t.expectEqualStrings("", sheet.filepath.slice());

    const exprs: []const []const u8 = &.{ "50 + 5", "500 * 2 / 34 + 1", "a0", "a2 * a1" };
    var asts: [4]Ast = undefined;
    for (&asts, exprs) |*ast, expr| {
        ast.* = try Ast.fromExpression(t.allocator, expr);
    }

    for (asts, exprs, 0..) |ast, expr, i| {
        try sheet.setCell(.{ .x = 0, .y = @intCast(i) }, expr, ast, .{});
    }

    try t.expectEqual(@as(u32, 4), sheet.cellCount());
    try t.expectEqual(@as(u32, 1), sheet.colCount());
    for (asts, 0..) |ast, i| {
        try t.expectEqual(ast, sheet.cells.get(.{ .x = 0, .y = @intCast(i) }).?.ast);
    }

    // for (0..4) |y| {
    //const pos = .{ .x = 0, .y = @intCast(u16, y) };
    //try t.expectEqual(@as(?f64, null), sheet.cells.get(pos).?.getValue());
    // }
    try sheet.update();
    // for (0..4) |y| {
    // const pos = .{ .x = 0, .y = @intCast(u16, y) };
    // try t.expect(sheet.cells.get(pos).?.getValue() != null);
    // }

    try sheet.deleteCell(.{ .x = 0, .y = 0 }, .{});

    try t.expectEqual(@as(u32, 3), sheet.cellCount());
}

test "setCell allocations" {
    const t = std.testing;
    const Test = struct {
        fn testSetCellAllocs(allocator: Allocator) !void {
            var sheet = Sheet.init(allocator);
            defer sheet.deinit();

            {
                const expr = "a4 * a1 * a3";
                var ast = try Ast.fromExpression(allocator, expr);
                errdefer ast.deinit(allocator);
                try sheet.setCell(.{ .x = 0, .y = 0 }, expr, ast, .{});
            }

            {
                const expr = "a2 * a1 * a3";
                var ast = try Ast.fromExpression(allocator, expr);
                errdefer ast.deinit(allocator);
                try sheet.setCell(.{ .x = 1, .y = 0 }, expr, ast, .{});
            }

            try sheet.deleteCell(.{ .x = 0, .y = 0 }, .{});

            try sheet.update();
        }
    };

    try t.checkAllAllocationFailures(t.allocator, Test.testSetCellAllocs, .{});
}

test "Position.columnAddressBuf" {
    const t = std.testing;
    var buf: [4]u8 = undefined;

    try t.expectEqualStrings("A", Position.columnAddressBuf(0, &buf));
    try t.expectEqualStrings("AA", Position.columnAddressBuf(26, &buf));
    try t.expectEqualStrings("AAA", Position.columnAddressBuf(702, &buf));
    try t.expectEqualStrings("AAAA", Position.columnAddressBuf(18278, &buf));
    try t.expectEqualStrings("CRXP", Position.columnAddressBuf(Position.MAX, &buf));
}

fn testCellEvaluation(allocator: Allocator) !void {
    const t = std.testing;
    var sheet = Sheet.init(allocator);
    defer sheet.deinit();

    const _setCell = struct {
        fn _setCell(
            _allocator: Allocator,
            _sheet: *Sheet,
            pos: Position,
            ast: Ast,
        ) !void {
            var c = ast;
            defer _sheet.endUndoGroup();
            _sheet.setCell(pos, "", c, .{}) catch |err| {
                c.deinit(_allocator);
                return err;
            };
            const last_undo = _sheet.undos.get(_sheet.undos.len - 1);
            try t.expectEqual(Undo{ .delete_cell = pos }, last_undo);
        }
    }._setCell;

    // Set cell values in random order
    try _setCell(allocator, &sheet, try Position.fromAddress("B17"), try Ast.fromExpression(allocator, "A17+B16"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G8"), try Ast.fromExpression(allocator, "G7+F8"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A9"), try Ast.fromExpression(allocator, "A8+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G11"), try Ast.fromExpression(allocator, "G10+F11"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E16"), try Ast.fromExpression(allocator, "E15+D16"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G10"), try Ast.fromExpression(allocator, "G9+F10"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D2"), try Ast.fromExpression(allocator, "D1+C2"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F2"), try Ast.fromExpression(allocator, "F1+E2"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B18"), try Ast.fromExpression(allocator, "A18+B17"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D15"), try Ast.fromExpression(allocator, "D14+C15"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D20"), try Ast.fromExpression(allocator, "D19+C20"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E13"), try Ast.fromExpression(allocator, "E12+D13"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C12"), try Ast.fromExpression(allocator, "C11+B12"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A16"), try Ast.fromExpression(allocator, "A15+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A10"), try Ast.fromExpression(allocator, "A9+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C19"), try Ast.fromExpression(allocator, "C18+B19"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F0"), try Ast.fromExpression(allocator, "E0+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B4"), try Ast.fromExpression(allocator, "A4+B3"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C11"), try Ast.fromExpression(allocator, "C10+B11"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B6"), try Ast.fromExpression(allocator, "A6+B5"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G5"), try Ast.fromExpression(allocator, "G4+F5"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A18"), try Ast.fromExpression(allocator, "A17+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D1"), try Ast.fromExpression(allocator, "D0+C1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G12"), try Ast.fromExpression(allocator, "G11+F12"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B5"), try Ast.fromExpression(allocator, "A5+B4"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D4"), try Ast.fromExpression(allocator, "D3+C4"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A5"), try Ast.fromExpression(allocator, "A4+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A0"), try Ast.fromExpression(allocator, "1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D13"), try Ast.fromExpression(allocator, "D12+C13"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A15"), try Ast.fromExpression(allocator, "A14+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A20"), try Ast.fromExpression(allocator, "A19+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G19"), try Ast.fromExpression(allocator, "G18+F19"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G13"), try Ast.fromExpression(allocator, "G12+F13"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G17"), try Ast.fromExpression(allocator, "G16+F17"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C14"), try Ast.fromExpression(allocator, "C13+B14"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B8"), try Ast.fromExpression(allocator, "A8+B7"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D10"), try Ast.fromExpression(allocator, "D9+C10"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F19"), try Ast.fromExpression(allocator, "F18+E19"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B11"), try Ast.fromExpression(allocator, "A11+B10"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F9"), try Ast.fromExpression(allocator, "F8+E9"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G7"), try Ast.fromExpression(allocator, "G6+F7"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C10"), try Ast.fromExpression(allocator, "C9+B10"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C2"), try Ast.fromExpression(allocator, "C1+B2"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D0"), try Ast.fromExpression(allocator, "C0+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C18"), try Ast.fromExpression(allocator, "C17+B18"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D6"), try Ast.fromExpression(allocator, "D5+C6"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C0"), try Ast.fromExpression(allocator, "B0+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B14"), try Ast.fromExpression(allocator, "A14+B13"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B19"), try Ast.fromExpression(allocator, "A19+B18"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G16"), try Ast.fromExpression(allocator, "G15+F16"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C8"), try Ast.fromExpression(allocator, "C7+B8"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G4"), try Ast.fromExpression(allocator, "G3+F4"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D18"), try Ast.fromExpression(allocator, "D17+C18"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E17"), try Ast.fromExpression(allocator, "E16+D17"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D3"), try Ast.fromExpression(allocator, "D2+C3"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E20"), try Ast.fromExpression(allocator, "E19+D20"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C6"), try Ast.fromExpression(allocator, "C5+B6"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E2"), try Ast.fromExpression(allocator, "E1+D2"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C1"), try Ast.fromExpression(allocator, "C0+B1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D17"), try Ast.fromExpression(allocator, "D16+C17"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C9"), try Ast.fromExpression(allocator, "C8+B9"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D12"), try Ast.fromExpression(allocator, "D11+C12"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F18"), try Ast.fromExpression(allocator, "F17+E18"));
    try _setCell(allocator, &sheet, try Position.fromAddress("H0"), try Ast.fromExpression(allocator, "G0+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D8"), try Ast.fromExpression(allocator, "D7+C8"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B12"), try Ast.fromExpression(allocator, "A12+B11"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E19"), try Ast.fromExpression(allocator, "E18+D19"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A14"), try Ast.fromExpression(allocator, "A13+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E14"), try Ast.fromExpression(allocator, "E13+D14"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F14"), try Ast.fromExpression(allocator, "F13+E14"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A13"), try Ast.fromExpression(allocator, "A12+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A19"), try Ast.fromExpression(allocator, "A18+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A4"), try Ast.fromExpression(allocator, "A3+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F7"), try Ast.fromExpression(allocator, "F6+E7"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A7"), try Ast.fromExpression(allocator, "A6+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E11"), try Ast.fromExpression(allocator, "E10+D11"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B1"), try Ast.fromExpression(allocator, "A1+B0"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A11"), try Ast.fromExpression(allocator, "A10+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B16"), try Ast.fromExpression(allocator, "A16+B15"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E12"), try Ast.fromExpression(allocator, "E11+D12"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F11"), try Ast.fromExpression(allocator, "F10+E11"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F1"), try Ast.fromExpression(allocator, "F0+E1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C4"), try Ast.fromExpression(allocator, "C3+B4"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G20"), try Ast.fromExpression(allocator, "G19+F20"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F16"), try Ast.fromExpression(allocator, "F15+E16"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D5"), try Ast.fromExpression(allocator, "D4+C5"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A17"), try Ast.fromExpression(allocator, "A16+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A22"), try Ast.fromExpression(allocator, "@sum(a0:g20)"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F4"), try Ast.fromExpression(allocator, "F3+E4"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B9"), try Ast.fromExpression(allocator, "A9+B8"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E4"), try Ast.fromExpression(allocator, "E3+D4"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F13"), try Ast.fromExpression(allocator, "F12+E13"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A1"), try Ast.fromExpression(allocator, "A0+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F3"), try Ast.fromExpression(allocator, "F2+E3"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F17"), try Ast.fromExpression(allocator, "F16+E17"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G14"), try Ast.fromExpression(allocator, "G13+F14"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D11"), try Ast.fromExpression(allocator, "D10+C11"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A2"), try Ast.fromExpression(allocator, "A1+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E9"), try Ast.fromExpression(allocator, "E8+D9"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B15"), try Ast.fromExpression(allocator, "A15+B14"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E18"), try Ast.fromExpression(allocator, "E17+D18"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E8"), try Ast.fromExpression(allocator, "E7+D8"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G18"), try Ast.fromExpression(allocator, "G17+F18"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A6"), try Ast.fromExpression(allocator, "A5+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C3"), try Ast.fromExpression(allocator, "C2+B3"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B0"), try Ast.fromExpression(allocator, "A0+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E10"), try Ast.fromExpression(allocator, "E9+D10"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B7"), try Ast.fromExpression(allocator, "A7+B6"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C7"), try Ast.fromExpression(allocator, "C6+B7"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D9"), try Ast.fromExpression(allocator, "D8+C9"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D14"), try Ast.fromExpression(allocator, "D13+C14"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B20"), try Ast.fromExpression(allocator, "A20+B19"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E7"), try Ast.fromExpression(allocator, "E6+D7"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E0"), try Ast.fromExpression(allocator, "D0+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A3"), try Ast.fromExpression(allocator, "A2+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G9"), try Ast.fromExpression(allocator, "G8+F9"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C17"), try Ast.fromExpression(allocator, "C16+B17"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F5"), try Ast.fromExpression(allocator, "F4+E5"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F6"), try Ast.fromExpression(allocator, "F5+E6"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G3"), try Ast.fromExpression(allocator, "G2+F3"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E5"), try Ast.fromExpression(allocator, "E4+D5"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A8"), try Ast.fromExpression(allocator, "A7+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B13"), try Ast.fromExpression(allocator, "A13+B12"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B3"), try Ast.fromExpression(allocator, "A3+B2"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D19"), try Ast.fromExpression(allocator, "D18+C19"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B2"), try Ast.fromExpression(allocator, "A2+B1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C5"), try Ast.fromExpression(allocator, "C4+B5"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G6"), try Ast.fromExpression(allocator, "G5+F6"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F12"), try Ast.fromExpression(allocator, "F11+E12"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E1"), try Ast.fromExpression(allocator, "E0+D1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C15"), try Ast.fromExpression(allocator, "C14+B15"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A12"), try Ast.fromExpression(allocator, "A11+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G1"), try Ast.fromExpression(allocator, "G0+F1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D16"), try Ast.fromExpression(allocator, "D15+C16"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F20"), try Ast.fromExpression(allocator, "F19+E20"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E6"), try Ast.fromExpression(allocator, "E5+D6"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E15"), try Ast.fromExpression(allocator, "E14+D15"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F8"), try Ast.fromExpression(allocator, "F7+E8"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F10"), try Ast.fromExpression(allocator, "F9+E10"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C16"), try Ast.fromExpression(allocator, "C15+B16"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C20"), try Ast.fromExpression(allocator, "C19+B20"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E3"), try Ast.fromExpression(allocator, "E2+D3"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B10"), try Ast.fromExpression(allocator, "A10+B9"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G2"), try Ast.fromExpression(allocator, "G1+F2"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D7"), try Ast.fromExpression(allocator, "D6+C7"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G15"), try Ast.fromExpression(allocator, "G14+F15"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G0"), try Ast.fromExpression(allocator, "F0+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F15"), try Ast.fromExpression(allocator, "F14+E15"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C13"), try Ast.fromExpression(allocator, "C12+B13"));

    // Test that updating this takes less than 100 ms
    const begin = try std.time.Instant.now();
    try sheet.update();
    const elapsed_time = (try std.time.Instant.now()).since(begin);
    t.expect(@as(f64, @floatFromInt(elapsed_time)) / std.time.ns_per_ms < 100) catch |err| {
        std.debug.print("Got time {d}\n", .{@as(f64, @floatFromInt(elapsed_time)) / std.time.ns_per_ms});
        return err;
    };

    // Test values of cells
    const testCell = struct {
        pub fn testCell(_sheet: *Sheet, pos: []const u8, expected: f64) !void {
            const cell = _sheet.getCell(try Position.fromAddress(pos)) orelse return error.CellNotFound;
            try t.expectApproxEqRel(expected, cell.value.number, 0.001);
        }
    }.testCell;

    try testCell(&sheet, "A0", 1.00);
    try testCell(&sheet, "B0", 2.00);
    try testCell(&sheet, "C0", 3.00);
    try testCell(&sheet, "D0", 4.00);
    try testCell(&sheet, "E0", 5.00);
    try testCell(&sheet, "F0", 6.00);
    try testCell(&sheet, "G0", 7.00);
    try testCell(&sheet, "H0", 8.00);
    try testCell(&sheet, "A1", 2.00);
    try testCell(&sheet, "B1", 4.00);
    try testCell(&sheet, "C1", 7.00);
    try testCell(&sheet, "D1", 11.00);
    try testCell(&sheet, "E1", 16.00);
    try testCell(&sheet, "F1", 22.00);
    try testCell(&sheet, "G1", 29.00);
    try testCell(&sheet, "A2", 3.00);
    try testCell(&sheet, "B2", 7.00);
    try testCell(&sheet, "C2", 14.00);
    try testCell(&sheet, "D2", 25.00);
    try testCell(&sheet, "E2", 41.00);
    try testCell(&sheet, "F2", 63.00);
    try testCell(&sheet, "G2", 92.00);
    try testCell(&sheet, "A3", 4.00);
    try testCell(&sheet, "B3", 11.00);
    try testCell(&sheet, "C3", 25.00);
    try testCell(&sheet, "D3", 50.00);
    try testCell(&sheet, "E3", 91.00);
    try testCell(&sheet, "F3", 154.00);
    try testCell(&sheet, "G3", 246.00);
    try testCell(&sheet, "A4", 5.00);
    try testCell(&sheet, "B4", 16.00);
    try testCell(&sheet, "C4", 41.00);
    try testCell(&sheet, "D4", 91.00);
    try testCell(&sheet, "E4", 182.00);
    try testCell(&sheet, "F4", 336.00);
    try testCell(&sheet, "G4", 582.00);
    try testCell(&sheet, "A5", 6.00);
    try testCell(&sheet, "B5", 22.00);
    try testCell(&sheet, "C5", 63.00);
    try testCell(&sheet, "D5", 154.00);
    try testCell(&sheet, "E5", 336.00);
    try testCell(&sheet, "F5", 672.00);
    try testCell(&sheet, "G5", 1254.00);
    try testCell(&sheet, "A6", 7.00);
    try testCell(&sheet, "B6", 29.00);
    try testCell(&sheet, "C6", 92.00);
    try testCell(&sheet, "D6", 246.00);
    try testCell(&sheet, "E6", 582.00);
    try testCell(&sheet, "F6", 1254.00);
    try testCell(&sheet, "G6", 2508.00);
    try testCell(&sheet, "A7", 8.00);
    try testCell(&sheet, "B7", 37.00);
    try testCell(&sheet, "C7", 129.00);
    try testCell(&sheet, "D7", 375.00);
    try testCell(&sheet, "E7", 957.00);
    try testCell(&sheet, "F7", 2211.00);
    try testCell(&sheet, "G7", 4719.00);
    try testCell(&sheet, "A8", 9.00);
    try testCell(&sheet, "B8", 46.00);
    try testCell(&sheet, "C8", 175.00);
    try testCell(&sheet, "D8", 550.00);
    try testCell(&sheet, "E8", 1507.00);
    try testCell(&sheet, "F8", 3718.00);
    try testCell(&sheet, "G8", 8437.00);
    try testCell(&sheet, "A9", 10.00);
    try testCell(&sheet, "B9", 56.00);
    try testCell(&sheet, "C9", 231.00);
    try testCell(&sheet, "D9", 781.00);
    try testCell(&sheet, "E9", 2288.00);
    try testCell(&sheet, "F9", 6006.00);
    try testCell(&sheet, "G9", 14443.00);
    try testCell(&sheet, "A10", 11.00);
    try testCell(&sheet, "B10", 67.00);
    try testCell(&sheet, "C10", 298.00);
    try testCell(&sheet, "D10", 1079.00);
    try testCell(&sheet, "E10", 3367.00);
    try testCell(&sheet, "F10", 9373.00);
    try testCell(&sheet, "G10", 23816.00);
    try testCell(&sheet, "A11", 12.00);
    try testCell(&sheet, "B11", 79.00);
    try testCell(&sheet, "C11", 377.00);
    try testCell(&sheet, "D11", 1456.00);
    try testCell(&sheet, "E11", 4823.00);
    try testCell(&sheet, "F11", 14196.00);
    try testCell(&sheet, "G11", 38012.00);
    try testCell(&sheet, "A12", 13.00);
    try testCell(&sheet, "B12", 92.00);
    try testCell(&sheet, "C12", 469.00);
    try testCell(&sheet, "D12", 1925.00);
    try testCell(&sheet, "E12", 6748.00);
    try testCell(&sheet, "F12", 20944.00);
    try testCell(&sheet, "G12", 58956.00);
    try testCell(&sheet, "A13", 14.00);
    try testCell(&sheet, "B13", 106.00);
    try testCell(&sheet, "C13", 575.00);
    try testCell(&sheet, "D13", 2500.00);
    try testCell(&sheet, "E13", 9248.00);
    try testCell(&sheet, "F13", 30192.00);
    try testCell(&sheet, "G13", 89148.00);
    try testCell(&sheet, "A14", 15.00);
    try testCell(&sheet, "B14", 121.00);
    try testCell(&sheet, "C14", 696.00);
    try testCell(&sheet, "D14", 3196.00);
    try testCell(&sheet, "E14", 12444.00);
    try testCell(&sheet, "F14", 42636.00);
    try testCell(&sheet, "G14", 131784.00);
    try testCell(&sheet, "A15", 16.00);
    try testCell(&sheet, "B15", 137.00);
    try testCell(&sheet, "C15", 833.00);
    try testCell(&sheet, "D15", 4029.00);
    try testCell(&sheet, "E15", 16473.00);
    try testCell(&sheet, "F15", 59109.00);
    try testCell(&sheet, "G15", 190893.00);
    try testCell(&sheet, "A16", 17.00);
    try testCell(&sheet, "B16", 154.00);
    try testCell(&sheet, "C16", 987.00);
    try testCell(&sheet, "D16", 5016.00);
    try testCell(&sheet, "E16", 21489.00);
    try testCell(&sheet, "F16", 80598.00);
    try testCell(&sheet, "G16", 271491.00);
    try testCell(&sheet, "A17", 18.00);
    try testCell(&sheet, "B17", 172.00);
    try testCell(&sheet, "C17", 1159.00);
    try testCell(&sheet, "D17", 6175.00);
    try testCell(&sheet, "E17", 27664.00);
    try testCell(&sheet, "F17", 108262.00);
    try testCell(&sheet, "G17", 379753.00);
    try testCell(&sheet, "A18", 19.00);
    try testCell(&sheet, "B18", 191.00);
    try testCell(&sheet, "C18", 1350.00);
    try testCell(&sheet, "D18", 7525.00);
    try testCell(&sheet, "E18", 35189.00);
    try testCell(&sheet, "F18", 143451.00);
    try testCell(&sheet, "G18", 523204.00);
    try testCell(&sheet, "A19", 20.00);
    try testCell(&sheet, "B19", 211.00);
    try testCell(&sheet, "C19", 1561.00);
    try testCell(&sheet, "D19", 9086.00);
    try testCell(&sheet, "E19", 44275.00);
    try testCell(&sheet, "F19", 187726.00);
    try testCell(&sheet, "G19", 710930.00);
    try testCell(&sheet, "A20", 21.00);
    try testCell(&sheet, "B20", 232.00);
    try testCell(&sheet, "C20", 1793.00);
    try testCell(&sheet, "D20", 10879.00);
    try testCell(&sheet, "E20", 55154.00);
    try testCell(&sheet, "F20", 242880.00);
    try testCell(&sheet, "G20", 953810.00);
    try testCell(&sheet, "A22", 4668856.00);

    // Check that cells are ordered correctly
    const positions = sheet.cells.keys();
    var last_pos = positions[0];
    for (positions[1..]) |pos| {
        try t.expect(pos.hash() > last_pos.hash());
        last_pos = pos;
    }

    for (sheet.undos.items(.tags)) |tag| {
        try t.expectEqual(std.meta.Tag(Undo).delete_cell, tag);
    }

    const UndoIterator = struct {
        undos: MultiArrayList(Undo).Slice,
        index: u32 = 0,

        pub fn next(iter: *@This()) Undo {
            if (iter.index >= iter.undos.len) unreachable;
            defer iter.index += 1;
            return iter.undos.get(iter.index);
        }
    };

    var iter = UndoIterator{ .undos = sheet.undos.slice() };
    // Check that undos are in the correct order
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B17") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G8") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A9") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G11") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E16") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G10") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D2") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F2") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B18") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D15") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D20") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E13") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C12") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A16") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A10") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C19") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F0") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B4") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C11") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B6") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G5") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A18") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D1") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G12") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B5") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D4") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A5") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A0") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D13") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A15") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A20") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G19") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G13") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G17") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C14") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B8") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D10") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F19") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B11") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F9") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G7") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C10") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C2") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D0") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C18") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D6") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C0") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B14") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B19") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G16") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C8") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G4") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D18") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E17") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D3") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E20") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C6") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E2") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C1") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D17") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C9") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D12") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F18") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("H0") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D8") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B12") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E19") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A14") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E14") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F14") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A13") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A19") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A4") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F7") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A7") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E11") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B1") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A11") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B16") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E12") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F11") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F1") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C4") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G20") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F16") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D5") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A17") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A22") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F4") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B9") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E4") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F13") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A1") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F3") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F17") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G14") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D11") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A2") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E9") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B15") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E18") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E8") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G18") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A6") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C3") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B0") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E10") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B7") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C7") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D9") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D14") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B20") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E7") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E0") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A3") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G9") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C17") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F5") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F6") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G3") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E5") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A8") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B13") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B3") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D19") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B2") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C5") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G6") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F12") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E1") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C15") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A12") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G1") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D16") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F20") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E6") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E15") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F8") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F10") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C16") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C20") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E3") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B10") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G2") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D7") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G15") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G0") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F15") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C13") }, iter.next());

    // Check undos
    try t.expectEqual(@as(usize, 149), sheet.undos.len);
    try t.expectEqual(@as(usize, 0), sheet.redos.len);

    try sheet.undo();
    try t.expectEqual(@as(usize, 148), sheet.undos.len);
    try t.expectEqual(@as(usize, 1), sheet.redos.len);
    try t.expectEqual(
        Undo{
            .set_cell = .{
                .pos = try Position.fromAddress("C13"),
                .index = 0,
            },
        },
        sheet.redos.get(0),
    );
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F15") }, sheet.undos.get(sheet.undos.len - 1));

    try sheet.redo();
    try t.expectEqual(@as(usize, 149), sheet.undos.len);
    try t.expectEqual(@as(usize, 0), sheet.redos.len);
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C13") }, sheet.undos.get(sheet.undos.len - 1));

    try sheet.deleteCell(try Position.fromAddress("A22"), .{});
    try sheet.deleteCell(try Position.fromAddress("G20"), .{});
    sheet.endUndoGroup();

    try t.expectEqual(@as(usize, 151), sheet.undos.len);
    try t.expectEqual(@as(usize, 0), sheet.redos.len);
    try t.expectEqual(
        Undo{
            .set_cell = .{
                .pos = try Position.fromAddress("A22"),
                .index = 0,
            },
        },
        sheet.undos.get(sheet.undos.len - 2),
    );
    try t.expectEqual(
        Undo{
            .set_cell = .{
                .pos = try Position.fromAddress("G20"),
                .index = 1,
            },
        },
        sheet.undos.get(sheet.undos.len - 1),
    );
    try sheet.undo();
    try t.expectEqual(@as(usize, 149), sheet.undos.len);
    try t.expectEqual(@as(usize, 2), sheet.redos.len);
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C13") }, sheet.undos.get(sheet.undos.len - 1));
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G20") }, sheet.redos.get(0));
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A22") }, sheet.redos.get(1));

    try sheet.undo();
    try t.expectEqual(@as(usize, 148), sheet.undos.len);
    try t.expectEqual(@as(usize, 3), sheet.redos.len);
    try sheet.undo();
    try t.expectEqual(@as(usize, 147), sheet.undos.len);
    try t.expectEqual(@as(usize, 4), sheet.redos.len);

    try sheet.redo();
    try t.expectEqual(@as(usize, 148), sheet.undos.len);
    try t.expectEqual(@as(usize, 3), sheet.redos.len);
    try sheet.redo();
    try t.expectEqual(@as(usize, 149), sheet.undos.len);
    try t.expectEqual(@as(usize, 2), sheet.redos.len);
    try sheet.redo();
    try t.expectEqual(@as(usize, 151), sheet.undos.len);
    try t.expectEqual(@as(usize, 0), sheet.redos.len);
    try sheet.redo();
    try t.expectEqual(@as(usize, 151), sheet.undos.len);
    try t.expectEqual(@as(usize, 0), sheet.redos.len);

    const _setCellText = struct {
        fn func(_allocator: Allocator, _sheet: *Sheet, pos: Position, expr: []const u8) !void {
            var ast = try Ast.fromStringExpression(_allocator, expr);
            errdefer ast.deinit(_allocator);
            try _sheet.setCell(pos, expr, ast, .{});
            _sheet.endUndoGroup();
            try t.expectEqual(ast, _sheet.cells.get(pos).?.ast);
        }
    }.func;

    try _setCellText(allocator, &sheet, try Position.fromAddress("A0"), "'1'");
    try _setCellText(allocator, &sheet, try Position.fromAddress("B0"), "A0 # '2'");
    try _setCellText(allocator, &sheet, try Position.fromAddress("C0"), "B0 # '3'");
    try _setCellText(allocator, &sheet, try Position.fromAddress("D0"), "C0 # '4'");
    try _setCellText(allocator, &sheet, try Position.fromAddress("E0"), "D0 # '5'");
    try _setCellText(allocator, &sheet, try Position.fromAddress("F0"), "E0 # '6'");
    try _setCellText(allocator, &sheet, try Position.fromAddress("G0"), "F0 # '7'");
    try _setCellText(allocator, &sheet, try Position.fromAddress("H0"), "G0 # '8'");
    try _setCellText(allocator, &sheet, try Position.fromAddress("A1"), "A0 # '2'");
    try _setCellText(allocator, &sheet, try Position.fromAddress("B1"), "A1 # B0");
    try _setCellText(allocator, &sheet, try Position.fromAddress("C1"), "B1 # C0");
    try _setCellText(allocator, &sheet, try Position.fromAddress("D1"), "C1 # D0");
    try _setCellText(allocator, &sheet, try Position.fromAddress("E1"), "D1 # E0");
    try _setCellText(allocator, &sheet, try Position.fromAddress("F1"), "E1 # F0");
    try _setCellText(allocator, &sheet, try Position.fromAddress("G1"), "F1 # G0");
    try _setCellText(allocator, &sheet, try Position.fromAddress("A2"), "A1 # '3'");
    try _setCellText(allocator, &sheet, try Position.fromAddress("B2"), "A2 # B1");
    try _setCellText(allocator, &sheet, try Position.fromAddress("C2"), "B2 # C1");
    try _setCellText(allocator, &sheet, try Position.fromAddress("D2"), "C2 # D1");
    try _setCellText(allocator, &sheet, try Position.fromAddress("E2"), "D2 # E1");
    try _setCellText(allocator, &sheet, try Position.fromAddress("F2"), "E2 # F1");
    try _setCellText(allocator, &sheet, try Position.fromAddress("G2"), "F2 # G1");
    try _setCellText(allocator, &sheet, try Position.fromAddress("A3"), "A2 # '4'");
    try _setCellText(allocator, &sheet, try Position.fromAddress("B3"), "A3 # B2");
    try _setCellText(allocator, &sheet, try Position.fromAddress("C3"), "B3 # C2");
    try _setCellText(allocator, &sheet, try Position.fromAddress("D3"), "C3 # D2");
    try _setCellText(allocator, &sheet, try Position.fromAddress("E3"), "D3 # E2");
    try _setCellText(allocator, &sheet, try Position.fromAddress("F3"), "E3 # F2");
    try _setCellText(allocator, &sheet, try Position.fromAddress("G3"), "F3 # G2");
    try _setCellText(allocator, &sheet, try Position.fromAddress("A4"), "A3 # '5'");
    try _setCellText(allocator, &sheet, try Position.fromAddress("B4"), "A4 # B3");
    try _setCellText(allocator, &sheet, try Position.fromAddress("C4"), "B4 # C3");
    try _setCellText(allocator, &sheet, try Position.fromAddress("D4"), "C4 # D3");
    try _setCellText(allocator, &sheet, try Position.fromAddress("E4"), "D4 # E3");
    try _setCellText(allocator, &sheet, try Position.fromAddress("F4"), "E4 # F3");
    try _setCellText(allocator, &sheet, try Position.fromAddress("G4"), "F4 # G3");
    try _setCellText(allocator, &sheet, try Position.fromAddress("A5"), "A4 # '6'");
    try _setCellText(allocator, &sheet, try Position.fromAddress("B5"), "A5 # B4");
    try _setCellText(allocator, &sheet, try Position.fromAddress("C5"), "B5 # C4");
    try _setCellText(allocator, &sheet, try Position.fromAddress("D5"), "C5 # D4");
    try _setCellText(allocator, &sheet, try Position.fromAddress("E5"), "D5 # E4");
    try _setCellText(allocator, &sheet, try Position.fromAddress("F5"), "E5 # F4");
    try _setCellText(allocator, &sheet, try Position.fromAddress("G5"), "F5 # G4");
    try _setCellText(allocator, &sheet, try Position.fromAddress("A6"), "A5 # '7'");
    try _setCellText(allocator, &sheet, try Position.fromAddress("B6"), "A6 # B5");
    try _setCellText(allocator, &sheet, try Position.fromAddress("C6"), "B6 # C5");
    try _setCellText(allocator, &sheet, try Position.fromAddress("D6"), "C6 # D5");
    try _setCellText(allocator, &sheet, try Position.fromAddress("E6"), "D6 # E5");
    try _setCellText(allocator, &sheet, try Position.fromAddress("F6"), "E6 # F5");
    try _setCellText(allocator, &sheet, try Position.fromAddress("G6"), "F6 # G5");
    try _setCellText(allocator, &sheet, try Position.fromAddress("A7"), "A6 # '8'");
    try _setCellText(allocator, &sheet, try Position.fromAddress("B7"), "A7 # B6");
    try _setCellText(allocator, &sheet, try Position.fromAddress("C7"), "B7 # C6");
    try _setCellText(allocator, &sheet, try Position.fromAddress("D7"), "C7 # D6");
    try _setCellText(allocator, &sheet, try Position.fromAddress("E7"), "D7 # E6");
    try _setCellText(allocator, &sheet, try Position.fromAddress("F7"), "E7 # F6");
    try _setCellText(allocator, &sheet, try Position.fromAddress("G7"), "F7 # G6");
    try _setCellText(allocator, &sheet, try Position.fromAddress("A8"), "A7 # '9'");
    try _setCellText(allocator, &sheet, try Position.fromAddress("B8"), "A8 # B7");
    try _setCellText(allocator, &sheet, try Position.fromAddress("C8"), "B8 # C7");
    try _setCellText(allocator, &sheet, try Position.fromAddress("D8"), "C8 # D7");
    try _setCellText(allocator, &sheet, try Position.fromAddress("E8"), "D8 # E7");
    try _setCellText(allocator, &sheet, try Position.fromAddress("F8"), "E8 # F7");
    try _setCellText(allocator, &sheet, try Position.fromAddress("G8"), "F8 # G7");
    try _setCellText(allocator, &sheet, try Position.fromAddress("A9"), "A8 # '0'");
    try _setCellText(allocator, &sheet, try Position.fromAddress("B9"), "A9 # B8");
    try _setCellText(allocator, &sheet, try Position.fromAddress("C9"), "B9 # C8");
    try _setCellText(allocator, &sheet, try Position.fromAddress("D9"), "C9 # D8");
    try _setCellText(allocator, &sheet, try Position.fromAddress("E9"), "D9 # E8");
    try _setCellText(allocator, &sheet, try Position.fromAddress("F9"), "E9 # F8");
    try _setCellText(allocator, &sheet, try Position.fromAddress("G9"), "F9 # G8");
    try _setCellText(allocator, &sheet, try Position.fromAddress("A10"), "A9 # '1'");
    try _setCellText(allocator, &sheet, try Position.fromAddress("B10"), "A10 # B9");
    try _setCellText(allocator, &sheet, try Position.fromAddress("C10"), "B10 # C9");
    try _setCellText(allocator, &sheet, try Position.fromAddress("D10"), "C10 # D9");
    try _setCellText(allocator, &sheet, try Position.fromAddress("E10"), "D10 # E9");
    try _setCellText(allocator, &sheet, try Position.fromAddress("F10"), "E10 # F9");
    try _setCellText(allocator, &sheet, try Position.fromAddress("G10"), "F10 # G9");
    try _setCellText(allocator, &sheet, try Position.fromAddress("A11"), "A10 # '2'");
    try _setCellText(allocator, &sheet, try Position.fromAddress("B11"), "A11 # B10");
    try _setCellText(allocator, &sheet, try Position.fromAddress("C11"), "B11 # C10");
    try _setCellText(allocator, &sheet, try Position.fromAddress("D11"), "C11 # D10");
    try _setCellText(allocator, &sheet, try Position.fromAddress("E11"), "D11 # E10");
    try _setCellText(allocator, &sheet, try Position.fromAddress("F11"), "E11 # F10");
    try _setCellText(allocator, &sheet, try Position.fromAddress("G11"), "F11 # G10");
    try _setCellText(allocator, &sheet, try Position.fromAddress("A12"), "A11 # '3'");
    try _setCellText(allocator, &sheet, try Position.fromAddress("B12"), "A12 # B11");
    try _setCellText(allocator, &sheet, try Position.fromAddress("C12"), "B12 # C11");
    try _setCellText(allocator, &sheet, try Position.fromAddress("D12"), "C12 # D11");
    try _setCellText(allocator, &sheet, try Position.fromAddress("E12"), "D12 # E11");
    try _setCellText(allocator, &sheet, try Position.fromAddress("F12"), "E12 # F11");
    try _setCellText(allocator, &sheet, try Position.fromAddress("G12"), "F12 # G11");
    try _setCellText(allocator, &sheet, try Position.fromAddress("A13"), "A12 # '4'");
    try _setCellText(allocator, &sheet, try Position.fromAddress("B13"), "A13 # B12");
    try _setCellText(allocator, &sheet, try Position.fromAddress("C13"), "B13 # C12");
    try _setCellText(allocator, &sheet, try Position.fromAddress("D13"), "C13 # D12");
    try _setCellText(allocator, &sheet, try Position.fromAddress("E13"), "D13 # E12");
    try _setCellText(allocator, &sheet, try Position.fromAddress("F13"), "E13 # F12");
    try _setCellText(allocator, &sheet, try Position.fromAddress("G13"), "F13 # G12");
    try _setCellText(allocator, &sheet, try Position.fromAddress("A14"), "A13 # '5'");
    try _setCellText(allocator, &sheet, try Position.fromAddress("B14"), "A14 # B13");
    try _setCellText(allocator, &sheet, try Position.fromAddress("C14"), "B14 # C13");
    try _setCellText(allocator, &sheet, try Position.fromAddress("D14"), "C14 # D13");
    try _setCellText(allocator, &sheet, try Position.fromAddress("E14"), "D14 # E13");
    try _setCellText(allocator, &sheet, try Position.fromAddress("F14"), "E14 # F13");
    try _setCellText(allocator, &sheet, try Position.fromAddress("G14"), "F14 # G13");
    try _setCellText(allocator, &sheet, try Position.fromAddress("A15"), "A14 # '6'");
    try _setCellText(allocator, &sheet, try Position.fromAddress("B15"), "A15 # B14");
    try _setCellText(allocator, &sheet, try Position.fromAddress("C15"), "B15 # C14");
    try _setCellText(allocator, &sheet, try Position.fromAddress("D15"), "C15 # D14");
    try _setCellText(allocator, &sheet, try Position.fromAddress("E15"), "D15 # E14");
    try _setCellText(allocator, &sheet, try Position.fromAddress("F15"), "E15 # F14");
    try _setCellText(allocator, &sheet, try Position.fromAddress("G15"), "F15 # G14");
    try _setCellText(allocator, &sheet, try Position.fromAddress("A16"), "A15 # '7'");
    try _setCellText(allocator, &sheet, try Position.fromAddress("B16"), "A16 # B15");
    try _setCellText(allocator, &sheet, try Position.fromAddress("C16"), "B16 # C15");
    try _setCellText(allocator, &sheet, try Position.fromAddress("D16"), "C16 # D15");
    try _setCellText(allocator, &sheet, try Position.fromAddress("E16"), "D16 # E15");
    try _setCellText(allocator, &sheet, try Position.fromAddress("F16"), "E16 # F15");
    try _setCellText(allocator, &sheet, try Position.fromAddress("G16"), "F16 # G15");
    try _setCellText(allocator, &sheet, try Position.fromAddress("A17"), "A16 # '8'");
    try _setCellText(allocator, &sheet, try Position.fromAddress("B17"), "A17 # B16");
    try _setCellText(allocator, &sheet, try Position.fromAddress("C17"), "B17 # C16");
    try _setCellText(allocator, &sheet, try Position.fromAddress("D17"), "C17 # D16");
    try _setCellText(allocator, &sheet, try Position.fromAddress("E17"), "D17 # E16");
    try _setCellText(allocator, &sheet, try Position.fromAddress("F17"), "E17 # F16");
    try _setCellText(allocator, &sheet, try Position.fromAddress("G17"), "F17 # G16");
    try _setCellText(allocator, &sheet, try Position.fromAddress("A18"), "A17 # '9'");
    try _setCellText(allocator, &sheet, try Position.fromAddress("B18"), "A18 # B17");
    try _setCellText(allocator, &sheet, try Position.fromAddress("C18"), "B18 # C17");
    try _setCellText(allocator, &sheet, try Position.fromAddress("D18"), "C18 # D17");
    try _setCellText(allocator, &sheet, try Position.fromAddress("E18"), "D18 # E17");
    try _setCellText(allocator, &sheet, try Position.fromAddress("F18"), "E18 # F17");
    try _setCellText(allocator, &sheet, try Position.fromAddress("G18"), "F18 # G17");
    try _setCellText(allocator, &sheet, try Position.fromAddress("A19"), "A18 # '0'");
    try _setCellText(allocator, &sheet, try Position.fromAddress("B19"), "A19 # B18");
    try _setCellText(allocator, &sheet, try Position.fromAddress("C19"), "B19 # C18");
    try _setCellText(allocator, &sheet, try Position.fromAddress("D19"), "C19 # D18");
    try _setCellText(allocator, &sheet, try Position.fromAddress("E19"), "D19 # E18");
    try _setCellText(allocator, &sheet, try Position.fromAddress("F19"), "E19 # F18");
    try _setCellText(allocator, &sheet, try Position.fromAddress("G19"), "F19 # G18");
    try _setCellText(allocator, &sheet, try Position.fromAddress("A20"), "A19 # '1'");
    try _setCellText(allocator, &sheet, try Position.fromAddress("B20"), "A20 # B19");
    try _setCellText(allocator, &sheet, try Position.fromAddress("C20"), "B20 # C19");
    try _setCellText(allocator, &sheet, try Position.fromAddress("D20"), "C20 # D19");
    try _setCellText(allocator, &sheet, try Position.fromAddress("E20"), "D20 # E19");
    try _setCellText(allocator, &sheet, try Position.fromAddress("F20"), "E20 # F19");
    try _setCellText(allocator, &sheet, try Position.fromAddress("G20"), "F20 # G19");

    try sheet.update();

    // Only checks the eval results of some of the cells, checking all is kinda slow
    const strings = @embedFile("strings.csv");
    var line_iter = std.mem.tokenizeScalar(u8, strings, '\n');
    var y: u16 = 0;
    while (line_iter.next()) |line| : (y += 1) {
        var col_iter = std.mem.tokenizeScalar(u8, line, ',');
        var x: u16 = 0;
        while (col_iter.next()) |col| : (x += 1) {
            const str = std.mem.span(sheet.cells.get(.{ .x = x, .y = y }).?.value.string);
            try t.expectEqualStrings(col, str);
        }
    }

    try t.expectEqual(
        Undo{ .delete_cell = try Position.fromAddress("G20") },
        sheet.undos.get(sheet.undos.len - 1),
    );
}

test "Cell assignment, updating, evaluation" {
    if (@import("compile_opts").fast_tests) {
        return error.SkipZigTest;
    }

    try std.testing.checkAllAllocationFailures(std.testing.allocator, testCellEvaluation, .{});
}
