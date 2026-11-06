//! bake parse: re-simulates a match's demo in BAR's headless engine with the dump widgets running,
//! then bakes the recording into a .curves. Fetches the engine, game and map the match needs.
//! It rewrites the BAR data folder's widget config, so the folder must be one kept for parsing,
//! never a BAR install someone plays with.

const std = @import("std");
const builtin = @import("builtin");
const bake = @import("bake.zig");
const content = @import("content.zig");

const Io = std.Io;
const Ctx = content.Ctx;
const windows = builtin.os.tag == .windows;
const exe_suffix = content.exe_suffix;
const join = content.join;

const dump_widget = @embedFile("dump_replay.lua");
const eco_widget = @embedFile("dump_replay_eco.lua");
const bar_widgets = @embedFile("bar-widgets.txt");
const recording_widgets = [_][]const u8{ "Replay Dump v2", "Replay Dump Eco" };

/// a match that never gets past BAR's loading screen sits in the pregame lobby forever
const pregame_seconds = 300;
const parse_seconds = 2 * 60 * 60;
const tail_bytes = 64 << 10;

pub const Options = struct {
    bar: []const u8,
    demo: []const u8,
    out: []const u8,
    log: []const u8,
    extra_widgets: ?[]const u8 = null,
};

/// Progress, one JSON object per line: {"pct": 0-100, "text": "..."}
pub const Progress = struct {
    w: *Io.Writer,
    last_pct: i32 = -1,
    last_text: [256]u8 = undefined,
    last_len: usize = 0,

    pub fn report(p: *Progress, pct: i32, text: []const u8) !void {
        const kept = text[0..@min(text.len, p.last_text.len)];
        if (pct == p.last_pct and std.mem.eql(u8, kept, p.last_text[0..p.last_len])) return;
        p.last_pct = pct;
        @memcpy(p.last_text[0..kept.len], kept);
        p.last_len = kept.len;
        try std.json.Stringify.value(.{ .pct = pct, .text = kept }, .{}, p.w);
        try p.w.writeByte('\n');
        try p.w.flush();
    }
};

/// What went wrong, when run returns EngineFailed: the engine's own last words, if it left any
pub var engine_message: []const u8 = "";

