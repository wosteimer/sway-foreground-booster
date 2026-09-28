const std = @import("std");
const Sway = @import("sway");

const max_iterations = 64;
const buf_capacity = 2048;
const dmem_low_prefix = "/sys/fs/cgroup/";
const dmem_low_postfix = "/dmem.low";
const dmem_capacity_path = "/sys/fs/cgroup/dmem.capacity";

const DMemLimit = struct {
    device: []const u8,
    limit: u64,

    pub fn format(self: *const DMemLimit, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{s} {d}", .{ self.device, self.limit });
    }
};

pub fn main(init: std.process.Init) !void {
    std.log.info("starting sway foreground booster", .{});
    const sock = init.environ_map.get("SWAYSOCK") orelse return error.SwaySockNotFound;
    std.log.info("connecting to Sway IPC: {s}", .{sock});

    var addr = try std.Io.net.UnixAddress.init(sock);
    const connection = try addr.connect(init.io);
    std.log.info("connected to Sway IPC", .{});

    var reader_buf: [buf_capacity]u8 = undefined;
    var reader = connection.reader(init.io, &reader_buf);

    var writer_buf: [buf_capacity]u8 = undefined;
    var writer = connection.writer(init.io, &writer_buf);

    var sway = Sway.init(&reader.interface, &writer.interface);

    const handler = try sway.subscribe(init.gpa, &.{.window});
    defer handler.deinit();
    std.log.info("subscribed to Sway window events", .{});

    var limits_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer limits_arena.deinit();
    const boost_limits = try dmemReadFromPath(limits_arena.allocator(), init.io, dmem_capacity_path);
    for (boost_limits) |capacity| {
        std.log.info("dmem device {s}: capacity={d}", .{ capacity.device, capacity.limit });
    }
    const unboost_limits = try limits_arena.allocator().alloc(DMemLimit, boost_limits.len);
    for (unboost_limits, 0..) |*limit, i| {
        limit.* = .{ .device = boost_limits[i].device, .limit = 0 };
    }

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var current: ?struct { name: []const u8, cgroup: []const u8 } = null;

    while (true) {
        const event = try handler.next();
        if (std.mem.eql(u8, event.window.change, "focus")) {
            if (event.window.container.pid) |pid| {
                const name = event.window.container.name orelse "unknown";

                std.log.info("(focus) {s}: pid={d}", .{ name, pid });

                const cgroup = getCgroupFromPid(init.gpa, init.io, pid) catch |err| {
                    switch (err) {
                        error.FileNotFound => {
                            std.log.warn("(focus) process disappeared before reading cgroup (pid={d})", .{pid});
                            continue;
                        },
                        else => return err,
                    }
                };
                defer init.gpa.free(cgroup);

                std.log.info("(focus) pid={d}: cgroup={s}", .{ pid, cgroup });

                if (current) |c| {
                    if (std.mem.eql(u8, cgroup, c.cgroup)) {
                        continue;
                    }
                    dmemWrite(init.io, c.cgroup, unboost_limits) catch |err| {
                        switch (err) {
                            error.FileNotFound => {
                                std.log.warn(
                                    "cannot unboost {s}: cgroup disappeared ({s})",
                                    .{ c.name, c.cgroup },
                                );
                            },
                            else => return err,
                        }
                    };
                    std.log.info("(unboost) {s}:  cgroup={s}", .{ c.name, c.cgroup });
                }
                _ = arena.reset(.{ .retain_with_limit = 4096 });
                current = .{
                    .name = try allocator.dupe(u8, name),
                    .cgroup = try allocator.dupe(u8, cgroup),
                };
                dmemWrite(init.io, cgroup, boost_limits) catch |err| {
                    switch (err) {
                        error.FileNotFound => {
                            std.log.warn(
                                "cannot boost {s}: cgroup disappeared ({s})",
                                .{ name, cgroup },
                            );
                            _ = arena.reset(.{ .retain_with_limit = 4096 });
                            current = null;
                            continue;
                        },
                        else => return err,
                    }
                };
                std.log.info("(boost) {s}: cgroup={s}", .{ name, cgroup });
            }
        }
    }
}

fn dmemWrite(io: std.Io, cgroup: []const u8, limits: []DMemLimit) !void {
    var buf: [buf_capacity]u8 = undefined;

    const path_fmt = std.fs.path.fmtJoin(&.{ dmem_low_prefix, cgroup, dmem_low_postfix });
    const path = try std.fmt.bufPrint(&buf, "{f}", .{path_fmt});

    std.log.debug("writing dmem limits: {s}", .{path});

    const file = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .write_only });
    defer file.close(io);
    var file_writer = file.writer(io, &buf);

    for (limits) |limit| {
        try file_writer.interface.print("{f}\n", .{limit});
    }
    try file_writer.interface.flush();

    std.log.debug("dmem limits written: {s}", .{cgroup});
}

fn dmemReadFromPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]DMemLimit {
    var buf: [buf_capacity]u8 = undefined;
    var result = std.ArrayList(DMemLimit).empty;

    const file = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
    defer file.close(io);
    var file_reader = file.reader(io, &buf);

    var count: u8 = 0;
    while (count < max_iterations) : (count += 1) {
        const line = try file_reader.interface.takeDelimiterExclusive('\n');
        if (std.mem.eql(u8, line, "")) {
            break;
        }
        var split = std.mem.splitScalar(u8, line, ' ');
        const device = split.next() orelse return error.FailedToParseDMemLimit;
        const limit_str = split.next() orelse return error.FailedToParseDMemLimit;
        var limit: u64 = 0;
        if (std.mem.eql(u8, limit_str, "max")) {
            limit = std.math.maxInt(u64);
        } else {
            limit = try std.fmt.parseInt(u64, limit_str, 10);
        }
        try result.append(allocator, .{ .device = try allocator.dupe(u8, device), .limit = limit });
    }
    return try result.toOwnedSlice(allocator);
}

fn getCgroupFromPid(allocator: std.mem.Allocator, io: std.Io, pid: i32) ![]const u8 {
    var buf: [buf_capacity]u8 = undefined;

    const path = try std.fmt.bufPrint(&buf, "/proc/{d}/cgroup", .{pid});
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
    defer file.close(io);
    var file_reader = file.reader(io, &buf);

    var count: u8 = 0;
    while (count < max_iterations) : (count += 1) {
        const line = try file_reader.interface.takeDelimiterExclusive('\n');
        if (std.mem.eql(u8, line, "")) {
            return error.CgroupNotFound;
        }
        if (std.mem.startsWith(u8, line, "0::")) {
            var split = std.mem.splitSequence(u8, line, "::");
            _ = split.next();
            const cgroup = split.next() orelse {
                return error.CGroupNotFound;
            };
            return try allocator.dupe(u8, cgroup);
        }
    }
    return error.CGroupNotFound;
}
