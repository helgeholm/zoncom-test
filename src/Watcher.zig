const std = @import("std");
const fanotify = std.os.linux.fanotify;

const Watcher = @This();

const Errors = error{
    FanotifyLimitExceeded,
    FanotifyNotSupported,
    FanotifyNotPermitted,
    FdQuotaExceeded,
    ThreadQuotaExceeded,
    OutOfMemory,
    DirAccess,
};

dir: std.fs.Dir,
on_renamed_ptr: *anyopaque,
on_renamed: *const fn (*anyopaque, []const u8) void,
fan_fd: i32 = undefined,
epoll_fd: i32 = undefined,
watch_thread: std.Thread = undefined,
running: bool = false,

pub fn start(self: *Watcher) Errors!void {
    try self.setup_watch();
    self.running = true;
    var it = self.dir.iterate();
    while (it.next() catch |err| return mapItErr(err)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".tmp"))
            @call(.auto, self.on_renamed, .{ self.on_renamed_ptr, entry.name });
    }
}

fn mapItErr(err: std.fs.Dir.Iterator.Error) Errors {
    return switch (err) {
        error.AccessDenied,
        error.PermissionDenied,
        => Errors.DirAccess,
        error.SystemResources,
        => Errors.OutOfMemory,
        error.InvalidUtf8,
        error.Unexpected,
        => @panic("Unexpected error from dir.iterate()"),
    };
}

fn watch(self: *Watcher) !void {
    const METADATA_SIZE = @sizeOf(fanotify.event_metadata);
    var buf: [4096]u8 = undefined;
    var epoll_events: [1]std.posix.system.epoll_event = .{.{
        .events = std.os.linux.EPOLL.IN,
        .data = undefined,
    }};
    try std.posix.epoll_ctl(
        self.epoll_fd,
        std.os.linux.EPOLL.CTL_ADD,
        self.fan_fd,
        &epoll_events[0],
    );
    var rem_events: []u8 = &.{};
    while (self.running) {
        if (std.posix.epoll_wait(self.epoll_fd, &epoll_events, 100) == 0) {
            if (rem_events.len > 0) return error.UnexpectedEof;
            continue;
        }
        const size = try std.posix.read(self.fan_fd, buf[rem_events.len..]);
        rem_events = buf[0 .. rem_events.len + size];
        while (rem_events.len >= METADATA_SIZE) {
            const em: [*]align(1) const fanotify.event_metadata = @ptrCast(rem_events);
            if (em[0].mask != fanotify.MarkMask{ .MOVED_TO = true })
                @panic("Received event other than MOVED_TO");
            if (rem_events.len < METADATA_SIZE + em[0].event_len)
                break; // incomplete event, loop to read rest
            var rem_info = rem_events[METADATA_SIZE..em[0].event_len];
            while (rem_info.len > 0) {
                const eif: [*]align(1) fanotify.event_info_fid = @ptrCast(rem_info);
                self.process_fanotify_event(&eif[0]);
                rem_info = rem_info[eif[0].hdr.len..];
            }
            rem_events = rem_events[em[0].event_len..];
        }
        @memmove(buf[0..rem_events.len], rem_events);
    }
}

fn process_fanotify_event(self: Watcher, eif: *align(1) fanotify.event_info_fid) void {
    switch (eif.hdr.info_type) {
        .DFID_NAME => {
            const file_handle: *align(1) std.os.linux.file_handle = @ptrCast(&eif.handle);
            const file_name_z: [*:0]u8 = @ptrCast((&file_handle.f_handle).ptr + file_handle.handle_bytes);
            @call(.auto, self.on_renamed, .{ self.on_renamed_ptr, std.mem.span(file_name_z) });
        },
        else => |eit| {
            var err_buf: [64]u8 = undefined;
            const m = std.fmt.bufPrint(&err_buf, "Unexpected fanotify event info_type {}", .{eit}) catch unreachable;
            @panic(m);
        },
    }
}

fn @"Watch 'n catch 😎"(self: *Watcher) void {
    self.watch() catch |err| {
        var err_buf: [64]u8 = undefined;
        const m = std.fmt.bufPrint(&err_buf, "Error watching tube: {}", .{err}) catch unreachable;
        @panic(m);
    };
}

fn setup_watch(self: *Watcher) Errors!void {
    self.fan_fd = try errorCheckValue(
        std.os.linux.fanotify_init(
            .{ .REPORT_DIR_FID = true, .REPORT_NAME = true },
            @intFromEnum(std.posix.ACCMODE.RDONLY),
        ),
    );
    errdefer std.posix.close(self.fan_fd);
    try errorCheck(std.os.linux.fanotify_mark(
        self.fan_fd,
        .{ .ADD = true },
        .{ .MOVED_TO = true },
        self.dir.fd,
        null,
    ));
    self.epoll_fd = std.posix.epoll_create1(0) catch |err| {
        return switch (err) {
            std.posix.EpollCreateError.SystemResources,
            => Errors.OutOfMemory,
            std.posix.EpollCreateError.ProcessFdQuotaExceeded,
            std.posix.EpollCreateError.SystemFdQuotaExceeded,
            => Errors.FdQuotaExceeded,
            std.posix.EpollCreateError.Unexpected,
            => @panic("Unexpected error from epoll_create1"),
        };
    };
    errdefer std.posix.close(self.epoll_fd);
    self.watch_thread = std.Thread.spawn(.{}, @"Watch 'n catch 😎", .{self}) catch |err| {
        return switch (err) {
            std.Thread.SpawnError.OutOfMemory,
            std.Thread.SpawnError.SystemResources,
            => Errors.OutOfMemory,
            std.Thread.SpawnError.ThreadQuotaExceeded,
            => Errors.ThreadQuotaExceeded,
            std.Thread.SpawnError.LockedMemoryLimitExceeded,
            std.Thread.SpawnError.Unexpected,
            => @panic("Unexpected error from Thread.spawn"),
        };
    };
    errdefer {
        self.running = false;
        self.watch_thread.join();
    }
}

pub fn deinit(self: *Watcher) void {
    if (!self.running) return;
    self.running = false;
    self.watch_thread.join();
    std.posix.close(self.epoll_fd);
    std.posix.close(self.fan_fd);
}

fn errorCheck(retval: anytype) !void {
    _ = try errorCheckValue(retval);
}

fn errorCheckValue(retval: anytype) !i32 {
    if (retval >= 0) return @intCast(retval);
    return switch (@as(std.posix.E, @enumFromInt(-@as(isize, @bitCast(retval))))) {
        std.posix.E.MFILE => Errors.FanotifyLimitExceeded,
        std.posix.E.NOMEM => Errors.OutOfMemory,
        std.posix.E.NOSYS => Errors.FanotifyNotSupported,
        std.posix.E.PERM => Errors.FanotifyNotPermitted,
        std.posix.E.INVAL => unreachable,
        else => |v| {
            var err_buf: [32]u8 = undefined;
            const m = std.fmt.bufPrint(&err_buf, "Unexpected {}", .{v}) catch unreachable;
            @panic(m);
        },
    };
}