pub fn run(ctx: Ctx, o: Options, progress: *Progress) !void {
    const demo = try bake.readDemo(ctx.io, ctx.gpa, o.demo);
    const game = bake.scriptField(demo.script, "gametype");
    const map = bake.scriptField(demo.script, "mapname");
    if (std.mem.startsWith(u8, game, "BAR Rewind")) return error.PlayerRecording;
    if (demo.last_frame == 0) return error.NeverStarted;
    if (!bake.engineVersion(demo.engine) or !bake.contentName(game) or !bake.contentName(map)) return error.UnusableNames;

    const log = try Io.Dir.cwd().createFile(ctx.io, o.log, .{});
    defer log.close(ctx.io);
    const rapid = try content.rapidEntries(ctx, o.bar);
    const missing = try content.missingContent(ctx, o.bar, demo.engine, game, map, rapid);
    if (missing.len > 0) {
        try progress.report(0, "downloading what the match needs");
        try content.fetchContent(ctx, o.bar, missing, log);
    }

    const widgets = try join(ctx, &.{ o.bar, "LuaUI", "Widgets" });
    try Io.Dir.cwd().createDirPath(ctx.io, widgets);
    const dump_path = try join(ctx, &.{ widgets, "dump_replay.lua" });
    const eco_path = try join(ctx, &.{ widgets, "dump_replay_eco.lua" });
    try Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = dump_path, .data = dump_widget });
    try Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = eco_path, .data = eco_widget });
    defer for ([_][]const u8{ dump_path, eco_path }) |p| Io.Dir.cwd().deleteFile(ctx.io, p) catch {};
    try widgetConfig(ctx, o.bar, try extraWidgets(ctx, widgets, o.extra_widgets));

    // LuaUI/Config is the one folder BAR lets a user widget both read and write (bar-game #9547)
    const dump = try join(ctx, &.{ o.bar, "LuaUI", "Config" });
    try Io.Dir.cwd().createDirPath(ctx.io, dump);
    const dump_files = [_][]const u8{ "bardump.jsonl", "bardump.bin", "bardump_view.bin", "bardump_eco.bin", "bardump.view.bin", "bardump.eco.bin" };
    for (dump_files) |f| Io.Dir.cwd().deleteFile(ctx.io, try join(ctx, &.{ dump, f })) catch {};
    defer for (dump_files) |f| Io.Dir.cwd().deleteFile(ctx.io, join(ctx, &.{ dump, f }) catch continue) catch {};
    // the widget stops at the replay's last frame (an unfinished replay never reaches GameOver)
    const request = try join(ctx, &.{ dump, "bardump.request" });
    try Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = request, .data = try std.fmt.allocPrint(ctx.gpa, "dump {d}\n", .{demo.last_frame}) });
    defer Io.Dir.cwd().deleteFile(ctx.io, request) catch {};

    try simulate(ctx, o, demo, log, progress);

    try progress.report(100, "baking the recording into keyframes");
    const jsonl = try join(ctx, &.{ dump, "bardump.jsonl" });
    // the widget closes a whole recording with this line: anything else is an engine that died
    var end: [64]u8 = undefined;
    if (!std.mem.endsWith(u8, std.mem.trimEnd(u8, tail(ctx, jsonl, &end), "\r\n"), "{\"end\":true}")) {
        var buffer: [tail_bytes]u8 = undefined;
        engine_message = try ctx.gpa.dupe(u8, engineError(tail(ctx, o.log, &buffer)) orelse "the engine stopped before the match ended");
        return error.EngineFailed;
    }
    // bake finds the dump's other files beside its .jsonl by suffix
    for ([_][2][]const u8{ .{ "bardump_view.bin", "bardump.view.bin" }, .{ "bardump_eco.bin", "bardump.eco.bin" } }) |pair| {
        const from = try join(ctx, &.{ dump, pair[0] });
        if (content.exists(ctx, from)) try Io.Dir.cwd().rename(from, Io.Dir.cwd(), try join(ctx, &.{ dump, pair[1] }), ctx.io);
    }
    bake.bakeDump(ctx.io, ctx.gpa, jsonl, o.out, o.demo) catch |err| {
        Io.Dir.cwd().deleteFile(ctx.io, o.out) catch {};
        return err;
    };
    try progress.report(100, "parsed");
}

const Waiter = struct {
    child: *std.process.Child,
    io: Io,
    term: ?std.process.Child.Term = null,
    done: std.atomic.Value(bool) = .init(false),

    fn wait(w: *Waiter) void {
        w.term = w.child.wait(w.io) catch null;
        w.done.store(true, .release);
    }
};

