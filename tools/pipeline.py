#!/usr/bin/env python3
# Usage: pipeline.py replay <demo.sdfz>   parse once (cached), then play
#        pipeline.py parse <demo.sdfz>    parse only
#        pipeline.py play <demo.sdfz> [camera.json shot.png]   (parsed before)
# The whole pipeline, Linux and Windows, Python stdlib only:
#   parse: BAR's headless engine re-simulates the replay with lua/dump_replay.lua -> dump -> bake -> .curves
#   play:  bake export-lua -> the BAR Rewind mutator, copied into BAR's games/ folder -> BAR starts
# Settings (BAR data folder, out folder) live in config_path(); the CLI and the app share them.
# Shot mode (camera.json from BAR, out.png): jumps to the camera's frame, screenshots and quits;
# SHOT_UI=1 keeps the interface, SHOT_SEEK / SHOT_LEAD / SHOT_SPEED / SHOT_BENCH tune it.
import gzip, json, os, re, shutil, struct, subprocess, sys, time, zipfile, zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WINDOWS = os.name == "nt"
EXE = ".exe" if WINDOWS else ""
MUTATOR = ROOT / "recoil" / "barrewind.sdd"
WIDGET = ROOT / "lua" / "dump_replay.lua"
WIDGET_ECO = ROOT / "lua" / "dump_replay_eco.lua"  # every team's resources once a second


# settings ----------------------------------------------------------------------------------------

def config_path():
    base = os.environ.get("APPDATA") if WINDOWS else os.environ.get("XDG_CONFIG_HOME")
    return Path(base or Path.home() / ".config") / "bar-rewind.json"


# where BAR keeps its data (engine/, games/, maps/, demos/) on each kind of install
def bar_candidates():
    home = Path.home()
    if WINDOWS:
        local = Path(os.environ.get("LOCALAPPDATA", home / "AppData/Local"))
        return [local / "Programs/Beyond-All-Reason/data", Path("C:/Program Files/Beyond-All-Reason/data"),
                home / "Documents/Beyond All Reason"]
    return [home / ".var/app/info.beyondallreason.bar/data",  # Flatpak
            home / ".local/state/Beyond All Reason",  # AppImage
            home / "Documents/Beyond All Reason"]


def bar_ok(path):
    return bool(path) and any(Path(path, "engine").glob("recoil_*"))


def load_config():
    try:
        cfg = json.loads(config_path().read_text())
    except (OSError, ValueError):
        cfg = {}
    if not bar_ok(cfg.get("bar_data")):
        found = next((p for p in bar_candidates() if bar_ok(p)), None)
        cfg["bar_data"] = str(found or cfg.get("bar_data") or bar_candidates()[0])
    cfg.setdefault("out_dir", str(ROOT / "out"))
    return cfg


def save_config(cfg):
    config_path().parent.mkdir(parents=True, exist_ok=True)
    config_path().write_text(json.dumps(cfg, indent=2) + "\n")


def engine_dir(bar, version=None):
    if version:
        exact = Path(bar, "engine", "recoil_" + version)
        if exact.is_dir():
            return exact
        raise RuntimeError(f"engine {version} is not installed in {Path(bar, 'engine')}")

    return sorted(Path(bar, "engine").glob("recoil_*"))[-1]


def bake_exe():
    for p in (ROOT / "bin" / ("bake" + EXE), ROOT / "zig-out" / "bin" / ("bake" + EXE)):
        if p.exists():
            return p
    raise SystemExit("no bake binary: run `zig build` first")


def bake_version():
    """The .curves version this bake writes, or None without a bake that says."""
    try:
        r = subprocess.run([str(bake_exe()), "version"], capture_output=True, text=True)
    except SystemExit:
        return None
    m = re.search(r"curves version (\d+)", r.stdout + r.stderr)

    return int(m.group(1)) if m else None


def curves_version(path):
    """The format version in a .curves header ("BRC1", u32 version), or None."""
    try:
        with open(path, "rb") as f:
            head = f.read(8)
    except OSError:
        return None

    return struct.unpack_from("<I", head, 4)[0] if len(head) == 8 and head[:4] == b"BRC1" else None


