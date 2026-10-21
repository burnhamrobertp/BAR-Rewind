//! bake <bardump.jsonl> <out.curves> <demo.sdfz>
//! bake export-lua <in.curves> <dir>   (chunked sections + meta.lua for the Recoil player)
//! bake start-script <in.curves> <out.txt>   (the player's start script)
//! bake info <in.curves>   (engine, game and map, one key=value per line)
//! Turns the dump widget's 10 Hz samples into ChronoCam curves: every entity becomes key lists
//! simplified with Douglas-Peucker, then everything is written as flat arrays (see curves.zig).

const std = @import("std");
const builtin = @import("builtin");
const curves = @import("curves.zig");

const Unit = curves.Unit;
const TransformKey = curves.TransformKey;
const StatusKey = curves.StatusKey;
const PieceKey = curves.PieceKey;
const PoseKey = curves.PoseKey;
const ProjectileKey = curves.ProjectileKey;
const List = std.ArrayList;

/// World units (elmos). Direction and rotation components are scaled so ~0.5 elmo also holds at
/// a 20 elmo lever arm.
pub const tolerance = 0.5;
const transform_scale: [9]f32 = .{ 1, 1, 1, 20, 20, 20, 20, 20, 20 };
const status_scale: [4]f32 = .{ 0.1, 0, 100, 100 }; // 5 hp, 0.5% build, any on/off change
const projectile_scale: [6]f32 = .{ 1, 1, 1, 2, 2, 2 };
const pose_scale: [6]f32 = .{ 20, 20, 20, 1, 1, 1 };

/// One dump frame. Units, pieces and features only on unit sample frames (every `step`), queues
/// every second; projectiles and terrain every frame.
const Sample = struct {
    f: u32,
    unit_sample: bool,
    /// 23 values (see the dump widget)
    u: []const []const f64,
    /// [unit, piece, 12 matrix values (no w row)]
    p: []const []const f64,
    fa: []const [8]f64,
    fr: []const u32,
    pr: []const [10]f64,
    /// heightmap x, z, height, previous height
    terrain: []const [4]f64,
    /// builder, team, n, then n x (def, x, z, facing)
    queues: []const f64,
};

const UnitBuild = struct {
    unit: Unit,
    last_frame: u32,
    queues: List(curves.Queue) = .empty,
    /// (frame, team) whenever the team differs from the last sample's
    teams: List([2]u32) = .empty,
    transforms: List(TransformKey) = .empty,
    statuses: List(StatusKey) = .empty,
    targets: List(curves.TargetKey) = .empty,
    /// indexed by piece - 1
    tracks: List(List(PieceKey)) = .empty,
};

const ProjectileBuild = struct {
    projectile: curves.Projectile,
    last_frame: u32,
    keys: List(ProjectileKey) = .empty,
};

/// ponytail: growable lists on the gpa, offline tool that runs once per replay; the viewer side is
/// fixed-size views into the mmapped file.
const Bake = struct {
    gpa: std.mem.Allocator,
    step: u32 = 3,
    first_frame: u32 = curves.alive_forever,
    last_frame: u32 = 0,
    last_unit_frame: u32 = 0,
    meta: List(u8) = .empty,
    pieces_meta: List(u8) = .empty,
    chat_meta: List(u8) = .empty,
    markers_meta: List(u8) = .empty,
    cameras_meta: List(u8) = .empty,
    /// per unit def: parent piece index (1-based, 0 = root) and original offset for each piece
    parents: std.AutoHashMapUnmanaged(u32, []const u32) = .empty,
    offsets: std.AutoHashMapUnmanaged(u32, []const [3]f32) = .empty,
    units: List(UnitBuild) = .empty,
    live_units: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    features: List(curves.Feature) = .empty,
    live_features: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    projectiles: List(ProjectileBuild) = .empty,
    live_projectiles: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    terrain: List(curves.TerrainKey) = .empty,
    queue_items: List(curves.QueueItem) = .empty,
};

fn v3(row: []const f64) [3]f32 {
    return .{ @floatCast(row[0]), @floatCast(row[1]), @floatCast(row[2]) };
}