/// Runs the engine on the demo until it quits, reporting the dump widget's progress
fn simulate(ctx: Ctx, o: Options, demo: bake.Demo, log: Io.File, progress: *Progress) !void {
    const engine = try content.engineDir(ctx, o.bar, demo.engine);
    const headless = try join(ctx, &.{ engine, "spring-headless" ++ exe_suffix });
    const exe = if (content.exists(ctx, headless)) headless else try join(ctx, &.{ engine, "spring" ++ exe_suffix });
    const total = demo.last_frame;
    var text: [256]u8 = undefined;
    try progress.report(0, std.fmt.bufPrint(&text, "starting the headless engine for {d} min of game", .{total / 1800}) catch unreachable);

    const started = Io.Timestamp.now(ctx.io, .awake);
    const started_real = Io.Timestamp.now(ctx.io, .real);
    var child = std.process.spawn(ctx.io, .{
        .argv = &.{ exe, "--write-dir", o.bar, "--isolation", o.demo },
        .stdin = .ignore,
        .stdout = .{ .file = log },
        .stderr = .{ .file = log },
        .create_no_window = true,
    }) catch |err| {
        engine_message = try std.fmt.allocPrint(ctx.gpa, "cannot start the engine {s}: {s}", .{ exe, @errorName(err) });

        return error.EngineFailed;
    };
    const id = child.id.?;
    var waiter: Waiter = .{ .child = &child, .io = ctx.io };
    const thread = std.Thread.spawn(.{}, Waiter.wait, .{&waiter}) catch |err| {
        child.kill(ctx.io);
        return err;
    };
    defer thread.join();
    errdefer if (!waiter.done.load(.acquire)) terminate(id);

    const infolog = try join(ctx, &.{ o.bar, "infolog.txt" });
    var shown: i32 = -1;
    var buffer: [tail_bytes]u8 = undefined;
    while (!waiter.done.load(.acquire)) {
        try ctx.io.sleep(.fromSeconds(1), .awake);
        const elapsed = started.untilNow(ctx.io, .awake).toSeconds();
        if (elapsed > parse_seconds) return error.TimedOut;
        // BAR's infolog.txt holds the last run's frames until the engine starts writing it
        const frame = lastDumpFrame(tail(ctx, o.log, &buffer)) orelse
            if (writtenSince(ctx, infolog, started_real)) lastDumpFrame(tail(ctx, infolog, &buffer)) else null;
        const f = frame orelse {
            if (shown >= 0) continue;
            if (elapsed > pregame_seconds) return error.NeverReachedGame;
            const message = loadMessage(tail(ctx, o.log, &buffer)) orelse "starting";
            try progress.report(0, std.fmt.bufPrint(&text, "loading BAR: {s}", .{message[0..@min(message.len, 200)]}) catch unreachable);
            continue;
        };
        const pct: i32 = @intCast(@min(100, @as(u64, f) * 100 / total));
        if (pct > shown) {
            shown = pct;
            try progress.report(pct, std.fmt.bufPrint(&text, "re-simulating, {d}:{d:0>2} of {d}:{d:0>2} game time", .{
                f / 1800, f / 30 % 60, total / 1800, total / 30 % 60,
            }) catch unreachable);
        }
    }
    const term = waiter.term orelse return error.EngineFailed;
    if (term == .exited) return;
    engine_message = if (engineError(tail(ctx, o.log, &buffer))) |m| try ctx.gpa.dupe(u8, m) else try std.fmt.allocPrint(ctx.gpa, "the engine {f}", .{term});

    return error.EngineFailed;
}

fn terminate(id: std.process.Child.Id) void {
    if (windows) {
        _ = std.os.windows.ntdll.NtTerminateProcess(id, @fromBackingInt(1));
    } else std.posix.kill(id, .KILL) catch {};
}

fn writtenSince(ctx: Ctx, path: []const u8, since: Io.Timestamp) bool {
    const stat = Io.Dir.cwd().statFile(ctx.io, path, .{}) catch return false;

    return stat.mtime.nanoseconds >= since.nanoseconds;
}

/// The end of a file, as much of it as fits in `buffer`, or "" when it can't be read
fn tail(ctx: Ctx, path: []const u8, buffer: []u8) []const u8 {
    const file = Io.Dir.cwd().openFile(ctx.io, path, .{}) catch return "";
    defer file.close(ctx.io);
    const size = file.length(ctx.io) catch return "";
    const n: usize = @intCast(@min(size, buffer.len));
    const got = file.readPositionalAll(ctx.io, buffer[0..n], size - n) catch return "";

    return buffer[0..got];
}

fn lastDumpFrame(text: []const u8) ?u32 {
    const key = "Replay Dump v2: frame ";
    const at = std.mem.lastIndexOf(u8, text, key) orelse return null;
    const digits = text[at + key.len ..];
    var end: usize = 0;
    while (end < digits.len and std.ascii.isDigit(digits[end])) end += 1;

    return std.fmt.parseInt(u32, digits[0..end], 10) catch null;
}

/// What BAR's loading screen says, or the last gadget or widget it loaded
fn loadMessage(text: []const u8) ?[]const u8 {
    const set = "SetLoadMessage] text=\"";
    var lines = std.mem.splitBackwardsAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, set)) |at| {
            const rest = line[at + set.len ..];

            return rest[0 .. std.mem.indexOfScalar(u8, rest, '"') orelse rest.len];
        }
        const at = std.mem.indexOf(u8, line, "Loading ") orelse continue;
        var what = line[at + "Loading ".len ..];
        for ([_][]const u8{ "synced ", "unsynced " }) |prefix| {
            if (std.mem.startsWith(u8, what, prefix)) what = what[prefix.len..];
        }
        if (!std.mem.startsWith(u8, what, "gadget") and !std.mem.startsWith(u8, what, "widget")) continue;
        const colon = std.mem.indexOfScalar(u8, what, ':') orelse continue;
        const name = std.mem.trim(u8, what[colon + 1 ..], " \t");

        return std.mem.trimEnd(u8, name[0 .. std.mem.indexOfScalar(u8, name, '<') orelse name.len], " \t");
    }

    return null;
}

