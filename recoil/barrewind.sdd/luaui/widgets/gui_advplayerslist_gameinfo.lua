local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "AdvPlayersList Game Info",
		desc = "BAR Rewind: the replay's time and speed, in the game info panel's place",
		author = "burnhamrobertp",
		date = "2026-10-20",
		license = "GNU GPL, v2 or later",
		layer = -3,
		enabled = true,
	}
end

-- Stands in for BAR's game info panel, which shows the engine's clock and speed: in playback those
-- are the session's, not the replay's. Docks on the player list stack the same way and keeps the
-- WG.displayinfo position API so neighbours still stack on it. The controls are Replay Timeline's.

local GetParam = Spring.GetGameRulesParam
local spGetViewGeometry = Spring.GetViewGeometry
local mathFloor, mathAbs = math.floor, math.abs

local widgetHeight = 22
local vsx, vsy = spGetViewGeometry()
local widgetScale = 1
local top, left, bottom, right = 0, 0, 0, 0
local advplayerlistPos = {}
local positionCheckTime = 0
local POSITION_CHECK_INTERVAL = 0.05

local font, elementCorner, RectRound, UiElement
local guishaderList

local function clock(frame)
	local s = mathFloor(frame / 30)

	return string.format("%d:%02d", mathFloor(s / 60), s % 60)
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
	top = math.ceil(advplayerlistPos[1] + (widgetHeight * advplayerlistPos[5]))
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

function widget:DrawScreen()
	if Spring.IsGUIHidden() then return end
	local t = GetParam("replay_t") or 0
	local last = GetParam("replay_last") or 1
	local speed = GetParam("replay_speed") or 1
	UiElement(left, bottom, right, top, 1, 0, 0, 1, 1, 1, 0, 1, nil, nil, nil, nil)

	local textsize = 11 * widgetScale * math.clamp(1 + ((1 - (vsy / 1200)) * 0.4), 1, 1.15)
	local y = bottom + (0.48 * widgetHeight * widgetScale) - (textsize * 0.35)
	local speedText = (speed < 0 and "-x" or "x") .. string.format("%.2f", mathAbs(speed))
	font:Begin(true)
	font:SetOutlineColor(0.15, 0.15, 0.15, 0.8)
	font:Print("\255\245\245\245" .. clock(t) .. "\255\210\210\210 / " .. clock(last), left + 10 * widgetScale, y, textsize, "no")
	font:Print("\255\245\245\245" .. speedText, right - 10 * widgetScale, y, textsize, "ron")
	font:End()
end