fn addSample(b: *Bake, s: Sample) !void {
    const gpa = b.gpa;
    const f = s.f;
    if (b.first_frame == curves.alive_forever) b.first_frame = f;
    b.last_frame = f;
    if (s.unit_sample) b.last_unit_frame = f;

    for (s.u) |row| {
        const id: u32 = @intFromFloat(row[0]);
        const entry = try b.live_units.getOrPut(gpa, id);
        // an id missing from the previous sample is a new unit: Recoil reuses ids
        if (!entry.found_existing or b.units.items[entry.value_ptr.*].last_frame + b.step != f) {
            entry.value_ptr.* = @intCast(b.units.items.len);
            try b.units.append(gpa, .{ .last_frame = f, .unit = .{
                .id = id,
                .def = @intFromFloat(row[1]),
                .team = @intFromFloat(row[2]),
                .born = f,
                .died = curves.alive_forever,
                .transforms = undefined,
                .statuses = undefined,
                .targets = undefined,
                .tracks = undefined,
            } });
        }
        const u = &b.units.items[entry.value_ptr.*];
        u.last_frame = f;
        const team: u32 = @intFromFloat(row[2]);
        const current = if (u.teams.items.len > 0) u.teams.getLast()[1] else u.unit.team;
        if (team != current) try u.teams.append(gpa, .{ f, team });
        var t: TransformKey = .{ .t = f, .v = undefined };
        for (&t.v, row[3..12]) |*o, x| o.* = @floatCast(x);
        try u.transforms.append(gpa, t);
        try u.statuses.append(gpa, .{ .t = f, .v = .{ @floatCast(row[12]), @floatCast(row[13]), @floatCast(row[14]), @floatCast(row[15]) } });
        {
            // step curve: a key only when the target changes (ground targets: moved 16 elmos) or the
            // builder's work does (task, or build power by 5%)
            var target: [7]f32 = undefined;
            for (&target, row[16..23]) |*o, x| o.* = @floatCast(x);
            const changed = if (u.targets.items.len == 0) true else blk: {
                const last = u.targets.items[u.targets.items.len - 1].v;
                if (last[0] != target[0] or (target[0] != 2 and last[1] != target[1])) break :blk true;
                if (last[4] != target[4] or last[5] != target[5]) break :blk true;
                if ((last[6] == 0) != (target[6] == 0) or @abs(last[6] - target[6]) > 0.05) break :blk true;
                const dx = last[1] - target[1];
                const dz = last[3] - target[3];
                break :blk target[0] == 2 and dx * dx + dz * dz > 16 * 16;
            };
            if (changed) try u.targets.append(gpa, .{ .t = f, .v = target });
        }
    }

    for (s.p) |row| {
        const id: u32 = @intFromFloat(row[0]);
        const piece: u32 = @intFromFloat(row[1]);
        const unit_index = b.live_units.get(id) orelse continue;
        const u = &b.units.items[unit_index];
        while (u.tracks.items.len < piece) try u.tracks.append(gpa, .empty);
        const track = &u.tracks.items[piece - 1];
        const m = row[2..];
        var key: PieceKey = .{ .t = f, .v = undefined };
        for (&key.v, m[0..12]) |*o, x| o.* = @floatCast(x);
        // the widget only writes changes: hold the previous value until the sample before this one
        if (track.items.len > 0) {
            const last = track.items[track.items.len - 1];
            if (last.t + b.step < f) try track.append(gpa, .{ .t = f - b.step, .v = last.v });
        }
        try track.append(gpa, key);
    }

    for (s.fa) |row| {
        const id: u32 = @intFromFloat(row[0]);
        try b.live_features.put(gpa, id, @intCast(b.features.items.len));
        try b.features.append(gpa, .{
            .id = id,
            .def = @intFromFloat(row[1]),
            .born = f,
            .died = curves.alive_forever,
            .pos = v3(row[2..5]),
            .dir = v3(row[5..8]),
        });
    }
    for (s.fr) |id| {
        const kv = b.live_features.fetchRemove(id) orelse continue;
        b.features.items[kv.value].died = f;
    }

    for (s.pr) |row| {
        const id: u32 = @intFromFloat(row[0]);
        const entry = try b.live_projectiles.getOrPut(gpa, id);
        if (!entry.found_existing or b.projectiles.items[entry.value_ptr.*].last_frame + 1 != f) {
            entry.value_ptr.* = @intCast(b.projectiles.items.len);
            try b.projectiles.append(gpa, .{ .last_frame = f, .projectile = .{
                .id = id,
                .def = @intFromFloat(row[1]),
                .team = @intFromFloat(row[2]),
                .born = f,
                .died = curves.alive_forever,
                .keys = undefined,
                .owner = @intFromFloat(row[9]),
            } });
        }
        const p = &b.projectiles.items[entry.value_ptr.*];
        p.last_frame = f;
        try p.keys.append(gpa, .{ .t = f, .v = .{
            @floatCast(row[3]), @floatCast(row[4]), @floatCast(row[5]),
            @floatCast(row[6]), @floatCast(row[7]), @floatCast(row[8]),
        } });
    }

    for (s.terrain) |row| try b.terrain.append(gpa, .{
        .t = f,
        .x = @intFromFloat(row[0]),
        .z = @intFromFloat(row[1]),
        .h = @floatCast(row[2]),
        .prev = @floatCast(row[3]),
    });

    var at: usize = 0;
    while (at + 3 <= s.queues.len) {
        const id: u32 = @intFromFloat(s.queues[at]);
        const n: usize = @intFromFloat(s.queues[at + 2]);
        const items = s.queues[at + 3 ..][0 .. n * 4];
        at += 3 + n * 4;
        const unit_index = b.live_units.get(id) orelse continue;
        const first: u32 = @intCast(b.queue_items.items.len);
        for (0..n) |i| try b.queue_items.append(gpa, .{
            .def = @intFromFloat(items[i * 4]),
            .x = @floatCast(items[i * 4 + 1]),
            .z = @floatCast(items[i * 4 + 2]),
            .facing = @floatCast(items[i * 4 + 3]),
        });
        try b.units.items[unit_index].queues.append(gpa, .{ .unit = unit_index, .t = f, .items = .{ .first = first, .count = @intCast(n) } });
    }
}

/// Records written by the dump widget into bardump.bin: "BRDB", u32 version 3, u32 unit row width,
/// then per frame u32 frame, u32 counts {units, pieces, features added, features removed,
/// projectiles, terrain, queue floats} and f32 rows of unit_row, 14, 8, 1, 10, 4 and 1 values.
/// ponytail: the whole file is read at once; stream it if dumps outgrow RAM
fn addBinarySamples(b: *Bake, arena_state: *std.heap.ArenaAllocator, bin: []const u8) !void {
    if (!std.mem.startsWith(u8, bin, "BRDB") or std.mem.readInt(u32, bin[4..8], .little) != 3) return error.OldDump;
    const unit_row: usize = std.mem.readInt(u32, bin[8..12], .little);
    if (unit_row != 23) return error.OldDump;
    var at: usize = 12;
    while (at + 32 <= bin.len) {
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        var head: [8]u32 = undefined;
        for (&head, 0..) |*h, i| h.* = std.mem.readInt(u32, bin[at + i * 4 ..][0..4], .little);
        at += 32;
        const counts = head[1..8];
        const widths = [7]usize{ unit_row, 14, 8, 1, 10, 4, 1 };
        var floats: [7][]f64 = undefined;
        for (counts, widths, &floats) |count, width, *out| {
            const n = count * width;
            if (at + n * 4 > bin.len) return error.TruncatedDump;
            out.* = try arena.alloc(f64, n);
            for (out.*, 0..) |*o, i| o.* = @as(f32, @bitCast(std.mem.readInt(u32, bin[at + i * 4 ..][0..4], .little)));
            at += n * 4;
        }
        const u = try arena.alloc([]const f64, counts[0]);
        for (u, 0..) |*row, i| row.* = floats[0][i * unit_row ..][0..unit_row];
        const p = try arena.alloc([]const f64, counts[1]);
        for (p, 0..) |*row, i| row.* = floats[1][i * 14 ..][0..14];
        const fr = try arena.alloc(u32, counts[3]);
        for (fr, floats[3]) |*o, x| o.* = @intFromFloat(x);
        try addSample(b, .{
            .f = head[0],
            .unit_sample = head[0] % b.step == 0,
            .u = u,
            .p = p,
            .fa = @as([*]const [8]f64, @ptrCast(floats[2].ptr))[0..counts[2]],
            .fr = fr,
            .pr = @as([*]const [10]f64, @ptrCast(floats[4].ptr))[0..counts[4]],
            .terrain = @as([*]const [4]f64, @ptrCast(floats[5].ptr))[0..counts[5]],
            .queues = floats[6],
        });
    }
}

