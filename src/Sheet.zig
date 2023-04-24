const std = @import("std");
const Ast = @import("Parse.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Sheet = @This();
const NodeList = std.ArrayList(Position);
const NodeListUnmanaged = std.ArrayListUnmanaged(Position);

const log = std.log.scoped(.sheet);

const PositionContext = struct {
	pub fn eql(_: @This(), p1: Position, p2: Position, _: usize) bool {
		return p1.y == p2.y and p1.x == p2.x;
	}

	pub fn hash(_: @This(), pos: Position) u32 {
		return @as(u32, pos.y) * std.math.maxInt(u16) + pos.x;
	}
};

const CellMap = std.ArrayHashMapUnmanaged(Position, Cell, PositionContext, false);

/// ArrayHashMap mapping spreadsheet positions to cells.
cells: CellMap = .{},

/// Maps column indexes (0 - 65535) to `Column` structs containing info about that column.
columns: std.AutoArrayHashMapUnmanaged(u16, Column) = .{},
filename: []const u8 = &.{},

/// Cell positions sorted topologically, used for order of evaluation when evaluating all cells.
sorted_nodes: NodeListUnmanaged = .{},
needs_update: bool = false,

allocator: Allocator,

pub fn init(allocator: Allocator) Sheet {
	return .{
		.allocator = allocator,
	};
}

pub fn deinit(sheet: *Sheet) void {
	sheet.cells.deinit(sheet.allocator);
	sheet.sorted_nodes.deinit(sheet.allocator);
	sheet.columns.deinit(sheet.allocator);
	sheet.* = undefined;
}

pub fn setCell(
	sheet: *Sheet,
	position: Position,
	data: Cell,
) !void {
	const col_entry = try sheet.columns.getOrPut(sheet.allocator, position.x);
	if (!col_entry.found_existing) {
		col_entry.value_ptr.* = Column{};
	}

	const entry = try sheet.cells.getOrPut(sheet.allocator, position);

	if (entry.found_existing) {
		entry.value_ptr.ast.deinit(sheet.allocator);
	}

	entry.value_ptr.* = data;
	sheet.needs_update = true;
}

pub fn getCell(sheet: Sheet, pos: Position) ?Cell {
	return sheet.cells.get(pos);
}

pub fn getCellPtr(sheet: *Sheet, pos: Position) ?*Cell {
	return sheet.cells.getPtr(pos);
}

const NodeMark = enum {
	temporary,
	permanent,
};

/// Re-evaluates all cells in the sheet. It evaluates cells in reverse topological order to ensure
/// that we only need to evaluate each cell once. Cell results are cached after they are evaluted
/// (see Cell.eval)
pub fn update(sheet: *Sheet) Allocator.Error!void {
	if (!sheet.needs_update)
		return;

	try sheet.rebuildSortedNodeList();

	var iter = std.mem.reverseIterator(sheet.sorted_nodes.items);
	while (iter.next()) |pos| {
		const cell = sheet.getCellPtr(pos).?;
		_ = cell.eval(sheet);
	}

	sheet.needs_update = false;
}

const NodeMap = std.HashMap(Position, NodeMark, struct {
	pub fn eql(_: @This(), p1: Position, p2: Position) bool {
		return p1.y == p2.y and p1.x == p2.x;
	}

	pub fn hash(_: @This(), pos: Position) u64 {
		return @as(u32, pos.y) * std.math.maxInt(u16) + pos.x;
	}
}, 99);

fn rebuildSortedNodeList(sheet: *Sheet) Allocator.Error!void {
	const node_count = @intCast(u32, sheet.cells.entries.len);

	// Topologically sorted set of cell positions
	var nodes = sheet.sorted_nodes.toManaged(sheet.allocator);
	nodes.clearRetainingCapacity();

	var visited_nodes = NodeMap.init(sheet.allocator);
	defer visited_nodes.deinit();

	try nodes.ensureTotalCapacity(node_count + 1);
	try visited_nodes.ensureTotalCapacity(node_count + 1);

	for (sheet.cells.keys()) |pos| {
		if (!visited_nodes.contains(pos))
			try visit(sheet, pos, &nodes, &visited_nodes);
	}

	sheet.sorted_nodes = nodes.moveToUnmanaged();
}

/// Recursive function that visits every dependency of a cell.
fn visit(
	sheet: *const Sheet,
	node: Position,
	nodes: *NodeList,
	visited_nodes: *NodeMap,
) Allocator.Error!void {
	if (visited_nodes.get(node)) |mark| {
		switch (mark) {
			.permanent => return,
			.temporary => unreachable,
		}
	}

	var cell = sheet.getCell(node) orelse return;

	visited_nodes.putAssumeCapacity(node, .temporary);

	const Context = struct {
		sheet: *const Sheet,
		node: Position,
		nodes: *NodeList,
		visited_nodes: *NodeMap,

		pub fn evalCell(context: @This(), index: u32) Allocator.Error!bool {
			const _cell = context.sheet.getCell(context.node).?;
			const ast_node = _cell.ast.nodes.get(index);
			if (ast_node == .cell) {
				// Stop traversal on cyclical reference
				if (context.visited_nodes.contains(ast_node.cell))
					return false;

				try visit(context.sheet, ast_node.cell, context.nodes, context.visited_nodes);
			}
			return true;
		}
	};

	try cell.ast.traverse(Context{
		.sheet = sheet,
		.node = node,
		.nodes = nodes,
		.visited_nodes = visited_nodes,
	});

	visited_nodes.putAssumeCapacity(node, .permanent);
	try nodes.insert(0, node);
}

pub const Position = struct {
	x: u16 = 0,
	y: u16 = 0,

	/// Writes the cell address of this position to the given writer.
	pub fn writeCellAddress(pos: Position, writer: anytype) @TypeOf(writer).Error!void {
		try writeColumnAddress(pos.x, writer);
		try writer.print("{d}", .{ pos.y });
	}

	/// Writes the alphabetic bijective base-26 representation of the given number to the passed
	/// writer.
	pub fn writeColumnAddress(index: u16, writer: anytype) @TypeOf(writer).Error!void {
		if (index < 26) {
			try writer.writeByte('A' + @intCast(u8, index));
			return;
		}

		// Max value is 'CRXO'
		var buf: [4]u8 = undefined;
		var stream = std.io.fixedBufferStream(&buf);
		const bufwriter = stream.writer();

		var i = index +| 1;
		while (i > 0) : (i /= 26) {
			i -= 1;
			const r = @intCast(u8, i % 26);
			bufwriter.writeByte('A' + r) catch unreachable;
		}

		const slice = stream.getWritten();
		std.mem.reverse(u8, slice);
		_ = try writer.writeAll(slice);
	}

	pub fn columnAddressBuf(index: u16, buf: []u8) []u8 {
		if (index < 26) {
			std.debug.assert(buf.len >= 1);
			buf[0] = 'A' + @intCast(u8, index);
			return buf[0..1];
		}

		var stream = std.io.fixedBufferStream(buf);
		const writer = stream.writer();

		var i = index +| 1;
		while (i > 0) : (i /= 26) {
			i -= 1;
			const r = @intCast(u8, i % 26);
			writer.writeByte('A' + r) catch break;
		}

		const slice = stream.getWritten();
		std.mem.reverse(u8, slice);
		return slice;
	}

	pub fn columnFromAddress(address: []const u8) u16 {
		var ret: u16 = 0;
		for (address) |c| {
			if (!std.ascii.isAlphabetic(c))
				break;
			ret = ret * 26 + (std.ascii.toUpper(c) - 'A' + 1);
		}

		return ret - 1;
	}

	pub fn fromCellAddress(address: []const u8) Position {
		assert(address.len > 1);
		assert(std.ascii.isAlphabetic(address[0]));
		assert(std.ascii.isDigit(address[address.len-1]));

		const letters_end = for (address, 0..) |c, i| {
			if (!std.ascii.isAlphabetic(c))
				break i;
		} else unreachable;

		return .{
			.x = columnFromAddress(address[0..letters_end]),
			.y = std.fmt.parseInt(u16, address[letters_end..], 0) catch unreachable,
		};
	}
};

pub const Cell = struct {
	num: ?f64 = null,
	ast: Ast = .{},

	pub fn deinit(cell: *Cell, allocator: Allocator) void {
		cell.ast.deinit(allocator);
		cell.* = undefined;
	}

	pub fn isEmpty(cell: Cell) bool {
		return cell.ast.nodes.len == 0;
	}

	pub fn getValue(cell: *Cell, sheet: *Sheet) f64 {
		return cell.num orelse cell.eval(sheet);
	}

	pub fn eval(cell: *Cell, sheet: *Sheet) f64 {
		const Context = struct {
			sheet: *const Sheet,
			stack: std.BoundedArray(Position, 512) = .{},
	
			pub fn evalCell(context: *@This(), pos: Position) f64 {
				// Check for cyclical references
				for (context.stack.slice()) |p| {
					if (std.meta.eql(pos, p)) {
						return 0;
					}
				}
	
				const _cell = context.sheet.getCell(pos) orelse return 0;
	
				if (context.stack.len == context.stack.capacity()) {
					_ = context.stack.orderedRemove(0);
				}
	
				context.stack.append(pos) catch unreachable;
				const ret = _cell.ast.eval(context);
				_ = context.stack.pop();
				return ret;
			}
		};
	
		var context = Context{ .sheet = sheet };
		const ret = cell.ast.eval(&context);
		cell.num = ret;
		return ret;
	}
};

pub const Column = struct {
	const CellMap = std.AutoArrayHashMapUnmanaged(u16, Cell);
	
	pub const default_width = 10;

	width: u16 = default_width,
	precision: u8 = 2,
};

pub fn getColumn(sheet: Sheet, index: u16) Column {
	return sheet.columns.get(index) orelse Column{};
}
