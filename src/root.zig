const std = @import("std");

const parent_path = "/tmp";
const sub_path = "tube";

pub fn Tube(comptime T: type) type {
    return struct {
        const TTube = @This();
        allocator: std.mem.Allocator,
        alloc_writer: std.Io.Writer.Allocating,
        dir: std.fs.Dir,
        pub fn initEmpty(allocator: std.mem.Allocator) !TTube {
            var parent_dir = try std.fs.openDirAbsolute(parent_path, .{});
            defer parent_dir.close();
            try parent_dir.deleteTree(sub_path);
            return .{
                .allocator = allocator,
                .alloc_writer = .init(allocator),
                .dir = try parent_dir.makeOpenPath(sub_path, .{ .iterate = true }),
            };
        }
        pub fn deinit(self: *TTube) void {
            self.dir.close();
            self.alloc_writer.deinit();
        }
        pub fn add(self: *TTube, key: []const u8, val: T) !void {
            var next: NextFile = try .open(self.dir, key);
            defer next.close();
            _ = try std.zon.stringify.serialize(
                val,
                .{ .emit_default_optional_fields = false, .whitespace = false },
                &next.writer.interface,
            );
            try next.writer.interface.writeByte('\n');
            try next.finalize();
        }
    };
}

const NextFile = struct {
    tmp_name_buf: [256]u8,
    tmp_name: []const u8,
    name: []const u8,
    parent: std.fs.Dir,
    file: std.fs.File,
    write_buf: [1024]u8,
    writer: std.fs.File.Writer,
    pub fn open(parent: std.fs.Dir, name: []const u8) !NextFile {
        var r: NextFile = undefined;
        r.parent = parent;
        r.name = name;
        r.tmp_name = try std.fmt.bufPrint(&r.tmp_name_buf, "{s}.tmp", .{name});
        r.file = try parent.createFile(r.tmp_name, .{ .lock = .exclusive });
        errdefer r.file.close();
        parent.copyFile(name, parent, r.tmp_name, .{}) catch |err| {
            if (err != error.FileNotFound) return err;
        };
        try r.file.seekFromEnd(0);
        r.writer = r.file.writer(&r.write_buf);
        return r;
    }
    pub fn finalize(self: *NextFile) !void {
        try self.writer.interface.flush();
        try self.parent.rename(self.tmp_name, self.name);
    }
    pub fn close(self: *NextFile) void {
        self.file.close();
    }
};
