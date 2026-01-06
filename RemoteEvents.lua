local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RemoteEvents = {}

-- Get or create RemoteEvents (ensures same instance is used)
local function getOrCreateRemoteEvent(name: string): RemoteEvent
	local existing = ReplicatedStorage:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	
	local remoteEvent = Instance.new("RemoteEvent")
	remoteEvent.Name = name
	remoteEvent.Parent = ReplicatedStorage
	return remoteEvent
end

-- RemoteEvent for loading ROMs (client -> server)
RemoteEvents.LoadROM = getOrCreateRemoteEvent("LoadROM")

-- RemoteEvent for player input (client -> server)
RemoteEvents.PlayerInput = getOrCreateRemoteEvent("PlayerInput")

-- RemoteEvent for getting EditableImage reference (client -> server, server -> client)
RemoteEvents.GetEditableImage = getOrCreateRemoteEvent("GetEditableImage")

-- RemoteEvent for status messages (server -> client)
RemoteEvents.StatusMessage = getOrCreateRemoteEvent("StatusMessage")

-- RemoteEvent for frame buffer data (server -> client)
RemoteEvents.FrameData = getOrCreateRemoteEvent("FrameData")

-- RemoteEvent for save state operations
RemoteEvents.SaveState = getOrCreateRemoteEvent("SaveState")
RemoteEvents.LoadState = getOrCreateRemoteEvent("LoadState")
RemoteEvents.GetPlayerGames = getOrCreateRemoteEvent("GetPlayerGames")
RemoteEvents.DeleteSaveSlot = getOrCreateRemoteEvent("DeleteSaveSlot")
RemoteEvents.ReloadGame = getOrCreateRemoteEvent("ReloadGame")
RemoteEvents.UpdateSlotName = getOrCreateRemoteEvent("UpdateSlotName")
RemoteEvents.CurrentGameUpdate = getOrCreateRemoteEvent("CurrentGameUpdate")

-- RemoteEvent for spectating operations
RemoteEvents.StartSpectating = getOrCreateRemoteEvent("StartSpectating")
RemoteEvents.StopSpectating = getOrCreateRemoteEvent("StopSpectating")
RemoteEvents.GetSpectatablePlayers = getOrCreateRemoteEvent("GetSpectatablePlayers")
RemoteEvents.SpectatorUpdate = getOrCreateRemoteEvent("SpectatorUpdate")

-- RemoteEvent for leaderboard operations
RemoteEvents.GetLeaderboard = getOrCreateRemoteEvent("GetLeaderboard")
RemoteEvents.LeaderboardUpdate = getOrCreateRemoteEvent("LeaderboardUpdate")
RemoteEvents.ScoreSubmitted = getOrCreateRemoteEvent("ScoreSubmitted")

-- RemoteEvent for audio operations
RemoteEvents.AudioChannelUpdate = getOrCreateRemoteEvent("AudioChannelUpdate")
RemoteEvents.AudioReset = getOrCreateRemoteEvent("AudioReset")

-- RemoteEvent for Game Boy Camera capture (server -> client request, client -> server response)
RemoteEvents.CameraCaptureRequest = getOrCreateRemoteEvent("CameraCaptureRequest")
RemoteEvents.CameraCaptureResponse = getOrCreateRemoteEvent("CameraCaptureResponse")

return RemoteEvents

