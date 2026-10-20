-- Shadows BAR's build menu: in playback nothing takes orders, so there is nothing to command.
function widget:GetInfo()
	return {
		name = "Build menu",
		desc = "Off in BAR Rewind playback",
		author = "burnhamrobertp",
		license = "GPL v2",
		layer = 0,
		enabled = false,
	}
end
