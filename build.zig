const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .abi = .gnu } });
    const optimize = b.standardOptimizeOption(.{});
    const mutator_tar = packMutator(b);
    const options = b.addOptions();
    options.addOption([]const u8, "version", b.option([]const u8, "version", "the release this build is (default 0.0.0-dev)") orelse "0.0.0-dev");

    // bake: demo -> recording -> curves, and what the player reads from them --------------------
    const bake = addBake(b, target, options);
    b.installArtifact(bake);
    const run_bake = b.addRunArtifact(bake);
    run_bake.addPassthruArgs();
    b.step("bake", "Run bake: zig build bake -- parse <demo.sdfz> <out.curves> --bar <BAR data folder>").dependOn(&run_bake.step);

    // bar-rewind: the player, with the mutator inside ----------------------------------------------
    const player = addPlayer(b, target, mutator_tar, options);
    b.installArtifact(player);
    const run_player = b.addRunArtifact(player);
    run_player.addPassthruArgs();
    b.step("run", "Play a replay: zig build run -- <replay.curves>").dependOn(&run_player.step);

    // dist: both for Windows and Linux, baseline x86_64 so they run on any CPU ---------------------
    const dist = b.step("dist", "Build zig-out/dist/: bake and the player for Windows and Linux");
    const platforms = [_]struct { query: []const u8, bake: []const u8, player: []const u8 }{
        .{ .query = "x86_64-windows-gnu", .bake = "bake.exe", .player = "bar-rewind.exe" },
        .{ .query = "x86_64-linux-musl", .bake = "bake-linux", .player = "bar-rewind-player-linux" },
    };
    for (platforms) |p| {
        const resolved = b.resolveTargetQuery(std.Target.Query.parse(.{ .arch_os_abi = p.query, .cpu_features = "baseline" }) catch unreachable);
        for ([_]struct { *std.Build.Step.Compile, []const u8 }{ .{ addBake(b, resolved, options), p.bake }, .{ addPlayer(b, resolved, mutator_tar, options), p.player } }) |exe| {
            dist.dependOn(&b.addInstallArtifact(exe[0], .{
                .dest_dir = .{ .override = .{ .custom = "dist" } },
                .dest_sub_path = exe[1],
                .pdb_dir = .disabled,
            }).step);
        }
    }

    // sign: a release's signed manifest ----------------------------------------------------------
    const sign = b.addExecutable(.{
        .name = "sign",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/sign.zig"), .target = b.graph.host, .optimize = .ReleaseSafe }),
    });
    const run_sign = b.addRunArtifact(sign);
    run_sign.addPassthruArgs();
    b.step("sign", "Release manifests: zig build sign -- keygen | manifest | verify").dependOn(&run_sign.step);

    // tests -----------------------------------------------------------------------------------
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    embedLua(b, tests.root_module);
    tests.root_module.addOptions("options", options);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

fn addBake(b: *std.Build, target: std.Build.ResolvedTarget, options: *std.Build.Step.Options) *std.Build.Step.Compile {
    const bake = b.addExecutable(.{
        .name = "bake",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bake.zig"),
            .target = target,
            // ponytail: always fast, a Debug bake of a long match takes minutes
            .optimize = .ReleaseFast,
            .strip = true,
        }),
    });
    embedLua(b, bake.root_module);
    bake.root_module.addOptions("options", options);

    return bake;
}

fn addPlayer(b: *std.Build, target: std.Build.ResolvedTarget, mutator_tar: std.Build.LazyPath, options: *std.Build.Step.Options) *std.Build.Step.Compile {
    const player = b.addExecutable(.{
        .name = "bar-rewind",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/player.zig"),
            .target = target,
            // safety checks stay on: the replays it reads were made on other people's machines
            .optimize = .ReleaseSafe,
            .strip = true,
        }),
    });
    player.root_module.addAnonymousImport("mutator.tar", .{ .root_source_file = mutator_tar });
    player.root_module.addOptions("options", options);

    return player;
}

fn packMutator(b: *std.Build) std.Build.LazyPath {
    const pack = b.addExecutable(.{
        .name = "pack",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/pack.zig"), .target = b.graph.host }),
    });
    const run_pack = b.addRunArtifact(pack);
    run_pack.addDirectoryArg(b.path("recoil/barrewind.sdd"));
    // the build cache keys a directory argument on its path, not its files: without this the player
    // keeps the first mutator it was built with
    run_pack.has_side_effects = true;

    return run_pack.addOutputFileArg("mutator.tar");
}

/// what bake parse writes into BAR's data folder
fn embedLua(b: *std.Build, module: *std.Build.Module) void {
    for ([_][]const u8{ "dump_replay.lua", "dump_replay_eco.lua", "bar-widgets.txt" }) |name| {
        module.addAnonymousImport(name, .{ .root_source_file = b.path(b.fmt("lua/{s}", .{name})) });
    }
}