/// Records written by the dump widget into bardump_view.bin (see it): cursors become one thinned
/// curve per player, camera states keys as recorded.
fn addView(
    gpa: std.mem.Allocator,
    view: []const u8,
    tracks: *Out(.cursor_tracks),
    keys: *Out(.cursor_keys),
    cams: *Out(.camera_keys),
    values: *Out(.camera_values),
    stats: *Stats,
) !void {
    if (view.len < 8 or !std.mem.eql(u8, view[0..4], "BRVW")) return error.BadView;
    var per: std.AutoArrayHashMapUnmanaged(u32, List(curves.CursorKey)) = .empty;
    defer per.deinit(gpa);
    var at: usize = 8;
    while (at + 16 <= view.len) {
        var h: [4]u32 = undefined;
        for (&h, 0..) |*o, i| o.* = std.mem.readInt(u32, view[at + i * 4 ..][0..4], .little);
        at += 16;
        const n: usize = h[3];
        if (at + n * 4 > view.len) break;
        const raw = view[at..][0 .. n * 4];
        at += n * 4;
        const f = struct {
            fn get(bytes: []const u8, i: usize) f32 {
                return @bitCast(std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little));
            }
        }.get;
        switch (h[1]) {
            1 => if (n == 5) {
                var k: curves.CursorKey = .{ .t = h[0], .v = undefined };
                for (&k.v, 0..) |*o, i| o.* = f(raw, i);
                const entry = try per.getOrPut(gpa, h[2]);
                if (!entry.found_existing) entry.value_ptr.* = .empty;
                try entry.value_ptr.append(gpa, k);
            },
            2, 3 => {
                const first: u32 = @intCast(values.items.len);
                const mode: i32 = if (h[1] == 2 and n > 0) @intFromFloat(f(raw, 0)) else -1;
                for (@min(n, @intFromBool(h[1] == 2))..n) |i| try values.append(gpa, f(raw, i));
                try cams.append(gpa, .{ .t = h[0], .player = h[2], .mode = mode, .values = .{ .first = first, .count = @intCast(values.items.len - first) } });
            },
            else => {},
        }
    }
    // within 8 elmos; a click always keeps its key
    const scale: [5]f32 = .{ 1.0 / 16.0, 1.0 / 16.0, 1.0 / 16.0, 1.0 / 16.0, 100 };
    for (per.keys(), per.values()) |player, *list| {
        defer list.deinit(gpa);
        try tracks.append(gpa, .{ .player = player, .keys = try bakeCurve(curves.CursorKey, gpa, list.items, scale, keys, stats) });
    }
}

/// Header lines ({"map":...}, {"defs":...}, one {"pieces":...} per unit def) become one JSON object.
fn addHeader(b: *Bake, line: []const u8) !void {
    const gpa = b.gpa;
    const inner = line[1 .. line.len - 1];
    const pieces_prefix = "\"pieces\":";
    if (std.mem.startsWith(u8, inner, pieces_prefix)) {
        try b.pieces_meta.append(gpa, if (b.pieces_meta.items.len == 0) '[' else ',');
        try b.pieces_meta.appendSlice(gpa, inner[pieces_prefix.len..]);
        const Pieces = struct { def: u32, names: []const []const u8, parents: []const []const u8, offsets: []const [3]f32 = &.{} };
        const p = try std.json.parseFromSliceLeaky(Pieces, gpa, inner[pieces_prefix.len..], .{ .ignore_unknown_fields = true });
        const parents = try gpa.alloc(u32, p.names.len);
        for (p.parents, parents) |name, *out| {
            out.* = 0;
            for (p.names, 1..) |candidate, i| if (std.mem.eql(u8, candidate, name)) {
                out.* = @intCast(i);
                break;
            };
        }
        try b.parents.put(gpa, p.def, parents);
        try b.offsets.put(gpa, p.def, p.offsets);
        return;
    }
    // one line per message or mark, collected into arrays
    inline for (.{ .{ "\"chat\":", &b.chat_meta }, .{ "\"marker\":", &b.markers_meta }, .{ "\"camkeys\":", &b.cameras_meta } }) |pair| {
        if (std.mem.startsWith(u8, inner, pair[0])) {
            try pair[1].append(gpa, if (pair[1].items.len == 0) '[' else ',');
            try pair[1].appendSlice(gpa, inner[pair[0].len..]);
            return;
        }
    }
    if (std.mem.eql(u8, inner, "\"end\":true")) return;
    try b.meta.append(gpa, if (b.meta.items.len == 0) '{' else ',');
    try b.meta.appendSlice(gpa, inner);
}

const Stats = struct { in: usize = 0, out: usize = 0, worst: f32 = 0 };

/// Simplifies `keys` into `out` and checks every input key against the result.
fn bakeCurve(comptime K: type, gpa: std.mem.Allocator, keys: []const K, scale: [K.len]f32, out: *List(K), stats: *Stats) !curves.Span {
    const keep = try gpa.alloc(bool, keys.len);
    defer gpa.free(keep);
    const stack = try gpa.alloc([2]u32, keys.len);
    defer gpa.free(stack);
    curves.simplify(K, keys, scale, tolerance, keep, stack);

    const first: u32 = @intCast(out.items.len);
    for (keys, keep) |k, kept| if (kept) try out.append(gpa, k);
    const span: curves.Span = .{ .first = first, .count = @intCast(out.items.len - first) };

    const baked = curves.slice(K, out.items, span);
    for (keys) |k| {
        const e = curves.keyError(K.len, curves.sample(K, baked, @floatFromInt(k.t)), k.v, scale);
        stats.worst = @max(stats.worst, e);
    }
    stats.in += keys.len;
    stats.out += span.count;
    return span;
}

