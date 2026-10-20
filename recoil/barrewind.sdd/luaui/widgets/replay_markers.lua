function widget:GetInfo()
	return {
		name = "Replay Map Marks",
		desc = "BAR Rewind: the match's map points, lines and erases at the replay time",
		author = "burnhamrobertp",
		license = "GPL v2",
		layer = 10002,
		enabled = true,
	}
end

-- Reads replay/meta.lua's markers list (written by `bake export-lua`), in sim-frame order, and
-- draws the marks itself: the engine's marker API fires BAR's map-mark effects and chat notices
-- for every add and erase, which a seek would spray across the map.

local M = VFS.Include("replay/meta.lua")
local marks = M.markers or {}
local GetParam, GetGroundHeight = Spring.GetGameRulesParam, Spring.GetGroundHeight
local WorldToScreen = Spring.WorldToScreenCoords
local ERASE_RADIUS2 = 100 * 100
local POLE, FONT = 60, 14

local live = {}
local cursor = 1
local last_t = nil

for _, m in ipairs(marks) do
	local team = not m.spec and M.teams[m.team]
	m.colour = team and team.color or { 0.85, 0.85, 0.85 }
	m.text = m.label ~= "" and (m.name .. ": " .. m.label) or m.name
end

local function near(x, z, m)
	local dx, dz = x - m.x, z - m.z
	if dx * dx + dz * dz <= ERASE_RADIUS2 then return true end
	if m.type ~= "line" then return false end
	dx, dz = x - m.x2, z - m.z2

	return dx * dx + dz * dz <= ERASE_RADIUS2
end

local function apply(m)
	if m.type == "erase" then
		for i = #live, 1, -1 do
			if near(m.x, m.z, live[i]) then table.remove(live, i) end
		end
	else
		live[#live + 1] = m
	end
end

function widget:Initialize()
	if #marks == 0 then widgetHandler:RemoveWidget() end
end

function widget:Update()
	local t = GetParam("replay_t")
	if not t then return end
	if last_t and t < last_t then
		live = {}
		cursor = 1
	end
	last_t = t
	while cursor <= #marks and marks[cursor].f <= t do
		apply(marks[cursor])
		cursor = cursor + 1
	end
end

local function drawLines()
	for _, m in ipairs(live) do
		gl.Color(m.colour[1], m.colour[2], m.colour[3], 0.9)
		if m.type == "line" then
			gl.Vertex(m.x, GetGroundHeight(m.x, m.z) + 2, m.z)
			gl.Vertex(m.x2, GetGroundHeight(m.x2, m.z2) + 2, m.z2)
		else
			local y = GetGroundHeight(m.x, m.z)
			gl.Vertex(m.x, y, m.z)
			gl.Vertex(m.x, y + POLE, m.z)
		end
	end
end

function widget:DrawWorld()
	if #live == 0 then return end
	gl.DepthTest(false)
	gl.LineWidth(2)
	gl.BeginEnd(GL.LINES, drawLines)
	for _, m in ipairs(live) do
		if m.type == "point" then
			gl.Color(m.colour[1], m.colour[2], m.colour[3], 0.9)
			gl.DrawGroundCircle(m.x, GetGroundHeight(m.x, m.z), m.z, 14, 16)
		end
	end
	gl.LineWidth(1)
	gl.DepthTest(true)
	gl.Color(1, 1, 1, 1)
end

function widget:DrawScreen()
	for _, m in ipairs(live) do
		if m.type == "point" then
			local sx, sy, sz = WorldToScreen(m.x, GetGroundHeight(m.x, m.z) + POLE, m.z)
			if sz and sz < 1 then
				gl.Color(m.colour[1], m.colour[2], m.colour[3], 1)
				gl.Text(m.text, sx, sy + 4, FONT, "oc")
			end
		end
	end
	gl.Color(1, 1, 1, 1)
end

local function drawMiniMapLines()
	for _, m in ipairs(live) do
		if m.type == "line" then
			gl.Color(m.colour[1], m.colour[2], m.colour[3], 0.9)
			gl.Vertex(m.x, m.z)
			gl.Vertex(m.x2, m.z2)
		end
	end
end

function widget:DrawInMiniMap(sx, sy)
	if #live == 0 then return end
	gl.PushMatrix()
	gl.Translate(0, sy, 0)
	gl.Scale(sx / Game.mapSizeX, -sy / Game.mapSizeZ, 1)
	gl.LineWidth(2)
	gl.BeginEnd(GL.LINES, drawMiniMapLines)
	gl.LineWidth(1)
	local s = Game.mapSizeX / sx * 4
	for _, m in ipairs(live) do
		if m.type == "point" then
			gl.Color(m.colour[1], m.colour[2], m.colour[3], 1)
			gl.Rect(m.x - s, m.z - s, m.x + s, m.z + s)
		end
	end
	gl.PopMatrix()
	gl.Color(1, 1, 1, 1)
end
