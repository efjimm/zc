const std = @import("std");
const utils = @import("utils.zig");
const Ast = @import("Parser.zig");
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
screen_pos: Pos = .{},

// The cell position of the cursor
cursor: Pos = .{},

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

pub const Pos = struct {
	x: u16 = 0,
	y: u16 = 0,
};

pub fn init(allocator: Allocator) !Self {
	return .{
		.sheet = Sheet.init(),
		.tui = try Tui.init(),
		.allocator = allocator,
	};
}

pub fn deinit(self: *Self) void {
	self.sheet.deinit(self.allocator);
	self.tui.deinit();
	self.* = undefined;
}

pub fn run(self: *Self) !void {
	while (self.running) {
		self.clampScreenToCursor();

		try self.tui.render(self);
		try self.handleInput();
	}
}

fn setMode(self: *Self, new_mode: Mode) void {
	self.mode = new_mode;
	if (new_mode == .command)
		self.tui.dismissStatusMessage();
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
				'f' => {
					if (self.sheet.columns.getPtr(self.cursor.x)) |col| {
						col.precision +|= 1;
					}
				},
				'F' => {
					if (self.sheet.columns.getPtr(self.cursor.x)) |col| {
						col.precision -|= 1;
					}
				},
				'j' => self.cursor.y +|= 1,
				'k' => self.cursor.y -|= 1,
				'l' => self.cursor.x +|= 1,
				'h' => self.cursor.x -|= 1,
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
			defer ast.deinit(self.allocator);

			const num = ast.evalNode(@intCast(u32, ast.nodes.len) - 1, 0);
			try self.sheet.setCell(self.allocator, self.cursor.y, self.cursor.x, num);
		},
	}
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

pub fn cursorUp(self: *Self) void {
	self.cursor.y -|= 1;
}

pub fn clampScreenToCursor(self: *Self) void {
	self.clampScreenToCursorY();
	self.clampScreenToCursorX();
}

pub fn clampScreenToCursorY(self: *Self) void {
	if (self.cursor.y < self.screen_pos.y) {
		self.screen_pos.y = self.cursor.y;
		return;
	}

	const height = self.contentHeight();
	if (self.cursor.y - self.screen_pos.y >= height) {
		self.screen_pos.y = self.cursor.y - (height -| 1);
	}
}

pub fn clampScreenToCursorX(self: *Self) void {
	if (self.cursor.x < self.screen_pos.x) {
		self.screen_pos.x = self.cursor.x;
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
	}
}
