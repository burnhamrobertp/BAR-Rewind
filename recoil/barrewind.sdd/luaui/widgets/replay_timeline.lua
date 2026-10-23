local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "Replay Timeline",
		desc = "BAR Rewind: play/pause, rewind, fast-forward and a scrub bar with time marks, along the bottom of the screen. Space play/pause, R reverse; over the timeline, Left/Right 10 s and Up/Down speed",
		author = "burnhamrobertp",
		date = "2026-10-20",
		license = "GNU GPL, v2 or later",
		layer = -2,
		enabled = true,
	}
end

-- Sits along the bottom edge between BAR's unit info panel (left) and player list (right), centred
-- in the space between them, at the UI scale the player list uses. The Replay Player gadget owns
-- time; this widget reads it and sends replay:<cmd> messages.

local GetParam, Send = Spring.GetGameRulesParam, Spring.SendLuaRulesMsg
local spGetViewGeometry, spGetMouseState = Spring.GetViewGeometry, Spring.GetMouseState
local mathFloor, mathMax, mathMin, mathAbs = math.floor, math.max, math.min, math.abs
local glColor, glTexture, glTexRect = gl.Color, gl.Texture, gl.TexRect

local MAX_SPEED = 64
local KEY_SPACE, KEY_R = 32, 114
local KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN = 276, 275, 273, 274
local HEIGHT = 40
-- time marks every this many seconds, the first that leaves room for its labels
local MARK_STEPS = { 10, 30, 60, 120, 300, 600, 900, 1800, 3600 }

local playTex = ":l:" .. LUAUI_DIRNAME .. "Images/music/play.png"
local pauseTex = ":l:" .. LUAUI_DIRNAME .. "Images/music/pause.png"
local nextTex = ":l:" .. LUAUI_DIRNAME .. "Images/music/next.png"

local vsx, vsy = spGetViewGeometry()
local scale = 1
local left, bottom, right, top = 0, 0, 0, 0
local positionCheck = 0

local font, elementCorner, RectRound, UiElement, UiSliderKnob
local guishaderList
local buttons = {}
local order = { "back", "playpause", "forward" }
local slider = { 0, 0, 0, 0 }
local textRight = 0
local dragging = false
local laidOut = nil

-- frames other widgets point out on the timeline, per widget:
-- WG.replay_timeline.setMarks(owner, { { f = frame, color = { r, g, b, a }, text = tooltip }, ... })
local marksBy = {}

local function setMarks(owner, marks)
	marksBy[owner] = marks
end

local function state()
	return GetParam("replay_t") or 0, GetParam("replay_first") or 0, GetParam("replay_last") or 1,
		(GetParam("replay_playing") or 0) == 1, GetParam("replay_speed") or 1
end

local clock = VFS.Include("LuaUI/replay_clock.lua")

local function inRect(x, y, r)
	return x >= r[1] and x <= r[3] and y >= r[2] and y <= r[4]
end

local function textSize()
	return 13 * scale
end

-- the room between BAR's unit info panel and player list, as their own position APIs report them
local function space()
	local listScale = (vsy / 880) * (1 + (Spring.GetConfigFloat("ui_scale", 1) - 1) / 1.25)
	local from, to = 0, vsx
	if WG.info and WG.info.getPosition then
		local w = WG.info.getPosition()
		if w then from = w * vsx end
	end
	local pos = WG.advplayerlist_api and WG.advplayerlist_api.GetPosition and WG.advplayerlist_api.GetPosition()
	if pos and pos[2] then
		to = pos[2]
		listScale = pos[5] or listScale
	end

	return from, to, listScale
end

local function refreshGuishader()
	if not WG.guishader then return end
	if guishaderList then guishaderList = gl.DeleteList(guishaderList) end
	guishaderList = gl.CreateList(function()
		RectRound(left, bottom, right, top, elementCorner, 1, 1, 0, 0)
	end)
	WG.guishader.InsertDlist(guishaderList, "replay_timeline", true)
end

