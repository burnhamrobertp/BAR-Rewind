//! bar-rewind: plays BAR Rewind replays (.curves) in an installed BAR. It finds BAR's data folder,
//! puts the BAR Rewind mutator in it, and fetches the replay's engine, game and map when missing.
//!   bar-rewind                              register barrewind:// links and .curves files for this user
//!   bar-rewind <replay.curves>              play a replay
//!   bar-rewind barrewind://play?url=<url>   download a replay from the BAR Rewind server, then play it
//!   bar-rewind --uninstall                  remove the registration

const std = @import("std");
const builtin = @import("builtin");
const bake = @import("bake.zig");
const curves = @import("curves.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const windows = builtin.os.tag == .windows;
const exe_suffix = if (windows) ".exe" else "";
const mutator_tar = @embedFile("mutator.tar");
const mutator_name = "barrewind.sdd";

const Ctx = struct { io: Io, gpa: Allocator, env: *std.process.Environ.Map };

var failure: ?[]const u8 = null;

fn fail(ctx: Ctx, comptime fmt: []const u8, args: anytype) error{Reported} {
    failure = std.fmt.allocPrint(ctx.gpa, fmt, args) catch "out of memory";

    return error.Reported;
}

pub fn main(init: std.process.Init) !void {
    const ctx: Ctx = .{ .io = init.io, .gpa = init.arena.allocator(), .env = init.environ_map };
    const args = try init.minimal.args.toSlice(ctx.gpa);
    run(ctx, args) catch |err| {
        std.debug.print("\nBAR Rewind: {s}\n", .{failure orelse @errorName(err)});
        pause(ctx);
        std.process.exit(1);
    };
}

fn run(ctx: Ctx, args: []const []const u8) !void {
    if (args.len == 1) return register(ctx, true);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--uninstall")) return register(ctx, false);
    if (args.len != 2) return fail(ctx, "usage: bar-rewind [<replay.curves> | barrewind://play?url=<url> | --uninstall]", .{});
    const path = if (std.ascii.startsWithIgnoreCase(args[1], "barrewind:")) try download(ctx, args[1]) else args[1];

    try play(ctx, path);
}

/// Started from a link or Explorer the console closes on exit: keep a message readable
fn pause(ctx: Ctx) void {
    std.debug.print("Press Enter to close.\n", .{});
    var buffer: [1]u8 = undefined;
    var stdin = Io.File.stdin().readerStreaming(ctx.io, &buffer);
    _ = stdin.interface.takeByte() catch {};
}

fn join(ctx: Ctx, parts: []const []const u8) ![]u8 {
    return std.fs.path.join(ctx.gpa, parts);
}

fn exists(ctx: Ctx, path: []const u8) bool {
    Io.Dir.cwd().access(ctx.io, path, .{}) catch return false;

    return true;
}

// registration ------------------------------------------------------------------------------------

fn register(ctx: Ctx, install: bool) !void {
    if (windows) try registerWindows(ctx, install) else try registerFreedesktop(ctx, install);
    if (!install) {
        std.debug.print("BAR Rewind: barrewind:// links and .curves files no longer open with this bar-rewind.\n", .{});
        pause(ctx);
        return;
    }

    const bar = barData(ctx) catch failure orelse "not found";
    std.debug.print(
        \\BAR Rewind is set up.
        \\  Watch links on the BAR Rewind site and .curves files now open with {s}
        \\  (keep it where it is, or run it again after moving it).
        \\  BAR's data folder: {s}
        \\
    , .{ try std.process.executablePathAlloc(ctx.io, ctx.gpa), bar });
    pause(ctx);
}

fn registerWindows(ctx: Ctx, install: bool) !void {
    const classes = "HKCU\\Software\\Classes\\";
    if (!install) {
        inline for (.{ "barrewind", ".curves", "BARRewind.curves" }) |key| _ = succeeds(ctx, &.{ "reg", "delete", classes ++ key, "/f" });
        return;
    }

    const exe = try std.process.executablePathAlloc(ctx.io, ctx.gpa);
    const command = try std.fmt.allocPrint(ctx.gpa, "\"{s}\" \"%1\"", .{exe});
    const writes = [_][]const []const u8{
        &.{ "reg", "add", classes ++ "barrewind", "/ve", "/d", "URL:BAR Rewind", "/f" },
        &.{ "reg", "add", classes ++ "barrewind", "/v", "URL Protocol", "/d", "", "/f" },
        &.{ "reg", "add", classes ++ "barrewind\\shell\\open\\command", "/ve", "/d", command, "/f" },
        &.{ "reg", "add", classes ++ ".curves", "/ve", "/d", "BARRewind.curves", "/f" },
        &.{ "reg", "add", classes ++ "BARRewind.curves", "/ve", "/d", "BAR Rewind replay", "/f" },
        &.{ "reg", "add", classes ++ "BARRewind.curves\\shell\\open\\command", "/ve", "/d", command, "/f" },
    };
    for (writes) |w| if (!succeeds(ctx, w)) return fail(ctx, "could not register with Windows (reg add {s})", .{w[2]});
}

const curves_mime = "application/x-bar-rewind-curves";

/// A desktop entry that handles barrewind:// and the .curves MIME type, in the user's own data
/// folder. Terminal=true gives the player a window to report downloads and errors in.
fn registerFreedesktop(ctx: Ctx, install: bool) !void {
    const data = ctx.env.get("XDG_DATA_HOME") orelse
        try join(ctx, &.{ ctx.env.get("HOME") orelse return fail(ctx, "no HOME", .{}), ".local", "share" });
    const apps = try join(ctx, &.{ data, "applications" });
    const mime = try join(ctx, &.{ data, "mime" });
    const entry = try join(ctx, &.{ apps, "bar-rewind.desktop" });
    const package = try join(ctx, &.{ mime, "packages", "bar-rewind.xml" });
    if (install) {
        const exe = try std.process.executablePathAlloc(ctx.io, ctx.gpa);
        try Io.Dir.cwd().createDirPath(ctx.io, apps);
        try Io.Dir.cwd().createDirPath(ctx.io, try join(ctx, &.{ mime, "packages" }));
        try Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = entry, .data = try std.fmt.allocPrint(ctx.gpa,
            \\[Desktop Entry]
            \\Type=Application
            \\Name=BAR Rewind
            \\Comment=Plays BAR Rewind replays in BAR
            \\Exec="{s}" %u
            \\Terminal=true
            \\NoDisplay=true
            \\MimeType=x-scheme-handler/barrewind;{s};
            \\
        , .{ exe, curves_mime }) });
        try Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = package, .data =
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
            \\  <mime-type type="application/x-bar-rewind-curves">
            \\    <comment>BAR Rewind replay</comment>
            \\    <glob pattern="*.curves"/>
            \\  </mime-type>
            \\</mime-info>
            \\
        });
    } else {
        Io.Dir.cwd().deleteFile(ctx.io, entry) catch {};
        Io.Dir.cwd().deleteFile(ctx.io, package) catch {};
    }
    // desktops without these tools read the files directly
    _ = succeeds(ctx, &.{ "update-mime-database", mime });
    _ = succeeds(ctx, &.{ "update-desktop-database", apps });
    if (!install) return;

    for ([_][]const u8{ "x-scheme-handler/barrewind", curves_mime }) |kind| {
        if (!succeeds(ctx, &.{ "xdg-mime", "default", "bar-rewind.desktop", kind }))
            return fail(ctx, "xdg-mime could not make bar-rewind the handler for {s} (is xdg-utils installed?)", .{kind});
    }
}

