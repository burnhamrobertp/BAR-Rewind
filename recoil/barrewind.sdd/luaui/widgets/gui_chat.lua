-- Shadows BAR's chat widget: it only shows players that are in the game, and in playback the
-- replay's players are not. Replay Chat draws the match's chat instead.
function widget:GetInfo()
	return {
		name = "Chat",
		desc = "Replaced by Replay Chat in BAR Rewind",
		author = "burnhamrobertp",
		license = "GPL v2",
		layer = -1,
		enabled = false,
	}
end