local function addTooltips()
	if not WG.tooltip then return end
	local keys = "\255\200\200\200"
	local white = "\255\255\255\255"
	WG.tooltip.AddTooltip("replay_back", buttons.back, "2x backwards, again to double\n" .. keys .. "R" .. white .. "  reverse direction\n" .. keys .. "Left" .. white .. "  skip back 10 s (over the timeline)", nil, "Rewind")
	WG.tooltip.AddTooltip("replay_playpause", buttons.playpause, "Play is 1x forward\n" .. keys .. "Space" .. white .. "  play / pause\n" .. keys .. "Up / Down" .. white .. "  double / halve speed (over the timeline)", nil, "Play / Pause")
	WG.tooltip.AddTooltip("replay_forward", buttons.forward, "2x forwards, again to double\n" .. keys .. "Right" .. white .. "  skip ahead 10 s (over the timeline)", nil, "Fast forward")
	WG.tooltip.AddTooltip("replay_timeline", { slider[1], bottom, slider[3], top }, "Drag to seek", nil, "Timeline")
end

local function removeTooltips()
	if not WG.tooltip then return end
	for _, name in ipairs({ "replay_back", "replay_playpause", "replay_forward", "replay_timeline" }) do
		WG.tooltip.RemoveTooltip(name)
	end
end

local function layout()
	local from, to, s = space()
	scale = s
	local gap = mathFloor(24 * scale)
	local width = mathMax(0, (to - from) - gap * 2)
	local height = mathFloor(HEIGHT * scale)
	left = mathFloor(from + ((to - from) - width) / 2)
	right = left + width
	bottom, top = 0, height
	local key = table.concat({ left, right, top, scale }, ":")
	if key == laidOut then return end
	laidOut = key

	local pad = mathFloor(6 * scale)
	local size = mathFloor(26 * scale)
	local y = mathFloor((top + bottom - size) / 2)
	local x = left + pad * 2
	for _, name in ipairs(order) do
		buttons[name] = { x, y, x + size, y + size }
		x = x + size + mathFloor(pad / 2)
	end
	local longest = clock(GetParam("replay_last") or 0) .. " / " .. clock(GetParam("replay_last") or 0) .. "    -x64.00"
	textRight = mathFloor(font:GetTextWidth(longest) * textSize()) + pad * 3
	-- the bar sits in the upper half; the time marks go under it
	local barHeight = mathMax(4, mathFloor(6 * scale))
	local barY = bottom + mathFloor(height * 0.62)
	slider = { x + pad * 3, barY - barHeight / 2, right - textRight, barY + barHeight / 2 }
	refreshGuishader()
	removeTooltips()
	addTooltips()
end

function widget:ViewResize()
	vsx, vsy = spGetViewGeometry()
	font = WG.fonts.getFont()
	elementCorner = WG.FlowUI.elementCorner
	RectRound = WG.FlowUI.Draw.RectRound
	UiElement = WG.FlowUI.Draw.Element
	UiSliderKnob = WG.FlowUI.Draw.SliderKnob
	laidOut = nil
	layout()
end

function widget:Initialize()
	widget:ViewResize()
	WG.replay_timeline = { setMarks = setMarks }
end

function widget:Shutdown()
	WG.replay_timeline = nil
	removeTooltips()
	if WG.guishader then WG.guishader.RemoveDlist("replay_timeline") end
	if guishaderList then gl.DeleteList(guishaderList) end
end

function widget:Update(dt)
	positionCheck = positionCheck + dt
	if positionCheck >= 0.1 then
		positionCheck = 0
		layout()
	end
end

-- replay control -----------------------------------------------------------------------------------

local function seekTo(mx)
	local _, first, last = state()
	local f = mathMax(0, mathMin(1, (mx - slider[1]) / (slider[3] - slider[1])))
	Send("replay:seek " .. mathFloor(first + f * (last - first)))
end

-- play is always 1x forward; << and >> start at 2x their way and double from there
local function faster(direction)
	local _, _, _, playing, speed = state()
	if not playing or (speed > 0) ~= (direction > 0) then
		Send("replay:speed " .. 2 * direction)
	else
		Send("replay:speed " .. mathMin(mathAbs(speed) * 2, MAX_SPEED) * direction)
	end
end

local function press(name)
	local _, _, _, playing = state()
	if name == "back" then
		faster(-1)
	elseif name == "playpause" then
		Send(playing and "replay:pause" or "replay:play")
	elseif name == "forward" then
		faster(1)
	end
