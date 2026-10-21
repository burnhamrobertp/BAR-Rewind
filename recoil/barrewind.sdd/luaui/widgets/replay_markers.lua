function widget:GetInfo()
	return {
		name = "Replay Map Marks",
		desc = "BAR Rewind: places the match's map points, lines and erases as the replay reaches them",
		author = "burnhamrobertp",
		license = "GPL v2",
		layer = 10002,
		enabled = true,
	}
end

-- Reads replay/meta.lua's markers list (written by `bake export-lua`), in sim-frame order, and
-- applies each through the engine's marker API under the player who made it, so the marks, BAR's
-- ping effects and the chat notices are the game's own. Once a seek, drag or reverse playback is
-- over, the map is cleared and only the marks still standing at the new time are placed again, so
-- marks erased in between never fire their effects.

local M = VFS.Include("replay/meta.lua")
local marks = M.markers or {}
local AddPoint, AddLine, Erase = Spring.MarkerAddPoint, Spring.MarkerAddLine, Spring.MarkerErasePosition
local GetParam = Spring.GetGameRulesParam
local players = {}
local cursor = 1
-- a seek, drag or reverse playback redraws the map once, when it is over
local shift = VFS.Include("LuaUI/replay_shift.lua")()

local function apply(m)
	local player = players[m.name] or Spring.GetMyPlayerID()
	if m.type == "point" then
		AddPoint(m.x, m.y, m.z, m.label, true, player)
	elseif m.type == "line" then
		AddLine(m.x, m.y, m.z, m.x2, m.y2, m.z2, true, player)
	elseif m.type == "erase" then
		Erase(m.x, m.y, m.z, nil, true, player, false)
	end
end

local ERASE_RADIUS2 = 100 * 100

local function clear()
	Spring.SendCommands("clearmapmarks")
	if Script.LuaUI("ClearMapMarks") then Script.LuaUI.ClearMapMarks() end
	cursor = 1
end

-- the engine's erase rule: marks within its radius made by the same side, spectator or player, a
-- line counting by its first point
local function erases(e, m)
	local dx, dz = e.x - m.x, e.z - m.z

	return m.spec == e.spec and dx * dx + dz * dz < ERASE_RADIUS2
end

-- clears the map and places the points and lines made before t that no erase before t removed
local function rebuild(t)
	clear()
	local standing = {}
	while cursor <= #marks and marks[cursor].f <= t do
		local m = marks[cursor]
		if m.type == "erase" then
			for i = #standing, 1, -1 do
				if erases(m, standing[i]) then table.remove(standing, i) end
			end
		else
			standing[#standing + 1] = m
		end
		cursor = cursor + 1
	end
	for _, m in ipairs(standing) do apply(m) end
end

function widget:Initialize()
	if #marks == 0 then widgetHandler:RemoveWidget() end
	for _, id in ipairs(Spring.GetPlayerList()) do
		local name = Spring.GetPlayerInfo(id, false)
		if name then players[name] = id end
	end
end

function widget:Update()
	local t = GetParam("replay_t")
	if not t then return end
	local state = shift(t)
	if state == "shifting" then return end
	if state == "settled" then rebuild(t) end
	while cursor <= #marks and marks[cursor].f <= t do
		apply(marks[cursor])
		cursor = cursor + 1
	end
end
