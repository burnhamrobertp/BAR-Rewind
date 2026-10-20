#!/usr/bin/env python3
# Usage: tools/ui.py   (or: zig build run)
# The app: a local page in the browser listing replays with their minimaps; parse or play one, with a
# progress bar. Python stdlib only, Linux and Windows. The work is in pipeline.py.
import json, threading, time, webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote

import pipeline

cfg = pipeline.load_config()


def tail(path, n=20):
    try:
        return "\n".join(Path(path).read_text(errors="replace").splitlines()[-n:])
    except OSError:
        return f"(no {path})"


# ponytail: one job at a time, a second Parse/Play waits for the first to finish or be cancelled
job = {"file": None, "mode": None, "pct": 0, "text": "", "running": False, "error": "", "started": 0, "done": 0}
proc = None
cancelled = False


def replays():
    demos = sorted(Path(cfg["bar_data"], "demos").glob("*.sdfz"), key=lambda p: p.stat().st_mtime, reverse=True)[:50]
    scanned = pipeline.scanned_names(cfg["bar_data"])
    rows = []
    for demo in demos:
        info = pipeline.demo_info(demo)
        if not info or info["game"].startswith("BAR Rewind"):  # recordings of this player itself
            continue
        missing = pipeline.demo_missing(cfg["bar_data"], info, scanned)
        rows.append({"file": demo.name, "date": demo.name[:16].replace("_", " "), "map": info["map"],
                     "players": info["players"], "length": info["length"],
                     "parsed": pipeline.curves_path(cfg, demo).exists(),
                     "problem": pipeline.demo_problem(info), "warning": pipeline.demo_warning(info),
                     "missing": [f"{kind} {name}" for kind, name in missing]})
    return rows


def run_job(file, mode):
    global proc, cancelled
    demo = Path(cfg["bar_data"], "demos", file)
    cancelled = False
    job.update(file=file, mode=mode, pct=0, text="starting", running=True, error="", started=time.time(), done=0)
    try:
        if mode == "download":
            info = pipeline.demo_info(demo)
            steps = pipeline.download(cfg["bar_data"], pipeline.demo_missing(cfg["bar_data"], info))
        else:
            steps = pipeline.parse(cfg, demo)
        for event in steps:
            if event[0] == "proc":
                proc = event[1]
            else:
                job.update(pct=max(event[1], 0), text=event[2])
        if mode == "play":
            job.update(pct=100, text="BAR is starting")
            proc = pipeline.play(cfg, demo)
            job["text"] = "BAR is open: close it to come back here"
            if proc.wait() != 0:
                job["error"] = "play failed:\n" + tail(Path(cfg["out_dir"], "play.log"))
            job["text"] = "BAR closed"
    except Exception as e:
        log = "" if mode == "download" else "\n" + tail(Path(cfg["out_dir"], "curves", "dump.log"))
        job["error"] = "cancelled" if cancelled else f"{e}{log}"
    job.update(running=False, done=time.time())


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, code, body, kind="application/json"):
        body = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        global last_seen
        last_seen = time.monotonic()
        if self.path == "/":
            return self.send(200, PAGE.encode(), "text/html; charset=utf-8")
        if self.path == "/api/list":
            ok = pipeline.bar_ok(cfg["bar_data"])
            return self.send(200, {"bar": cfg["bar_data"], "out": cfg["out_dir"], "conf": str(pipeline.config_path()),
                                   "ok": ok, "replays": replays() if ok else []})
        if self.path == "/api/job":
            end = job["done"] or time.time()
            return self.send(200, dict(job, elapsed=int(end - job["started"]) if job["started"] else 0))
        if self.path.startswith("/map/"):
            name = unquote(self.path[5:])
            png = Path(cfg["out_dir"], "minimaps", Path(name).name + ".png")
            if not png.exists():
                png.parent.mkdir(parents=True, exist_ok=True)
                pipeline.minimap(cfg["bar_data"], name, png)
            return self.send(200, png.read_bytes(), "image/png") if png.exists() else self.send(404, {})
        self.send(404, {})

    def do_POST(self):
        data = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        if self.path == "/api/folders":
            bar = str(Path(data.get("bar", "").strip()).expanduser())
            if not pipeline.bar_ok(bar):
                return self.send(400, {"error": "That's not BAR's data folder: it has no engine/ folder inside."})
            out = Path(data.get("out", "").strip() or pipeline.ROOT / "out").expanduser().resolve()
            try:
                out.mkdir(parents=True, exist_ok=True)
            except OSError as e:
                return self.send(400, {"error": f"Can't create the output folder: {e}"})
            cfg.update(bar_data=bar, out_dir=str(out))
            pipeline.save_config(cfg)
            return self.send(200, {})
        if self.path == "/api/open-out":
            pipeline.open_folder(cfg["out_dir"])
            return self.send(200, {})
        if self.path == "/api/run":
            if job["running"]:
                return self.send(409, {"error": "busy"})
            file = data.get("file", "")
            if Path(file).name != file or not Path(cfg["bar_data"], "demos", file).is_file():
                return self.send(400, {"error": "no such replay"})
            threading.Thread(target=run_job, args=(file, data.get("mode")), daemon=True).start()
            return self.send(200, {})
        if self.path == "/api/cancel":
            global cancelled
            if proc and proc.poll() is None:
                cancelled = True
                proc.kill()
            return self.send(200, {})
        self.send(404, {})


