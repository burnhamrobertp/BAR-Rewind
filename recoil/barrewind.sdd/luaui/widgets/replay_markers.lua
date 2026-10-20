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
-- applies each once through the engine's marker API under the player who made it, so the marks,
-- BAR's ping effects and the chat notices are the game's own. Marks are history: a seek back
-- leaves what was already placed.

local M = VFS.Include("replay/meta.lua")
local marks = M.markers or {}
local AddPoint, AddLine, Erase = Spring.MarkerAddPoint, Spring.MarkerAddLine, Spring.MarkerErasePosition
local GetParam = Spring.GetGameRulesParam
local players = {}
local cursor = 1

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
	while cursor <= #marks and marks[cursor].f <= t do
		apply(marks[cursor])
		cursor = cursor + 1
	end
end