/// True when the command ran and exited 0; a missing command is false
fn succeeds(ctx: Ctx, argv: []const []const u8) bool {
    const r = std.process.run(ctx.gpa, ctx.io, .{ .argv = argv }) catch return false;

    return r.term == .exited and r.term.exited == 0;
}

// download ------------------------------------------------------------------------------------------

/// barrewind://play?url=<the replay's https URL, percent-encoded>. Any web page can open such a
/// link, so only hosts the user said yes to are fetched from (see trust).
fn download(ctx: Ctx, link: []const u8) ![]const u8 {
    const at = std.mem.indexOf(u8, link, "url=") orelse return fail(ctx, "not a BAR Rewind link: {s}", .{link});
    const raw = try ctx.gpa.dupe(u8, link[at + "url=".len ..]);
    const end = std.mem.indexOfScalar(u8, raw, '&') orelse raw.len;
    const url = std.Uri.percentDecodeInPlace(raw[0..end]);
    const uri = std.Uri.parse(url) catch return fail(ctx, "not a URL: {s}", .{url});
    var host_buffer: [Io.net.HostName.max_len]u8 = undefined;
    const host = (Io.net.HostName.fromUri(uri, &host_buffer) catch return fail(ctx, "no host in {s}", .{url})).bytes;
    if (!std.mem.eql(u8, uri.scheme, "https")) return fail(ctx, "refusing {s}: replays are only downloaded over https", .{url});
    try trust(ctx, host);

    const path = try uri.path.toRawMaybeAlloc(ctx.gpa);
    const base = std.fs.path.basenamePosix(path);
    if (!std.mem.endsWith(u8, base, ".curves")) return fail(ctx, "{s} is not a .curves file", .{url});
    const name = try ctx.gpa.dupe(u8, base);
    for (name) |*c| if (!std.ascii.isAlphanumeric(c.*) and std.mem.indexOfScalar(u8, "._-", c.*) == null) {
        c.* = '_';
    };
    const dir = try join(ctx, &.{ try cacheDir(ctx), "replays" });
    try Io.Dir.cwd().createDirPath(ctx.io, dir);
    const dest = try join(ctx, &.{ dir, name });
    if (exists(ctx, dest)) {
        std.debug.print("{s} was downloaded before\n", .{name});
        return dest;
    }

    std.debug.print("downloading {s}\n", .{name});
    const part = try std.fmt.allocPrint(ctx.gpa, "{s}.part", .{dest});
    var client: std.http.Client = .{ .allocator = ctx.gpa, .io = ctx.io };
    defer client.deinit();
    var req = client.request(.GET, uri, .{ .redirect_behavior = .unhandled }) catch |err| return fail(ctx, "cannot reach {s}: {s}", .{ host, @errorName(err) });
    defer req.deinit();
    try req.sendBodiless();
    var response = try req.receiveHead(&.{});
    if (response.head.status != .ok) return fail(ctx, "the server answered {d} {s} (links expire: get a new one from the site)", .{ @intFromEnum(response.head.status), response.head.reason });
    const total = response.head.content_length;
    const gzipped = response.head.content_encoding == .gzip;
    var transfer_buffer: [64]u8 = undefined;
    const body = response.reader(&transfer_buffer);

    {
        const file = try Io.Dir.cwd().createFile(ctx.io, part, .{});
        defer file.close(ctx.io);
        var write_buffer: [1 << 16]u8 = undefined;
        var out = file.writer(ctx.io, &write_buffer);
        var chunk: [1 << 16]u8 = undefined;
        var got: u64 = 0;
        var shown: u64 = 0;
        while (true) {
            const n = body.readSliceShort(&chunk) catch return fail(ctx, "download failed: {s}", .{@errorName(response.bodyErr() orelse error.ReadFailed)});
            if (n == 0) break;
            try out.interface.writeAll(chunk[0..n]);
            got += n;
            if (got - shown >= 1 << 20) {
                shown = got;
                if (total) |t| std.debug.print("\r  {d} of {d} MB", .{ got >> 20, t >> 20 }) else std.debug.print("\r  {d} MB", .{got >> 20});
            }
        }
        try out.interface.flush();
        std.debug.print("\r  {d} MB, done\n", .{got >> 20});
    }

    if (gzipped) {
        try gunzip(ctx, part, dest);
        try Io.Dir.cwd().deleteFile(ctx.io, part);
    } else try Io.Dir.cwd().rename(part, Io.Dir.cwd(), dest, ctx.io);

    return dest;
}

