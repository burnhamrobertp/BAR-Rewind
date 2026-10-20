function widget:GetInfo()
	return {
		name = "Replay Chat",
		desc = "BAR Rewind: the match's chat and map points up to the replay time, names in team colours",
		author = "burnhamrobertp",
		license = "GPL v2",
		layer = 10001,
		enabled = true,
	}
end

-- Reads replay/meta.lua's chat and markers lists (written by `bake export-lua`), each entry
-- stamped with its sim frame. Stands in for BAR's chat widget, which only shows players that are
-- in the game: in playback the replay's players are not.

local M = VFS.Include("replay/meta.lua")
local GetParam = Spring.GetGameRulesParam
local floor, char = math.floor, string.char
local LINES, FONT, GAP = 12, 15, 4

local function clock(frame)
	local s = floor(frame / 30)
	return string.format("%d:%02d", floor(s / 60), s % 60)
end

local function rgb(r, g, b)
	return char(255, math.max(1, floor(r * 255)), math.max(1, floor(g * 255)), math.max(1, floor(b * 255)))
end

local GREY, WHITE, SPEC = rgb(0.6, 0.6, 0.6), rgb(1, 1, 1), rgb(0.75, 0.75, 0.75)

local function nameColour(m)
	if m.spec or m.team < 0 then return SPEC end
	local team = M.teams[m.team]
	if not team then return WHITE end
	return rgb(team.color[1], team.color[2], team.color[3])
end

local events = {}
for _, m in ipairs(M.chat or {}) do
	local tag = m.channel == "allies" and "(a) " or m.channel == "spectators" and "(s) " or ""
	events[#events + 1] = { f = m.f, text = nameColour(m) .. m.name .. ": " .. WHITE .. tag .. m.text }
end
for _, m in ipairs(M.markers or {}) do
	if m.type == "point" then
		local label = m.label ~= "" and m.label or "Look here!"
		events[#events + 1] = { f = m.f, text = nameColour(m) .. m.name .. " " .. GREY .. "added point: " .. WHITE .. label }
	end
end
table.sort(events, function(a, b) return a.f < b.f end)
for _, e in ipairs(events) do e.text = GREY .. clock(e.f) .. "  " .. e.text end

-- index of the last event at or before t
local function lastAt(t)
	local a, b = 0, #events
	while a < b do
		local mid = floor((a + b + 1) / 2)
		if events[mid].f <= t then a = mid else b = mid - 1 end
	end

	return a
end

function widget:Initialize()
	-- the engine's own console would print over the screen now that BAR's chat widget is out
	Spring.SendCommands("console 0")
	if #events == 0 then widgetHandler:RemoveWidget() end
end

function widget:DrawScreen()
	local t = GetParam("replay_t")
	if not t then return end
	local last = lastAt(t)
	if last == 0 then return end
	local first = math.max(1, last - LINES + 1)
	local vsx, vsy = Spring.GetViewGeometry()
	local x, y = vsx * 0.01, vsy * 0.12

	gl.Color(0, 0, 0, 0.5)
	gl.Rect(x - 6, y - 6, x + vsx * 0.3, y + (last - first + 1) * (FONT + GAP) + 4)
	gl.Color(1, 1, 1, 1)
	for i = last, first, -1 do
		gl.Text(events[i].text, x, y, FONT, "o")
		y = y + FONT + GAP
	end
end