def open_folder(path):
    Path(path).mkdir(parents=True, exist_ok=True)
    if WINDOWS:
        os.startfile(path)
    else:
        subprocess.Popen(["open" if sys.platform == "darwin" else "xdg-open", str(path)],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


# demo files (.sdfz): gzip, a header, the start script, then the packet stream ---------------------

def demo_load(path):
    b = gzip.open(path).read()
    head = struct.unpack_from("<i", b, 20)[0]
    script, stream = struct.unpack_from("<ii", b, 304)
    return b, head, script, stream


def demo_script(path):
    b, head, script, _ = demo_load(path)
    return b[head:head + script].decode(errors="replace")


# the engine refuses a demo recorded by any other version, so parse must run that exact build
def demo_engine(path):
    b = gzip.open(path).read(280)

    return b[24:280].split(b"\0")[0].decode(errors="replace")


def script_field(text, key):
    m = re.search(rf"(?im)^\s*{key}=([^;]*)", text)
    return m.group(1) if m else "?"


# the last keyframe packet: the header's length stays 0 when a game crashed or was quit, and the
# engine then keeps simulating past the end of the recording
def demo_last_frame(path):
    b, head, script, stream = demo_load(path)
    end = head + script + stream if stream else len(b)
    i, last = head + script, 0
    while i + 8 <= end:
        _time, size = struct.unpack_from("<fI", b, i)
        i += 8
        if size >= 5 and i + size <= end and b[i] == 1:  # NETMSG_KEYFRAME: id byte, int32 frame
            last = struct.unpack_from("<i", b, i + 1)[0]
        i += size
    return last


def demo_info(path):
    """{game, map, players, length, frames, engine} or None for an unreadable file."""
    try:
        text = demo_script(path)
        frames = demo_last_frame(path)
        engine = demo_engine(path)
    except Exception:
        return None
    secs = frames // 30
    players = [script_field(body, "name") for body in re.findall(r"(?i)\[(?:player|ai)\d+\]\s*\{([^{}]*)\}", text)
               if script_field(body, "spectator") != "1"]
    return {"game": script_field(text, "gametype"), "map": script_field(text, "mapname"), "players": players,
            "length": f"{secs // 60}:{secs % 60:02}", "frames": frames, "engine": engine}


def demo_problem(info):
    """Why a parse can never work, or None."""
    if info["frames"] == 0:
        return "the game never started in this recording"

    return None


# installed content ---------------------------------------------------------------------------------

def scanned_names(bar):
    """Lowercased names of every map and game the engine's archive scan found."""
    caches = sorted(Path(bar, "cache").glob("ArchiveCache*.lua"), key=lambda p: p.stat().st_mtime)
    if not caches:
        return set()

    return {n.lower() for n in re.findall(r'\bname = "([^"]*)"', caches[-1].read_text(errors="replace"))}


def rapid_installed(bar, name):
    """True when rapid's index has `name` and its package file is on disk."""
    for versions in Path(bar, "rapid").glob("*/*/versions.gz"):
        for line in gzip.open(versions).read().decode(errors="replace").splitlines():
            parts = line.split(",", 3)
            if len(parts) == 4 and parts[3] == name and Path(bar, "packages", parts[1] + ".sdp").exists():
                return True

    return False


def map_file(bar, name):
    want = re.sub(r"[^a-z0-9.-]+", "_", name.lower())
    maps = Path(bar, "maps")
    if not maps.is_dir():
        return None

    return next((p for p in maps.iterdir() if p.suffix in (".sd7", ".sdz") and p.stem == want), None)


def demo_missing(bar, info, scanned=None):
    """What a parse of this replay needs that is not installed: [(kind, name)], kind engine / game / map.
    The archive scan is only refreshed when the engine runs, so content downloaded since counts too."""
    if scanned is None:
        scanned = scanned_names(bar)
    missing = []
    if not Path(bar, "engine", "recoil_" + info["engine"]).is_dir():
        missing.append(("engine", info["engine"]))
    game = info["game"]
    if game != "?" and "$VERSION" not in game and game.lower() not in scanned and not rapid_installed(bar, game):
        missing.append(("game", game))
    if info["map"] != "?" and info["map"].lower() not in scanned and not map_file(bar, info["map"]):
        missing.append(("map", info["map"]))

    return missing


def prd_exe(bar):
    """BAR's own downloader: shipped with every engine, and beside the launcher."""
    name = "pr-downloader" + EXE
    engines = sorted(Path(bar, "engine").glob("recoil_*"), reverse=True)
    for p in [e / name for e in engines] + [Path(bar).parent / "bin" / name]:
        if p.exists():
            return p

    raise RuntimeError("no pr-downloader found in BAR's engine or bin folders")


# the repositories BAR's launcher points pr-downloader at
PRD_ENV = {
    "PRD_RAPID_REPO_MASTER": "https://repos-cdn.beyondallreason.dev/repos.gz",
    "PRD_HTTP_SEARCH_URL": "https://files-cdn.beyondallreason.dev/find",
    "PRD_RAPID_USE_STREAMER": "false",
}


def download(bar, missing):
    """Generator: yields ("proc", Popen) once, then ("progress", pct, text). Fetches `missing`
    (from demo_missing) into BAR's data folder; raises RuntimeError with pr-downloader's last words."""
    flags = {"engine": "--download-engine", "game": "--download-game", "map": "--download-map"}
    args = [str(prd_exe(bar)), "--filesystem-writepath", str(bar)]
    for kind, name in missing:
        args += [flags[kind], name]
    what = ", ".join(f"{kind} {name}" for kind, name in missing)
    yield "progress", 0, "downloading " + what
    proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env={**os.environ, **PRD_ENV},
                            **new_group())
    yield "proc", proc
    lines = []
    buf = b""
    # progress lines end in \r, not \n
    while chunk := proc.stdout.read1(4096):
        buf += chunk
        *done, buf = re.split(rb"[\r\n]", buf)
        for raw in done:
            line = raw.decode(errors="replace").strip()
            if not line:
                continue
            lines = (lines + [line])[-40:]
            m = re.search(r"\[Progress\]\s+(\d+)%", line)
            if m:
                yield "progress", int(m.group(1)), "downloading " + what
    if proc.wait() != 0:
        errors = [l for l in lines if re.search(r"(?i)\berror\b|failed|not found", l)]
        raise RuntimeError("download failed: " + (errors[-1] if errors else f"pr-downloader exit {proc.returncode}")
                           + "\n" + "\n".join(lines[-15:]))
    yield "progress", 100, "downloaded " + what


