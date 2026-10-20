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
-- frame, and prints each line once, in the form the engine prints chat, when the replay time first
-- passes it. BAR's chat widget then shows it like any other message. Chat is history: a seek back
-- leaves what was already shown.

local M = VFS.Include("replay/meta.lua")
local chat = M.chat or {}
local GetParam = Spring.GetGameRulesParam
local shown = {}

local function line(m)
	local prefix = m.channel == "allies" and "Allies: " or m.channel == "spectators" and "Spectators: " or ""
	if m.spec then return "[" .. m.name .. "] " .. prefix .. m.text end

	return "<" .. m.name .. "> " .. prefix .. m.text
end

function widget:Initialize()
	if #chat == 0 then widgetHandler:RemoveWidget() end
end

function widget:Update()
	local t = GetParam("replay_t")
	if not t then return end
	for i, m in ipairs(chat) do
		if m.f > t then break end
		if not shown[i] then
			shown[i] = true
			Spring.Echo(line(m))
		end
	end
end
