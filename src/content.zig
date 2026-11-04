//! BAR content in a BAR data folder: what is installed, and fetching what is not with BAR's own
//! pr-downloader.

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Allocator = std.mem.Allocator;
pub const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";

pub const Ctx = struct { io: Io, gpa: Allocator, env: *std.process.Environ.Map };

pub fn join(ctx: Ctx, parts: []const []const u8) ![]u8 {
    return std.fs.path.join(ctx.gpa, parts);
}

pub fn exists(ctx: Ctx, path: []const u8) bool {
    Io.Dir.cwd().access(ctx.io, path, .{}) catch return false;

    return true;
}

/// Lowercased names of every map and game the engine's last archive scan found
pub fn scannedNames(ctx: Ctx, bar: []const u8) !std.StringHashMapUnmanaged(void) {
    var names: std.StringHashMapUnmanaged(void) = .empty;
    var dir = Io.Dir.cwd().openDir(ctx.io, try join(ctx, &.{ bar, "cache" }), .{ .iterate = true }) catch return names;
    defer dir.close(ctx.io);
    var newest: ?[]const u8 = null;
    var newest_time: i96 = 0;
    var it = dir.iterate();
    while (try it.next(ctx.io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "ArchiveCache") or !std.mem.endsWith(u8, entry.name, ".lua")) continue;
        const stat = try dir.statFile(ctx.io, entry.name, .{});
        if (newest == null or stat.mtime.nanoseconds > newest_time) {
            newest = try ctx.gpa.dupe(u8, entry.name);
            newest_time = stat.mtime.nanoseconds;
        }
    }
    const name = newest orelse return names;
    const text = try dir.readFileAlloc(ctx.io, name, ctx.gpa, .limited(256 << 20));
    const key = "name = \"";
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, key)) |at| {
        const start = at + key.len;
        const end = std.mem.indexOfScalarPos(u8, text, start, '"') orelse break;
        try names.put(ctx.gpa, try std.ascii.allocLowerString(ctx.gpa, text[start..end]), {});
        i = end;
    }

    return names;
}

pub const RapidEntry = struct { tag: []const u8, package: []const u8, name: []const u8 };

/// Every line of every rapid repository's versions.gz: tag,md5,depends,name
pub fn rapidEntries(ctx: Ctx, bar: []const u8) ![]RapidEntry {
    var entries: std.ArrayList(RapidEntry) = .empty;
    var rapid = Io.Dir.cwd().openDir(ctx.io, try join(ctx, &.{ bar, "rapid" }), .{ .iterate = true }) catch return entries.items;
    defer rapid.close(ctx.io);
    var hosts = rapid.iterate();
    while (try hosts.next(ctx.io)) |host| {
        if (host.kind != .directory) continue;
        var host_dir = try rapid.openDir(ctx.io, host.name, .{ .iterate = true });
        defer host_dir.close(ctx.io);
        var repos = host_dir.iterate();
        while (try repos.next(ctx.io)) |repo| {
            if (repo.kind != .directory) continue;
            const path = try join(ctx, &.{ repo.name, "versions.gz" });
            const compressed = host_dir.readFileAlloc(ctx.io, path, ctx.gpa, .limited(256 << 20)) catch continue;
            var in: Io.Reader = .fixed(compressed);
            var window: [std.compress.flate.max_window_len]u8 = undefined;
            var gz: std.compress.flate.Decompress = .init(&in, .gzip, &window);
            const text = gz.reader.allocRemaining(ctx.gpa, .limited(1 << 30)) catch continue;
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |line| {
                var parts = std.mem.splitScalar(u8, std.mem.trimEnd(u8, line, "\r"), ',');
                const tag = parts.next() orelse continue;
                const package = parts.next() orelse continue;
                _ = parts.next() orelse continue;
                try entries.append(ctx.gpa, .{ .tag = tag, .package = package, .name = parts.rest() });
            }
        }
    }

    return entries.items;
}

/// The archive name rapid's byar:test tag points at, for replays whose game is unknown
pub fn newestGame(rapid: []const RapidEntry) error{NoGame}![]const u8 {
    for (rapid) |e| if (std.mem.eql(u8, e.tag, "byar:test")) return e.name;

    return error.NoGame;
}

pub fn gameInstalled(ctx: Ctx, bar: []const u8, game: []const u8, scanned: std.StringHashMapUnmanaged(void), rapid: []const RapidEntry) !bool {
    if (std.mem.indexOf(u8, game, "$VERSION") != null) return true;
    if (scanned.contains(try std.ascii.allocLowerString(ctx.gpa, game))) return true;
    for (rapid) |e| if (std.mem.eql(u8, e.name, game)) {
        const package = try std.fmt.allocPrint(ctx.gpa, "{s}.sdp", .{e.package});
        if (exists(ctx, try join(ctx, &.{ bar, "packages", package }))) return true;
    };

    return false;
}

