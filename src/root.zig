const std = @import("std");
const Watcher = @import("Watcher.zig");

const parent_path = "/tmp";
const sub_path = "tube";

pub fn Tube(comptime T: type) type {
    return struct {
        pub const Options = struct {};
        const TTube = @This();
        parser_arena: std.heap.ArenaAllocator,
        alloc_writer: std.Io.Writer.Allocating,
        dir: std.fs.Dir,
        on_added: *const fn (*anyopaque, T) void = undefined,
        on_added_end: *const fn (*anyopaque) void = undefined,
        on_added_ptr: *anyopaque = undefined,
        watcher: ?Watcher = null,
        mutex: std.Thread.Mutex,
        io_buffer: [1024]u8 = undefined,
        pub fn init(
            allocator: std.mem.Allocator,
            start_empty: bool,
        ) !TTube {
            var parent_dir = try std.fs.openDirAbsolute(parent_path, .{});
            defer parent_dir.close();
            if (start_empty) try parent_dir.deleteTree(sub_path);
            return .{
                .parser_arena = .init(allocator),
                .alloc_writer = .init(allocator),
                .dir = try parent_dir.makeOpenPath(sub_path, .{ .iterate = true }),
                .mutex = .{},
            };
        }
        pub fn listen(self: *TTube, on_added_ptr: *anyopaque, on_added: *const fn (*anyopaque, T) void) !void {
            self.on_added_ptr = on_added_ptr;
            self.on_added = on_added;
            self.watcher = .{ .dir = self.dir, .on_renamed_ptr = self, .on_renamed = on_file_updated };
            try self.watcher.?.start();
        }
        /// Thread safe
        fn on_file_updated(self_ptr: *anyopaque, file_name: []const u8) void {
            var self: *TTube = @ptrCast(@alignCast(self_ptr));
            self.mutex.lock();
            defer self.mutex.unlock();
            self.read_updated_file(file_name) catch |err| {
                var buf: [300]u8 = undefined;
                const m = std.fmt.bufPrint(&buf, "Error reading update on {s}: {}", .{ file_name, err }) catch unreachable;
                @panic(m);
            };
        }
        fn read_updated_file(self: *TTube, file_name: []const u8) !void {
            var file = try self.dir.openFile(file_name, .{});
            defer file.close();
            var fr = file.reader(&self.io_buffer);
            var w = &self.alloc_writer.writer;
            while (!fr.atEnd()) {
                self.alloc_writer.clearRetainingCapacity();
                _ = self.parser_arena.reset(.retain_capacity);
                _ = std.io.Reader.streamDelimiter(&fr.interface, w, '\n') catch |err| {
                    if (err == error.EndOfStream) break;
                    return err;
                };
                if (try fr.interface.takeByte() != '\n') unreachable;
                try w.writeByte(0);
                const written = self.alloc_writer.written();
                const data = try std.zon.parse.fromSlice(
                    T,
                    self.parser_arena.allocator(),
                    written[0 .. written.len - 1 :0],
                    null,
                    .{},
                );
                @call(.auto, self.on_added, .{ self.on_added_ptr, data });
            }
            @call(.auto, self.on_added_end, .{self.on_added_ptr});
        }
        pub fn deinit(self: *TTube) void {
            if (self.watcher) |*w| w.deinit();
            self.dir.close();
            self.parser_arena.deinit();
            self.alloc_writer.deinit();
        }
        /// Thread safe
        pub fn add(self: *TTube, key: []const u8, val: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            var next: NextFile = try .open(self.dir, &self.io_buffer, key);
            defer next.close();
            _ = try std.zon.stringify.serialize(
                val,
                .{ .emit_default_optional_fields = false, .whitespace = false },
                next.writer(),
            );
            try next.writer().writeByte('\n');
            try next.commit();
        }
    };
}

const NextFile = struct {
    tmp_name: []const u8,
    name: []const u8,
    parent: std.fs.Dir,
    file: std.fs.File,
    file_writer: std.fs.File.Writer,
    /// work_buffer needs to be at least 256 bytes
    pub fn open(parent: std.fs.Dir, work_buffer: []u8, name: []const u8) !NextFile {
        const fname_buffer = work_buffer[0..256];
        const write_buffer = work_buffer[256..];
        const tmp_name = try std.fmt.bufPrint(fname_buffer, "{s}.tmp", .{name});
        var file = try parent.createFile(tmp_name, .{ .lock = .exclusive });
        errdefer file.close();
        parent.copyFile(name, parent, tmp_name, .{}) catch |err| {
            if (err != error.FileNotFound) return err;
        };
        try file.seekFromEnd(0);
        return .{
            .parent = parent,
            .name = name,
            .file = file,
            .tmp_name = tmp_name,
            .file_writer = file.writer(write_buffer),
        };
    }
    pub fn writer(self: *NextFile) *std.Io.Writer {
        return &self.file_writer.interface;
    }
    /// The only valid operation after commit is close.
    pub fn commit(self: *NextFile) !void {
        try self.file_writer.interface.flush();
        try self.parent.rename(self.tmp_name, self.name);
    }
    pub fn close(self: *NextFile) void {
        self.file.close();
    }
};
