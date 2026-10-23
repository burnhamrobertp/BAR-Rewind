function widget:GetInfo()
	return {
		name = "Replay Dump v2",
		desc = "Dumps a replay to bardump.jsonl for bar-rewind. Idle unless bardump.request exists.",
		author = "lucas",
		date = "2026-09-27",
		license = "GPL v2",
		layer = 0,
		enabled = true,
	}
end

-- Protocol: tools/pipeline.py writes bardump.request (first line = output path), launches the
-- replay; this widget dumps every SAMPLE_EVERY frames and quits the engine at GameOver.

local SAMPLE_EVERY = 3 -- sim is 30 Hz, so 10 Hz
local HEIGHT_STEP = 64
-- BAR confines user widgets to reading LuaUI/ and writing LuaUI/Config/ (bar-game #9547)
local DIR = "LuaUI/Config/"
local REQUEST = DIR .. "bardump.request"

local format, concat, abs = string.format, table.concat, math.abs
local S = Spring

local file = nil
local lastPiece = {} -- [unitID][piece] = last written matrix, only changes are written
local seenPieces = {} -- [defID] = true once its piece tree is written
local aimPieces = {} -- [defID] = the pieces that aim: each weapon's muzzle piece and its parents up to the root
local features = {} -- [featureID] = the sample that last saw it

-- json -----------------------------------------------------------------------------------------

local function jstr(s)
	return '"' .. s:gsub('[%c"\\]', function(c) return format("\\u%04x", c:byte()) end) .. '"'
end

local function json(v, depth)
	depth = depth or 0
	local t = type(v)
	if t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then return "0" end
		if v == math.floor(v) and math.abs(v) < 2^53 then return format("%d", v) end
		return format("%.6g", v)
	elseif t == "string" then return jstr(v)
	elseif t == "boolean" then return tostring(v)
	elseif t ~= "table" or depth > 6 then return "null" end
	if #v > 0 then
		local out = {}
		for i = 1, #v do out[i] = json(v[i], depth + 1) end
		return "[" .. concat(out, ",") .. "]"
	end
	local out = {}
	local ok = pcall(function()
		for k, x in pairs(v) do
			local tx = type(x)
			if tx ~= "function" and tx ~= "userdata" then
				out[#out + 1] = jstr(tostring(k)) .. ":" .. json(x, depth + 1)
			end
		end
	end)
	if not ok then return "null" end
	return "{" .. concat(out, ",") .. "}"
end

local pending = {}
local gameStarted = false

local function line(key, value)
	local text = '{"' .. key .. '":' .. json(value) .. "}\n"
	if file then file:write(text) else pending[#pending + 1] = text end
end

-- chat and map marks ---------------------------------------------------------------------------
-- The engine labels replayed chat "<name> text" for players and "[name (replay)] text" for
-- spectators, with "Allies: " or "Spectators: " ahead of the text for those channels.

-- engine log lines use the same "<source> text" shape, so only names of the replay's players count
local function playerByName(name)
	for _, id in ipairs(S.GetPlayerList()) do
		local n, _, spec, team = S.GetPlayerInfo(id, false)
		if n == name then return true, team, spec end
	end

	return false
end

function widget:AddConsoleLine(msg)
	local name, text = msg:match("^<([^>]+)> (.*)")
	if not name then
		name, text = msg:match("^%[([^%]]+)%] (.*)")
		if not name then return end
		name = name:gsub(" %(replay%)$", "")
	end
	local channel = "all"
	local rest = text:match("^Allies: (.*)")
	if rest then channel, text = "allies", rest end
	rest = text:match("^Spectators: (.*)")
	if rest then channel, text = "spectators", rest end
	local known, team, spec = playerByName(name)
	if not known then return end
	line("chat", { f = math.max(0, S.GetGameFrame()), name = name, team = team or -1, spec = spec or false,
		channel = channel, text = text, pre = not gameStarted })
end

function widget:GameStart()
	gameStarted = true
end

function widget:MapDrawCmd(playerID, cmdType, px, py, pz, a, b, c)
	local name, _, spec, team = S.GetPlayerInfo(playerID, false)
	local mark = { f = math.max(0, S.GetGameFrame()), name = name or "", team = team or -1, spec = spec or false,
		type = cmdType, x = px, y = py, z = pz }
	if cmdType == "point" then
		mark.label = a or ""
	elseif cmdType == "line" then
		mark.x2, mark.y2, mark.z2 = a, b, c
	elseif cmdType ~= "erase" then
		return
	end
	line("marker", mark)
end

-- moments other widgets point out, for widgets of their own to show in playback:
-- WG.replay_dump.event{ kind =, team =, x =, y =, z =, text = } records one at the current frame
local function event(e)
	line("event", { f = math.max(0, S.GetGameFrame()), kind = e.kind or "", team = e.team or -1,
		x = e.x, y = e.y, z = e.z, text = e.text or "" })
end

-- one-time headers -----------------------------------------------------------------------------

local function modelOf(def)
	local out = {}
	pcall(function() out.modelname = def.modelname end)
	local m = def.model
	if type(m) == "table" then
		pcall(function()
			for k, v in pairs(m) do
				local t = type(v)
				if t == "string" or t == "number" or t == "boolean" then out[k] = v end
			end
		end)
		local tex = m.textures or {}
		out.tex1 = tex.tex1
		out.tex2 = tex.tex2
	end
	return out
end

local function sunState()
	local out = {}
	local function grab(key, ...)
		local r = { pcall(...) }
		if r[1] then table.remove(r, 1); out[key] = r end
	end
	grab("pos", gl.GetSun, "pos")
	for _, mode in ipairs({ "ground", "unit" }) do
		for _, p in ipairs({ "ambient", "diffuse", "specular", "shadowDensity" }) do
			grab(mode .. "_" .. p, gl.GetSun, p, mode)
		end
	end
	for _, p in ipairs({ "fogStart", "fogEnd", "fogColor", "skyColor", "sunColor", "cloudColor", "skyAxisAngle" }) do
		grab(p, gl.GetAtmosphere, p)
	end
	for _, p in ipairs({ "splatTexScales", "splatTexMults", "voidWater", "voidGround", "splatDetailNormalDiffuseAlpha" }) do
		grab(p, gl.GetMapRendering, p)
	end
	for _, p in ipairs({ "absorb", "baseColor", "minColor", "surfaceColor", "surfaceAlpha", "diffuseColor", "specularColor",
		"planeColor", "ambientFactor", "diffuseFactor", "specularFactor", "specularPower", "fresnelMin", "fresnelMax",
		"fresnelPower", "reflectionDistortion", "blurBase", "blurExponent", "perlinStartFreq", "perlinLacunarity",
		"perlinAmplitude", "numTiles", "texture", "foamTexture", "normalTexture", "shoreWaves", "hasWaterPlane", "forceRendering" }) do
		grab("water_" .. p, gl.GetWaterRendering, p)
	end
	return out
end

local function writeHeaders()
	local mapinfo = nil
	pcall(function() mapinfo = VFS.Include("mapinfo.lua") end)
	line("map", {
		name = Game.mapName, file = Game.mapFileName, sizeX = Game.mapSizeX, sizeZ = Game.mapSizeZ,
		gravity = Game.gravity, waterLevel = 0, info = mapinfo, render = sunState(),
		game = Game.gameName, gameVersion = Game.gameVersion,
	})

	local rows = {}
	for z = 0, Game.mapSizeZ, HEIGHT_STEP do
		local row = {}
		for x = 0, Game.mapSizeX, HEIGHT_STEP do row[#row + 1] = format("%.1f", S.GetGroundHeight(x, z)) end
		rows[#rows + 1] = "[" .. concat(row, ",") .. "]"
	end
	file:write(format('{"terrain":{"sizeX":%d,"sizeZ":%d,"step":%d,"h":[%s]}}\n',
		Game.mapSizeX, Game.mapSizeZ, HEIGHT_STEP, concat(rows, ",")))

	local defs = {}
	for id, d in pairs(UnitDefs) do
		defs[tostring(id)] = { name = d.name, radius = d.radius, height = d.height, model = modelOf(d) }
	end
	line("defs", defs)

	local fdefs = {}
	for id, d in pairs(FeatureDefs) do
		fdefs[tostring(id)] = { name = d.name, radius = d.radius, height = d.height, model = modelOf(d),
			drawType = d.drawType, tree = d.customParams and d.customParams.treeshader }
	end
	line("fdefs", fdefs)

	local wdefs = {}
	for id, d in pairs(WeaponDefs) do
		local w = {}
		pcall(function()
			for k, v in d:pairs() do
				local t = type(v)
				if t == "number" or t == "string" or t == "boolean" then w[k] = v end
			end
		end)
		w.visuals = d.visuals
		wdefs[tostring(id)] = w
	end
	line("wdefs", wdefs)

	local teams = {}
	for _, id in ipairs(S.GetTeamList()) do
		local r, g, b = S.GetTeamColor(id)
		local _, leader, _, isAI, side, ally = S.GetTeamInfo(id)
		local name = leader and S.GetPlayerInfo(leader) or nil
		teams[tostring(id)] = { color = { r, g, b }, ally = ally, side = side, ai = isAI, leader = name }
	end
	line("teams", teams)

	local players = {}
	for _, id in ipairs(S.GetPlayerList()) do
		local name = S.GetPlayerInfo(id, false)
		if name then players[tostring(id)] = name end
	end
	line("players", players)
end

local function writePieces(u, def)
	seenPieces[def] = true
	local names = S.GetUnitPieceList(u) or {}
	local parents, offsets = {}, {}
	for i = 1, #names do
		local info = S.GetUnitPieceInfo(u, i) or {}
		parents[i] = info.parent or ""
		offsets[i] = info.offset or { 0, 0, 0 }
	end
	line("pieces", { def = def, names = names, parents = parents, offsets = offsets })

	-- only these are recorded: BAR's script animates the rest (legs, walk bob) from the movement
	local index, aim, list = {}, {}, {}
	for i = 1, #names do index[names[i]] = i end
	for w = 1, #(UnitDefs[def].weapons or {}) do
		local mx, my, mz = S.GetUnitWeaponVectors(u, w)
		local muzzle, best = nil, math.huge
		for i = 1, mx and #names or 0 do
			local px, py, pz = S.GetUnitPiecePosDir(u, i)
			local d = px and (px - mx) ^ 2 + (py - my) ^ 2 + (pz - mz) ^ 2 or math.huge
			if d < best then muzzle, best = i, d end
		end
		local i = muzzle
		-- up to and with the root: piece curves are relative to their parent's, and roots can carry a turn
		while i and not aim[i] do
			aim[i] = true
			list[#list + 1] = i
			i = index[parents[i]]
		end
	end
	aimPieces[def] = list
end

-- per-frame: binary, into bardump.bin ------------------------------------------------------------
-- Record: u32 frame, u32 counts {units, pieces, features added, features removed, projectiles,
-- terrain, queue floats}, then f32 rows: unit 23 (.., on/off, weapon target type + unit id or ground
-- xyz, worker cmd, worker target (unit id, or -(feature id + 1)), build power), piece 14 (unit,
-- piece, 12 matrix values), feature 8, removed 1, projectile 10 (id, def, team, xyz, velocity,
-- owner unit or -1), terrain 4 (heightmap x, z, new height, previous height), queues (unit,
-- team, n, then n x (cmd, x, y, z, target, extra)). Projectiles and terrain every frame, the rest every
-- SAMPLE_EVERY frames, queues every QUEUE_EVERY.
-- Recoil's Lua numbers are 32-bit floats, so f32 loses nothing.

local isBuilder = {}
for id, d in pairs(UnitDefs) do isBuilder[id] = d.isBuilder end

local UNIT_ROW, PIECE_ROW, FEATURE_ROW, PROJECTILE_ROW, TERRAIN_ROW = 23, 14, 8, 10, 4
-- a multiple of SAMPLE_EVERY: bake finds a queue's unit by the unit rows of the same frame
local QUEUE_EVERY = 6

-- every aim piece whose model-space matrix moved since it was last written; returns the new row end
local function recordPieces(u, def, ps, np)
	local last = lastPiece[u]
	if not last then last = {}; lastPiece[u] = last end
	local aim = aimPieces[def]
	for k = 1, #aim do
		local p = aim[k]
		local m11, m21, m31, _, m12, m22, m32, _, m13, m23, m33, _, tx, ty, tz = S.GetUnitPieceMatrix(u, p)
		if m11 then
			local l = last[p]
			-- only real motion: rotation terms beyond 0.004, translation beyond 0.05 elmo
			if not l or abs(l[1] - m11) > 0.004 or abs(l[2] - m21) > 0.004 or abs(l[3] - m31) > 0.004
				or abs(l[4] - m12) > 0.004 or abs(l[5] - m22) > 0.004 or abs(l[6] - m32) > 0.004
				or abs(l[7] - m13) > 0.004 or abs(l[8] - m23) > 0.004 or abs(l[9] - m33) > 0.004
				or abs(l[10] - tx) > 0.05 or abs(l[11] - ty) > 0.05 or abs(l[12] - tz) > 0.05 then
				if not l then l = {}; last[p] = l end
				l[1], l[2], l[3], l[4], l[5], l[6] = m11, m21, m31, m12, m22, m32
				l[7], l[8], l[9], l[10], l[11], l[12] = m13, m23, m33, tx, ty, tz
				ps[np + 1], ps[np + 2] = u, p
				ps[np + 3], ps[np + 4], ps[np + 5], ps[np + 6] = m11, m21, m31, m12
				ps[np + 7], ps[np + 8], ps[np + 9], ps[np + 10] = m22, m32, m13, m23
				ps[np + 11], ps[np + 12], ps[np + 13], ps[np + 14] = m33, tx, ty, tz
				np = np + PIECE_ROW
			end
		end
	end
	return np
end

-- which sample last saw each unit, instead of a fresh set of the living every sample
local seenAt, sampleNo = {}, 0

local function unitsSample(us, ps)
	local units = S.GetAllUnits()
	sampleNo = sampleNo + 1
	local nu, np = 0, 0
	for i = 1, #units do
		local u = units[i]
		local x, y, z = S.GetUnitPosition(u)
		-- a killed unit lingers while its death animation runs: the player's kill replays that
		if x and not S.GetUnitIsDead(u) then
			seenAt[u] = sampleNo
			local def = S.GetUnitDefID(u) or 0
			local fx, fy, fz, _, _, _, ux, uy, uz = S.GetUnitDirection(u)
			local hp, maxHp, _, _, build = S.GetUnitHealth(u)
			us[nu + 1], us[nu + 2], us[nu + 3] = u, def, S.GetUnitTeam(u) or 0
			us[nu + 4], us[nu + 5], us[nu + 6] = x, y, z
			us[nu + 7], us[nu + 8], us[nu + 9] = fx or 0, fy or 0, fz or 1
			us[nu + 10], us[nu + 11], us[nu + 12] = ux or 0, uy or 1, uz or 0
			us[nu + 13], us[nu + 14], us[nu + 15] = hp or 0, maxHp or 0, build or 1
			us[nu + 16] = S.GetUnitIsActive(u) == false and 0 or 1
			-- what the first weapon aims at: 0 nothing, 1 unit (id), 2 ground (xyz), 3 projectile
			local tt, _, target = S.GetUnitWeaponTarget(u, 1)
			local ta, tb, tc = 0, 0, 0
			if tt == 1 or tt == 3 then
				ta = target or 0
			elseif tt == 2 and type(target) == "table" then
				ta, tb, tc = target[1] or 0, target[2] or 0, target[3] or 0
			end
			us[nu + 17], us[nu + 18], us[nu + 19], us[nu + 20] = tt or 0, ta, tb, tc
			-- what a builder works on (build, repair, reclaim, ...) and how hard: drives BAR's nano spray
			local wc, wt, bp = 0, 0, 0
			if isBuilder[def] then
				local cmd, id = S.GetUnitWorkerTask(u)
				bp = S.GetUnitCurrentBuildPower(u) or 0
				if cmd and id then
					wc, wt = cmd, id >= Game.maxUnits and -(id - Game.maxUnits + 1) or id
				end
			end
			us[nu + 21], us[nu + 22], us[nu + 23] = wc, wt, bp
			nu = nu + UNIT_ROW

			if not seenPieces[def] then writePieces(u, def) end
			-- aim pieces' motion: the player sets them from these curves, so turrets and torsos point
			-- right after a seek
			np = recordPieces(u, def, ps, np)
		end
	end
	for u in pairs(lastPiece) do
		if seenAt[u] ~= sampleNo then
			lastPiece[u], seenAt[u] = nil, nil
		end
	end

	return nu, np
end

local function featuresSample(added, removed)
	local all = S.GetAllFeatures()
	local n, nr = 0, 0
	for i = 1, #all do
		local f = all[i]
		if not features[f] then
			local x, y, z = S.GetFeaturePosition(f)
			local dx, dy, dz = S.GetFeatureDirection(f)
			added[n + 1], added[n + 2] = f, S.GetFeatureDefID(f) or 0
			added[n + 3], added[n + 4], added[n + 5] = x or 0, y or 0, z or 0
			added[n + 6], added[n + 7], added[n + 8] = dx or 0, dy or 0, dz or 1
			n = n + FEATURE_ROW
		end
		features[f] = sampleNo
	end
	for f, at in pairs(features) do
		if at ~= sampleNo then
			nr = nr + 1
			removed[nr] = f
			features[f] = nil
		end
	end

	return n, nr
end

local function projectileRow(p, rows, n)
	local x, y, z = S.GetProjectilePosition(p)
	if not x then return n end
	local vx, vy, vz = S.GetProjectileVelocity(p)
	local weapon = S.GetProjectileType(p)
	rows[n + 1], rows[n + 2] = p, weapon and (S.GetProjectileDefID(p) or -1) or -2 -- -2 = piece debris
	rows[n + 3] = S.GetProjectileTeamID(p) or -1
	rows[n + 4], rows[n + 5], rows[n + 6] = x, y, z
	rows[n + 7], rows[n + 8], rows[n + 9] = vx or 0, vy or 0, vz or 0
	rows[n + 10] = S.GetProjectileOwnerID(p) or -1
	return n + PROJECTILE_ROW
end

local function projectilesSample(ps)
	local all = S.GetAllProjectiles and S.GetAllProjectiles(false, false)
		or S.GetProjectilesInRectangle(0, 0, Game.mapSizeX, Game.mapSizeZ, false, false)
	local n = 0
	for i = 1, #all do n = projectileRow(all[i], ps, n) end

	return n
end

-- terrain: heightmap points inside the rectangles the engine reports as changed, written when they
-- really moved, with the height they had before (the map's original height the first time)
local SQUARE = Game.squareSize
local dirty = {} -- flat x1, z1, x2, z2 lists
local heights = {} -- [z * (mapx + 1) + x] = last written height
local terrain_updates = 0

function widget:UnsyncedHeightMapUpdate(x1, z1, x2, z2)
	local n = #dirty
	dirty[n + 1], dirty[n + 2], dirty[n + 3], dirty[n + 4] = x1, z1, x2, z2
	terrain_updates = terrain_updates + 1
end

local function terrainSample(ts)
	local stride = Game.mapSizeX / SQUARE + 1
	local n = 0
	for r = 1, #dirty, 4 do
		for z = dirty[r + 1], dirty[r + 3] do
			for x = dirty[r], dirty[r + 2] do
				local key = z * stride + x
				local h = S.GetGroundHeight(x * SQUARE, z * SQUARE)
				local last = heights[key] or S.GetGroundOrigHeight(x * SQUARE, z * SQUARE)
				if abs(h - last) > 0.01 then
					heights[key] = h
					ts[n + 1], ts[n + 2], ts[n + 3], ts[n + 4] = x, z, h, last
					n = n + TERRAIN_ROW
				end
			end
		end
	end
	dirty = {}

	return n
end

-- every unit's command queue (a factory's: the orders its new units get), written when it changes.
-- Only units the command call-ins flagged are read, and every QUEUE_SWEEP frames any unit whose
-- queue length changed some other way
local lastQueue = {} -- [unitID] = string of the last written queue
local lastQueueLength = {}
local queueDirty = {}
local QUEUE_SWEEP = 300
local MAX_UNITS = Game.maxUnits

function widget:UnitCommand(u) queueDirty[u] = true end
function widget:UnitCmdDone(u) queueDirty[u] = true end
function widget:UnitIdle(u) queueDirty[u] = true end
function widget:UnitCreated(u) queueDirty[u] = true end
function widget:UnitFinished(u) queueDirty[u] = true end
function widget:UnitGiven(u) queueDirty[u] = true end

-- orders whose 4th parameter is an area radius
local AREA = {}
for _, name in ipairs({ "RECLAIM", "REPAIR", "RESURRECT", "CAPTURE", "RESTORE", "AREA_ATTACK", "LOAD_UNITS", "UNLOAD_UNITS" }) do
	if CMD[name] then AREA[CMD[name]] = true end
end

-- one order as cmd, x, y, z, target (unit id, -(feature id + 1) or 0), extra (build facing or area
-- radius); nil for orders with nowhere to draw. An order on one object that an area order made
-- carries the area after the object: { id, x, y, z, radius }
local function order(c)
	local p = c.params
	if #p == 1 or #p == 5 then
		local id = p[1]
		if id >= MAX_UNITS then
			local x, y, z = S.GetFeaturePosition(id - MAX_UNITS)
			if x then return c.id, x, y, z, -(id - MAX_UNITS + 1), 0 end
		else
			local x, y, z = S.GetUnitPosition(id)
			if x then return c.id, x, y, z, id, 0 end
		end
	elseif #p >= 3 then
		return c.id, p[1], p[2], p[3], 0, (c.id < 0 or AREA[c.id]) and p[4] or 0
	end
end

local function queueRows(u, qs, n)
	local cmds = S.GetUnitCommands(u, 200) or {}
	lastQueueLength[u] = #cmds
	local items = {}
	for k = 1, #cmds do
		local cmd, x, y, z, target, extra = order(cmds[k])
		-- a target unit's position moves: the key holds only who it is
		if cmd then items[#items + 1] = target ~= 0 and format("%d %d", cmd, target) or format("%d %.0f %.0f %.0f %.0f", cmd, x, y, z, extra) end
	end
	local key = concat(items, ",")
	if key == (lastQueue[u] or "") then
		return n
	end

	lastQueue[u] = key
	qs[n + 1], qs[n + 2], qs[n + 3] = u, S.GetUnitTeam(u) or 0, #items
	n = n + 3
	for k = 1, #cmds do
		local cmd, x, y, z, target, extra = order(cmds[k])
		if cmd then
			qs[n + 1], qs[n + 2], qs[n + 3], qs[n + 4], qs[n + 5], qs[n + 6] = cmd, x, y, z, target, extra
			n = n + 6
		end
	end

	return n
end

local function queuesSample(qs, sweep)
	if sweep then
		local units = S.GetAllUnits()
		for i = 1, #units do
			local u = units[i]
			if S.GetUnitCommands(u, 0) ~= (lastQueueLength[u] or 0) then queueDirty[u] = true end
		end
		for u in pairs(lastQueue) do
			if not S.ValidUnitID(u) or S.GetUnitIsDead(u) then lastQueue[u], lastQueueLength[u] = nil, nil end
		end
	end
	local n = 0
	for u in pairs(queueDirty) do
		queueDirty[u] = nil
		if S.ValidUnitID(u) and not S.GetUnitIsDead(u) then n = queueRows(u, qs, n) end
	end

	return n
end

local bin = nil

-- what players looked at: their cursors and cameras, as BAR's broadcast gadgets decoded them, into
-- bardump_view.bin. Record: u32 frame, kind (1 cursor, 2 camera, 3 camera stopped), player, n,
-- then n f32: cursor x1, z1, x2, z2, click; camera mode, then its fields in the order the
-- "camkeys" header line gives for that mode. Repeats of a player's last record are dropped.
local view = nil
local lastView = {} -- [kind .. player] = string of the last record's values
local camKeys = {} -- [mode] = sorted field names

local function writeView(kind, player, values)
	if not view then return end
	local key = kind .. ":" .. player
	local sig = concat(values, ",")
	if lastView[key] == sig then return end
	lastView[key] = sig
	view:write(VFS.PackU32(math.max(0, S.GetGameFrame()), kind, player, #values))
	if #values > 0 then view:write(VFS.PackF32(values)) end
end

function widget:MouseCursorEvent(playerID, x1, z1, x2, z2, click)
	writeView(1, playerID, { x1 or 0, z1 or 0, x2 or x1 or 0, z2 or z1 or 0, click and 1 or 0 })
end

function widget:CameraBroadcastEvent(playerID, state)
	if not state then
		lastView["2:" .. playerID] = nil
		return writeView(3, playerID, {})
	end
	local mode = state.mode or -1
	local keys = camKeys[mode]
	if not keys then
		keys = {}
		for k, v in pairs(state) do
			if type(v) == "number" and k ~= "mode" then keys[#keys + 1] = k end
		end
		table.sort(keys)
		camKeys[mode] = keys
		line("camkeys", { mode = mode, name = state.name or "", keys = keys })
	end
	local values = { mode }
	for i = 1, #keys do values[i + 1] = state[keys[i]] or 0 end
	writeView(2, playerID, values)
end

-- one set of row buffers for the whole recording, each cut back to what this frame filled
local rows = { {}, {}, {}, {}, {}, {}, {} }
local filled = { 0, 0, 0, 0, 0, 0, 0 }

local function writeRows(k, n)
	local r = rows[k]
	for i = n + 1, filled[k] do r[i] = nil end
	filled[k] = n
	if n > 0 then bin:write(VFS.PackF32(r)) end
end

local function writeFrame(frame)
	local us, ps, fa, fr, pr, ts, qs = rows[1], rows[2], rows[3], rows[4], rows[5], rows[6], rows[7]
	local nu, np, nfa, nfr, nq = 0, 0, 0, 0, 0
	if frame % SAMPLE_EVERY == 0 then
		nu, np = unitsSample(us, ps)
		nfa, nfr = featuresSample(fa, fr)
	end
	if frame % QUEUE_EVERY == 0 then nq = queuesSample(qs, frame % QUEUE_SWEEP == 0) end
	local npr = projectilesSample(pr)
	local nts = terrainSample(ts)
	bin:write(VFS.PackU32(frame, nu / UNIT_ROW, np / PIECE_ROW, nfa / FEATURE_ROW, nfr, npr / PROJECTILE_ROW,
		nts / TERRAIN_ROW, nq))
	writeRows(1, nu)
	writeRows(2, np)
	writeRows(3, nfa)
	writeRows(4, nfr)
	writeRows(5, npr)
	writeRows(6, nts)
	writeRows(7, nq)
end

-- lifecycle ------------------------------------------------------------------------------------

-- first line: "dump <last frame>"
-- or "shot <frame> <x> <z>" for a reference screenshot
local function readRequest()
	local f = io.open(REQUEST, "r")
	if not f then return nil end
	local line = f:read("*l") or ""
	f:close()
	local frame, x, z = line:match("^shot (%d+) ([%d%.]+) ([%d%.]+)")
	if frame then return { shot = tonumber(frame), x = tonumber(x), z = tonumber(z) } end
	-- io.open is sandboxed to the write dir; pipeline.py moves the files out
	return { path = DIR .. "bardump.jsonl", last = tonumber(line:match("(%d+)$")) }
end

-- reference screenshot mode ---------------------------------------------------------------------

local shot = nil -- { frame, x, z, state = nil | "aimed" | draw frames counted }

local function shotFrame(frame)
	if frame < shot.shot or shot.state then return end
	S.SendCommands("pause 1", "hideinterface 1")
	local ok, state = pcall(VFS.Include, DIR .. "barshot_camera_in.lua", nil, VFS.RAW)
	if ok and type(state) == "table" then
		S.SetCameraState(state, 0)
	else
		local y = S.GetGroundHeight(shot.x, shot.z)
		S.SetCameraTarget(shot.x, y, shot.z, 0)
	end
	shot.state = 0
end

function widget:Update()
	if not shot or not shot.state then return end
	shot.state = shot.state + 1
	if shot.state == 30 then
		S.SendCommands("screenshot png")
	elseif shot.state == 31 then
		local px, py, pz = S.GetCameraPosition()
		local dx, dy, dz = S.GetCameraDirection()
		local vfov = S.GetCameraFOV()
		local vx, vy = S.GetViewGeometry()
		local f = io.open(DIR .. "barshot_camera.json", "w")
		f:write(format('{"frame":%d,"pos":[%f,%f,%f],"dir":[%f,%f,%f],"vfov":%f,"size":[%d,%d],"state":%s}\n',
			S.GetGameFrame(), px, py, pz, dx, dy, dz, vfov, vx, vy, json(S.GetCameraState())))
		f:close()
	elseif shot.state == 60 then
		os.remove(REQUEST)
		S.SendCommands("quitforce")
	end
end

local function stop(quit)
	if bin then
		bin:close()
		bin = nil
	end
	if view then
		view:close()
		view = nil
	end
	if file then
		file:write('{"end":true}\n')
		file:close()
		file = nil
		S.Echo("Replay Dump v2: done")
	end
	if quit then
		os.remove(REQUEST)
		S.SendCommands("quitforce")
	end
end

local started = false
local last_frame = nil -- the replay's last keyframe: an unfinished replay never reaches GameOver
local path = nil

function widget:GameFrame(frame)
	if not started then
		started = true
		local request = S.IsReplay() and readRequest()
		if not request then
			widgetHandler:RemoveWidget()
			return
		end
		if request.shot then
			shot = request
			S.SendCommands("specfullview 1", "setminspeed 100", "setmaxspeed 100", "setspeed 100")
		else
			path = request.path
			last_frame = request.last
		end
	end
	if shot then
		shotFrame(frame)
		return
	end
	if not file and path then
		-- binary mode: text mode writes \r\n on Windows
		file = io.open(path, "wb")
		bin = io.open(DIR .. "bardump.bin", "wb")
		view = io.open(DIR .. "bardump_view.bin", "wb")
		if view then view:write("BRVW", VFS.PackU32(1)) end
		-- file header: magic, format version, floats per unit row
		if bin then bin:write("BRDB", VFS.PackU32(4, UNIT_ROW)) end
		if not file or not bin then
			S.Echo("Replay Dump v2: cannot open " .. path)
			return
		end
		S.SendCommands("specfullview 1", "setminspeed 100", "setmaxspeed 100", "setspeed 100")
		writeHeaders()
		for i = 1, #pending do file:write(pending[i]) end
		pending = {}
		S.Echo("Replay Dump v2: recording to " .. path)
		path = nil
	end
	if frame % 300 == 0 then S.Echo("Replay Dump v2: frame " .. frame .. ", terrain updates " .. terrain_updates) end
	if last_frame and last_frame > 0 and frame > last_frame then return stop(true) end
	if not bin then return end
	writeFrame(frame)
end

-- the replay's pre-game lobby (start positions) plays in real time unless sped up before frame 0
function widget:Initialize()
	if S.IsReplay() and io.open(REQUEST, "r") then
		S.SendCommands("setminspeed 100", "setmaxspeed 100", "setspeed 100")
	end
	WG.replay_dump = { event = event }
end

function widget:GameOver()
	stop(true)
end

function widget:Shutdown()
	stop(false)
	WG.replay_dump = nil
end
