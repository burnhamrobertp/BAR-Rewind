function gadget:GetInfo()
	return {
		name = "Replay View",
		desc = "BAR Rewind: replays what each player looked at, their map cursor and their camera, at the replay time",
		author = "burnhamrobertp",
		license = "GPL v2",
		layer = 2,
		enabled = true,
	}
end

if gadgetHandler:IsSyncedCode() then return end

-- Reads replay/cursor_* and replay/camera_* (written by `bake export-lua`) and hands them to LuaUI
-- the way BAR's Cursor Broadcast and CameraBroadcast gadgets do, through the MouseCursorEvent and
-- CameraBroadcastEvent callins, so BAR's ally cursorTracks and lock camera widgets show them as they
-- would live. Recoil's Lua numbers are 32-bit floats: records are read per chunk, never by a byte
-- offset into all of them.

local M = VFS.Include("replay/meta.lua")
local U32, F32 = VFS.UnpackU32, VFS.UnpackF32
local floor = math.floor
local GetParam = Spring.GetGameRulesParam
local GetTimer, DiffTimers = Spring.GetTimer, Spring.DiffTimers
-- about BAR's own cursor broadcast rate
local CURSOR_SEND_SECONDS = 0.1

local function chunks(name)
	local s = M.sections[name]
	if not s or s.count == 0 then return nil end
	local out = {}
	for c = 0, s.chunks - 1 do
		local z = VFS.LoadFile("replay/" .. name .. "_" .. c .. ".bin")
		out[c] = z and #z > 0 and VFS.ZlibDecompress(z) or ""
	end

	return { data = out, size = s.size, per = s.per_chunk }
end

-- chunk string and 1-based byte position of record i (0-based)
local function at(sec, i)
	local c = floor(i / sec.per)

	return sec.data[c], (i - c * sec.per) * sec.size + 1
end

local tracks, cursorKeys = chunks("cursor_tracks"), chunks("cursor_keys")
local cameraKeys, cameraValues = chunks("camera_keys"), chunks("camera_values")

-- the playback game numbers players by its start script: match them to the replay's by name
local localId = {}
do
	local byName = {}
	for _, id in ipairs(Spring.GetPlayerList()) do
		local name = Spring.GetPlayerInfo(id, false)
		if name then byName[name] = id end
	end
	for id, name in pairs(M.players or {}) do localId[id] = byName[name] end
end

local cursorTracks = {}
local cameraKeysByPlayer = {}
local lastSentCameraKey = {}

local function cursorKey(i)
	local str, pos = at(cursorKeys, i)
	local v = F32(str, pos + 4, 5)

	return U32(str, pos), v
end

local function load()
	for i = 0, (tracks and M.sections.cursor_tracks.count or 0) - 1 do
		local str, pos = at(tracks, i)
		local player = U32(str, pos)
		if localId[player] and cursorKeys then
			cursorTracks[#cursorTracks + 1] = { player = player, first = U32(str, pos + 4), count = U32(str, pos + 8), at = 0 }
		end
	end
	for i = 0, (cameraKeys and M.sections.camera_keys.count or 0) - 1 do
		local str, pos = at(cameraKeys, i)
		local player = U32(str, pos + 4)
		if localId[player] then
			cameraKeysByPlayer[player] = cameraKeysByPlayer[player] or {}
			cameraKeysByPlayer[player][#cameraKeysByPlayer[player] + 1] = i
		end
	end
end

local function cameraState(i)
	local str, pos = at(cameraKeys, i)
	local mode = U32(str, pos + 8)
	if mode >= 2147483648 then return nil end
	local layout = M.cameras and M.cameras[mode]
	if not layout then return nil end
	local first, count = U32(str, pos + 12), U32(str, pos + 16)
	local state = { name = layout.name, mode = mode }
	for k = 1, math.min(count, #layout.keys) do
		local vs, vp = at(cameraValues, first + k - 1)
		state[layout.keys[k]] = F32(vs, vp)
	end

	return state
end

-- BAR's camera gadget passes a player's camera on only to spectators with full view and to allies
local function seesCamera(player)
	local spec, fullView = Spring.GetSpectatingState()
	if spec and fullView then return true end
	local _, _, targetSpec, _, ally = Spring.GetPlayerInfo(localId[player], false)
	local _, _, _, _, myAlly = Spring.GetPlayerInfo(Spring.GetMyPlayerID(), false)

	return not targetSpec and ally == myAlly
end

local function sendCursors(t)
	if not Script.LuaUI("MouseCursorEvent") then return end
	for _, c in ipairs(cursorTracks) do
		local first_t = cursorKey(c.first)
		local last_t = cursorKey(c.first + c.count - 1)
		if t >= first_t and t <= last_t then
			-- walk the cached index to the last key at or before t
			local k = c.at
			while k > 0 and cursorKey(c.first + k) > t do k = k - 1 end
			while k + 1 < c.count and cursorKey(c.first + k + 1) <= t do k = k + 1 end
			c.at = k
			local ta, a = cursorKey(c.first + k)
			local x1, z1, x2, z2 = a[1], a[2], a[3], a[4]
			if k + 1 < c.count then
				local tb, b = cursorKey(c.first + k + 1)
				local f = tb > ta and (t - ta) / (tb - ta) or 0
				x1, z1 = x1 + (b[1] - x1) * f, z1 + (b[2] - z1) * f
				x2, z2 = x2 + (b[3] - x2) * f, z2 + (b[4] - z2) * f
			end
			Script.LuaUI.MouseCursorEvent(localId[c.player], x1, z1, x2, z2, a[5] > 0.5)
		end
	end
end

local function sendCameras(t)
	if not Script.LuaUI("CameraBroadcastEvent") then return end
	for player, list in pairs(cameraKeysByPlayer) do
		local a, b = 0, #list
		while a < b do
			local mid = floor((a + b + 1) / 2)
			local str, pos = at(cameraKeys, list[mid])
			if U32(str, pos) <= t then a = mid else b = mid - 1 end
		end
		local key = a > 0 and list[a] or false
		if key ~= lastSentCameraKey[player] and seesCamera(player) then
			lastSentCameraKey[player] = key
			Script.LuaUI.CameraBroadcastEvent(localId[player], key and cameraState(key) or nil)
		end
	end
end

local lastCursorSend = nil

function gadget:Initialize()
	load()
	if #cursorTracks == 0 and next(cameraKeysByPlayer) == nil then gadgetHandler:RemoveGadget() end
end

function gadget:Update()
	local t = GetParam("replay_t")
	if not t then return end
	local now = GetTimer()
	if not lastCursorSend or DiffTimers(now, lastCursorSend) >= CURSOR_SEND_SECONDS then
		lastCursorSend = now
		sendCursors(t)
	end
	sendCameras(t)
end