def demo_warning(info):
    """What may go wrong with a parse, or None."""
    if "$VERSION" in info["game"]:
        return "a dev-checkout game: it re-simulates against whatever that checkout is now, and desyncs if it changed"

    return None


# parse -------------------------------------------------------------------------------------------

def curves_path(cfg, demo):
    return Path(cfg["out_dir"], "curves", Path(demo).stem + ".curves")


def curves_info(curves):
    """{engine, game, map} of a parsed replay."""
    r = subprocess.run([str(bake_exe()), "info", str(curves)], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"cannot read {curves}: " + r.stderr)

    return dict(line.split("=", 1) for line in r.stdout.splitlines() if "=" in line)


def parse(cfg, demo):
    """Generator: yields ("proc", Popen) once (kill it to cancel), then ("progress", pct, text).
    Leaves <out>/curves/<name>.curves; raises RuntimeError with the log path on failure."""
    bar, demo = Path(cfg["bar_data"]), Path(demo).resolve()
    if script_field(demo_script(demo), "gametype").startswith("BAR Rewind"):
        raise RuntimeError(f"{demo.name} is a recording of this player, not a match")
    curves = curves_path(cfg, demo)
    curves.parent.mkdir(parents=True, exist_ok=True)
    # ponytail: cache keyed by file name only
    if curves.exists() and curves_version(curves) == bake_version():
        yield "progress", 100, "cached"
        return
    total = demo_last_frame(demo)
    if total == 0:
        raise RuntimeError(f"{demo.name}: the game never started in this recording")
    log = curves.parent / "dump.log"
    widget = bar / "LuaUI" / "Widgets" / WIDGET.name
    widget.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(WIDGET, widget)
    widget_eco = widget.with_name(WIDGET_ECO.name)
    shutil.copy(WIDGET_ECO, widget_eco)
    # LuaUI/Config is the one folder BAR lets a user widget both read and write (bar-game #9547)
    dump = bar / "LuaUI" / "Config"
    dump.mkdir(parents=True, exist_ok=True)
    for f in ("bardump.jsonl", "bardump.bin", "bardump_eco.bin", "bardump_view.bin"):
        (dump / f).unlink(missing_ok=True)
    # the widget stops at the replay's last frame (an unfinished replay never reaches GameOver)
    (dump / "bardump.request").write_text(f"dump {total}\n")
    engine = engine_dir(bar, demo_engine(demo))
    headless = engine / ("spring-headless" + EXE)
    exe = headless if headless.exists() else engine / ("spring" + EXE)
    yield "progress", 0, f"starting the headless engine for {total // 1800} min of game"
    try:
        with open(log, "w") as out:
            # ponytail: 2h timeout covers any real match at headless speed; raise it if a dump gets cut off
            proc = subprocess.Popen([str(exe), "--write-dir", str(bar), "--isolation", str(demo)], stdout=out,
                                    stderr=subprocess.STDOUT, **new_group())
            yield "proc", proc
            started, shown = time.time(), -1
            while proc.poll() is None:
                if time.time() - started > 7200:
                    proc.kill()
                time.sleep(1)
                frame = last_dump_frame(log) or last_dump_frame(bar / "infolog.txt")
                # a recording the engine cannot play sits in the pregame lobby forever
                if not frame and time.time() - started > 300:
                    proc.kill()
                    raise RuntimeError(f"the engine never reached the game in 5 minutes, see {log}")
                if not frame:
                    yield "progress", 0, "loading BAR: " + (last_load_message(log) or "starting")
                    continue
                pct = frame * 100 // total if total else -1
                if pct > shown:
                    shown = pct
                    yield "progress", pct, f"re-simulating, {frame // 1800}:{frame // 30 % 60:02} of {total // 1800}:{total // 30 % 60:02} game time"
        if proc.returncode < 0 or not (dump / "bardump.jsonl").exists():
            raise RuntimeError(engine_error(log) or f"parse failed (engine exit {proc.returncode}), see {log}")
        yield "progress", 100, "baking the recording into keyframes"
        tmp = curves.with_suffix(".jsonl")
        shutil.move(dump / "bardump.jsonl", tmp)
        shutil.move(dump / "bardump.bin", tmp.with_suffix(".bin"))
        for name, suffix in (("bardump_view.bin", ".view.bin"), ("bardump_eco.bin", ".eco.bin")):
            if (dump / name).exists():
                shutil.move(dump / name, tmp.with_suffix(suffix))
        r = subprocess.run([str(bake_exe()), str(tmp), str(curves), str(demo)], capture_output=True, text=True)
        with open(log, "a") as out:
            out.write(r.stdout + r.stderr)
        for suffix in (".jsonl", ".bin", ".view.bin", ".eco.bin"):
            tmp.with_suffix(suffix).unlink(missing_ok=True)
        if r.returncode != 0:
            curves.unlink(missing_ok=True)
            # a negative code is the signal that ended it; the kernel's out-of-memory killer sends 9
            how = (f"was killed by signal {-r.returncode}" + (", likely out of memory" if r.returncode == -9 else "")
                   if r.returncode < 0 else f"exited with {r.returncode}")
            with open(log, "a") as out:
                out.write(f"bake {how}\n")
            raise RuntimeError(f"bake {how}, see {log}")
    finally:
        (dump / "bardump.request").unlink(missing_ok=True)
        widget.unlink(missing_ok=True)
        widget_eco.unlink(missing_ok=True)
    yield "progress", 100, "parsed"