pub fn mapInstalled(ctx: Ctx, bar: []const u8, map: []const u8, scanned: std.StringHashMapUnmanaged(void)) !bool {
    const lower = try std.ascii.allocLowerString(ctx.gpa, map);
    if (scanned.contains(lower)) return true;
    for (lower) |*c| if (!std.ascii.isAlphanumeric(c.*) and c.* != '.' and c.* != '-') {
        c.* = '_';
    };
    for ([_][]const u8{ ".sd7", ".sdz" }) |ext| {
        const file = try std.fmt.allocPrint(ctx.gpa, "{s}{s}", .{ lower, ext });
        if (exists(ctx, try join(ctx, &.{ bar, "maps", file }))) return true;
    }

    return false;
}

/// BAR's own downloader: shipped with every engine, and beside the launcher
fn prDownloader(ctx: Ctx, bar: []const u8) ![]const u8 {
    const name = "pr-downloader" ++ exe_suffix;
    var engines: std.ArrayList([]const u8) = .empty;
    if (Io.Dir.cwd().openDir(ctx.io, try join(ctx, &.{ bar, "engine" }), .{ .iterate = true })) |dir_const| {
        var dir = dir_const;
        defer dir.close(ctx.io);
        var it = dir.iterate();
        while (try it.next(ctx.io)) |entry| if (std.mem.startsWith(u8, entry.name, "recoil_")) try engines.append(ctx.gpa, try ctx.gpa.dupe(u8, entry.name));
    } else |_| {}
    std.mem.sort([]const u8, engines.items, {}, struct {
        fn newer(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .gt;
        }
    }.newer);
    for (engines.items) |e| {
        const p = try join(ctx, &.{ bar, "engine", e, name });
        if (exists(ctx, p)) return p;
    }
    const beside = try join(ctx, &.{ std.fs.path.dirname(bar) orelse bar, "bin", name });
    if (exists(ctx, beside)) return beside;

    return error.NoPrDownloader;
}

/// `output` takes pr-downloader's output, or null for this process's own
pub fn fetchContent(ctx: Ctx, bar: []const u8, missing: []const [2][]const u8, output: ?Io.File) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(ctx.gpa, &.{ try prDownloader(ctx, bar), "--filesystem-writepath", bar });
    for (missing) |m| {
        try argv.appendSlice(ctx.gpa, &.{ m[0], m[1] });
        std.debug.print("downloading {s} {s}\n", .{ m[0]["--download-".len..], m[1] });
    }
    // the repositories BAR's launcher points pr-downloader at
    var env = try ctx.env.clone(ctx.gpa);
    try env.put("PRD_RAPID_REPO_MASTER", "https://repos-cdn.beyondallreason.dev/repos.gz");
    try env.put("PRD_HTTP_SEARCH_URL", "https://files-cdn.beyondallreason.dev/find");
    try env.put("PRD_RAPID_USE_STREAMER", "false");
    const out: std.process.SpawnOptions.StdIo = if (output) |f| .{ .file = f } else .inherit;
    var child = try std.process.spawn(ctx.io, .{ .argv = argv.items, .environ_map = &env, .stdout = out, .stderr = out });
    const term = try child.wait(ctx.io);
    if (term != .exited or term.exited != 0) return error.FetchFailed;
}

/// BAR's launcher installs an engine as engine/recoil_<version>, pr-downloader as engine/<platform>/<version>:
/// whichever is there, else the launcher's
pub fn engineDir(ctx: Ctx, bar: []const u8, engine: []const u8) ![]u8 {
    const launcher = try join(ctx, &.{ bar, "engine", try std.fmt.allocPrint(ctx.gpa, "recoil_{s}", .{engine}) });
    if (exists(ctx, launcher)) return launcher;
    const downloaded = try join(ctx, &.{ bar, "engine", if (builtin.os.tag == .windows) "windows64" else "linux64", engine });

    return if (exists(ctx, downloaded)) downloaded else launcher;
}

/// What playing or parsing a match on `engine`, `game` and `map` needs that `bar` lacks, as
/// fetchContent's pairs
pub fn missingContent(ctx: Ctx, bar: []const u8, engine: []const u8, game: []const u8, map: []const u8, rapid: []const RapidEntry) ![]const [2][]const u8 {
    var out: std.ArrayList([2][]const u8) = .empty;
    if (!exists(ctx, try engineDir(ctx, bar, engine))) try out.append(ctx.gpa, .{ "--download-engine", engine });
    const scanned = try scannedNames(ctx, bar);
    if (!try gameInstalled(ctx, bar, game, scanned, rapid)) try out.append(ctx.gpa, .{ "--download-game", game });
    if (!try mapInstalled(ctx, bar, map, scanned)) try out.append(ctx.gpa, .{ "--download-map", map });

    return out.items;
}
