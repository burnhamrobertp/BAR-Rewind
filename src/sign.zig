//! Release manifests: what a release holds, signed so a worker only runs files the release key vouched for.
//!   sign keygen <secret file>               a new key: its seed (hex) into a new file, the public key to stdout
//!   sign manifest <dir> <version>           manifest.json for every file in <dir>, and manifest.json.sig,
//!                                           signed with the seed (hex) in RELEASE_SIGNING_KEY
//!   sign verify <dir> <public key hex>      checks manifest.json.sig, then every file against manifest.json

const std = @import("std");
const curves = @import("curves.zig");

const Io = std.Io;
const Ed25519 = std.crypto.sign.Ed25519;

pub const Manifest = struct {
    version: []const u8,
    curves_version: u32,
    files: []const File,

    pub const File = struct { name: []const u8, size: u64, sha256: []const u8 };
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len == 3 and std.mem.eql(u8, args[1], "keygen")) return keygen(io, args[2]);
    if (args.len == 4 and std.mem.eql(u8, args[1], "manifest")) {
        const hex = init.environ_map.get("RELEASE_SIGNING_KEY") orelse return fatal("RELEASE_SIGNING_KEY is not set");
        const seed = parseHex(Ed25519.KeyPair.seed_length, hex) catch return fatal("RELEASE_SIGNING_KEY is not 64 hex digits");

        return writeManifest(io, gpa, args[2], args[3], try Ed25519.KeyPair.generateDeterministic(seed));
    }
    if (args.len == 4 and std.mem.eql(u8, args[1], "verify")) {
        const public = parseHex(Ed25519.PublicKey.encoded_length, args[3]) catch return fatal("the public key is not 64 hex digits");
        verify(io, gpa, args[2], try Ed25519.PublicKey.fromBytes(public)) catch |err| return fatal(@errorName(err));
        std.debug.print("{s}: signature and every file check out\n", .{args[2]});

        return;
    }
    fatal("usage: sign keygen <secret file> | sign manifest <dir> <version> | sign verify <dir> <public key hex>");
}

fn fatal(message: []const u8) noreturn {
    std.debug.print("sign: {s}\n", .{message});
    std.process.exit(1);
}

fn keygen(io: Io, secret_path: []const u8) !void {
    var seed: [Ed25519.KeyPair.seed_length]u8 = undefined;
    try io.randomSecure(&seed);
    const pair = try Ed25519.KeyPair.generateDeterministic(seed);
    Io.Dir.cwd().writeFile(io, .{ .sub_path = secret_path, .data = &std.fmt.bytesToHex(seed, .lower), .flags = .{ .exclusive = true } }) catch |err| switch (err) {
        error.PathAlreadyExists => fatal("the secret file already exists: a new key would replace the one releases are signed with"),
        else => return err,
    };
    var buffer: [128]u8 = undefined;
    var out = Io.File.stdout().writerStreaming(io, &buffer);
    try out.interface.print("{s}\n", .{&std.fmt.bytesToHex(pair.public_key.toBytes(), .lower)});
    try out.interface.flush();
}

/// Exactly `n` bytes of hex: hexToBytes alone takes shorter input and leaves the rest undefined
fn parseHex(comptime n: usize, text: []const u8) error{BadHex}![n]u8 {
    var out: [n]u8 = undefined;
    const got = std.fmt.hexToBytes(&out, std.mem.trim(u8, text, " \r\n")) catch return error.BadHex;
    if (got.len != n) return error.BadHex;

    return out;
}

fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});

    return std.fmt.bytesToHex(digest, .lower);
}

fn isManifest(name: []const u8) bool {
    return std.mem.eql(u8, name, "manifest.json") or std.mem.eql(u8, name, "manifest.json.sig");
}

