local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "AdvPlayersList Game Info",
		desc = "BAR Rewind: replay time, speed and scrub bar, in the game info panel's place. Space play/pause, R reverse, Left/Right 10 s, Up/Down speed",
		author = "burnhamrobertp",
		date = "2026-10-20",
		license = "GNU GPL, v2 or later",
		layer = -3,
		enabled = true,
	}
end

-- Stands in for BAR's game info panel, which shows the engine's clock and speed: in playback those
-- are the session's, not the replay's. Docks on the player list stack the same way and keeps the
-- WG.displayinfo position API so neighbours still stack on it. The Replay Player gadget owns time;
-- this widget reads it and sends replay:<cmd> messages.

local GetParam, Send = Spring.GetGameRulesParam, Spring.SendLuaRulesMsg
local spGetViewGeometry, spGetMouseState = Spring.GetViewGeometry, Spring.GetMouseState
local mathFloor, mathMax, mathMin, mathAbs = math.floor, math.max, math.min, math.abs
local glColor, glTexture, glTexRect = gl.Color, gl.Texture, gl.TexRect

local MAX_SPEED = 64
local KEY_SPACE, KEY_R = 32, 114
local KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN = 276, 275, 273, 274
local rowHeight = 22

local playTex = ":l:" .. LUAUI_DIRNAME .. "Images/music/play.png"
local pauseTex = ":l:" .. LUAUI_DIRNAME .. "Images/music/pause.png"
local backTex = ":l:" .. LUAUI_DIRNAME .. "Images/backward.dds"
local forwardTex = ":l:" .. LUAUI_DIRNAME .. "Images/forward.dds"

local vsx, vsy = spGetViewGeometry()
local widgetScale = 1
local top, left, bottom, right = 0, 0, 0, 0
local advplayerlistPos = {}
local positionCheckTime = 0
local POSITION_CHECK_INTERVAL = 0.05

local font, elementCorner, RectRound, UiElement, UiSliderKnob
local guishaderList
local buttons = {}
local order = { "back", "playpause", "forward" }
local textX = 0
local slider = { 0, 0, 0, 0 }
local dragging = false

local function state()
	return GetParam("replay_t") or 0, GetParam("replay_first") or 0, GetParam("replay_last") or 1,
		(GetParam("replay_playing") or 0) == 1, GetParam("replay_speed") or 1
end

local function clock(frame)
	local s = mathFloor(frame / 30)

	return string.format("%d:%02d", mathFloor(s / 60), s % 60)
end

local function inRect(x, y, r)
	return x >= r[1] and x <= r[3] and y >= r[2] and y <= r[4]
end

local function layout()
	local padding = mathFloor(2.5 * widgetScale)
	local size = mathFloor(rowHeight * widgetScale) - padding * 2
	local y = top - padding - size
	local x = left + padding * 3
	for _, name in ipairs(order) do
		buttons[name] = { x, y, x + size, y + size }
		x = x + size + padding
	end
	textX = x + padding * 2
	local rowBottom = bottom + padding
	slider = { left + padding * 4, rowBottom + size * 0.3, right - padding * 4, rowBottom + size * 0.7 }
end

local function refreshGuishader()
	if not WG.guishader then return end
	if guishaderList then guishaderList = gl.DeleteList(guishaderList) end
	guishaderList = gl.CreateList(function()
		RectRound(left, bottom, right, top, elementCorner, 1, 0, 0, 1)
	end)
	WG.guishader.InsertDlist(guishaderList, "displayinfo", true)
end

local function updatePosition(force)
	local prevPos = advplayerlistPos
	if WG.unittotals ~= nil then
		advplayerlistPos = WG.unittotals.GetPosition()
	elseif WG.music ~= nil then
		advplayerlistPos = WG.music.GetPosition()
	elseif WG.advplayerlist_api then
		advplayerlistPos = WG.advplayerlist_api.GetPosition()
	else
		local scale = (vsy / 880) * (1 + (Spring.GetConfigFloat("ui_scale", 1) - 1) / 1.25)
		advplayerlistPos = { 0, vsx - (220 * scale), 0, vsx, scale }
	end
	if not advplayerlistPos or advplayerlistPos[5] == nil then return end
	left = advplayerlistPos[2]
	bottom = advplayerlistPos[1]
	right = advplayerlistPos[4]
	top = math.ceil(advplayerlistPos[1] + (2 * rowHeight * advplayerlistPos[5]))
	widgetScale = advplayerlistPos[5]
	if force or prevPos[1] ~= advplayerlistPos[1] or prevPos[2] ~= advplayerlistPos[2] or prevPos[5] ~= advplayerlistPos[5] then
		widget:ViewResize()
	end
end

