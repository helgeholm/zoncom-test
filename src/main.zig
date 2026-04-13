const std = @import("std");
const zoncom = @import("zoncom");

const log = std.log.scoped(.example);

const Record = struct {
    some_text: []const u8,
    some_float: f64,
    ms_timestamp: i64,
    pub fn random(rng: std.Random) Record {
        return .{
            .some_text = example_texts[@mod(rng.int(u8), example_texts.len)],
            .some_float = rng.float(f64),
            .ms_timestamp = std.time.milliTimestamp(),
        };
    }
};

const example_texts: []const []const u8 = &.{
    "Hello I am a text to be data-ed about",
    "Birds!",
    "Bunnies!",
    "It is true that this is a piece of text.",
    "It is not true that the word the is not a word.",
    "One two three!",
    "Four five six!",
    "Steven hate wine!",
    "Ten ben be my fren.",
};

const UpdateReceiver = struct {
    buckets: struct {
        @"<1       ms": usize = 0,
        @"1-2      ms": usize = 0,
        @"2-5      ms": usize = 0,
        @"5-10     ms": usize = 0,
        @"10-100   ms": usize = 0,
        @"100-1000 ms": usize = 0,
        @">1000    ms": usize = 0,
    } = .{},
    delta_count: usize = 0,
    pub fn receive(self_ptr: *anyopaque, _: []const u8, r: Record) void {
        var self: *UpdateReceiver = @ptrCast(@alignCast(self_ptr));
        const d = std.time.milliTimestamp() - r.ms_timestamp;
        if (d < 1) {
            self.buckets.@"<1       ms" += 1;
        } else if (d < 2) {
            self.buckets.@"1-2      ms" += 1;
        } else if (d < 5) {
            self.buckets.@"2-5      ms" += 1;
        } else if (d < 10) {
            self.buckets.@"5-10     ms" += 1;
        } else if (d < 100) {
            self.buckets.@"10-100   ms" += 1;
        } else if (d < 1000) {
            self.buckets.@"100-1000 ms" += 1;
        } else self.buckets.@">1000    ms" += 1;
        self.delta_count += 1;
    }
    pub fn logBuckets(self: UpdateReceiver) void {
        const f_c: f64 = @floatFromInt(self.delta_count);
        inline for (std.meta.fields(@TypeOf(self.buckets))) |f| {
            const f_v: f64 = @floatFromInt(@field(self.buckets, f.name));
            log.info("{s}: {d:0.2}%", .{ f.name, 100 * f_v / f_c });
        }
    }
};

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    log.info("== FULL SPEED APPENDS ==", .{});
    try benchmark(alloc, 10, false);
    log.info("== 1 MS BETWEEN APPENDS ==", .{});
    try benchmark(alloc, 2, true);
}

pub fn benchmark(alloc: std.mem.Allocator, updates: usize, space_writes: bool) !void {
    const keys = 10_000;
    const key_width = 4;
    const key_names = try alloc.alloc(u8, keys * key_width);
    for (0..keys) |i| {
        _ = try std.fmt.bufPrint(
            key_names[key_width * i .. key_width * i + key_width],
            "{d:04}",
            .{i},
        );
    }
    var rng: std.Random.RomuTrio = .init(1);
    const random = rng.random();

    var tube: zoncom.Tube(Record) = try .init(alloc, .{ .start_empty = true, .log = true });
    defer tube.deinit();
    var receiver: UpdateReceiver = .{};
    try tube.listen(&receiver, &UpdateReceiver.receive);

    const t_ms = std.time.milliTimestamp();
    var sent_count: usize = 0;
    const begin = std.time.nanoTimestamp();
    for (0..updates) |u| {
        log.info("Round {d}/{d}, appending to {d} keys", .{ u + 1, updates, keys });
        for (0..keys) |id| {
            const key = key_names[key_width * id .. key_width * (id + 1)];
            try tube.add(key, Record.random(random));
            sent_count += 1;
            if (space_writes) std.Thread.sleep(std.time.ns_per_ms);
        }
        const t2_ms = std.time.milliTimestamp();
        log.info("{d}ms, {d} sent, {d} received, {d} backpressure", .{ t2_ms - t_ms, sent_count, receiver.delta_count, sent_count - receiver.delta_count });
    }
    const write_diff = std.time.nanoTimestamp() - begin;

    const ns_per_full_update = @divTrunc(write_diff, updates);
    const ns_per_single_update = @divTrunc(ns_per_full_update, keys);
    logTime("Avg write time per single update", ns_per_single_update);
    const total_updates = keys * updates;
    while (receiver.delta_count < total_updates) {
        log.info("Waiting for remaining {d} updates to be received...", .{total_updates - receiver.delta_count});
        std.Thread.sleep(std.time.ns_per_s);
    }
    log.info("Latency quantiles:", .{});
    receiver.logBuckets();
}

fn logTime(comptime desc: []const u8, ns: i128) void {
    log.info("{s}: {d}ns, {d:.3}us, {d:.3}ms", .{ desc, ns, u_sec(ns), m_sec(ns) });
}

fn m_sec(ns: i128) f32 {
    return @as(f32, @floatFromInt(ns)) / 1_000_000;
}

fn u_sec(ns: i128) f32 {
    return @as(f32, @floatFromInt(ns)) / 1_000;
}