fn gunzip(ctx: Ctx, from: []const u8, to: []const u8) !void {
    const in_file = try Io.Dir.cwd().openFile(ctx.io, from, .{});
    defer in_file.close(ctx.io);
    var read_buffer: [1 << 16]u8 = undefined;
    var in = in_file.reader(ctx.io, &read_buffer);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var gz: std.compress.flate.Decompress = .init(&in.interface, .gzip, &window);
    const out_file = try Io.Dir.cwd().createFile(ctx.io, to, .{});
    defer out_file.close(ctx.io);
    var write_buffer: [1 << 16]u8 = undefined;
    var out = out_file.writer(ctx.io, &write_buffer);
    _ = try gz.reader.streamRemaining(&out.interface);
    try out.interface.flush();
}

/// Asks once per host, in the player's window, and remembers a yes in the config file
fn trust(ctx: Ctx, host: []const u8) !void {
    var config = try loadConfig(ctx);
    const hosts = config.object.get("trusted_hosts");
    if (hosts) |list| if (list == .array) for (list.array.items) |h| {
        if (h == .string and std.ascii.eqlIgnoreCase(h.string, host)) return;
    };

    if (!(Io.File.stdin().isTty(ctx.io) catch false))
        return fail(ctx, "{s} is not a trusted host, and there is no window to ask in: run bar-rewind on the link from a terminal", .{host});
    std.debug.print(
        \\A web page asked BAR Rewind to download and play a replay from
        \\
        \\    {s}
        \\
        \\Only say yes to a BAR Rewind site you use. BAR runs what the replay contains.
        \\Allow downloads from {s} from now on? [y/N]
    , .{ host, host });
    var buffer: [256]u8 = undefined;
    var stdin = Io.File.stdin().readerStreaming(ctx.io, &buffer);
    const answer = std.mem.trim(u8, (stdin.interface.takeDelimiter('\n') catch null) orelse "", " \t\r");
    if (!std.ascii.eqlIgnoreCase(answer, "y") and !std.ascii.eqlIgnoreCase(answer, "yes"))
        return fail(ctx, "not downloading from {s}", .{host});

    var list = if (hosts) |h| (if (h == .array) h.array else std.json.Array.init(ctx.gpa)) else std.json.Array.init(ctx.gpa);
    try list.append(.{ .string = try std.ascii.allocLowerString(ctx.gpa, host) });
    try config.object.put(ctx.gpa, "trusted_hosts", .{ .array = list });
    try saveConfig(ctx, config);
    std.debug.print("{s} is trusted (remove it from {s} to undo)\n", .{ host, try configPath(ctx) });
}

