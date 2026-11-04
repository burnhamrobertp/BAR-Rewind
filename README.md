# BAR-Rewind - replay rewind tool for Beyond All Reason
### (Prototype)
Rewind, pause and scrub [Beyond All Reason](https://www.beyondallreason.info/) replays, rendered by BAR itself.

A fork of [LuEklund/BAR-Rewind](https://github.com/LuEklund/BAR-Rewind) that has since gone its own way: replays
are queued on [bar-rewind-server](https://github.com/burnhamrobertp/bar-rewind-server) and parsed by `bake parse` on
moderators' machines running [bar-rewind-worker](https://github.com/burnhamrobertp/bar-rewind-worker), the browser
app and the Python pipeline are gone, and releases here carry a signed manifest that the workers check.

**[Download the player](https://github.com/burnhamrobertp/BAR-Rewind/releases/latest)** (Linux and Windows)

### Jump anywhere

Click or drag the timeline and the match is there, at that moment.

![Jumping around the timeline](docs/rewind.gif)

### Play backwards

Press R and the fight runs in reverse: shots fly back into the guns and dead units come back.

![A fight playing backwards](docs/play-backwards.gif)

### Any speed, either way

Up/Down change the speed. At 64x a whole match unwinds in seconds.

![A match playing backwards at 64x](docs/play-backwards-64x.gif)

## How to use

Replays are parsed by a BAR Rewind server's workers and watched with the player. Needs BAR installed.

1. Download `bar-rewind.exe` (Windows) or `bar-rewind-player-linux` (Linux) from the
   [latest release](https://github.com/burnhamrobertp/BAR-Rewind/releases/latest).
2. Run it once: `.curves` files and Watch links on a BAR Rewind server now open with it (on Linux through
   a desktop entry in `~/.local/share/applications`, which needs `xdg-utils`). `--uninstall` undoes that.
3. Click Watch on a parsed replay, or open a `.curves` file.

The first Watch link from a server asks whether to trust that server; the answer is kept in
`bar-rewind.json` (`trusted_hosts`). The player puts the BAR Rewind game in BAR's data folder and fetches
the replay's engine, game and map when they're missing. If BAR's data folder isn't where its installer puts
it, set `bar_data` in `bar-rewind.json` to it: the folder with `engine/`, `maps/` and `demos/` inside.

In the player a timeline runs along the bottom of the screen: play/pause and rewind/fast-forward buttons,
a scrub bar to drag with time marks under it, and the replay time and speed; the game info panel under the
player list shows the replay time and speed too. Space play/pause, R reverse; with the mouse over the
timeline, Left/Right skip 10 s and Up/Down change speed.

### Parsing a replay yourself

```sh
bake parse <replay.sdfz> <out.curves> --bar <folder>
```

`bake.exe` (Windows) or `bake-linux` (Linux) comes with each release. `--bar` is a BAR data folder kept
for parsing: bake rewrites its widget config to switch BAR's interface off, so never point it at the BAR
install you play with. Its `engine/` folder needs a `recoil_*` engine (for BAR's pr-downloader); bake
fetches the replay's own engine, game and map. Progress comes out as one JSON object per line, the
engine's output goes to `<out.curves>.log`, and `--widgets <folder>` runs the widgets in that folder
during the parse too.

## Build from source

Needs [Zig](https://ziglang.org/) 0.17.

```sh
zig build                                # bake and the player, in zig-out/bin
zig build run -- <replay.curves>         # play a replay
zig build bake -- parse <replay.sdfz> <out.curves> --bar <folder>
zig build test
zig build dist                           # both for Windows and Linux, in zig-out/dist
```

Pushing a version tag (like `0.5.0`) builds a release: GitHub Actions tests, builds `dist`, signs a `manifest.json` of the
files with the release key (`release-key.pub` is its public half) and drafts the release.

- `lua/dump_replay.lua`: the BAR widget that records a replay while the headless engine re-simulates it
- `src/parse.zig`: `bake parse`, which runs the engine on a replay with the dump widgets, then bakes
- `src/bake.zig`, `src/curves.zig`: recording → `.curves` (keyframes thinned with Douglas–Peucker), and
  `bake export-lua`, which writes them in the form the player reads
- `src/player.zig`: the player, which plays a `.curves` with the mutator built in
- `recoil/barrewind.sdd`: the BAR Rewind game (a mutator on top of BAR) that plays `.curves`: the
  `replay_player`, `replay_eco` and `replay_view` gadgets, the chat, map-mark and timeline widgets, and
  the game info panel that stands in for BAR's

## How it works

BAR replays only play forward: a `.sdfz` file is a list of player commands that the engine re-simulates.
bar-rewind runs a replay through the engine once ("parse"), records where everything is, and plays that
recording back inside BAR, where you can drag a timeline, play backwards and change speed.

### What's recorded

The parse keeps only the keyframes playback needs: a key is dropped when interpolating without it stays
within 0.5 [elmo](#whats-recorded "Recoil distance unit: one map grid square is 8 elmos"). What it records:

- **Every unit:** position, facing, health, build progress, on/off, what its weapon aims at, what it builds
- **Aim pieces:** each weapon's barrel and everything it hangs from (torso, turret, arms), so a turret
  points the right way the moment you jump to any time
- **Projectiles**, **features** (wrecks, trees) and **terrain changes**
- **Command queues:** every unit's queued orders. Playback gives each unit its orders, so the engine
  draws them for the selected units and BAR shows queued buildings as it does live; the units never
  carry them out
- **Chat and map marks:** every message, point, drawn line and erase, fed into BAR's own chat and map
  marks as the replay reaches them (the match's players are listed in the playback game so BAR knows them)
- **Economy**: every team's metal and energy level, storage, income, expense and pull, once a second. The player feeds them back through the engine's own resource counters, so BAR's top bar, player list and eco stats show the match's economy at the replay time (replays parsed before this show what the replayed units produce instead).

BAR animates the rest itself, from the recorded movement: walk cycles, idle motion, deaths and explosions.

### How keys are picked

![Keyframe thinning](docs/keyframe_thinning.gif)

1. **Parse:** the engine plays the replay and records every unit every 0.1 s.
2. **Bake:** per unit, start with only the first and last sample as keys.
3. Slide a "playback" unit straight between the two keys at constant speed, and measure how far it is
   from the real unit at each sample's time.
4. Worst gap over 0.5 [elmo](#whats-recorded "Recoil distance unit: one map grid square is 8 elmos"): keep that sample as a key, then repeat on both halves.
   Otherwise drop every sample in between.

Being on the right path isn't enough: a unit that idles and then drives off is late compared to the
straight line, so the moment it starts moving becomes a key.

### Numbers

One 53-minute match (2240 units, 14k projectiles) on a Ryzen 7 5800X:

| | |
|-|-|
| BAR replay (`.sdfz`) | 1.7 MB |
| Parse (once per replay) | 6 min |
| Parsed replay (`.curves`) | 108 MB |


A 16-minute match parses in under a minute, to 12 MB.

## Files it creates

- **Settings**: `bar-rewind.json` in `~/.config/` (Linux) or `%APPDATA%` (Windows): the servers you trust
  and, if set, BAR's data folder.
- **Cache**: `~/.cache/bar-rewind` (Linux) or `%LOCALAPPDATA%\bar-rewind` (Windows): downloaded replays
  (`replays/`), the last start script and `play.log`.
- **In BAR's data folder**: `games/barrewind.sdd`, the player BAR loads.

## AI disclosure

The code was written by AI. I guided it: Provided sources, how to connect ideas, coming up with ideas on how to solve problems, talked it through what to build and how. 
(To save time and provide a tool quickly).

## License

GPL-2.0 (see `LICENSE`), like BAR's own code. Nothing from BAR is included: models, maps and the game
itself are loaded from your BAR install.
