const std = @import("std");
const zoncom = @import("zoncom");

const log = std.log.scoped(.example);

var clock: u64 = 0;
fn timestamp() u64 {
    defer clock += 1;
    return clock;
}

const Record = struct {
    some_text: []const u8,
    some_float: f64,
    ms_timestamp: u64,
    pub fn random(rng: std.Random) Record {
        return .{
            .some_text = example_texts[@mod(rng.int(u8), example_texts.len)],
            .some_float = rng.float(f64),
            .ms_timestamp = timestamp(),
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

pub fn main() !void {
    var alloc = std.heap.page_allocator;
    const keys = 10_000;
    const key_width: usize = @intFromFloat(@round(@log10(@as(f64, @floatFromInt(keys - 1)))));
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
    const updates = 100;

    var tube: zoncom.Tube(Record) = try .initEmpty(alloc);
    defer tube.deinit();

    const begin = std.time.nanoTimestamp();
    for (0..updates) |_| {
        for (0..keys) |id| {
            const key = key_names[key_width * id .. key_width * (id + 1)];
            try tube.add(key, Record.random(random));
        }
    }
    const diff = std.time.nanoTimestamp() - begin;

    const ns_per_full_update = @divTrunc(diff, updates);
    const ns_per_single_update = @divTrunc(ns_per_full_update, keys);
    logTime("Total Time", diff);
    logTime("Avg per full update", ns_per_full_update);
    logTime("Avg per single update", ns_per_single_update);
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