// settings --------------------------------------------------------------------------------------------

/// Shared with the BAR Rewind app, which keeps bar_data and out_dir in it
fn configPath(ctx: Ctx) ![]const u8 {
    const home = ctx.env.get(if (windows) "USERPROFILE" else "HOME") orelse "";
    if (windows) return join(ctx, &.{ ctx.env.get("APPDATA") orelse home, "bar-rewind.json" });

    return join(ctx, &.{ ctx.env.get("XDG_CONFIG_HOME") orelse try join(ctx, &.{ home, ".config" }), "bar-rewind.json" });
}

fn loadConfig(ctx: Ctx) !std.json.Value {
    const text = Io.Dir.cwd().readFileAlloc(ctx.io, try configPath(ctx), ctx.gpa, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return .{ .object = .{} },
        else => return err,
    };
    const value = std.json.parseFromSliceLeaky(std.json.Value, ctx.gpa, text, .{}) catch
        return fail(ctx, "{s} is not valid JSON", .{try configPath(ctx)});
    if (value != .object) return fail(ctx, "{s} is not a JSON object", .{try configPath(ctx)});

    return value;
}

fn saveConfig(ctx: Ctx, config: std.json.Value) !void {
    const path = try configPath(ctx);
    if (std.fs.path.dirname(path)) |dir| try Io.Dir.cwd().createDirPath(ctx.io, dir);
    const text = try std.json.Stringify.valueAlloc(ctx.gpa, config, .{ .whitespace = .indent_2 });
    try Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = try std.fmt.allocPrint(ctx.gpa, "{s}\n", .{text}) });
}

// BAR's data folder -----------------------------------------------------------------------------------

fn cacheDir(ctx: Ctx) ![]const u8 {
    if (windows) return join(ctx, &.{ ctx.env.get("LOCALAPPDATA") orelse return fail(ctx, "no LOCALAPPDATA", .{}), "bar-rewind" });
    if (ctx.env.get("XDG_CACHE_HOME")) |xdg| return join(ctx, &.{ xdg, "bar-rewind" });

    return join(ctx, &.{ ctx.env.get("HOME") orelse return fail(ctx, "no HOME", .{}), ".cache", "bar-rewind" });
}

fn hasEngine(ctx: Ctx, bar: []const u8) bool {
    var dir = Io.Dir.cwd().openDir(ctx.io, join(ctx, &.{ bar, "engine" }) catch return false, .{ .iterate = true }) catch return false;
    defer dir.close(ctx.io);
    var it = dir.iterate();
    while (it.next(ctx.io) catch return false) |entry| if (std.mem.startsWith(u8, entry.name, "recoil_")) return true;

    return false;
}