end

-- drawing -------------------------------------------------------------------------------------------

-- the first step (in frames) whose marks are at least `gap` pixels apart and that divides `within`
local function stepFor(px, sx, span, gap, within)
	for _, s in ipairs(MARK_STEPS) do
		local frames = s * 30
		if (sx - px) * frames / span >= gap and (not within or within % frames == 0) then return frames end
	end

	return within or MARK_STEPS[#MARK_STEPS] * 30
end

-- labelled marks with room for three labels between them (5:00, 10:00 on most games), unlabelled
-- ticks between those as fine as stays readable
local function drawMarks(first, last)
	local span = mathMax(last - first, 1)
	local px, sx = slider[1], slider[3]
	local labelSize = 10 * scale
	local labelStep = stepFor(px, sx, span, font:GetTextWidth("00:00") * labelSize * 3)
	local tickStep = stepFor(px, sx, span, 24 * scale, labelStep)
	local y = slider[2] - mathFloor(3 * scale)
	local function xOf(m) return mathFloor(px + (sx - px) * (m - first) / span) end
	for m = tickStep, last, tickStep do
		if m > first then
			local major = m % labelStep == 0
			local len = (major and 4 or 2) * scale
			RectRound(xOf(m) - 0.5, y - len, xOf(m) + 0.5, y, 0, 0, 0, 0, 0, { 1, 1, 1, major and 0.45 or 0.2 })
		end
	end
	font:Begin(true)
	font:SetOutlineColor(0.15, 0.15, 0.15, 0.8)
	for m = labelStep, last, labelStep do
		if m > first then
			font:Print("\255\170\170\170" .. clock(m), xOf(m), y - 4 * scale - labelSize * 0.95, labelSize, "co")
		end
	end
	font:End()
end

local function markX(m, first, last)
	return slider[1] + (slider[3] - slider[1]) * (m.f - first) / mathMax(last - first, 1)
end

-- the mark under the mouse, if any
local function markAt(mx, my, first, last)
	if my < slider[2] - 4 * scale or my > slider[4] + 14 * scale then return nil end
	local best, bestDist = nil, 5 * scale
	for _, marks in pairs(marksBy) do
		for _, m in ipairs(marks) do
			local d = mathAbs(markX(m, first, last) - mx)
			if d <= bestDist then best, bestDist = m, d end
		end
	end

	return best
end

-- per mark, a coloured line through the bar with a flag on top
local function drawEventMarks(first, last, hovered)
	local w = mathMax(1, mathFloor(scale))
	local flag = mathFloor(4 * scale)
	for _, marks in pairs(marksBy) do
		for _, m in ipairs(marks) do
			local x = mathFloor(markX(m, first, last))
			local c = m.color or { 1, 1, 1, 0.9 }
			local top = slider[4] + mathFloor((m == hovered and 14 or 10) * scale)
			RectRound(x - w, slider[2] - mathFloor(2 * scale), x + w, top, 0, 0, 0, 0, 0, c)
			RectRound(x - flag, top - flag * 2, x + flag, top, flag * 0.5, 1, 1, 1, 1, c)
		end
	end
end

local function drawSlider(f)
	local px, py, sx, sy = slider[1], slider[2], slider[3], slider[4]
	local cs = (sy - py) * 0.5
	RectRound(px, py, sx, sy, cs, 1, 1, 1, 1, { 1, 1, 1, 0.1 }, { 1, 1, 1, 0 })
	RectRound(px, py, sx, sy, cs, 1, 1, 1, 1, { 0.1, 0.1, 0.1, 0.22 }, { 0.9, 0.9, 0.9, 0.22 })
	local kx = px + (sx - px) * f
	if kx > px + cs then
		RectRound(px, py, kx, sy, cs, 1, 1, 1, 1, { 0.7, 0.7, 0.7, 0.4 }, { 1, 1, 1, 0.5 })
	end
	UiSliderKnob(kx, (py + sy) / 2, (sy - py) * 1.6)
end

function widget:DrawScreen()
	if Spring.IsGUIHidden() or right - left < 100 then return end
	local t, first, last, playing, speed = state()
	local mx, my = spGetMouseState()
	local inner = mathFloor(3 * scale)

	UiElement(left, bottom, right, top, 1, 1, 0, 0, 1, 1, 0, 1, nil, nil, nil, nil)

	for _, name in ipairs(order) do
		local b = buttons[name]
		local active = playing and mathAbs(speed) > 1 and ((name == "back" and speed < 0) or (name == "forward" and speed > 0))
		if active or inRect(mx, my, b) then
			RectRound(b[1], b[2], b[3], b[4], (b[4] - b[2]) * 0.2, 1, 1, 1, 1, { 1, 1, 1, active and 0.18 or 0.1 })
		end
		glColor(1, 1, 1, 1)
		if name == "playpause" then
			glTexture(playing and pauseTex or playTex)
			glTexRect(b[1] + inner, b[2] + inner, b[3] - inner, b[4] - inner)
		else
			-- the music player's skip icon, mirrored for rewind
			glTexture(nextTex)
			local s1, s2 = 0, 1
			if name == "back" then s1, s2 = 1, 0 end
			glTexRect(b[1] + inner, b[2] + inner, b[3] - inner, b[4] - inner, s1, 0, s2, 1)
		end
		glTexture(false)
	end

	drawMarks(first, last)
	drawSlider((t - first) / mathMax(last - first, 1))
	local hovered = markAt(mx, my, first, last)
	drawEventMarks(first, last, hovered)
	if hovered and hovered.text and WG.tooltip then
		WG.tooltip.ShowTooltip("replay_timeline_mark", hovered.text, nil, nil, clock(hovered.f))
	end

	local size = textSize()
	local y = (top + bottom) / 2 - size * 0.35
	local speedText = (speed < 0 and "-x" or "x") .. string.format("%.2f", mathAbs(speed))
	font:Begin(true)
	font:SetOutlineColor(0.15, 0.15, 0.15, 0.8)
	font:Print("\255\245\245\245" .. clock(t) .. "\255\170\170\170 / " .. clock(last) .. "    \255\245\245\245" .. speedText, right - mathFloor(8 * scale), y, size, "ro")
	font:End()
end

-- input ---------------------------------------------------------------------------------------------

function widget:IsAbove(mx, my)
	return inRect(mx, my, { left, bottom, right, top })
end

function widget:MousePress(mx, my, button)
	if button ~= 1 or Spring.IsGUIHidden() then return false end
	for _, name in ipairs(order) do
		if inRect(mx, my, buttons[name]) then
			press(name)
			return true
		end
	end
	-- a mark clicked jumps to its frame
	local _, first, last = state()
	local m = markAt(mx, my, first, last)
	if m then
		Send("replay:seek " .. m.f)
		return true
	end
	if inRect(mx, my, { slider[1] - 6 * scale, bottom, slider[3] + 6 * scale, top }) then
		dragging = true
		seekTo(mx)
		return true
	end

	return inRect(mx, my, { left, bottom, right, top })
end

function widget:MouseMove(mx)
	if dragging then seekTo(mx) end
end

function widget:MouseRelease()
	dragging = false
	return false
end

function widget:KeyPress(key)
	if WG.chat and WG.chat.isInputActive and WG.chat.isInputActive() then return false end
	-- the arrows scroll the camera everywhere else
	local arrow = key == KEY_LEFT or key == KEY_RIGHT or key == KEY_UP or key == KEY_DOWN
	if arrow and not widget:IsAbove(spGetMouseState()) then return false end
	local t, _, _, playing, speed = state()
	if key == KEY_SPACE then
		Send(playing and "replay:pause" or "replay:play")
	elseif key == KEY_R then
		Send("replay:speed " .. -speed)
	elseif key == KEY_LEFT then
		Send("replay:seek " .. (t - 300))
	elseif key == KEY_RIGHT then
		Send("replay:seek " .. (t + 300))
	elseif key == KEY_UP then
		Send("replay:speed " .. mathMin(mathAbs(speed) * 2, MAX_SPEED) * (speed < 0 and -1 or 1))
	elseif key == KEY_DOWN then
		Send("replay:speed " .. mathMax(mathAbs(speed) / 2, 0.25) * (speed < 0 and -1 or 1))
	else
		return false
	end

	return true
end