fn Out(comptime s: curves.Section) type {
    return List(curves.SectionType(s));
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 4 and std.mem.eql(u8, args[1], "export-lua")) return exportLua(io, gpa, args[2], args[3]);
    if (args.len == 4 and std.mem.eql(u8, args[1], "start-script")) return writeStartScript(io, gpa, args[2], args[3]);
    if (args.len == 3 and std.mem.eql(u8, args[1], "info")) return printInfo(io, gpa, args[2]);
    if (args.len == 2 and std.mem.eql(u8, args[1], "version")) {
        std.log.info("curves version {d}", .{curves.version});
        return;
    }
    if (args.len != 4) {
        std.log.err("usage: bake <bardump.jsonl> <out.curves> <demo.sdfz> | bake export-lua <in.curves> <out-dir> | bake start-script <in.curves> <out.txt> | bake info <in.curves> | bake version", .{});
        std.process.exit(2);
    }
    const demo = try readDemo(io, gpa, args[3]);

    const text = try std.Io.Dir.cwd().readFileAlloc(io, args[1], gpa, .limited(16 << 30));
    var b: Bake = .{ .gpa = gpa };

    var lines = std.mem.splitScalar(u8, text, '\n');
    var parse_arena: std.heap.ArenaAllocator = .init(gpa);
    while (lines.next()) |raw| {
        // dumps written in Windows text mode end lines in \r\n
        const line = if (builtin.os.tag == .windows) std.mem.trimEnd(u8, raw, "\r") else raw;
        if (line.len < 2) continue;
        try addHeader(&b, line);
    }
    gpa.free(text);

    // the per-frame samples sit next to the headers: out.jsonl -> out.bin
    const stem = if (std.mem.endsWith(u8, args[1], ".jsonl")) args[1][0 .. args[1].len - ".jsonl".len] else args[1];
    const bin_path = try std.fmt.allocPrint(gpa, "{s}.bin", .{stem});
    const bin = try std.Io.Dir.cwd().readFileAlloc(io, bin_path, gpa, .limited(64 << 30));
    try addBinarySamples(&b, &parse_arena, bin);
    gpa.free(bin);

    // what the players looked at, when the dump recorded it: out.jsonl -> out.view.bin
    var cursor_tracks: Out(.cursor_tracks) = .empty;
    var cursor_keys: Out(.cursor_keys) = .empty;
    var camera_keys: Out(.camera_keys) = .empty;
    var camera_values: Out(.camera_values) = .empty;
    var cursor_stats: Stats = .{};
    const view_path = try std.fmt.allocPrint(gpa, "{s}.view.bin", .{stem});
    if (std.Io.Dir.cwd().readFileAlloc(io, view_path, gpa, .limited(16 << 30))) |view| {
        defer gpa.free(view);
        try addView(gpa, view, &cursor_tracks, &cursor_keys, &camera_keys, &camera_values, &cursor_stats);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    const eco_path = try std.fmt.allocPrint(gpa, "{s}.eco.bin", .{stem});
    const eco: []const u8 = std.Io.Dir.cwd().readFileAlloc(io, eco_path, gpa, .limited(1 << 30)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    if (b.pieces_meta.items.len > 0) try b.pieces_meta.append(gpa, ']') else try b.pieces_meta.appendSlice(gpa, "[]");
    try b.meta.appendSlice(gpa, if (b.meta.items.len == 0) "{\"pieces\":" else ",\"pieces\":");
    try b.meta.appendSlice(gpa, b.pieces_meta.items);
    inline for (.{ .{ ",\"chat\":", &b.chat_meta }, .{ ",\"markers\":", &b.markers_meta }, .{ ",\"cameras\":", &b.cameras_meta } }) |pair| {
        try b.meta.appendSlice(gpa, pair[0]);
        if (pair[1].items.len > 0) {
            try pair[1].append(gpa, ']');
            try b.meta.appendSlice(gpa, pair[1].items);
        } else try b.meta.appendSlice(gpa, "[]");
    }
    try b.meta.append(gpa, '}');

    // deaths: gone at the sample after the last one it was seen in; seen in the last one = alive
    const died = struct {
        fn at(last_seen: u32, last_sample: u32, step: u32) u32 {
            return if (last_seen == last_sample) curves.alive_forever else last_seen + step;
        }
    }.at;

    var units: Out(.units) = .empty;
    var transforms: Out(.transforms) = .empty;
    var statuses: Out(.statuses) = .empty;
    var tracks: Out(.tracks) = .empty;
    var projectiles: Out(.projectiles) = .empty;
    var projectile_keys: Out(.projectile_keys) = .empty;
    var pose_keys: Out(.pose_keys) = .empty;
    var targets: Out(.targets) = .empty;
    var queues: Out(.queues) = .empty;
    var team_keys: Out(.team_keys) = .empty;
    var st: [4]Stats = @splat(.{});

    for (b.units.items) |*u| {
        var unit = u.unit;
        unit.died = died(u.last_frame, b.last_unit_frame, b.step);
        for (u.teams.items) |k| try team_keys.append(gpa, .{ .unit = @intCast(units.items.len), .t = k[0], .team = k[1] });
        try queues.appendSlice(gpa, u.queues.items);
        // the plan ends with the builder
        if (unit.died != curves.alive_forever and u.queues.items.len > 0 and u.queues.getLast().items.count > 0)
            try queues.append(gpa, .{ .unit = @intCast(units.items.len), .t = unit.died, .items = .{ .first = 0, .count = 0 } });
        unit.transforms = try bakeCurve(TransformKey, gpa, u.transforms.items, transform_scale, &transforms, &st[0]);
        unit.statuses = try bakeCurve(StatusKey, gpa, u.statuses.items, status_scale, &statuses, &st[1]);
        unit.targets = .{ .first = @intCast(targets.items.len), .count = @intCast(u.targets.items.len) };
        try targets.appendSlice(gpa, u.targets.items);
        unit.tracks = .{ .first = @intCast(tracks.items.len), .count = 0 };
        const parents: []const u32 = b.parents.get(u.unit.def) orelse &.{};
        const offsets: []const [3]f32 = b.offsets.get(u.unit.def) orelse &.{};
        // aim pieces (each weapon's muzzle and its parents, as the dump records them) play from their
        // curves; everything else is animated by BAR's own unit scripts (as PA does)
        for (u.tracks.items, 1..) |track, piece| {
            if (track.items.len == 0) continue;
            // piece space: inverse(parent model matrix) * model matrix, at each of this piece's keys,
            // then as Recoil unit-script Turn angles + Move offsets
            const parent = if (piece - 1 < parents.len) parents[piece - 1] else 0;
            const offset: [3]f32 = if (piece - 1 < offsets.len) offsets[piece - 1] else .{ 0, 0, 0 };
            const pose = try gpa.alloc(PoseKey, track.items.len);
            defer gpa.free(pose);
            var previous: [3]f32 = .{ 0, 0, 0 };
            for (track.items, pose, 0..) |k, *out, i| {
                var local = k.v;
                if (parent != 0 and parent <= u.tracks.items.len and u.tracks.items[parent - 1].items.len > 0) {
                    const pm = curves.sample(PieceKey, u.tracks.items[parent - 1].items, @floatFromInt(k.t));
                    local = curves.mulRigid(curves.invertRigid(pm), k.v);
                }
                var angles = curves.recoilAngles(local);
                for (&angles) |*a| if (std.math.isNan(a.*)) {
                    a.* = 0;
                };
                if (i > 0) angles = curves.nearestAngles(angles, previous);
                previous = angles;
                out.* = .{ .t = k.t, .v = .{ angles[0], angles[1], angles[2], local[9] - offset[0], local[10] - offset[1], local[11] - offset[2] } };
            }
            const pose_span = try bakeCurve(PoseKey, gpa, pose, pose_scale, &pose_keys, &st[2]);
            try tracks.append(gpa, .{ .piece = @intCast(piece), .pose = pose_span });
            unit.tracks.count += 1;
        }
        try units.append(gpa, unit);
    }
    for (b.projectiles.items) |*p| {
        var projectile = p.projectile;
        projectile.died = died(p.last_frame, b.last_frame, 1);
        projectile.keys = try bakeCurve(ProjectileKey, gpa, p.keys.items, projectile_scale, &projectile_keys, &st[3]);
        try projectiles.append(gpa, projectile);
    }

    // write: header, then each section 16-byte aligned
    var header: curves.Header = .{
        .magic = curves.magic,
        .version = curves.version,
        .first_frame = b.first_frame,
        .last_frame = b.last_frame,
        .offsets = undefined,
        .counts = undefined,
    };
    const sections = .{
        b.meta.items,     units.items,      transforms.items,  statuses.items,        tracks.items,
        b.features.items, projectiles.items, projectile_keys.items, pose_keys.items, targets.items,
        b.terrain.items, queues.items, b.queue_items.items, team_keys.items,
        cursor_tracks.items, cursor_keys.items, camera_keys.items, camera_values.items,
        demo.engine,     demo.script,      eco,
    };
    var offset: u64 = std.mem.alignForward(u64, @sizeOf(curves.Header), 16);
    inline for (sections, 0..) |items, i| {
        header.offsets[i] = offset;
        header.counts[i] = items.len;
        offset = std.mem.alignForward(u64, offset + std.mem.sliceAsBytes(items).len, 16);
    }

    const file = try std.Io.Dir.cwd().createFile(io, args[2], .{});
    defer file.close(io);
    try file.writePositionalAll(io, std.mem.asBytes(&header), 0);
    inline for (sections, 0..) |items, i| try file.writePositionalAll(io, std.mem.sliceAsBytes(items), header.offsets[i]);

    const names = [_][]const u8{ "transform", "status", "pose", "projectile" };
    std.log.info("frames {d}..{d}, {d} units, {d} features, {d} projectiles, {d} terrain changes, {d} queues, {d} team changes, {d} MB", .{
        b.first_frame, b.last_frame, units.items.len, b.features.items.len, projectiles.items.len, b.terrain.items.len, queues.items.len, team_keys.items.len, offset >> 20,
    });
    for (st, names) |s, name| std.log.info("{s}: {d} -> {d} keys, worst error {d:.3}", .{ name, s.in, s.out, s.worst });
    std.log.info("cursor: {d} -> {d} keys for {d} players, camera: {d} keys", .{ cursor_stats.in, cursor_stats.out, cursor_tracks.items.len, camera_keys.items.len });
    for (st) |s| if (s.worst > tolerance + 1e-3) {
        std.log.err("baked curve exceeds tolerance", .{});
        std.process.exit(1);
    };
}

// export for the Recoil player --------------------------------------------------------------------

/// Recoil's Lua numbers are 32-bit floats: byte offsets past 2^24 are not exact. Every section is
/// split into files of at most `chunk_bytes`, so offsets inside one chunk stay exact.
pub const chunk_bytes = 8 << 20;
/// 30 s of sim frames per window: the player keeps one window of key data in memory
pub const window_frames = 900;

/// Writes `bytes` zlib-compressed (what Recoil's VFS.ZlibDecompress inflates). Empty stays empty.
fn writeZlib(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    const file = try dir.createFile(io, name, .{});
    defer file.close(io);
    if (bytes.len == 0) return;
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, bytes.len / 2 + 64);
    defer out.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var z = try std.compress.flate.Compress.init(&out.writer, &window, .zlib, .level_6);
    try z.writer.writeAll(bytes);
    try z.finish();
    try file.writePositionalAll(io, out.written(), 0);
}

