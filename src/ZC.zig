const std = @import("std");
const utils = @import("utils.zig");
const Ast = @import("Parse.zig");
const spoon = @import("spoon");
const Sheet = @import("Sheet.zig");
const Tui = @import("Tui.zig");
const TextInput = @import("text_input.zig").TextInput;

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Self = @This();

sheet: Sheet,
tui: Tui,

mode: Mode = .normal,

/// The top left corner of the screen
screen_pos: Position = .{},

prev_cursor: Position = .{},
/// The cell position of the cursor
cursor: Position = .{},

running: bool = true,

allocator: Allocator,

command_buf: TextInput(512) = .{},

pub const status_line = 0;
pub const input_line = 1;
pub const col_heading_line = 2;
pub const content_line = 3;

pub const Mode = enum {
	normal,
	command,

	pub fn format(
		self: Mode,
		comptime _: []const u8,
		_: std.fmt.FormatOptions,
		writer: anytype,
	) !void {
		const name = inline for (std.meta.fields(Mode)) |field| {
			const val = comptime std.meta.stringToEnum(Mode, field.name);
			if (self == val)
				break field.name;
		} else unreachable;

		try writer.writeAll(name);
	}
};

pub const Position = struct {
	x: u16 = 0,
	y: u16 = 0,
};

pub fn init(allocator: Allocator) !Self {
	return .{
		.sheet = Sheet.init(allocator),
		.tui = try Tui.init(),
		.allocator = allocator,
	};
}

pub fn deinit(self: *Self) void {
	self.sheet.deinit();
	self.tui.deinit();
	self.* = undefined;
}

pub fn run(self: *Self) !void {
	while (self.running) {
		try self.updateCells();
		try self.tui.render(self);
		try self.handleInput();
	}
}

pub fn updateCells(self: *Self) Allocator.Error!void {
	return self.sheet.update();
}

fn setMode(self: *Self, new_mode: Mode) void {
	if (new_mode == .command) {
		self.tui.dismissStatusMessage();
	} else if (self.mode == .command) {
		self.tui.update_command = true;
	}

	self.mode = new_mode;
}

fn handleInput(self: *Self) !void {
	var buf: [16]u8 = undefined;
	const slice = try self.tui.term.readInput(&buf);

	try switch (self.mode) {
		.normal => self.doNormalMode(slice),
		.command => self.doCommandMode(slice) catch |err| switch (err) {
			error.UnexpectedToken => self.tui.setStatusMessage("Error: unexpected token", .{}),
			else => return err,
		},
	};
}

fn doNormalMode(self: *Self, buf: []const u8) !void {
	var iter = spoon.inputParser(buf);

	while (iter.next()) |in| {
		if (!in.mod_ctrl)  switch (in.content) {
			.escape => self.tui.dismissStatusMessage(),
			.codepoint => |cp| switch (cp) {
				'q' => self.running = false,
				':' => self.setMode(.command),
				'f' => if (self.sheet.columns.getPtr(self.cursor.x)) |col| {
					col.precision +|= 1;
				},
				'F' => if (self.sheet.columns.getPtr(self.cursor.x)) |col| {
					col.precision -|= 1;
				},
				'k' => self.setCursor(.{ .y = self.cursor.y -| 1, .x = self.cursor.x }),
				'j' => self.setCursor(.{ .y = self.cursor.y +| 1, .x = self.cursor.x }),
				'h' => self.setCursor(.{ .x = self.cursor.x -| 1, .y = self.cursor.y }),
				'l' => self.setCursor(.{ .x = self.cursor.x +| 1, .y = self.cursor.y }),
				'=' => {
					self.setMode(.command);
					var _buf: [16]u8 = undefined;
					const cell_name = utils.posToCellName(self.cursor.y, self.cursor.x, &_buf);

					const writer = self.command_buf.writer();
					writer.print("{s} = ", .{ cell_name }) catch unreachable;
				},
				else => {},
			},
			else => {},
		} else switch (in.content) {
			.codepoint => |cp| switch (cp) {
				// C-[ is indistinguishable from Escape on most terminals. On terminals where they
				// can be distinguished, we make them do the same thing for a consistent experience
				'[' => self.tui.dismissStatusMessage(),
				else => {},
			},
			else => {},
		}
	}
}

fn doCommandMode(self: *Self, input: []const u8) !void {
	const status = self.command_buf.handleInput(input);
	switch (status) {
		.waiting => {},
		.cancelled => self.setMode(.normal),
		.string => |arr| {
			defer self.setMode(.normal);
			const str = arr.slice();

			var ast = try Ast.parse(self.allocator, str);
			errdefer ast.deinit(self.allocator);

			const root = ast.rootNode();
			switch (root) {
				.assignment => |op| {
					const pos = ast.nodes.items(.data)[op.lhs].cell;
					ast.splice(op.rhs); // Cut ast down to just the expression

					try self.sheet.setCell(pos, .{ .ast = ast });
					self.tui.update_cursor = true;
					self.tui.update_cells = true;
				},
				else => {
					ast.deinit(self.allocator);
				},
			}
		},
	}
}

pub fn setCursor(self: *Self, new_pos: Position) void {
	self.prev_cursor = self.cursor;
	self.cursor = new_pos;
	self.clampScreenToCursor();

	self.tui.update_cursor = true;
}

pub inline fn contentHeight(self: Self) u16 {
	return self.tui.term.height -| content_line;
}

pub fn leftReservedColumns(self: Self) u16 {
	const y = self.screen_pos.y +| self.contentHeight() -| 1;

	if (y == 0)
		return 2;

	return std.math.log10(y) + 2;
}

pub fn clampScreenToCursor(self: *Self) void {
	self.clampScreenToCursorY();
	self.clampScreenToCursorX();
}

pub fn clampScreenToCursorY(self: *Self) void {
	if (self.cursor.y < self.screen_pos.y) {
		self.screen_pos.y = self.cursor.y;
		self.tui.update_row_numbers = true;
		self.tui.update_cells = true;
		return;
	}

	const height = self.contentHeight();
	if (self.cursor.y - self.screen_pos.y >= height) {
		self.screen_pos.y = self.cursor.y - (height -| 1);
		self.tui.update_row_numbers = true;
		self.tui.update_cells = true;
	}
}

pub fn clampScreenToCursorX(self: *Self) void {
	if (self.cursor.x < self.screen_pos.x) {
		self.screen_pos.x = self.cursor.x;
		self.tui.update_column_headings = true;
		self.tui.update_cells = true;
		return;
	}

	const reserved_cols = self.leftReservedColumns();

	var w = reserved_cols;
	var x: i17 = self.cursor.x;

	while (true) : (x -= 1) {
		if (x < self.screen_pos.x)
			return;

		const width = blk: {
			if (x >= 0) {
				if (self.sheet.columns.get(@intCast(u16, x))) |col| {
					break :blk col.width;
				}
			}

			break :blk Sheet.Column.default_width;
		};

		w += width;

		if (w > self.tui.term.width)
			break;
	}

	if (x >= self.screen_pos.x) {
		self.screen_pos.x = @intCast(u16, @max(0, x + 1));
		self.tui.update_column_headings = true;
		self.tui.update_cells = true;
	}
}