/// The engine's own reason for quitting: its Fatal errorMsg. The message quotes names itself, so it
/// ends at the next field, not the next quote. Cut to what the server keeps of a job's error, so the
/// line bake prints it on stays short enough for a worker's line buffer.
fn engineError(text: []const u8) ?[]const u8 {
    const key = "errorMsg=\"";
    const at = std.mem.lastIndexOf(u8, text, key) orelse return null;
    const rest = text[at + key.len ..];
    const message = rest[0 .. std.mem.indexOf(u8, rest, "\" msgCaption=") orelse return null];
    if (message.len <= max_error_len) return message;
    var end: usize = max_error_len;
    while (end > 0 and message[end] & 0xC0 == 0x80) end -= 1;

    return message[0..end];
}

const max_error_len = 2000;

/// Copies the .lua widgets in `from` into `widgets`, after removing the ones copied last time (one
/// may have been taken out), and returns their names
fn extraWidgets(ctx: Ctx, widgets: []const u8, from: ?[]const u8) ![]const []const u8 {
    const copied = try join(ctx, &.{ widgets, ".extra-widgets" });
    if (Io.Dir.cwd().readFileAlloc(ctx.io, copied, ctx.gpa, .limited(1 << 20))) |list| {
        var lines = std.mem.splitScalar(u8, list, '\n');
        while (lines.next()) |name| if (name.len > 0) Io.Dir.cwd().deleteFile(ctx.io, try join(ctx, &.{ widgets, name })) catch {};
    } else |_| {}

    var names: std.ArrayList([]const u8) = .empty;
    var files: Io.Writer.Allocating = .init(ctx.gpa);
    if (from) |dir_path| {
        var dir = try Io.Dir.cwd().openDir(ctx.io, dir_path, .{ .iterate = true });
        defer dir.close(ctx.io);
        var it = dir.iterate();
        while (try it.next(ctx.io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".lua")) continue;
            const text = try dir.readFileAlloc(ctx.io, entry.name, ctx.gpa, .limited(16 << 20));
            try Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = try join(ctx, &.{ widgets, entry.name }), .data = text });
            try files.writer.print("{s}\n", .{entry.name});
            if (widgetName(text)) |name| try names.append(ctx.gpa, name);
        }
    }
    try Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = copied, .data = files.written() });

    return names.items;
}

fn widgetName(text: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, "name")) |at| {
        i = at + "name".len;
        if (at > 0 and (std.ascii.isAlphanumeric(text[at - 1]) or text[at - 1] == '_')) continue;
        var j = i;
        while (j < text.len and (text[j] == ' ' or text[j] == '\t')) j += 1;
        if (j >= text.len or text[j] != '=') continue;
        j += 1;
        while (j < text.len and (text[j] == ' ' or text[j] == '\t')) j += 1;
        if (j >= text.len or text[j] != '"') continue;
        const end = std.mem.indexOfScalarPos(u8, text, j + 1, '"') orelse return null;

        return text[j + 1 .. end];
    }

    return null;
}

