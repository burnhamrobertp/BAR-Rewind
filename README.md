# BAR-Rewind

Rewind, pause and scrub [Beyond All Reason](https://www.beyondallreason.info/) replays, rendered by BAR itself.
Drag the timeline to any moment, play the match backwards (shots fly back into the guns, dead units come
back), or run it at up to 64x either way.

A fork of [LuEklund/BAR-Rewind](https://github.com/LuEklund/BAR-Rewind) that has since gone its own way:
replays are queued on [bar-rewind-server](https://github.com/burnhamrobertp/bar-rewind-server) and parsed on
volunteers' machines running [bar-rewind-worker](https://github.com/burnhamrobertp/bar-rewind-worker); this
repo has the player and the parser (`bake`) they run.

## Watching a replay

Needs BAR installed.

1. Download `bar-rewind.exe` (Windows) or `bar-rewind-player-linux` (Linux) from the
   [latest release](https://github.com/burnhamrobertp/BAR-Rewind/releases/latest) and put it somewhere it
   can stay.
2. Run it once. `.curves` files and Watch links from a BAR Rewind server now open with it (on Linux through a
   desktop entry in `~/.local/share/applications`, which needs `xdg-utils`). Moved it? Run it again.
   `--uninstall` undoes this.
3. On the server's site, paste a replay link to queue it, then click Watch once it's parsed. Or open a
   `.curves` file.

The first Watch link from a server asks whether to trust that server. The player puts the BAR Rewind game in
BAR's data folder and fetches the replay's engine, game and map when they're missing.

### Controls

A timeline runs along the bottom of the screen: play/pause, rewind and fast-forward buttons, a scrub bar with
time marks, and the replay time and speed.

| | |
|-|-|
| Space | play / pause |
| R | reverse |
| Left / Right (mouse over the timeline) | skip 10 s |
| Up / Down (mouse over the timeline) | double / halve the speed, 0.25x to 64x |

### BAR somewhere else?

If BAR's data folder isn't where its installer puts it, set `bar_data` in `bar-rewind.json` to it: the
folder with `engine/`, `maps/` and `demos/` inside.

## Parsing a replay yourself

Workers do this for the server; you don't need to. But if you want a `.curves` without one:

```sh
bake parse <replay.sdfz> <out.curves> --bar <folder>
```

`bake.exe` (Windows) or `bake-linux` (Linux) comes with each release. `--bar` is a BAR data folder kept just
for parsing: bake rewrites its widget config to switch BAR's interface off, so never point it at the BAR
install you play with. Its `engine/` folder needs one `recoil_*` engine (for BAR's pr-downloader); bake
fetches the replay's own engine, game and map. Progress comes out as one JSON object per line and the
engine's output goes to `<out.curves>.log`.

## How it works

BAR replays only play forward: a `.sdfz` is a list of player commands that the engine re-simulates. A parse
runs the replay through a headless engine once, records where everything is, and bakes that into a `.curves`
file. The player then plays the `.curves` inside BAR, where time can go anywhere.

### What's recorded

- **Units:** position, facing, health, build progress, on/off, what the weapon aims at, what a builder works
  on, and team changes (gifts, captures)
- **Aim pieces:** each weapon's barrel and everything it hangs from, so a turret points the right way the
  moment you jump anywhere
- **Projectiles**, **features** (wrecks, trees) and **terrain changes**
- **Command queues:** shown for selected units and as queued buildings, as BAR does live; the units never
  carry them out
- **Chat and map marks:** fed into BAR's own chat and map marks as the replay reaches them
- **Economy:** every team's metal and energy, storage, income, expense and pull, fed through the engine's own
  counters so BAR's top bar and player list show the match's economy
- **What players looked at:** their map cursors and cameras, shown by BAR's own cursor and lock-camera widgets

BAR animates the rest from the recorded movement: walk cycles, idle motion, deaths and explosions.

### How keys are picked

Units are sampled 10 times a second, then thinned to the keyframes playback needs:

![Keyframe thinning](docs/keyframe_thinning.gif)

1. Per unit, start with only the first and last sample as keys.
2. Slide a "playback" unit straight between the two keys at constant speed and measure how far it is from
   the real unit at each sample.
3. Worst gap over 0.5 elmo (a map grid square is 8)? Keep that sample as a key and repeat on both halves.
   Otherwise drop everything in between.

Being on the right path isn't enough: a unit that idles and then drives off is late compared to the straight
line, so the moment it starts moving becomes a key.

## Files it creates

- **Settings:** `bar-rewind.json` in `~/.config/` (Linux) or `%APPDATA%` (Windows): the servers you trust and,
  if set, BAR's data folder.
- **Cache:** `~/.cache/bar-rewind` (Linux) or `%LOCALAPPDATA%\bar-rewind` (Windows): downloaded replays
  (`replays/`), the last start script and `play.log`.
- **In BAR's data folder:** `games/barrewind.sdd`, the game BAR loads to play a `.curves`.

## Build from source

Needs [Zig](https://ziglang.org/) 0.17.

```sh
zig build                                # bake and the player, in zig-out/bin
zig build run -- <replay.curves>         # play a replay
zig build bake -- parse <replay.sdfz> <out.curves> --bar <folder>
zig build test
zig build dist                           # both for Windows and Linux, in zig-out/dist
```

Pushing a version tag (like `0.5.0`) builds a release: GitHub Actions tests, builds `dist`, signs a
`manifest.json` of the files with the release key (`release-key.pub` is its public half) and publishes it.
Workers only run a parser whose manifest carries that signature.

- `lua/dump_replay.lua`: the widget that records a replay while the headless engine re-simulates it
- `src/parse.zig`: `bake parse`, which runs the engine with the dump widgets, then bakes
- `src/bake.zig`, `src/curves.zig`: recording to `.curves`, and `bake export-lua`, which writes them in the
  form the player reads
- `src/player.zig`: the player, with the BAR Rewind game built in
- `recoil/barrewind.sdd`: the BAR Rewind game (a mutator on top of BAR) that plays a `.curves`

AI disclosure: written with assistance from Claude Code.

## License

GPL-2.0 (see `LICENSE`), like BAR's own code. Nothing from BAR is included: models, maps and the game itself
are loaded from your BAR install.