fn writeManifest(io: Io, gpa: std.mem.Allocator, dir_path: []const u8, version: []const u8, pair: Ed25519.KeyPair) !void {
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var files: std.ArrayList(Manifest.File) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or isManifest(entry.name)) continue;
        const bytes = try dir.readFileAlloc(io, entry.name, gpa, .limited(1 << 30));
        try files.append(gpa, .{ .name = try gpa.dupe(u8, entry.name), .size = bytes.len, .sha256 = try gpa.dupe(u8, &sha256Hex(bytes)) });
    }
    std.mem.sort(Manifest.File, files.items, {}, struct {
        fn less(_: void, a: Manifest.File, b: Manifest.File) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.less);

    const json = try std.json.Stringify.valueAlloc(gpa, Manifest{ .version = version, .curves_version = curves.version, .files = files.items }, .{ .whitespace = .indent_2 });
    const signature = try pair.sign(json, null);
    try dir.writeFile(io, .{ .sub_path = "manifest.json", .data = json });
    try dir.writeFile(io, .{ .sub_path = "manifest.json.sig", .data = &std.fmt.bytesToHex(signature.toBytes(), .lower) });
}

/// The signature over manifest.json's exact bytes, then each listed file's size and hash
pub fn verify(io: Io, gpa: std.mem.Allocator, dir_path: []const u8, public: Ed25519.PublicKey) !void {
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    const json = try dir.readFileAlloc(io, "manifest.json", gpa, .limited(1 << 20));
    const sig_hex = try dir.readFileAlloc(io, "manifest.json.sig", gpa, .limited(1 << 10));
    const sig = parseHex(Ed25519.Signature.encoded_length, sig_hex) catch return error.BadSignature;
    Ed25519.Signature.fromBytes(sig).verify(json, public) catch return error.BadSignature;

    const manifest = try std.json.parseFromSliceLeaky(Manifest, gpa, json, .{ .ignore_unknown_fields = true });
    for (manifest.files) |f| {
        const bytes = dir.readFileAlloc(io, f.name, gpa, .limited(1 << 30)) catch return error.MissingFile;
        if (bytes.len != f.size or !std.mem.eql(u8, &sha256Hex(bytes), f.sha256)) return error.FileDoesNotMatch;
    }
}

test "a signed manifest checks out, and stops checking out when a file or the manifest changes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.writeFile(io, .{ .sub_path = "bake-linux", .data = "bake" });
    try tmp.dir.writeFile(io, .{ .sub_path = "bar-rewind.exe", .data = "player" });
    const pair = try Ed25519.KeyPair.generateDeterministic(@splat(7));
    const other = try Ed25519.KeyPair.generateDeterministic(@splat(8));

    try writeManifest(io, gpa, path, "v1.2.3", pair);
    try verify(io, gpa, path, pair.public_key);
    try std.testing.expectError(error.BadSignature, verify(io, gpa, path, other.public_key));

    try tmp.dir.writeFile(io, .{ .sub_path = "bake-linux", .data = "bakf" });
    try std.testing.expectError(error.FileDoesNotMatch, verify(io, gpa, path, pair.public_key));

    try writeManifest(io, gpa, path, "v1.2.3", pair);
    const json = try tmp.dir.readFileAlloc(io, "manifest.json", gpa, .limited(1 << 20));
    const forged = try std.mem.replaceOwned(u8, gpa, json, "v1.2.3", "v9.9.9");
    try tmp.dir.writeFile(io, .{ .sub_path = "manifest.json", .data = forged });
    try std.testing.expectError(error.BadSignature, verify(io, gpa, path, pair.public_key));
}

test "hex keys and signatures must be complete" {
    try std.testing.expectEqual([2]u8{ 0xab, 0x01 }, try parseHex(2, " ab01\n"));
    try std.testing.expectError(error.BadHex, parseHex(32, ""));
    try std.testing.expectError(error.BadHex, parseHex(32, "abababababababababababababababababababababababababababababab01"));
    try std.testing.expectError(error.BadHex, parseHex(2, "ab0123"));
}