PAGE = r"""<!doctype html>
<html><head><meta charset="utf-8"><title>BAR Rewind</title>
<style>
:root { --bg:#14161a; --card:#1e2127; --line:#2c3038; --text:#e6e8eb; --dim:#8b919c; --accent:#4f9cf0; --ok:#4caf7d; --bad:#e06464; }
* { box-sizing:border-box; }
body { margin:0; background:var(--bg); color:var(--text); font:14px system-ui, sans-serif; }
header { padding:16px 24px; border-bottom:1px solid var(--line); display:grid; grid-template-columns:auto 1fr auto; gap:8px 12px; align-items:center; }
header h1 { grid-column:1 / -1; }
header label { font-weight:600; }
.hint { grid-column:2 / -1; margin-top:-4px; }
h1 { font-size:18px; margin:0 16px 0 0; }
header input { min-width:0; background:var(--card); color:var(--text); border:1px solid var(--line); border-radius:6px; padding:7px 10px; font:inherit; }
.dim { color:var(--dim); font-size:12px; }
button { background:var(--card); color:var(--text); border:1px solid var(--line); border-radius:6px; padding:7px 14px; font:inherit; cursor:pointer; }
button:hover:not(:disabled) { border-color:var(--accent); }
button.primary { background:var(--accent); border-color:var(--accent); color:#fff; }
button:disabled { opacity:.4; cursor:default; }
button.unsaved { background:#e0b84f; border-color:#e0b84f; color:#14161a; font-weight:600; }
main { padding:20px 24px 100px; display:grid; grid-template-columns:repeat(auto-fill, minmax(260px, 1fr)); gap:16px; }
.card { background:var(--card); border:1px solid var(--line); border-radius:10px; overflow:hidden; display:flex; flex-direction:column; }
.card img { width:100%; aspect-ratio:1; object-fit:cover; background:#0c0d10; display:block; }
.body { padding:12px; display:flex; flex-direction:column; gap:6px; flex:1; }
.map { font-weight:600; font-size:15px; }
.players { color:var(--dim); margin:0; padding-left:18px; }
.time { border:1px solid var(--line); border-radius:4px; padding:1px 6px; }
.row { display:flex; gap:8px; align-items:center; margin-top:auto; padding-top:8px; }
footer { position:fixed; bottom:0; left:0; right:0; z-index:10; background:#262b35; border-top:3px solid var(--line); box-shadow:0 -6px 24px rgba(0,0,0,.55); padding:14px 24px; display:flex; flex-wrap:wrap; gap:10px 18px; align-items:center; font-size:15px; }
footer.running { border-top-color:var(--accent); }
footer.ok { border-top-color:var(--ok); }
footer.failed { border-top-color:var(--bad); }
footer .badge { font-size:12px; font-weight:700; letter-spacing:.06em; text-transform:uppercase; padding:4px 10px; border-radius:999px; background:var(--line); color:var(--text); white-space:nowrap; }
footer.running .badge { background:var(--accent); color:#0b1520; }
footer.ok .badge { background:var(--ok); color:#0b1a12; }
footer.failed .badge { background:var(--bad); color:#1f0b0b; }
footer .what { flex:1 1 320px; min-width:0; }
footer .what b { margin-right:10px; }
.progress { flex:1 1 220px; height:12px; background:var(--bg); border-radius:6px; overflow:hidden; }
.progress div { height:100%; width:0; background:var(--accent); transition:width .5s; }
footer.idle .progress div { background:var(--line); }
footer.ok .progress div { background:var(--ok); }
footer.failed .progress div { background:var(--bad); }
footer.running.waiting .progress div { width:100% !important; background:repeating-linear-gradient(-45deg, var(--accent) 0 12px, #3b7cc4 12px 24px); background-size:34px 100%; animation:crawl 1s linear infinite; }
@keyframes crawl { to { background-position:34px 0; } }
.elapsed { color:var(--text); font-variant-numeric:tabular-nums; min-width:5ch; text-align:right; }
footer details { flex-basis:100%; }
footer summary { color:var(--bad); cursor:pointer; }
footer pre { margin:8px 0 0; max-height:30vh; overflow:auto; font-size:12px; color:var(--dim); white-space:pre-wrap; }
main { padding-bottom:120px; }
.card.active { border-color:var(--accent); box-shadow:0 0 0 1px var(--accent); }
.card .stage { color:var(--accent); font-size:12px; }
button:disabled { opacity:.45; cursor:default; }
</style></head><body>
<header>
  <h1>BAR Rewind</h1>
  <label for="bar">BAR data folder</label>
  <input id="bar" placeholder="e.g. ~/.local/state/Beyond All Reason">
  <button id="save" onclick="saveFolders()">Save</button>
  <span class="dim hint">Not the install folder: the one BAR keeps its data in, with <code>engine/</code>, <code>maps/</code> and <code>demos/</code> inside.</span>
  <label for="out">Output folder</label>
  <input id="out" placeholder="where parsed replays and logs go">
  <button onclick="post('/api/open-out')">Open</button>
  <span class="dim hint">Parsed replays (<code>curves/</code>), map previews and logs. Press Enter in either field to save; <span id="conf"></span></span>
</header>
<main id="list"></main>
<footer id="job" class="idle">
  <span class="badge" id="badge">Ready</span>
  <div class="what"><b id="jobname">Ready</b><span id="jobtext" class="dim"></span></div>
  <div class="progress"><div id="pct"></div></div>
  <span class="elapsed" id="elapsed"></span>
  <button id="cancel" onclick="post('/api/cancel')" style="display:none">Cancel</button>
  <details id="joberr" style="display:none"><summary id="errhead"></summary><pre id="errlog"></pre></details>
</footer>
<script>
const $ = id => document.getElementById(id);
const esc = s => s.replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
let busy = false;
let summary = '';
const saved = {bar: '', out: ''};
const mmss = s => Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0');
const markUnsaved = () => $('save').classList.toggle('unsaved', $('bar').value !== saved.bar || $('out').value !== saved.out);
async function post(url, body) {
  const r = await fetch(url, {method:'POST', body:JSON.stringify(body || {})});
  return r.ok ? null : (await r.json()).error;
}
async function load() {
  const d = await (await fetch('/api/list')).json();
  $('bar').value = saved.bar = d.bar;
  $('out').value = saved.out = d.out;
  markUnsaved();
  $('conf').textContent = 'settings are kept in ' + d.conf;
  summary = d.replays.length + ' replays, ' + d.replays.filter(r => r.parsed).length + ' parsed';
  $('list').innerHTML = !d.ok ? '<p class="error">No BAR engine in that folder. Point it at BAR\'s data folder and Save.</p>'
    : d.replays.length ? d.replays.map(r => `
    <div class="card" data-card="${esc(r.file)}">
      <img loading="lazy" src="/map/${encodeURIComponent(r.map)}" alt="" onerror="this.style.visibility='hidden'">
      <div class="body">
        <div class="map">${esc(r.map)}</div>
        <div class="dim">${esc(r.date)} <span class="time">${esc(r.length)}</span> <span class="stage"></span></div>
        <ul class="players">${r.players.slice().sort((a, b) => a.localeCompare(b, undefined, {sensitivity:'base'})).map(p => `<li>${esc(p)}</li>`).join('')}</ul>
        <div class="row">
          ${r.parsed ? `<button class="primary" data-file="${esc(r.file)}" data-mode="play">Play</button>`
            : r.problem ? `<button disabled title="${esc(r.problem)}">Parse</button>`
            : r.missing.length ? `<button disabled title="needs ${esc(r.missing.join(', '))}">Parse</button>
                <button data-file="${esc(r.file)}" data-mode="download" title="fetch ${esc(r.missing.join(', '))} with BAR's downloader" data-title="fetch ${esc(r.missing.join(', '))} with BAR's downloader">Download</button>`
            : `<button data-file="${esc(r.file)}" data-mode="parse" title="${esc(r.warning || '')}" data-title="${esc(r.warning || '')}">Parse</button>`}
        </div>
      </div>
    </div>`).join('') : '<p class="dim">No replays in demos/.</p>';
  setBusy(busy);
}
function setBusy(b, why) {
  busy = b;
  document.querySelectorAll('[data-file]').forEach(x => { x.disabled = b; x.title = b ? 'busy: ' + why : (x.dataset.title || ''); });
}
function showOnCard(file, stage) {
  document.querySelectorAll('.card').forEach(c => {
    const mine = c.dataset.card === file;
    c.classList.toggle('active', mine);
    c.querySelector('.stage').textContent = mine ? stage : '';
  });
}
async function saveFolders() {
  const err = await post('/api/folders', {bar: $('bar').value, out: $('out').value});
  if (err) alert(err); else load();
}
$('list').onclick = async e => {
  const b = e.target.closest('[data-file]');
  if (!b) return;
  const err = await post('/api/run', {file: b.dataset.file, mode: b.dataset.mode});
  if (err) alert(err); else poll();
};
async function poll() {
  const j = await (await fetch('/api/job')).json();
  if (!j.file) {
    $('job').className = 'idle';
    $('badge').textContent = 'Ready';
    $('jobname').textContent = 'Nothing running';
    $('jobtext').textContent = summary;
    $('elapsed').textContent = '';
    return;
  }
  const name = j.file.slice(0, 16).replace('_', ' ') + ' · ' + j.mode;
  const failed = !!j.error;
  const finished = !j.running && !failed;
  if (!j.running && busy) { setBusy(false); await load(); }
  $('jobname').textContent = name;
  $('jobtext').textContent = j.running ? j.text : failed ? (j.error.split('\n')[0]) : ({play: 'BAR closed', parse: 'parsed', download: 'downloaded'}[j.mode]) + ' · ' + summary;
  $('jobtext').className = failed ? 'error' : 'dim';
  $('pct').style.width = (j.running ? j.pct : 100) + '%';
  $('job').className = (j.running ? 'running' + (j.pct ? '' : ' waiting') : failed ? 'failed' : 'ok');
  $('badge').textContent = j.running ? ({play: 'Playing', parse: 'Parsing', download: 'Downloading'}[j.mode]) : failed ? (j.error === 'cancelled' ? 'Cancelled' : 'Failed') : 'Done';
  $('elapsed').textContent = mmss(j.elapsed);
  $('cancel').style.display = j.running ? '' : 'none';
  $('joberr').style.display = failed ? '' : 'none';
  if (failed) {
    $('errhead').textContent = 'what the engine said';
    $('errlog').textContent = j.error.split('\n').slice(1).join('\n') || '(no log)';
  }
  const stage = j.running ? j.text + (j.pct ? ' ' + j.pct + '%' : '') + ' · ' + mmss(j.elapsed) : failed ? 'failed' : finished ? 'done' : '';
  if (j.running) {
    setBusy(true, name);
    setTimeout(poll, 1000);
  }
  showOnCard(j.file, stage);
}
for (const id of ['bar', 'out']) {
  $(id).addEventListener('keydown', e => { if (e.key === 'Enter') saveFolders(); });
  $(id).addEventListener('input', markUnsaved);
}
load().then(poll);
setInterval(() => fetch('/api/job'), 20000);
</script></body></html>"""

last_seen = time.monotonic()


def quit_when_page_closed(server):
    # ponytail: browsers slow hidden-tab timers to ~1/min, so silence must outlast that before quitting
    while job["running"] or time.monotonic() - last_seen < 90:
        time.sleep(10)
    server.shutdown()


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    url = f"http://127.0.0.1:{server.server_port}/"
    print(f"BAR Rewind: {url}  (quits 90 s after the page is closed, or Ctrl+C)", flush=True)
    webbrowser.open(url)
    threading.Thread(target=quit_when_page_closed, args=(server,), daemon=True).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
