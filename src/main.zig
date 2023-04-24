const std = @import("std");
const builtin = @import("builtin");

const spoon = @import("spoon");
const Sheet = @import("Sheet.zig");
const Tui = @import("Tui.zig");
const ZC = @import("ZC.zig");

const Allocator = std.mem.Allocator;

var zc: ZC = undefined;

pub fn main() !void {
	if (builtin.mode == .Debug) {
		logfile = try std.fs.cwd().createFile("log.txt", .{});
	}
	defer {
		if (builtin.mode == .Debug) {
			logfile.?.close();
			logfile = null;
		}
	}

	var filename: ?[]const u8 = null;
	var iter = std.process.args();
	_ = iter.next();
	while (iter.next()) |arg| {
		if (arg.len == 0) continue;

		switch (arg[0]) {
			'-' => {},
			else => {
				if (filename) |_| {
					return error.InvalidArguments;
				}
				filename = arg;
			},
		}
	}

	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer _ = gpa.deinit();

	const allocator = gpa.allocator();

	zc = try ZC.init(allocator, filename);
	defer zc.deinit();

	try zc.run();
}

pub fn panic(msg: []const u8, trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    @setCold(true);
    zc.tui.term.cook() catch {};
    std.builtin.default_panic(msg, trace, ret_addr);
}

var logfile: ?std.fs.File = null;

pub const std_options = struct {
	pub const log_level = if (builtin.mode == .Debug) .debug else .info;
	pub const logFn = if (builtin.mode == .Debug) log else std.log.defaultLog;
};

pub fn log(
	comptime level: std.log.Level,
	comptime scope: @TypeOf(.EnumLiteral),
	comptime format: []const u8,
	args: anytype,
) void {
	if (logfile) |file| {
		const writer = file.writer();
		writer.print("[{}] {}:", .{ scope, level }) catch unreachable;
		writer.print(format, args) catch unreachable;
		writer.writeByte('\n') catch unreachable;
		file.sync() catch unreachable;
	} else {
		std.log.defaultLog(level, scope, format, args);
	}
}

// Reference all tests in other modules
comptime {
	std.testing.refAllDecls(@import("Parse.zig"));
	std.testing.refAllDecls(ZC);
	std.testing.refAllDecls(@import("utils.zig"));
}