/// The folder the BAR Rewind app was told about, else where BAR's installers put it
fn barData(ctx: Ctx) ![]const u8 {
    const home = ctx.env.get(if (windows) "USERPROFILE" else "HOME") orelse "";
    const config = try configPath(ctx);
    if (Io.Dir.cwd().readFileAlloc(ctx.io, config, ctx.gpa, .limited(1 << 20))) |text| {
        const Config = struct { bar_data: []const u8 = "" };
        if (std.json.parseFromSliceLeaky(Config, ctx.gpa, text, .{ .ignore_unknown_fields = true })) |cfg| {
            if (hasEngine(ctx, cfg.bar_data)) return cfg.bar_data;
        } else |_| {}
    } else |_| {}

    const candidates: []const []const u8 = if (windows) &.{
        try join(ctx, &.{ ctx.env.get("LOCALAPPDATA") orelse home, "Programs", "Beyond-All-Reason", "data" }),
        "C:\\Program Files\\Beyond-All-Reason\\data",
        try join(ctx, &.{ home, "Documents", "Beyond All Reason" }),
    } else &.{
        try join(ctx, &.{ home, ".var", "app", "info.beyondallreason.bar", "data" }),
        try join(ctx, &.{ home, ".local", "state", "Beyond All Reason" }),
        try join(ctx, &.{ home, "Documents", "Beyond All Reason" }),
    };
    for (candidates) |c| if (hasEngine(ctx, c)) return c;

    return fail(ctx, "BAR is not installed where its installer puts it. Put {{\"bar_data\": \"<BAR's data folder>\"}} in {s}", .{config});
}

