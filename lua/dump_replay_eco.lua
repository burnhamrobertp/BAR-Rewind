function widget:GetInfo()
	return {
		name = "Replay Dump Eco",
		desc = "Records every team's resources once a second while Replay Dump v2 records a replay (idle unless bardump.request exists); replay_eco.lua plays them back in the player",
		author = "beyondbarb (MotionCorrect)",
		date = "2026-10-17",
		license = "GPL v2",
		layer = 0,
		enabled = true,
	}
end

-- bardump_eco.bin: "BBEC", u32 version, u32 frames per sample, u32 fields per team, u32 team count,
-- u32 team ids, then rows of f32: frame, then per team metal (level, storage, pull, income, expense)
-- and energy (the same five). Income, expense and pull are the engine's per-second figures, what
-- BAR's top bar shows. bake stores it in the .curves.

-- BAR confines user widgets to reading LuaUI/ and writing LuaUI/Config/ (bar-game #9547)
local REQUEST, OUT = "LuaUI/Config/bardump.request", "LuaUI/Config/bardump_eco.bin"
local EVERY, FIELDS = 30, 10
local S = Spring

local file, teams, last_frame = nil, nil, nil
local started = false

local function request()
	local f = io.open(REQUEST, "r")
	if not f then return nil end
	local line = f:read("*l") or ""
	f:close()
	if line:match("^shot") then return nil end -- a reference screenshot, not a dump
	return tonumber(line:match("(%d+)$")) or 0
end

local function stop()
	if file then
		file:close()
		file = nil
		S.Echo("Replay Dump Eco: done")
	end
end

function widget:GameFrame(frame)
	if not started then
		started = true
		last_frame = S.IsReplay() and request()
		if not last_frame then
			widgetHandler:RemoveWidget()
			return
		end
		S.SendCommands("specfullview 1") -- GetTeamResources answers for every team only with full view
		teams = {}
		local gaia = S.GetGaiaTeamID()
		for _, id in ipairs(S.GetTeamList()) do
			if id ~= gaia then teams[#teams + 1] = id end
		end
		file = io.open(OUT, "wb") -- binary: text mode writes \r\n on Windows
		if not file then
			S.Echo("Replay Dump Eco: cannot open " .. OUT)
			widgetHandler:RemoveWidget()
			return
		end
		file:write("BBEC", VFS.PackU32(1, EVERY, FIELDS, #teams), VFS.PackU32(teams))
		S.Echo("Replay Dump Eco: recording " .. #teams .. " teams to " .. OUT)
	end
	if not file then return end
	if last_frame > 0 and frame > last_frame then return stop() end
	if frame % EVERY ~= 0 then return end
	local row = { frame }
	for i = 1, #teams do
		local id = teams[i]
		local ml, ms, mp, mi, me = S.GetTeamResources(id, "metal")
		local el, es, ep, ei, ee = S.GetTeamResources(id, "energy")
		local n = #row
		row[n + 1], row[n + 2], row[n + 3], row[n + 4], row[n + 5] = ml or 0, ms or 0, mp or 0, mi or 0, me or 0
		row[n + 6], row[n + 7], row[n + 8], row[n + 9], row[n + 10] = el or 0, es or 0, ep or 0, ei or 0, ee or 0
	end
	file:write(VFS.PackF32(row))
	file:flush() -- the dump widget quits the engine at the last frame; nothing may stay buffered
end

function widget:GameOver()
	stop()
end

function widget:Shutdown()
	stop()
end
