//! pack <dir> <out.tar>: a folder as a tar, without its replay/ (what the player exports there)

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    var dir = try std.Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true });
    defer dir.close(io);

    var out: std.Io.Writer.Allocating = .init(gpa);
    var tar: std.tar.Writer = .{ .underlying_writer = &out.writer };
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const path = try gpa.dupe(u8, entry.path);
        std.mem.replaceScalar(u8, path, '\\', '/');
        if (std.mem.startsWith(u8, path, "replay/")) continue;
        const bytes = try entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(64 << 20));
        try tar.writeFileBytes(path, bytes, .{});
    }
    try tar.finishPedantically();

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = out.written() });
}
