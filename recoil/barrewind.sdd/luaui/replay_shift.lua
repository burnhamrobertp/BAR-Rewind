-- Tells the Replay widgets when the timeline was shifted (seeked, dragged, played backwards) rather
-- than played: replay time is expected to move by speed x sim frames while playing forward, and
-- not at all otherwise; anything else is a shift. A shift is over once time has gone as expected
-- for SETTLE seconds.
--
--   local shift = VFS.Include("LuaUI/replay_shift.lua")()
--   local state, from, to = shift(t)   -- "playing", "shifting", or "settled" once with its span

local GetParam, GetGameFrame = Spring.GetGameRulesParam, Spring.GetGameFrame
local GetTimer, DiffTimers = Spring.GetTimer, Spring.DiffTimers
local SETTLE = 1
-- frames of slack for the gadget writing its params a frame apart from the widget reading them
local SLACK = 2

return function()
	local last_t, last_frame, last_speed = nil, nil, 0
	local from, to, since = nil, nil, nil

	return function(t)
		local frame = GetGameFrame()
		local playing = (GetParam("replay_playing") or 0) == 1
		local speed = GetParam("replay_speed") or 1
		local now_speed = playing and speed or 0
		if last_t then
			-- the step where the speed changes may run at either speed
			local frames = frame - last_frame
			local a, b = math.max(last_speed, 0) * frames, math.max(now_speed, 0) * frames
			local lo, hi = math.min(a, b), math.max(a, b)
			local moved = t - last_t
			if moved < 0 or moved < lo - SLACK or moved > hi + SLACK + math.max(last_speed, now_speed, 0) then
				from = from or last_t
				to = t
				since = GetTimer()
			end
		end
		last_t, last_frame, last_speed = t, frame, now_speed
		if not from then return "playing" end
		if DiffTimers(GetTimer(), since) < SETTLE then return "shifting" end
		local span_from = from
		from = nil

		return "settled", span_from, to
	end
end
