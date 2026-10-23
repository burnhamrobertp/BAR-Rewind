function widget:GetInfo()
	return {
		name = "Replay Orders",
		desc = "BAR Rewind: the selected units' command queues at the replay time, drawn as BAR draws them live",
		author = "burnhamrobertp",
		license = "GPL v2",
		layer = 57,
		enabled = true,
	}
end

-- Reads replay/queues + queue_items (written by `bake export-lua`). The replay's units never get
-- real orders (they would carry them out), so the engine draws no queue for them: this does, in the
-- colours of BAR's cmdcolors_icexuick.txt.

local M = VFS.Include("replay/meta.lua")
local U32, S32, F32 = VFS.UnpackU32, VFS.UnpackS32, VFS.UnpackF32
local floor = math.floor
local GetUnitRulesParam, GetUnitPosition = Spring.GetUnitRulesParam, Spring.GetUnitPosition
local LINE_WIDTH = 2
local REMAP_EVERY = 1 -- seconds between rebuilds of the replay id -> unit map, when one is missing

local COLOURS = {
	build = { 0.0, 1.0, 0.0, 0.3 },
	[CMD.MOVE] = { 0.5, 1.0, 0.5, 0.3 },
	[CMD.ATTACK] = { 1.0, 0.2, 0.2, 0.3 },
	[CMD.AREA_ATTACK] = { 1.0, 0.2, 0.2, 0.3 },
	[CMD.MANUALFIRE] = { 1.0, 0.2, 0.2, 0.3 },
	[CMD.FIGHT] = { 1.0, 0.2, 1.0, 0.3 },
	[CMD.GUARD] = { 0.6, 1.0, 1.0, 0.3 },
	[CMD.PATROL] = { 0.2, 0.5, 1.0, 0.3 },
	[CMD.CAPTURE] = { 1.0, 1.0, 0.3, 0.6 },
	[CMD.REPAIR] = { 1.0, 0.9, 0.2, 0.6 },
	[CMD.RECLAIM] = { 0.5, 1.0, 0.4, 0.3 },
	[CMD.RESTORE] = { 0.0, 1.0, 0.0, 0.3 },
	[CMD.RESURRECT] = { 0.9, 0.5, 1.0, 0.5 },
	[CMD.LOAD_UNITS] = { 0.4, 0.9, 0.9, 0.7 },
	[CMD.LOAD_ONTO] = { 0.4, 0.9, 0.9, 0.7 },
	[CMD.UNLOAD_UNITS] = { 1.0, 0.8, 0.0, 0.7 },
	[CMD.UNLOAD_UNIT] = { 1.0, 0.8, 0.0, 0.7 },
	other = { 1.0, 1.0, 1.0, 0.3 },
}

local function section(name)
	local s = M.sections[name]
	local parts = {}
	for c = 0, (s and s.chunks or 0) - 1 do
		local z = VFS.LoadFile("replay/" .. name .. "_" .. c .. ".bin")
		parts[#parts + 1] = z and #z > 0 and VFS.ZlibDecompress(z) or ""
	end
	return table.concat(parts), s
end

-- per unit record index: t, first item, item count, ... in time order
local orders = {}
local items, item_size

local function load()
	local q, qs = section("queues")
	if not qs then return false end
	for i = 0, qs.count - 1 do
		local v = U32(q, i * qs.size + 1, 4)
		local o = orders[v[1]]
		if not o then o = {}; orders[v[1]] = o end
		o[#o + 1], o[#o + 2], o[#o + 3] = v[2], v[3], v[4]
	end
	local s
	items, s = section("queue_items")
	item_size = s.size
	return true
end

-- the replay's unit id -> the unit playing it, rebuilt when a lookup misses
local byReplayId, remapped_at = {}, nil

local function unitPlaying(id)
	local u = byReplayId[id]
	if u and GetUnitRulesParam(u, "replay_id") == id then return u end
	local now = Spring.GetTimer()
	if remapped_at and Spring.DiffTimers(now, remapped_at) < REMAP_EVERY then return nil end
	remapped_at = now
	byReplayId = {}
	for _, other in ipairs(Spring.GetAllUnits()) do
		local rid = GetUnitRulesParam(other, "replay_id")
		if rid then byReplayId[rid] = other end
	end

	return byReplayId[id]
end

-- the record at or before t in a unit's orders: its first item and count
local function queueAt(o, t)
	local a, b = 0, #o / 3
	if b == 0 or o[1] > t then return 0, 0 end
	while b - a > 1 do
		local mid = floor((a + b) / 2)
		if o[mid * 3 + 1] <= t then a = mid else b = mid end
	end

	return o[a * 3 + 2], o[a * 3 + 3]
end

local function colourOf(cmd)
	return cmd < 0 and COLOURS.build or COLOURS[cmd] or COLOURS.other
end

local CIRCLE_STEPS = 32

-- an area order's circle, as line segments
local function circle(x, y, z, r)
	for k = 0, CIRCLE_STEPS - 1 do
		local a, b = k * 2 * math.pi / CIRCLE_STEPS, (k + 1) * 2 * math.pi / CIRCLE_STEPS
		gl.Vertex(x + r * math.cos(a), y, z + r * math.sin(a))
		gl.Vertex(x + r * math.cos(b), y, z + r * math.sin(b))
	end
end

-- a unit's queue at t: a line from it through each order, as GL.LINES vertices
local function queueLines(u, t)
	local index = GetUnitRulesParam(u, "replay_index")
	local o = index and orders[index]
	if not o then return end
	local first, count = queueAt(o, t)
	local px, py, pz = GetUnitPosition(u)
	if count == 0 or not px then return end
	for i = first, first + count - 1 do
		local pos = i * item_size + 1
		local cmd = S32(items, pos)
		local x, y, z = F32(items, pos + 4), F32(items, pos + 8), F32(items, pos + 12)
		local target, extra = S32(items, pos + 16), F32(items, pos + 20)
		local tu = target > 0 and unitPlaying(target)
		if tu then
			local tx, ty, tz = GetUnitPosition(tu)
			if tx then x, y, z = tx, ty, tz end
		end
		local c = colourOf(cmd)
		gl.Color(c[1], c[2], c[3], c[4])
		gl.Vertex(px, py, pz)
		gl.Vertex(x, y, z)
		if cmd >= 0 and extra > 0 then circle(x, y, z, extra) end
		px, py, pz = x, y, z
	end
end

local draw_t, draw_selected

local function lines()
	for k = 1, #draw_selected do queueLines(draw_selected[k], draw_t) end
end

function widget:Initialize()
	if not load() then widgetHandler:RemoveWidget() end
end

function widget:DrawWorld()
	draw_t, draw_selected = Spring.GetGameRulesParam("replay_t"), Spring.GetSelectedUnits()
	if not draw_t or #draw_selected == 0 then return end
	gl.LineWidth(LINE_WIDTH)
	gl.DepthTest(false)
	gl.BeginEnd(GL.LINES, lines)
	gl.Color(1, 1, 1, 1)
	gl.LineWidth(1)
end