/// BAR's interface widgets draw nothing in a headless parse yet took about a quarter of a long one:
/// the widget config turns off every widget it knows, and those a newer BAR added to it since, except
/// the recording widgets and `keep`
fn widgetConfig(ctx: Ctx, bar: []const u8, keep: []const []const u8) !void {
    const path = try join(ctx, &.{ bar, "LuaUI", "Config", "BYAR.lua" });
    var names: std.StringArrayHashMapUnmanaged(void) = .empty;
    var lines = std.mem.splitScalar(u8, bar_widgets, '\n');
    while (lines.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \r");
        if (name.len > 0) try names.put(ctx.gpa, name, {});
    }
    if (Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.gpa, .limited(16 << 20))) |text| {
        if (orderBlock(text)) |order| {
            var i: usize = 0;
            while (std.mem.indexOfPos(u8, order, i, "[\"")) |at| {
                const end = std.mem.indexOfPos(u8, order, at + 2, "\"]") orelse break;
                try names.put(ctx.gpa, order[at + 2 .. end], {});
                i = end + 2;
            }
        }
    } else |_| {}
    for (recording_widgets) |n| try names.put(ctx.gpa, n, {});
    for (keep) |n| try names.put(ctx.gpa, n, {});
    const sorted = try ctx.gpa.dupe([]const u8, names.keys());
    std.mem.sort([]const u8, sorted, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);

    var out: Io.Writer.Allocating = .init(ctx.gpa);
    try out.writer.writeAll("return {\n\tallowUserWidgets = true,\n\torder = {\n");
    for (sorted) |name| {
        var on = false;
        for (recording_widgets) |n| on = on or std.mem.eql(u8, n, name);
        for (keep) |n| on = on or std.mem.eql(u8, n, name);
        try out.writer.writeAll("\t\t[");
        try bake.luaString(&out.writer, name);
        try out.writer.print("] = {d},\n", .{@intFromBool(on)});
    }
    try out.writer.writeAll("\t},\n}\n");
    try Io.Dir.cwd().createDirPath(ctx.io, std.fs.path.dirname(path).?);
    try Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = out.written() });
}

/// The `order = { ... }` block of a BAR widget config
fn orderBlock(text: []const u8) ?[]const u8 {
    const key = "\n\torder";
    const at = std.mem.indexOf(u8, text, key) orelse return null;
    const open = std.mem.indexOfScalarPos(u8, text, at + key.len, '{') orelse return null;
    const close = std.mem.indexOfPos(u8, text, open, "\n\t}") orelse return null;

    return text[open + 1 .. close];
}

test "widget names and the order block come out of the files BAR writes" {
    try std.testing.expectEqualStrings("Replay Dump v2", widgetName("function widget:GetInfo()\n\treturn {\n\t\tname = \"Replay Dump v2\",\n").?);
    try std.testing.expectEqualStrings("Eco", widgetName("local filename = \"x.txt\"\nname=\"Eco\"").?);
    try std.testing.expect(widgetName("no widget here") == null);
    const config = "return {\n\tallowUserWidgets = true,\n\torder = {\n\t\t[\"A\"] = 1,\n\t\t[\"B b\"] = 0,\n\t},\n}\n";
    try std.testing.expectEqualStrings("\n\t\t[\"A\"] = 1,\n\t\t[\"B b\"] = 0,", orderBlock(config).?);
}

test "progress and failures come out of the engine's log" {
    const log =
        "[t=00:00:02.058664][f=-000001] [LuaIntro] Loading widget:      Engine Taskbar Stuff   <engine_taskbar_control.lua>\n" ++
        "[t=00:00:02.112596][f=-000001] [LoadScreen::SetLoadMessage] text=\"Loading SMF\"\n" ++
        "[t=00:00:03.000000][f=-000001] Loading tweakdefs1 modoption\n";
    try std.testing.expectEqualStrings("Loading SMF", loadMessage(log).?);
    try std.testing.expectEqualStrings("Engine Taskbar Stuff", loadMessage(log[0..120]).?);
    try std.testing.expectEqualStrings("Unit Script", loadMessage("[f=-000001] Loading synced gadget:  Unit Script  <unit_script.lua>\r\n").?);
    try std.testing.expect(loadMessage("[LuaIntro] Loading widgets   <>=vfs  **=raw  ()=unknown\n") == null);

    try std.testing.expectEqual(600, lastDumpFrame("Replay Dump v2: frame 300, terrain updates 2\nReplay Dump v2: frame 600, terrain updates 5\n").?);
    try std.testing.expect(lastDumpFrame("Replay Dump v2: done\n") == null);

    try std.testing.expectEqualStrings("map \"x\" not found", engineError("[Fatal] errorMsg=\"map \"x\" not found\" msgCaption=\"Spring: caught\"").?);
    try std.testing.expect(engineError("errorMsg=\"cut off") == null);
    const gpa = std.testing.allocator;
    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(gpa);
    try long.appendSlice(gpa, "errorMsg=\"");
    for (0..1500) |_| try long.appendSlice(gpa, "\xc3\xa9");
    try long.appendSlice(gpa, "\" msgCaption=\"x\"");
    const cut = engineError(long.items).?;
    try std.testing.expect(cut.len <= max_error_len and std.unicode.utf8ValidateSlice(cut));
}
