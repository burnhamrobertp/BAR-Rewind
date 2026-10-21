function gadget:GetInfo()
	return {
		name = "Replay Eco",
		desc = "Drives every team's real resource counters (level, storage, income, expense, pull) from the parse's recording, so BAR's top bar, player list and eco stats show the game's economy at the replay time",
		author = "beyondbarb (MotionCorrect)",
		date = "2026-10-17",
		license = "GPL v2",
		layer = 1, -- after Replay Player (layer 0), which sets replay_t for the frame
		enabled = true,
	}
end

if not gadgetHandler:IsSyncedCode() then return end

-- replay/eco.bin is what lua/dump_replay_eco.lua recorded during the parse (the layout is described there).
-- The engine turns what AddTeamResource / UseTeamResource / UseUnitResource moved during the last
-- 30 frames into the per-second income, expense and pull that BAR's top bar shows (Team.cpp
-- ResetResourceState, run after the gadgets' GameFrame), so each frame this gadget moves 1/30 of the
-- recorded per-second figures and then pins the level. The replayed units still produce for real
-- (extractors, wind, BAR's converter gadget): that production is measured from the previous second
-- and taken off what is added, so the sum matches the recording.

local data = VFS.LoadFile("replay/eco.bin")
if not data or data:sub(1, 4) ~= "BBEC" then
	Spring.Echo("Replay Eco: no replay/eco.bin (parsed before the economy recording existed); the economy display stays blank")
	return
end
local U32, F32 = VFS.UnpackU32, VFS.UnpackF32
local fields, nteams = U32(data, 13), U32(data, 17)
local teams = U32(data, 21, nteams)
local vals = F32(data, 21 + 4 * nteams, -1)
local rowlen = 1 + fields * nteams
local nrows = math.floor(#vals / rowlen)
if nrows < 1 then
	Spring.Echo("Replay Eco: empty recording")
	return
end

local floor, max, min = math.floor, math.max, math.min
local GetParam = Spring.GetGameRulesParam
local GetRes, SetRes, AddRes, UseRes = Spring.GetTeamResources, Spring.SetTeamResource, Spring.AddTeamResource, Spring.UseTeamResource
local UseUnitRes, GetTeamUnits, ValidUnitID, GetUnitTeam = Spring.UseUnitResource, Spring.GetTeamUnits, Spring.ValidUnitID, Spring.GetUnitTeam
local SLOW = 30 -- TEAM_SLOWUPDATE_RATE

local function rowFrame(r) return vals[(r - 1) * rowlen + 1] end

-- the last row recorded at or before frame t
local function rowAt(t)
	local lo, hi = 1, nrows
	while lo < hi do
		local mid = floor((lo + hi + 1) / 2)
		if rowFrame(mid) <= t then lo = mid else hi = mid - 1 end
	end
	return lo
end

-- per team: what this gadget moved this window and the last one (add, use, pull for metal; the same for energy)
local cur, prev, unitOf, refreshAt = {}, {}, {}, {}
for i = 1, nteams do
	cur[i], prev[i], refreshAt[i] = { 0, 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0, 0 }, 0
end
local window = nil

-- a live unit of the team: pull is only counted through a unit
local function teamUnit(i, team, frame)
	local u = unitOf[i]
	if u and ValidUnitID(u) and GetUnitTeam(u) == team then return u end
	if frame < refreshAt[i] then return nil end
	refreshAt[i] = frame + SLOW
	u = GetTeamUnits(team)[1]
	unitOf[i] = u
	return u
end

-- one resource of one team for this frame; k = 1 (metal) or 4 (energy) indexes the tallies
local function drive(team, u, key, skey, tally, last, k, level, storage, pull, income, expense, prevPull, prevIncome, prevExpense)
	local own = max(0, prevIncome - last[k]) -- the replayed units' own production last second
	local add = max(0, income - own) / SLOW
	local ownUse = max(0, prevExpense - last[k + 1])
	local use = max(0, expense - ownUse) / SLOW
	local ownPull = max(0, prevPull - last[k + 2])
	local extra = max(0, max(0, pull - ownPull) / SLOW - use) -- pull beyond the expense: wanted but unpaid
	SetRes(team, skey, storage)
	SetRes(team, key, min(storage, level + use))
	if add > 0 then AddRes(team, key, add) end
	if u then
		if use > 0 then UseUnitRes(u, key, use) end
		if extra > 0 then
			SetRes(team, key, 0)
			UseUnitRes(u, key, extra) -- fails on purpose: counts as pull only
		end
		tally[k + 2] = tally[k + 2] + use + extra
	elseif use > 0 then
		UseRes(team, key, use) -- no unit left to pull through
	end
	SetRes(team, key, level)
	tally[k] = tally[k] + add
	tally[k + 1] = tally[k + 1] + use
end

-- Units under construction in the recording are finished units in the player (CreateUnit, then the build
-- progress is set), so they would produce and consume: wind, solar, extractors, upkeep. The engine runs all of
-- that only for activated units, so an unfinished unit is deactivated here through its script environment
-- (UnitScript.SetUnitValue(COB.ACTIVATION) is the one Lua path to the engine's flag) and activated again when
-- it finishes, as the engine does for activateWhenBuilt. On/off-able units are left alone: for those the call
-- becomes a CMD.ONOFF order and Replay Player already replays their recorded on/off state.
local CallAsUnit, SetUnitValue = Spring.UnitScript.CallAsUnit, Spring.UnitScript.SetUnitValue
local GetAllUnits, GetUnitHealth, GetUnitDefID = Spring.GetAllUnits, Spring.GetUnitHealth, Spring.GetUnitDefID
local ACTIVATION = COB and COB.ACTIVATION or 54
local onoffable, activateWhenBuilt = {}, {}
for id, ud in pairs(UnitDefs) do
	onoffable[id] = ud.onOffable or false
	activateWhenBuilt[id] = ud.activateWhenBuilt or false
end
local deactivated = {} -- [unitID] = true while this gadget holds it inactive
local SCAN = 15

local function setActive(u, on)
	CallAsUnit(u, SetUnitValue, ACTIVATION, on and 1 or 0)
end

local function scanBuilding(frame)
	if frame % SCAN ~= 0 then return end
	for _, u in ipairs(GetAllUnits()) do
		local _, _, _, _, build = GetUnitHealth(u)
		if build then
			if build < 1 then
				if not deactivated[u] then
					local def = GetUnitDefID(u)
					if def and not onoffable[def] then
						deactivated[u] = true
						setActive(u, false)
					end
				end
			elseif deactivated[u] then
				deactivated[u] = nil
				if activateWhenBuilt[GetUnitDefID(u)] then setActive(u, true) end
			end
		end
	end
end

function gadget:UnitDestroyed(u)
	deactivated[u] = nil
end

function gadget:Initialize()
	for i = 1, nteams do
		Spring.SetTeamShareLevel(teams[i], "metal", 1) -- no engine sharing of the pinned levels
		Spring.SetTeamShareLevel(teams[i], "energy", 1)
	end
	Spring.Echo("Replay Eco: " .. nrows .. " samples for " .. nteams .. " teams, frames " .. rowFrame(1) .. ".." .. rowFrame(nrows))
end

-- the levels pinned in GameFrame drift before the frame ends: the units' own production and BAR's gadgets
-- (converters) run after it, so they are pinned once more in GameFramePost, after everything else in the frame
local pinM, pinE, pinMS, pinES = {}, {}, {}, {}

function gadget:GameFramePost(frame)
	for i = 1, nteams do
		if pinM[i] then
			SetRes(teams[i], "ms", pinMS[i])
			SetRes(teams[i], "es", pinES[i])
			SetRes(teams[i], "m", pinM[i])
			SetRes(teams[i], "e", pinE[i])
		end
	end
end

function gadget:GameFrame(frame)
	scanBuilding(frame)
	local t = GetParam("replay_t")
	if not t then return end
	local w = floor((frame - 1) / SLOW)
	if w ~= window then
		window = w
		for i = 1, nteams do
			cur[i], prev[i] = prev[i], cur[i]
			local c = cur[i]
			for k = 1, 6 do c[k] = 0 end
		end
	end
	local r = rowAt(t)
	local base = (r - 1) * rowlen
	local base2, frac = base, 0
	if r < nrows then
		local f0, f1 = vals[base + 1], vals[base + rowlen + 1]
		if f1 > f0 then
			frac = max(0, min(1, (t - f0) / (f1 - f0)))
			base2 = base + rowlen
		end
	end
	for i = 1, nteams do
		local team = teams[i]
		local o, o2 = base + 1 + (i - 1) * fields, base2 + 1 + (i - 1) * fields
		local u = teamUnit(i, team, frame)
		local _, _, ppm, pim, pem = GetRes(team, "metal")
		if ppm then
			local ml = vals[o + 1] + (vals[o2 + 1] - vals[o + 1]) * frac
			drive(team, u, "m", "ms", cur[i], prev[i], 1, ml, vals[o + 2], vals[o + 3], vals[o + 4], vals[o + 5], ppm, pim, pem)
			local _, _, ppe, pie, pee = GetRes(team, "energy")
			local el = vals[o + 6] + (vals[o2 + 6] - vals[o + 6]) * frac
			drive(team, u, "e", "es", cur[i], prev[i], 4, el, vals[o + 7], vals[o + 8], vals[o + 9], vals[o + 10], ppe, pie, pee)
			pinM[i], pinMS[i], pinE[i], pinES[i] = ml, vals[o + 2], el, vals[o + 7]
		end
	end
end