/// Lowercased names of every map and game the engine's last archive scan found
fn scannedNames(ctx: Ctx, bar: []const u8) !std.StringHashMapUnmanaged(void) {
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

const RapidEntry = struct { tag: []const u8, package: []const u8, name: []const u8 };

/// Every line of every rapid repository's versions.gz: tag,md5,depends,name
fn rapidEntries(ctx: Ctx, bar: []const u8) ![]RapidEntry {
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
fn newestGame(ctx: Ctx, rapid: []const RapidEntry) ![]const u8 {
    for (rapid) |e| if (std.mem.eql(u8, e.tag, "byar:test")) return e.name;

    return fail(ctx, "no BAR game installed (no byar:test in rapid's versions)", .{});
}

fn gameInstalled(ctx: Ctx, bar: []const u8, game: []const u8, scanned: std.StringHashMapUnmanaged(void), rapid: []const RapidEntry) !bool {
    if (std.mem.indexOf(u8, game, "$VERSION") != null) return true;
    if (scanned.contains(try std.ascii.allocLowerString(ctx.gpa, game))) return true;
    for (rapid) |e| if (std.mem.eql(u8, e.name, game)) {
        const package = try std.fmt.allocPrint(ctx.gpa, "{s}.sdp", .{e.package});
        if (exists(ctx, try join(ctx, &.{ bar, "packages", package }))) return true;
    };

    return false;
}

fn mapInstalled(ctx: Ctx, bar: []const u8, map: []const u8, scanned: std.StringHashMapUnmanaged(void)) !bool {
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

    return fail(ctx, "no pr-downloader in BAR's engine or bin folders", .{});
}

fn fetchContent(ctx: Ctx, bar: []const u8, missing: []const [2][]const u8) !void {
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
    var child = try std.process.spawn(ctx.io, .{ .argv = argv.items, .environ_map = &env });
    const term = try child.wait(ctx.io);
    if (term != .exited or term.exited != 0) return fail(ctx, "pr-downloader could not fetch what the replay needs (see its output above)", .{});
}

// play ------------------------------------------------------------------------------------------------

fn play(ctx: Ctx, path: []const u8) !void {
    const bar = try barData(ctx);
    const bytes = Io.Dir.cwd().readFileAllocOptions(ctx.io, path, ctx.gpa, .limited(16 << 30), .@"16", null) catch |err|
        return fail(ctx, "cannot read {s}: {s}", .{ path, @errorName(err) });
    if (bytes.len < @sizeOf(curves.Header) or !std.mem.eql(u8, bytes[0..4], &curves.magic)) return fail(ctx, "{s} is not a BAR Rewind replay", .{path});
    const version = std.mem.readInt(u32, bytes[4..8], .little);
    if (version != curves.version) return fail(ctx, "{s} is curves version {d}, this bar-rewind plays version {d}: {s}", .{
        path, version, curves.version, if (version > curves.version) "download the newest bar-rewind" else "parse the replay again",
    });
    const file = curves.File.view(bytes) catch return fail(ctx, "{s} is damaged", .{path});
    const meta = try bake.parseMeta(ctx.gpa, file);

    const rapid = try rapidEntries(ctx, bar);
    const recorded_game = bake.scriptField(file.demo_script, "gametype");
    const game = if (recorded_game.len > 0 and !std.mem.startsWith(u8, recorded_game, "BAR Rewind")) recorded_game else try newestGame(ctx, rapid);
    const engine_dir = try join(ctx, &.{ bar, "engine", try std.fmt.allocPrint(ctx.gpa, "recoil_{s}", .{file.engine}) });
    const scanned = try scannedNames(ctx, bar);
    var missing: std.ArrayList([2][]const u8) = .empty;
    if (!exists(ctx, engine_dir)) try missing.append(ctx.gpa, .{ "--download-engine", file.engine });
    if (!try gameInstalled(ctx, bar, game, scanned, rapid)) try missing.append(ctx.gpa, .{ "--download-game", game });
    if (!try mapInstalled(ctx, bar, meta.map.name, scanned)) try missing.append(ctx.gpa, .{ "--download-map", meta.map.name });
    if (missing.items.len > 0) try fetchContent(ctx, bar, missing.items);

    std.debug.print("preparing {s}\n", .{std.fs.path.basename(path)});
    const mutator = try join(ctx, &.{ bar, "games", mutator_name });
    try Io.Dir.cwd().deleteTree(ctx.io, mutator);
    {
        var dir = try Io.Dir.cwd().createDirPathOpen(ctx.io, mutator, .{});
        defer dir.close(ctx.io);
        var tar: Io.Reader = .fixed(mutator_tar);
        try std.tar.extract(ctx.io, dir, &tar, .{});
        // the mutator runs on top of the match's own BAR version
        const modinfo = try dir.readFileAlloc(ctx.io, "modinfo.lua", ctx.gpa, .limited(1 << 20));
        const start = (std.mem.indexOf(u8, modinfo, "depend = {") orelse return error.BadModinfo) + "depend = {".len;
        const end = std.mem.indexOfScalarPos(u8, modinfo, start, '}') orelse return error.BadModinfo;
        const patched = try std.fmt.allocPrint(ctx.gpa, "{s} \"{s}\" {s}", .{ modinfo[0..start], game, modinfo[end..] });
        try dir.writeFile(ctx.io, .{ .sub_path = "modinfo.lua", .data = patched });
    }
    try bake.exportFile(ctx.io, ctx.gpa, file, try join(ctx, &.{ mutator, "replay" }));

    const cache = try cacheDir(ctx);
    try Io.Dir.cwd().createDirPath(ctx.io, cache);
    var script: Io.Writer.Allocating = .init(ctx.gpa);
    try bake.startScript(&script.writer, ctx.gpa, meta, file.demo_script);
    const script_path = try join(ctx, &.{ cache, "play_script.txt" });
    try Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = script_path, .data = script.written() });

    const log_path = try join(ctx, &.{ cache, "play.log" });
    const log = try Io.Dir.cwd().createFile(ctx.io, log_path, .{});
    // the replay's own engine, as the parse used: newer engines draw nano spray natively, only for
    // units that really build, so BAR's Lua nano gadget (which the player feeds) stands down
    const spring = try join(ctx, &.{ engine_dir, "spring" ++ exe_suffix });
    _ = std.process.spawn(ctx.io, .{
        .argv = &.{ spring, "--write-dir", bar, "--isolation", "--window", script_path },
        .stdin = .ignore,
        .stdout = .{ .file = log },
        .stderr = .{ .file = log },
        .create_no_window = true,
    }) catch |err| return fail(ctx, "cannot start {s}: {s}", .{ spring, @errorName(err) });
    std.debug.print("starting BAR (its log: {s})\n", .{log_path});
}
