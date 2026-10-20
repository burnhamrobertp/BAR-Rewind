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
-- BAR's chat widget shows it like any other message. Lines already printed stay after a seek back,
-- and print again when the replay reaches them again.

local M = VFS.Include("replay/meta.lua")
local chat = M.chat or {}
local GetParam = Spring.GetGameRulesParam
local cursor = 1

local function line(m)
	local prefix = m.channel == "allies" and "Allies: " or m.channel == "spectators" and "Spectators: " or ""
	if m.spec then return "[" .. m.name .. "] " .. prefix .. m.text end

	return "<" .. m.name .. "> " .. prefix .. m.text
end

-- index of the first message after t
local function firstAfter(t)
	local a, b = 1, #chat + 1
	while a < b do
		local mid = math.floor((a + b) / 2)
		if chat[mid].f <= t then a = mid + 1 else b = mid end
	end

	return a
end

function widget:Initialize()
	if #chat == 0 then widgetHandler:RemoveWidget() end
end

function widget:Update()
	local t = GetParam("replay_t")
	if not t then return end
	if cursor > 1 and chat[cursor - 1].f > t then cursor = firstAfter(t) end
	while cursor <= #chat and chat[cursor].f <= t do
		Spring.Echo(line(chat[cursor]))
		cursor = cursor + 1
	end
end