def engine_error(log):
    """The engine's own reason for quitting (its Fatal errorMsg), or None."""
    try:
        # the message quotes names itself, so it ends at the next field, not the next quote
        hits = re.findall(r'errorMsg="(.*?)" msgCaption=', Path(log).read_text(errors="replace"))
    except OSError:
        return None

    return hits[-1] if hits else None


def last_load_message(log):
    try:
        with open(log, "rb") as f:
            f.seek(max(0, f.seek(0, 2) - 65536))
            hits = re.findall(rb'SetLoadMessage\] text="([^"]*)"|Loading (?:synced |unsynced )?(?:gadget|widget)[^:]*:\s+(.*?)\s+<', f.read())
    except OSError:
        return None
    if not hits:
        return None
    text = hits[-1][0] or hits[-1][1]

    return text.decode(errors="replace")


def last_dump_frame(log):
    try:
        with open(log, "rb") as f:
            f.seek(max(0, f.seek(0, 2) - 65536))
            hits = re.findall(rb"Replay Dump v2: frame (\d+)", f.read())
    except OSError:
        return None
    return int(hits[-1]) if hits else None


# a process group of its own: cancelling kills the engine, not the app
def new_group():
    return {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP} if WINDOWS else {"start_new_session": True}


# play --------------------------------------------------------------------------------------------