function widget:ViewResize()
	vsx, vsy = spGetViewGeometry()
	font = WG.fonts.getFont()
	elementCorner = WG.FlowUI.elementCorner
	RectRound = WG.FlowUI.Draw.RectRound
	UiElement = WG.FlowUI.Draw.Element
	UiSliderKnob = WG.FlowUI.Draw.SliderKnob
	layout()
	refreshGuishader()
end

function widget:Initialize()
	widget:ViewResize()
	updatePosition(true)
	WG.displayinfo = {}
	WG.displayinfo.GetPosition = function()
		return { top, left, bottom, right, widgetScale }
	end
	Spring.SendCommands("fps 0")
	Spring.SendCommands("clock 0")
	Spring.SendCommands("speed 0")
end

function widget:Shutdown()
	if WG.guishader then WG.guishader.RemoveDlist("displayinfo") end
	if guishaderList then gl.DeleteList(guishaderList) end
	Spring.SendCommands("fps 1")
	Spring.SendCommands("clock 1")
	Spring.SendCommands("speed 1")
	WG.displayinfo = nil
end

function widget:Update(dt)
	positionCheckTime = positionCheckTime + dt
	if positionCheckTime >= POSITION_CHECK_INTERVAL then
		positionCheckTime = 0
		updatePosition()
	end
end

-- replay control -----------------------------------------------------------------------------------

local function seekTo(mx)
	local _, first, last = state()
	local f = mathMax(0, mathMin(1, (mx - slider[1]) / (slider[3] - slider[1])))
	Send("replay:seek " .. mathFloor(first + f * (last - first)))
end

-- << and >>: play that way at 1x, or twice as fast when already playing that way
local function faster(direction)
	local _, _, _, playing, speed = state()
	if not playing or (speed > 0) ~= (direction > 0) then
		Send("replay:speed " .. direction)
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

local function drawSlider(f)
	local px, py, sx, sy = slider[1], slider[2], slider[3], slider[4]
	local cs = (sy - py) * 0.25
	RectRound(px, py, sx, sy, cs, 1, 1, 1, 1, { 1, 1, 1, 0.1 }, { 1, 1, 1, 0 })
	RectRound(px, py, sx, sy, cs, 1, 1, 1, 1, { 0.1, 0.1, 0.1, 0.22 }, { 0.9, 0.9, 0.9, 0.22 })
	local kx = px + (sx - px) * f
	if kx > px + cs then
		RectRound(px, py, kx, sy, cs, 1, 1, 1, 1, { 0.7, 0.7, 0.7, 0.4 }, { 1, 1, 1, 0.5 })
	end
	UiSliderKnob(kx, (py + sy) / 2, (sy - py) * 0.85)
end

function widget:DrawScreen()
	if Spring.IsGUIHidden() then return end
	local t, first, last, playing, speed = state()
	local mx, my = spGetMouseState()
	local padding2 = mathFloor(2.5 * widgetScale)

	UiElement(left, bottom, right, top, 1, 0, 0, 1, 1, 1, 0, 1, nil, nil, nil, nil)

	local textures = {
		back = backTex,
		playpause = playing and pauseTex or playTex,
		forward = forwardTex,
	}
	for _, name in ipairs(order) do
		local b = buttons[name]
		local active = playing and ((name == "back" and speed < 0) or (name == "forward" and speed > 0))
		if active or inRect(mx, my, b) then
			RectRound(b[1], b[2], b[3], b[4], (b[4] - b[2]) * 0.2, 1, 1, 1, 1, { 1, 1, 1, active and 0.18 or 0.1 })
		end
		glColor(1, 1, 1, 1)
		glTexture(textures[name])
		glTexRect(b[1] + padding2, b[2] + padding2, b[3] - padding2, b[4] - padding2)
		glTexture(false)
	end

	local textsize = 11 * widgetScale * math.clamp(1 + ((1 - (vsy / 1200)) * 0.4), 1, 1.15)
	local titleColor, valueColor = "\255\210\210\210", "\255\245\245\245"
	local rowBottom = top - rowHeight * widgetScale
	local y = rowBottom + (0.48 * rowHeight * widgetScale) - (textsize * 0.35)
	local speedText = (speed < 0 and "-x" or "x") .. string.format("%.2f", mathAbs(speed))
	font:Begin(true)
	font:SetOutlineColor(0.15, 0.15, 0.15, 0.8)
	font:Print(valueColor .. clock(t) .. titleColor .. " / " .. clock(last), textX, y, textsize, "no")
	font:Print(titleColor .. (playing and "" or "paused ") .. valueColor .. speedText, right - 10 * widgetScale, y, textsize, "ron")
	font:End()

	drawSlider((t - first) / mathMax(last - first, 1))
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
	local reach = (slider[4] - slider[2]) * 1.5
	if inRect(mx, my, { slider[1], slider[2] - reach, slider[3], slider[4] + reach }) then
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
