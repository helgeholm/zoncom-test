const std = @import("std");

pub fn Tube(comptime T: type) type {
    return struct {
        const TTube = @This();
        allocator: std.mem.Allocator,
        alloc_writer: std.Io.Writer.Allocating,
        pub fn initEmpty(allocator: std.mem.Allocator) !TTube {
            return .{
                .allocator = allocator,
                .alloc_writer = .init(allocator),
            };
        }
        pub fn deinit(self: *TTube) void {
            self.alloc_writer.deinit();
        }
        pub fn add(self: *TTube, key: []const u8, val: T) !void {
            self.alloc_writer.clearRetainingCapacity();
            _ = try std.zon.stringify.serialize(
                val,
                .{ .emit_default_optional_fields = false, .whitespace = false },
                &self.alloc_writer.writer,
            );
            _ = key;
        }
    };
}
