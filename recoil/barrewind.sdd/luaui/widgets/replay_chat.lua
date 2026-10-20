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

local cursor = 1
local last_t = nil
local rewound_from = nil

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
	if last_t then
		if t < last_t then
			rewound_from = rewound_from or last_t
		elseif rewound_from then
			-- the rewind is over once time stands still or moves forward again
			notice(rewound_from, t)
			rewound_from = nil
		elseif t - last_t > JUMP then
			notice(last_t, t)
		end
	end
	last_t = t
	if rewound_from then return end
	if cursor > 1 and chat[cursor - 1].f > t then cursor = firstAfter(t) end
	while cursor <= #chat and chat[cursor].f <= t do
		local m = chat[cursor]
		Spring.Echo(line(m))
		local after = chat[cursor + 1]
		if m.pre and not (after and after.pre) then Spring.Echo(NOTICE .. "Match started") end
		cursor = cursor + 1
	end
end
