const std = @import("std");
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (std.mem.eql(u8, args[1], "build")) {
        if (init.environ_map.get("ZIGMKAY_BUILD_FIXTURE")) |mode| {
            if (std.mem.eql(u8, mode, "spawn-hang") or std.mem.eql(u8, mode, "hang")) {
                var descendant: ?std.process.Child = null;
                defer if (descendant) |*child| child.kill(init.io);
                if (std.mem.eql(u8, mode, "spawn-hang")) {
                    const own_path = try std.process.executablePathAlloc(init.io, init.arena.allocator());
                    descendant = try std.process.spawn(init.io, .{ .argv = &.{ own_path, "hang" }, .stdin = .ignore });
                }
                for (args[0 .. args.len - 1], 0..) |arg, index| if (std.mem.eql(u8, arg, "-p")) {
                    var output = try std.Io.Dir.cwd().openDir(init.io, args[index + 1], .{});
                    defer output.close(init.io);
                    try output.writeFile(init.io, .{ .sub_path = "cancel-ready", .data = "running fixture producer" });
                };
                try std.Io.sleep(init.io, .fromSeconds(10), .awake);
                return;
            }
            if (std.mem.eql(u8, mode, "failed")) std.process.exit(7);
            if (std.mem.eql(u8, mode, "missing")) return;
            var install: ?[]const u8 = null;
            for (args[0 .. args.len - 1], 0..) |arg, index| if (std.mem.eql(u8, arg, "-p")) {
                install = args[index + 1];
            };
            const path = try std.fs.path.join(init.arena.allocator(), &.{ install orelse return error.MissingFixtureInstall, "firmware" });
            var dir = try std.Io.Dir.cwd().createDirPathOpen(init.io, path, .{});
            defer dir.close(init.io);
            var bytes: [512]u8 = @splat(0);
            for ([_]struct { usize, u32 }{ .{ 0, 0x0a324655 }, .{ 4, 0x9e5d5157 }, .{ 8, 0x2000 }, .{ 12, 0x10000000 }, .{ 16, 256 }, .{ 24, 1 }, .{ 28, 0xe48bff56 }, .{ 508, 0x0ab16f30 } }) |entry| std.mem.writeInt(u32, bytes[entry[0]..][0..4], entry[1], .little);
            if (std.mem.eql(u8, mode, "invalid")) bytes[0] = 0;
            try dir.writeFile(init.io, .{ .sub_path = "project.uf2", .data = &bytes });
            if (std.mem.eql(u8, mode, "missing-runner") or std.mem.eql(u8, mode, "invalid")) return;
            const bin_path = try std.fs.path.join(init.arena.allocator(), &.{ install.?, "bin" });
            var bin = try std.Io.Dir.cwd().createDirPathOpen(init.io, bin_path, .{});
            defer bin.close(init.io);
            const own_path = try std.process.executablePathAlloc(init.io, init.arena.allocator());
            const own_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, own_path, init.arena.allocator(), .limited(64 * 1024 * 1024));
            const runner_name = "project-runner" ++ if (@import("builtin").os.tag == .windows) ".exe" else "";
            var runner = try bin.createFileAtomic(init.io, runner_name, .{});
            defer runner.deinit(init.io);
            try runner.file.writeStreamingAll(init.io, own_bytes);
            try runner.file.setPermissions(init.io, .executable_file);
            try runner.link(init.io);
            return;
        }
    }
    if (std.mem.eql(u8, args[1], "environment")) {
        try std.Io.File.stdout().writeStreamingAll(init.io, init.environ_map.get("ZIGMKAY_JOB_FIXTURE") orelse "absent");
        return;
    }
    if (std.mem.eql(u8, args[1], "version")) {
        try std.Io.File.stdout().writeStreamingAll(init.io, "0.17.0\n");
        return;
    }
    if (std.mem.eql(u8, args[1], "hang")) {
        try std.Io.sleep(init.io, .fromSeconds(10), .awake);
        return;
    }
    if (std.mem.eql(u8, args[1], "crash")) std.process.exit(7);
    if (std.mem.eql(u8, args[1], "closed-hang")) {
        std.Io.File.stdout().close(init.io);
        std.Io.File.stderr().close(init.io);
        try std.Io.sleep(init.io, .fromSeconds(10), .awake);
        return;
    }
    if (std.mem.eql(u8, args[1], "echo")) {
        var buffer: [4097]u8 = undefined;
        var reader = std.Io.File.stdin().readerStreaming(init.io, &buffer);
        while (try reader.interface.takeDelimiter('\n')) |line| {
            try std.Io.File.stdout().writeStreamingAll(init.io, line);
            try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
        }
        return;
    }
    if (std.mem.eql(u8, args[1], "flood")) {
        const block: [4096]u8 = @splat('x');
        for (0..300) |_| try std.Io.File.stdout().writeStreamingAll(init.io, &block);
        return;
    }
    try std.Io.File.stdout().writeStreamingAll(init.io, args[1]);
}
