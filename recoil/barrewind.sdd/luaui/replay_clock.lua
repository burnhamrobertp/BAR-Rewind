-- How the Replay widgets show a replay frame: minutes and seconds of game time.

return function(frame)
	local s = math.floor(frame / 30)

	return string.format("%d:%02d", math.floor(s / 60), s % 60)
end