fn orderT(comptime K: type) fn (u32, K) std.math.Order {
    return struct {
        fn order(t: u32, k: K) std.math.Order {
            return std.math.order(t, k.t);
        }
    }.order;
}

fn isAny(name: []const u8, names: []const []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

/// `s` as a double-quoted Lua string literal
fn luaString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        0...9, 11, 12, 14...31, 127 => try w.print("\\{d:0>3}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// Writes `<name>_w<w>_<chunk>.bin` (keys) and `<name>_w<w>_index.bin` (u32 curve, first, count)
/// for every window, and the Lua table describing them.
fn writeWindows(
    comptime K: type,
    io: std.Io,
    gpa: std.mem.Allocator,
    dir: std.Io.Dir,
    w: *std.Io.Writer,
    comptime name: []const u8,
    file: curves.File,
    keys: []const K,
    comptime per: enum { units, tracks },
    comptime which: usize,
    owner: []const u32,
    windows: u32,
) !void {
    const per_chunk = chunk_bytes / @sizeOf(K);
    try w.print("    {s} = {{ size = {d}, per_chunk = {d}, chunks = {{", .{ name, @sizeOf(K), per_chunk });
    var data: List(K) = .empty;
    defer data.deinit(gpa);
    var index: List(u32) = .empty;
    defer index.deinit(gpa);
    const count = if (per == .units) file.units.len else file.tracks.len;
    for (0..windows) |win| {
        data.clearRetainingCapacity();
        index.clearRetainingCapacity();
        const ws = file.header.first_frame + @as(u32, @intCast(win)) * window_frames;
        const we = ws + window_frames;
        for (0..count) |c| {
            const unit = file.units[if (per == .units) c else owner[c]];
            if (unit.born >= we or (unit.died != curves.alive_forever and unit.died <= ws)) continue;
            const span = if (per == .units) switch (which) {
                0 => unit.transforms,
                1 => unit.statuses,
                else => unit.targets,
            } else file.tracks[c].pose;
            const all = curves.slice(K, keys, span);
            if (all.len == 0) continue;
            // a: last key at or before the window start; b: first key at or after its end
            const a = std.sort.upperBound(K, all, ws, orderT(K)) -| 1;
            const b = @min(std.sort.lowerBound(K, all, we, orderT(K)), all.len - 1);
            try index.appendSlice(gpa, &.{ @intCast(c), @intCast(data.items.len), @intCast(b - a + 1) });
            try data.appendSlice(gpa, all[a .. b + 1]);
        }
        var chunks: usize = 0;
        var i: usize = 0;
        while (i < data.items.len or chunks == 0) : (i += per_chunk) {
            var buf: [96]u8 = undefined;
            try writeZlib(io, gpa, dir, try std.fmt.bufPrint(&buf, "{s}_w{d}_{d}.bin", .{ name, win, chunks }), std.mem.sliceAsBytes(data.items[i..@min(i + per_chunk, data.items.len)]));
            chunks += 1;
            if (data.items.len == 0) break;
        }
        var buf: [96]u8 = undefined;
        try writeZlib(io, gpa, dir, try std.fmt.bufPrint(&buf, "{s}_w{d}_index.bin", .{ name, win }), std.mem.sliceAsBytes(index.items));
        try w.print(" [{d}] = {d},", .{ win, chunks });
    }
    try w.writeAll(" } },\n");
}

/// The player's transform keys: pos xyz + rotation quaternion. Along each unit's curve every
/// quaternion takes the sign nearer its predecessor, so lerping two keys turns the short way.
fn quatTransforms(gpa: std.mem.Allocator, file: curves.File) ![]curves.Key(7) {
    const out = try gpa.alloc(curves.Key(7), file.transforms.len);
    for (file.units) |unit| {
        var prev: [4]f32 = .{ 0, 0, 0, 1 };
        for (curves.slice(curves.TransformKey, file.transforms, unit.transforms), unit.transforms.first..) |k, i| {
            var q = curves.basisQuat(k.v[3..6].*, k.v[6..9].*);
            if (q[0] * prev[0] + q[1] * prev[1] + q[2] * prev[2] + q[3] * prev[3] < 0) q = .{ -q[0], -q[1], -q[2], -q[3] };
            prev = q;
            out[i] = .{ .t = k.t, .v = .{ k.v[0], k.v[1], k.v[2], q[0], q[1], q[2], q[3] } };
        }
    }
    return out;
}

fn exportLua(io: std.Io, gpa: std.mem.Allocator, curves_path: []const u8, out_dir: []const u8) !void {
    try exportFile(io, gpa, try readCurves(io, gpa, curves_path), out_dir);
    std.log.info("exported {s} to {s}", .{ curves_path, out_dir });
}

/// What the Recoil player reads from its replay/ folder
pub fn exportFile(io: std.Io, gpa: std.mem.Allocator, file: curves.File, out_dir: []const u8) !void {
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, out_dir, .{});
    defer dir.close(io);

    var lua: std.Io.Writer.Allocating = .init(gpa);
    const w = &lua.writer;
    try w.print("return {{\n  first_frame = {d},\n  last_frame = {d},\n  exact_poses = {},\n  sections = {{\n", .{ file.header.first_frame, file.header.last_frame, file.pose_keys.len > 0 });
    inline for (curves.section_names, 0..) |name, s| {
        // the Recoil player needs poses, not the model-space matrices the Vulkan viewer uses;
        // per-unit key curves go out in time windows below
        if (comptime isAny(name, &.{ "meta", "transforms", "statuses", "pose_keys", "targets", "engine", "demo_script", "eco" })) continue;
        const T = curves.SectionType(@enumFromInt(s));
        const items = @field(file, name);
        const per_chunk = chunk_bytes / @sizeOf(T);
        var chunks: usize = 0;
        var i: usize = 0;
        while (i < items.len or (i == 0 and chunks == 0)) : (i += per_chunk) {
            const end = @min(i + per_chunk, items.len);
            var name_buffer: [64]u8 = undefined;
            const chunk_name = try std.fmt.bufPrint(&name_buffer, "{s}_{d}.bin", .{ name, chunks });
            try writeZlib(io, gpa, dir, chunk_name, std.mem.sliceAsBytes(items[i..end]));
            chunks += 1;
            if (items.len == 0) break;
        }
        try w.print("    {s} = {{ size = {d}, count = {d}, per_chunk = {d}, chunks = {d} }},\n", .{ name, @sizeOf(T), items.len, per_chunk, chunks });
    }
    try w.writeAll("  },\n");

    // windows: each holds, for every curve alive in it, just the keys needed to sample inside it
    const windows = (file.header.last_frame - file.header.first_frame) / window_frames + 1;
    const owner = try gpa.alloc(u32, file.tracks.len);
    for (file.units, 0..) |unit, i| for (curves.slice(curves.Track, file.tracks, unit.tracks), 0..) |_, k| {
        owner[unit.tracks.first + k] = @intCast(i);
    };
    const unit_spans = try gpa.alloc([2]curves.Span, file.units.len);
    for (file.units, unit_spans) |unit, *out| out.* = .{ unit.transforms, unit.statuses };
    try w.print("  windows = {{ size = {d}, count = {d},\n", .{ window_frames, windows });
    try writeWindows(curves.Key(7), io, gpa, dir, w, "transforms", file, try quatTransforms(gpa, file), .units, 0, owner, windows);
    try writeWindows(curves.StatusKey, io, gpa, dir, w, "statuses", file, file.statuses, .units, 1, owner, windows);
    try writeWindows(curves.PoseKey, io, gpa, dir, w, "pose_keys", file, file.pose_keys, .tracks, 0, owner, windows);
    try writeWindows(curves.TargetKey, io, gpa, dir, w, "targets", file, file.targets, .units, 2, owner, windows);
    try w.writeAll("  },\n");

    if (file.eco.len > 0) {
        const eco = try dir.createFile(io, "eco.bin", .{});
        defer eco.close(io);
        try eco.writePositionalAll(io, file.eco, 0);
    }

    // names instead of ids: the playing BAR version may number defs differently than the replay's
    const meta = try parseMeta(gpa, file);
    try w.writeAll("  map = ");
    try luaString(w, meta.map.name);
    try w.writeAll(",\n");
    inline for (.{ .{ "defs", meta.defs }, .{ "fdefs", meta.fdefs }, .{ "wdefs", meta.wdefs } }) |pair| {
        try w.print("  {s} = {{", .{pair[0]});
        for (pair[1].map.keys(), pair[1].map.values()) |id, def| {
            try w.print(" [{d}] = ", .{try std.fmt.parseInt(i64, id, 10)});
            try luaString(w, def.name);
            try w.writeAll(",");
        }
        try w.writeAll(" },\n");
    }
    try w.writeAll("  teams = {");
    for (meta.teams.map.keys(), meta.teams.map.values()) |id, team| {
        const c = byteColor(team.color);
        try w.print(" [{d}] = {{ color = {{ {d:.9}, {d:.9}, {d:.9} }}, ally = {d}, leader = ", .{ try std.fmt.parseInt(i64, id, 10), c[0], c[1], c[2], team.ally });
        try luaString(w, team.leader orelse "");
        try w.writeAll(" },");
    }
    try w.writeAll(" },\n  chat = {\n");
    for (meta.chat) |c| {
        try w.print("    {{ f = {d}, team = {d}, spec = {}, pre = {}, channel = ", .{ c.f, c.team, c.spec, c.pre });
        try luaString(w, c.channel);
        try w.writeAll(", name = ");
        try luaString(w, c.name);
        try w.writeAll(", text = ");
        try luaString(w, c.text);
        try w.writeAll(" },\n");
    }
    try w.writeAll("  },\n  markers = {\n");
    for (meta.markers) |m| {
        try w.print("    {{ f = {d}, team = {d}, spec = {}, type = ", .{ m.f, m.team, m.spec });
        try luaString(w, m.@"type");
        try w.writeAll(", name = ");
        try luaString(w, m.name);
        try w.print(", x = {d}, y = {d}, z = {d}, x2 = {d}, y2 = {d}, z2 = {d}, label = ", .{ m.x, m.y, m.z, m.x2, m.y2, m.z2 });
        try luaString(w, m.label);
        try w.writeAll(" },\n");
    }
    try w.writeAll("  },\n  players = {");
    for (meta.players.map.keys(), meta.players.map.values()) |id, name| {
        try w.print(" [{d}] = ", .{try std.fmt.parseInt(i64, id, 10)});
        try luaString(w, name);
        try w.writeAll(",");
    }
    try w.writeAll(" },\n  cameras = {\n");
    for (meta.cameras) |cam| {
        try w.print("    [{d}] = {{ name = ", .{cam.mode});
        try luaString(w, cam.name);
        try w.writeAll(", keys = {");
        for (cam.keys) |k| {
            try w.writeAll(" ");
            try luaString(w, k);
            try w.writeAll(",");
        }
        try w.writeAll(" } },\n");
    }
    try w.writeAll("  },\n}\n");
    const meta_file = try dir.createFile(io, "meta.lua", .{});
    defer meta_file.close(io);
    try meta_file.writePositionalAll(io, lua.written(), 0);
}

const Named = struct { name: []const u8 = "" };
const Team = struct { color: [3]f32 = .{ 1, 1, 1 }, ally: i32 = 0, leader: ?[]const u8 = null };
const Chat = struct { f: u32 = 0, name: []const u8 = "", team: i32 = -1, spec: bool = false, channel: []const u8 = "all", text: []const u8 = "", pre: bool = false };
const Marker = struct {
    f: u32 = 0,
    name: []const u8 = "",
    team: i32 = -1,
    spec: bool = false,
    @"type": []const u8 = "point",
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    x2: f32 = 0,
    y2: f32 = 0,
    z2: f32 = 0,
    label: []const u8 = "",
};
const Camera = struct { mode: i32 = -1, name: []const u8 = "", keys: []const []const u8 = &.{} };
pub const Meta = struct {
    map: struct { name: []const u8 = "" } = .{},
    defs: std.json.ArrayHashMap(Named) = .{},
    fdefs: std.json.ArrayHashMap(Named) = .{},
    wdefs: std.json.ArrayHashMap(Named) = .{},
    teams: std.json.ArrayHashMap(Team) = .{},
    chat: []const Chat = &.{},
    markers: []const Marker = &.{},
    players: std.json.ArrayHashMap([]const u8) = .{},
    cameras: []const Camera = &.{},
};

pub fn parseMeta(gpa: std.mem.Allocator, file: curves.File) !Meta {
    return std.json.parseFromSliceLeaky(Meta, gpa, file.meta, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

/// BAR's colour codes take floor(c * 255) as a byte: the recording's colours were bytes, so each
/// is put back on its byte, nudged up so the floor cannot land one below
fn byteColor(color: [3]f32) [3]f32 {
    var c: [3]f32 = undefined;
    for (&c, color) |*o, v| o.* = (@round(std.math.clamp(v, 0, 1) * 255) + 0.1) / 255;

    return c;
}

pub fn readCurves(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !curves.File {
    const bytes = try std.Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .limited(16 << 30), .@"16", null);

    return curves.File.view(bytes);
}

// the match's demo and start script --------------------------------------------------------------

const Demo = struct { engine: []const u8, script: []const u8 };

/// A demo (.sdfz) is gzip around a header (its length at 20, the engine version at 24, the start
/// script's length at 304), the start script, then the packet stream.
fn readDemo(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !Demo {
    const compressed = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 30));
    defer gpa.free(compressed);
    var in: std.Io.Reader = .fixed(compressed);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var gz: std.compress.flate.Decompress = .init(&in, .gzip, &window);
    const bytes = try gz.reader.allocRemaining(gpa, .limited(4 << 30));
    if (bytes.len < 312) return error.BadDemo;
    const head: usize = @intCast(std.mem.readInt(i32, bytes[20..24], .little));
    const script_len: usize = @intCast(std.mem.readInt(i32, bytes[304..308], .little));
    if (head + script_len > bytes.len) return error.BadDemo;

    return .{ .engine = std.mem.sliceTo(bytes[24..280], 0), .script = bytes[head..][0..script_len] };
}

/// `[name] { body }` in a start script whose body holds no block of its own
const Block = struct { name: []const u8, body: []const u8 };

fn flatBlocks(gpa: std.mem.Allocator, script: []const u8) ![]Block {
    var out: List(Block) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, script, i, '[')) |open| {
        const close = std.mem.indexOfScalarPos(u8, script, open, ']') orelse break;
        i = close + 1;
        var brace = close + 1;
        while (brace < script.len and std.ascii.isWhitespace(script[brace])) brace += 1;
        if (brace >= script.len or script[brace] != '{') continue;
        const end = std.mem.indexOfAnyPos(u8, script, brace + 1, "{}") orelse break;
        if (script[end] == '{') continue;
        try out.append(gpa, .{ .name = script[open + 1 .. close], .body = script[brace + 1 .. end] });
        i = end + 1;
    }

    return out.items;
}

