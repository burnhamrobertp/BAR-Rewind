function widget:GetInfo()
	return {
		name = "Replay Chat",
		desc = "BAR Rewind: feeds the match's chat into BAR's chat as the replay reaches it",
		author = "burnhamrobertp",
		license = "GPL v2",
		layer = 10001,
		enabled = true,
	}
end

-- Reads replay/meta.lua's chat list (written by `bake export-lua`), each entry stamped with its sim
-- frame, and prints each line in the form the engine prints chat as the replay time passes it, so
-- BAR's chat widget shows it like any other message. Notices go out as relayed lobby lines
-- ("> <name> text"), which BAR's chat shows as game messages: one where the pre-match chat ends,
-- and one whenever the timeline jumps or is rewound, so the lines after it read as replayed.

local M = VFS.Include("replay/meta.lua")
local chat = M.chat or {}
local GetParam = Spring.GetGameRulesParam
local floor = math.floor
local NOTICE = "> <BAR Rewind> "
-- forward jumps shorter than this are playback at speed, not a seek
local JUMP = 600
-- a shift (seek, drag, reverse playback) is over once time has moved only forward, in steps no
-- bigger than playback makes, for this long
local SETTLE = 1
-- shifts that end within this many frames of where they began are not worth a line
local MIN_SHIFT = 30
local GetTimer, DiffTimers = Spring.GetTimer, Spring.DiffTimers

local cursor = 1
local last_t = nil
local shift_from = nil
local last_jump = nil

local function clock(frame)
	local s = floor(frame / 30)

	return string.format("%d:%02d", floor(s / 60), s % 60)
end

local function line(m)
	local prefix = m.channel == "allies" and "Allies: " or m.channel == "spectators" and "Spectators: " or ""
	if m.spec then return "[" .. m.name .. "] " .. prefix .. m.text end

	return "<" .. m.name .. "> " .. prefix .. m.text
end

-- index of the first message after t
local function firstAfter(t)
	local a, b = 1, #chat + 1
	while a < b do
		local mid = floor((a + b) / 2)
		if chat[mid].f <= t then a = mid + 1 else b = mid end
	end

	return a
end

local function notice(from, to)
	Spring.Echo(NOTICE .. "Timeline " .. clock(from) .. " -> " .. clock(to))
end

function widget:Initialize()
	if #chat == 0 then widgetHandler:RemoveWidget() end
end

function widget:Update()
	local t = GetParam("replay_t")
	if not t then return end
	if last_t and (t < last_t or t - last_t > JUMP) then
		shift_from = shift_from or last_t
		last_jump = GetTimer()
	end
	last_t = t
	if shift_from then
		if DiffTimers(GetTimer(), last_jump) < SETTLE then return end
		if math.abs(t - shift_from) >= MIN_SHIFT then notice(shift_from, t) end
		shift_from = nil
	end
	if cursor > 1 and chat[cursor - 1].f > t then cursor = firstAfter(t) end
	while cursor <= #chat and chat[cursor].f <= t do
		local m = chat[cursor]
		Spring.Echo(line(m))
		local after = chat[cursor + 1]
		if m.pre and not (after and after.pre) then Spring.Echo(NOTICE .. "Match started") end
		cursor = cursor + 1
	end
end