def newest_game(bar):
    """The archive name rapid's byar:test tag points at, e.g. 'Beyond All Reason test-31422-df3633c'."""
    for versions in Path(bar, "rapid").glob("*/byar/versions.gz"):
        for line in gzip.open(versions).read().decode().splitlines():
            tag, _md5, _dep, name = line.split(",", 3)
            if tag == "byar:test":
                return name
    raise RuntimeError("no BAR game installed (no byar:test in rapid versions)")


def lua_value(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return json.dumps(v)
    if isinstance(v, list):
        return "{" + ", ".join(lua_value(x) for x in v) + "}"
    return "{" + ", ".join(f"[{json.dumps(k)}] = {lua_value(x)}" for k, x in v.items()) + "}"


def play(cfg, demo, shot=None):
    """Starts BAR on the demo's parsed curves and returns its Popen; the caller waits. `shot` =
    {"camera": json path, "png": out path} plays shot mode. The engine's output goes to <out>/play.log."""
    bar, out_dir, curves = Path(cfg["bar_data"]), Path(cfg["out_dir"]), curves_path(cfg, demo)
    out_dir.mkdir(parents=True, exist_ok=True)
    info = curves_info(curves)
    # a copy, not a link: Windows needs admin rights for symlinks
    game = bar / "games" / MUTATOR.name
    if game.is_symlink() or game.is_file():
        game.unlink()
    elif game.exists():
        shutil.rmtree(game)
    shutil.copytree(MUTATOR, game, ignore=shutil.ignore_patterns("replay"))
    r = subprocess.run([str(bake_exe()), "export-lua", str(curves), str(game / "replay")], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("export failed: " + r.stdout + r.stderr)
    version = info["game"] if info["game"] and not info["game"].startswith("BAR Rewind") else newest_game(bar)
    modinfo = game / "modinfo.lua"
    modinfo.write_text(re.sub(r"depend = \{.*\}", f'depend = {{ "{version}" }}', modinfo.read_text()))
    play_script = out_dir / "play_script.txt"
    r = subprocess.run([str(bake_exe()), "start-script", str(curves), str(play_script)], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("start script failed: " + r.stdout + r.stderr)
    if shot:
        cam = json.loads(Path(shot["camera"]).read_text())
        extra = "".join(f", {k} = {lua_value(conv(os.environ[env]))}" for k, env, conv in (
            ("ui", "SHOT_UI", bool), ("seek", "SHOT_SEEK", int), ("lead", "SHOT_LEAD", int),
            ("bench", "SHOT_BENCH", bool), ("speed", "SHOT_SPEED", float)) if os.environ.get(env))
        (game / "replay" / "shot.lua").write_text(f"return {{ frame = {cam['frame']}, state = {lua_value(cam['state'])}{extra} }}\n")
    log = open(out_dir / "play.log", "w")
    # the replay's own engine, as the parse uses: newer engines draw nano spray natively, only for units that
    # really build, so BAR's Lua nano gadget (which the player feeds) stands down and no spray shows
    return subprocess.Popen([str(engine_dir(bar, info["engine"]) / ("spring" + EXE)), "--write-dir", str(bar), "--isolation",
                             "--window", str(play_script)], stdout=log, stderr=subprocess.STDOUT, **new_group())


def latest_screenshot(bar):
    shots = sorted(Path(bar, "screenshots").glob("*.png"), key=lambda p: p.stat().st_mtime)
    return shots[-1] if shots else None


# map previews ------------------------------------------------------------------------------------

def find_7z(bar):
    for name in ("7z", "7za", "7zz"):
        if shutil.which(name):
            return shutil.which(name)
    for p in (Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "7-Zip/7z.exe",):
        if p.exists():
            return str(p)
    # the BAR launcher bundles 7za next to its data folder
    bundled = Path(bar).parent / "resources" / "app.asar.unpacked" / "node_modules" / "7zip-bin"
    os_dir = "win" if WINDOWS else "mac" if sys.platform == "darwin" else "linux"
    for p in sorted(bundled.glob(f"{os_dir}/*/7za*"), key=lambda p: "x64" not in p.parts):
        if p.is_file():
            return str(p)
    return None


def minimap(bar, name, out):
    """Writes the map's minimap as a 256² PNG; False when the map or a 7z tool (for .sd7) is missing."""
    want = re.sub(r"[^a-z0-9.-]+", "_", name.lower())
    maps = Path(bar, "maps")
    arch = next((p for p in maps.iterdir() if p.suffix in (".sd7", ".sdz") and p.stem == want), None) if maps.is_dir() else None
    if not arch:
        return False
    smf = b""
    if arch.suffix == ".sdz":
        with zipfile.ZipFile(arch) as z:
            smf = next((z.read(n) for n in z.namelist() if n.lower().endswith(".smf")), b"")
    elif find_7z(bar):
        smf = subprocess.run([find_7z(bar), "e", "-so", str(arch), "-r", "*.smf"], capture_output=True).stdout
    if smf[:15] != b"spring map file":
        return False
    SIZE = 256
    # mip 2 of the 1024² DXT1 minimap: skip mip 0 (1024²/2 bytes) and mip 1 (512²/2)
    at = struct.unpack_from("<i", smf, 64)[0] + 1024 * 1024 // 2 + 512 * 512 // 2

    def rgb565(c):
        return ((c >> 11) & 31) * 255 // 31, ((c >> 5) & 63) * 255 // 63, (c & 31) * 255 // 31

    px = bytearray(SIZE * SIZE * 3)
    for by in range(SIZE // 4):
        for bx in range(SIZE // 4):
            c0, c1, bits = struct.unpack_from("<HHI", smf, at)
            at += 8
            a, b = rgb565(c0), rgb565(c1)
            if c0 > c1:
                pal = [a, b, tuple((2 * x + y) // 3 for x, y in zip(a, b)), tuple((x + 2 * y) // 3 for x, y in zip(a, b))]
            else:
                pal = [a, b, tuple((x + y) // 2 for x, y in zip(a, b)), (0, 0, 0)]
            for i in range(16):
                o = ((by * 4 + i // 4) * SIZE + bx * 4 + i % 4) * 3
                px[o:o + 3] = bytes(pal[(bits >> (2 * i)) & 3])

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    rows = b"".join(b"\0" + px[y * SIZE * 3:(y + 1) * SIZE * 3] for y in range(SIZE))
    Path(out).write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0))
                          + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
    return True


# CLI ---------------------------------------------------------------------------------------------

def main(argv):
    if len(argv) < 2 or argv[0] not in ("replay", "parse", "play"):
        raise SystemExit(__doc__ or open(__file__).read().split("\nimport")[0])
    cfg = load_config()
    if not bar_ok(cfg["bar_data"]):
        raise SystemExit(f"no BAR engine in {cfg['bar_data']}: set the BAR data folder in the app or in {config_path()}")
    if argv[0] in ("replay", "parse"):
        last = None
        for event in parse(cfg, argv[1]):
            if event[0] == "progress" and event[2] != last:
                last = event[2]
                print(last, flush=True)
        if argv[0] == "parse":
            return
    shot = {"camera": argv[2], "png": argv[3]} if len(argv) >= 4 else None
    proc = play(cfg, argv[1], shot)
    try:
        proc.wait(timeout=600 if shot else None)
    except subprocess.TimeoutExpired:
        proc.kill()
    if shot:
        png = latest_screenshot(cfg["bar_data"])
        if png:
            shutil.copy(png, argv[3])
    print(f"BAR exited ({proc.returncode}), log: {Path(cfg['out_dir'], 'play.log')}")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except RuntimeError as e:
        raise SystemExit(str(e))
