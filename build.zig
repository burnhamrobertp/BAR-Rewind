const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .abi = .gnu } });
    const optimize = b.standardOptimizeOption(.{});

    // bake: dump -> curves ------------------------------------------------------------------
    const bake = b.addExecutable(.{
        .name = "bake",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bake.zig"),
            .target = target,
            // ponytail: always fast, a Debug bake of a long match takes minutes
            .optimize = .ReleaseFast,
        }),
    });
    b.installArtifact(bake);
    const run_bake = b.addRunArtifact(bake);
    if (b.option([]const u8, "in", "bake: the dump to read (<name>.jsonl, with <name>.bin beside it)")) |in| run_bake.addArg(in);
    if (b.option([]const u8, "out", "bake: the .curves to write")) |out| run_bake.addArg(out);
    b.step("bake", "Bake a dump: zig build bake -Din=<dump.jsonl> -Dout=<out.curves>").dependOn(&run_bake.step);

    // bar-rewind: the player, with the mutator inside ----------------------------------------------
    const pack = b.addExecutable(.{
        .name = "pack",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/pack.zig"), .target = b.graph.host }),
    });
    const run_pack = b.addRunArtifact(pack);
    run_pack.addDirectoryArg(b.path("recoil/barrewind.sdd"));
    const mutator_tar = run_pack.addOutputFileArg("mutator.tar");
    const player_options = b.addOptions();
    player_options.addOption([]const u8, "server_host", b.option([]const u8, "server-host", "bar-rewind: the only host it downloads replays from") orelse "");
    const player = b.addExecutable(.{
        .name = "bar-rewind",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/player.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .strip = true,
        }),
    });
    player.root_module.addAnonymousImport("mutator.tar", .{ .root_source_file = mutator_tar });
    player.root_module.addOptions("options", player_options);
    b.installArtifact(player);

    // run: the app, or one replay straight to playback ------------------------------------------
    const python = if (b.graph.host.result.os.tag == .windows) "python" else "python3";
    const demo = b.option([]const u8, "demo", "run: play this replay instead of opening the app");
    const run_app = b.addSystemCommand(&.{python});
    if (demo) |path| {
        run_app.addFileArg(b.path("tools/pipeline.py"));
        run_app.addArgs(&.{ "replay", path });
    } else {
        run_app.addFileArg(b.path("tools/ui.py"));
    }
    run_app.step.dependOn(&b.addInstallArtifact(bake, .{}).step);
    b.step("run", "Open the app, or play one replay: zig build run -Ddemo=<demo.sdfz> (parsed once, cached)").dependOn(&run_app.step);

    const run_dist = b.addSystemCommand(&.{python});
    run_dist.addFileArg(b.path("tools/dist.py"));
    b.step("dist", "Pack dist/bar-rewind-linux.tar.gz and dist/bar-rewind-windows.zip").dependOn(&run_dist.step);

    // tests -----------------------------------------------------------------------------------
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

}
