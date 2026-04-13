# zoncom

"Zero-service" shared key-value store for low throughput (<1000 messages/second) applications
on a single system at ~1ms latency.

The motivation for `zoncom` is to communicate a shared state between processes running on the
same machine without using or running a separate service process, like a database.

It uses the Linux operating system as the "service", via:
- Folder `/tmp/tube` for persistence
- POSIX file rename() atomicity guarantee
- Linux `fanotify` mechanism to signal updates

# Running the benchmark test

`zig build run` will run some benchmark tests on your system:
- A full speed test that is likely to trigger `Fanotify queue overloaded` warnings and show
  90% of latency measurements below 100ms.
- A normal speed test that should show 99.9% of latency measurements below 2ms.

# Example use

```
const zoncom = @import("zomcom");

const FootballMatch = struct {
	name: []const u8,
	start_time_rfc3339: []const u8,
	score: struct { u16, u16 },
};

const UpdateReceiver = struct {
    pub fn receive(self_ptr: *anyopaque, key: []const u8, value: FootballMatch) void {
        var self: *UpdateReceiver = @ptrCast(@alignCast(self_ptr));
        std.log.info(
            "Received update on match {s} (id {s}) starting {s}: Score {d}-{d}",
            .{ value.name, key, value.start_time_rfc3339, score.@"0", score.@"1" },
        );
    }
};

pub fn main() !void {
    var tube: zoncom.Tube(FootballMatch) = try .init(std.heap.page_allocator, .{});
    defer tube.deinit();
    
    var receiver: UpdateReceiver = .{};
    try tube.listen(&receiver, &UpdateReceiver.receive);

    try tube.add("match-1", .{
      .name = "Viking - Brann",
      .start_time_rfc3339 = "🤷",
      .score = .{0, 0},
    });

    try tube.add("match-1", .{
      .name = "Viking - Brann",
      .start_time_rfc3339 = "2026-04-18T16:00:00Z",
      .score = .{0, 0},
    });

    try tube.add("match-1", .{
      .name = "Viking - Brann",
      .start_time_rfc3339 = "2026-04-18T16:00:00Z",
      .score = .{1, 0},
    });
    
    // Wait 1 second then exit
    std.Thread.sleep(std.time.ns_per_s);
}
```

# Tube

Tubes are the communication queues, named after how they tend to look when I draw them
on a whiteboard. An application can subscribe to receive key-value updates from
a tube, and write key-value updates to the tube.

# Storage, details

Each key is stored as a file under `/tmp/tube` with the key as filename.

Each value update for the key is appended in Zig Object Notation (zon) serialized form followed
by a newline.

For example, With a zoncom tube for type `struct { name: []const u8, shoe_size: u6 }`, after
writing a few updates to key `customer-1`:

```
$ cat /tmp/tube/customer-1
.{.name="Jermeny Higglesworth",.shoe_size=40}
.{.name="Jeremy Higglesworth",.shoe_size=40}
```

# Restrictions

Keys have to be valid filenames, not ending in `.tmp`. Avoid `/` and don't exceed 256 bytes and
you should be good.

Each key is represented as a file, so the total number of keys must be within file system allowance.
Typically this limit is 10 million files, but the use case `zoncom` was designed for was 10-20
thousand keys.

Each key file stores the full history of updates, with the expectation that the system resets
before it becomes an issue.