fn writeBlockLines(w: *std.Io.Writer, body: []const u8, keys: ?[]const []const u8) !void {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (keys) |wanted| {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            var known = false;
            for (wanted) |k| known = known or std.ascii.eqlIgnoreCase(line[0..eq], k);
            if (!known) continue;
        }
        try w.print("\t\t{s}\n", .{line});
    }
}

/// The value of the first `key=value;` line in a start script, or ""
pub fn scriptField(script: []const u8, key: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, script, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimStart(u8, raw, " \t\r");
        if (line.len <= key.len or !std.ascii.startsWithIgnoreCase(line, key) or line[key.len] != '=') continue;
        const value = line[key.len + 1 ..];

        return value[0 .. std.mem.indexOfAny(u8, value, ";\r") orelse value.len];
    }

    return "";
}

fn byFirst(_: void, a: [2]i64, b: [2]i64) bool {
    return a[0] < b[0];
}

/// BAR start script for a local spectator game with the replay's map, teams and options
pub fn startScript(w: *std.Io.Writer, gpa: std.mem.Allocator, meta: Meta, script: []const u8) !void {
    try w.print("[GAME]\n{{\n\tMapName={s};\n\tGameType=BAR Rewind dev;\n\tIsHost=1;\n\tOnlyLocal=1;\n" ++
        "\tMyPlayerName=viewer;\n\tStartPosType=0;\n\tRecordDemo=0;\n\t[PLAYER0]\n\t{{\n\t\tName=viewer;\n\t\tSpectator=1;\n\t}}\n", .{meta.map.name});

    // the match's players, who never connect: BAR's chat and map marks only show players it knows
    const blocks = try flatBlocks(gpa, script);
    var players: List([2]i64) = .empty;
    for (blocks, 0..) |block, i| {
        if (block.name.len <= "player".len or !std.ascii.startsWithIgnoreCase(block.name, "player")) continue;
        const n = std.fmt.parseInt(u32, block.name["player".len..], 10) catch continue;
        try players.append(gpa, .{ n, @intCast(i) });
    }
    std.mem.sort([2]i64, players.items, {}, byFirst);
    const player_keys = [_][]const u8{ "name", "spectator", "team", "countrycode", "rank", "accountid" };
    for (players.items, 1..) |p, n| {
        try w.print("\t[PLAYER{d}]\n\t{{\n", .{n});
        try writeBlockLines(w, blocks[@intCast(p[1])].body, &player_keys);
        try w.writeAll("\t}\n");
    }

    // the replay's own allyteams (numbered densely): weapons can only aim at enemies. Nothing
    // fires: the gadget locks every weapon's reload. NullAI holds each team; the highest is Gaia.
    var teams: List([2]i64) = .empty;
    for (meta.teams.map.keys(), 0..) |id, i| try teams.append(gpa, .{ try std.fmt.parseInt(i64, id, 10), @intCast(i) });
    std.mem.sort([2]i64, teams.items, {}, byFirst);
    if (teams.items.len > 0) teams.items.len -= 1;
    var allies: List(i32) = .empty;
    for (teams.items) |t| {
        const ally = meta.teams.map.values()[@intCast(t[1])].ally;
        if (std.mem.indexOfScalar(i32, allies.items, ally) == null) try allies.append(gpa, ally);
    }
    std.mem.sort(i32, allies.items, {}, std.sort.asc(i32));
    for (teams.items) |t| {
        const team = meta.teams.map.values()[@intCast(t[1])];
        const c = byteColor(team.color);
        const ally = std.mem.indexOfScalar(i32, allies.items, team.ally).?;
        try w.print("\t[TEAM{d}]\n\t{{\n\t\tTeamLeader=0;\n\t\tAllyTeam={d};\n\t\tRGBColor={d:.9} {d:.9} {d:.9};\n\t}}\n", .{ t[0], ally, c[0], c[1], c[2] });
        try w.print("\t[AI{d}]\n\t{{\n\t\tShortName=NullAI;\n\t\tTeam={d};\n\t\tHost=0;\n\t\tName=team{d};\n\t}}\n", .{ t[0], t[0], t[0] });
    }
    for (0..allies.items.len) |i| try w.print("\t[ALLYTEAM{d}]\n\t{{\n\t}}\n", .{i});

    inline for (.{ .{ "modoptions", "MODOPTIONS" }, .{ "mapoptions", "MAPOPTIONS" } }) |pair| {
        try w.print("\t[{s}]\n\t{{\n", .{pair[1]});
        for (blocks) |block| if (std.ascii.eqlIgnoreCase(block.name, pair[0])) {
            try writeBlockLines(w, block.body, null);
            break;
        };
        try w.writeAll("\t}\n");
    }
    try w.writeAll("}\n");
}

fn writeStartScript(io: std.Io, gpa: std.mem.Allocator, curves_path: []const u8, out_path: []const u8) !void {
    const file = try readCurves(io, gpa, curves_path);
    var text: std.Io.Writer.Allocating = .init(gpa);
    try startScript(&text.writer, gpa, try parseMeta(gpa, file), file.demo_script);
    const out = try std.Io.Dir.cwd().createFile(io, out_path, .{});
    defer out.close(io);
    try out.writePositionalAll(io, text.written(), 0);
}

fn printInfo(io: std.Io, gpa: std.mem.Allocator, curves_path: []const u8) !void {
    const file = try readCurves(io, gpa, curves_path);
    const meta = try parseMeta(gpa, file);
    var buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &buffer);
    try out.interface.print("engine={s}\ngame={s}\nmap={s}\n", .{ file.engine, scriptField(file.demo_script, "gametype"), meta.map.name });
    try out.interface.flush();
}
