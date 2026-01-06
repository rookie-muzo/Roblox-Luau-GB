local AssetService = game:GetService("AssetService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Gameboy = require(ReplicatedStorage.Gameboy)
local RemoteEvents = require(ReplicatedStorage.RemoteEvents)
local GameboyDataStore = require(ReplicatedStorage.GameboyDataStore)

-- Verify RemoteEvents are accessible
print("[Gameboy] RemoteEvents loaded:")
print("  - LoadROM:", RemoteEvents.LoadROM and "OK" or "MISSING")
print("  - PlayerInput:", RemoteEvents.PlayerInput and "OK" or "MISSING")
print("  - GetEditableImage:", RemoteEvents.GetEditableImage and "OK" or "MISSING")
print("  - StatusMessage:", RemoteEvents.StatusMessage and "OK" or "MISSING")
print("  - FrameData:", RemoteEvents.FrameData and "OK" or "MISSING")

-- Check if EditableImage is enabled
local enabled = pcall(function()
	AssetService:CreateEditableImage()
end)

if not enabled then
	warn("[Gameboy] EditableImage is not enabled! Go to 'Game Settings > Security' and check 'Allow Mesh / Image APIs' to use the Gameboy Emulator!")
else
	print("[Gameboy] EditableImage API is enabled")
end

-- Check if HttpService is enabled
if not HttpService.HttpEnabled then
	warn("[Gameboy] HttpService is not enabled! Go to 'Game Settings > Security' and enable 'Allow HTTP Requests' to load ROMs from URLs!")
else
	print("[Gameboy] HttpService is enabled")
end

local WIDTH = 160
local HEIGHT = 144
local size = Vector2.new(WIDTH, HEIGHT)

-- Store per-player emulator instances
local playerEmulators: { [Player]: {
	gameboy: any,
	screen: EditableImage?,
	runner: thread?,
	frameBuffer: buffer,
	ticker: number,
	lastTick: number,
	currentGameId: string?,
	currentGameUrl: string?,
	currentGameTitle: string?,
	currentGameIsColor: boolean?,
	hasBattery: boolean?,
	lastBatteryRamSave: number?,
	proximityPrompt: ProximityPrompt?,
	proximityPromptGui: BillboardGui?,
	lastScore: number?,
	lastScoreCheck: number?,
	gameOverDetected: boolean?,
	lastSavedScore: number?,
	scoreCheckCount: number?,
	audioChannels: {
		tone1: { frequency: number?, volume: number?, enabled: boolean?, dutyCycle: number?, sweepActive: boolean? },
		tone2: { frequency: number?, volume: number?, enabled: boolean?, dutyCycle: number? },
		wave3: { frequency: number?, volume: number?, enabled: boolean? },
		noise4: { volume: number?, enabled: boolean?, lfsrType: number? }
	}?,
	lastAudioRegisters: { [number]: number }?,
	lastAudioUpdate: number?,
} } = {}

-- Track spectators: spectators[playerBeingWatched][spectatorPlayer] = true
local spectators: { [Player]: { [Player]: boolean } } = {}

-- Track which player each spectator is watching: spectating[spectatorPlayer] = playerBeingWatched
local spectating: { [Player]: Player? } = {}

-- Game score configuration (memory addresses for score detection)
local gameScoreConfig = {
	["TETRIS_GB"] = {
		scoreAddresses = { 0xC0A0, 0xC0A1, 0xC0A2 }, -- BCD format, 6 digits (WRAM)
		gameStateAddress = 0xFFE1, -- Game state in HRAM (0xFF00-0xFFFF)
		-- Game state values: 00=Title/demo, 01=Playing, 02=Pause, 03=Game over sequence, 04=Score tally/results
		gameStatePlaying = 0x01,
		gameStateGameOver = 0x03,
		gameStateScoreTally = 0x04,
		scoreFormat = "BCD" -- Binary Coded Decimal
	}
}

-- Convert BCD byte to decimal
local function bcdToDecimal(bcd: number): number
	local tens = bit32.rshift(bit32.band(bcd, 0xF0), 4)
	local ones = bit32.band(bcd, 0x0F)
	return (tens * 10) + ones
end

-- Debug counter for score reading
local scoreReadDebugCount = 0

-- Read Tetris score from memory
local function readTetrisScore(gameboy: any): (number?, boolean?)
	local config = gameScoreConfig["TETRIS_GB"]
	if not config then
		return nil, nil
	end
	
	-- Read score bytes (BCD format, little-endian)
	-- Score 123456 is stored as:
	-- $C0A0: $56 (ones and tens)
	-- $C0A1: $34 (hundreds and thousands)
	-- $C0A2: $12 (ten thousands and hundred thousands)
	local byte1 = gameboy.memory.read_byte(config.scoreAddresses[1]) -- 0xC0A0: ones and tens
	local byte2 = gameboy.memory.read_byte(config.scoreAddresses[2]) -- 0xC0A1: hundreds and thousands
	local byte3 = gameboy.memory.read_byte(config.scoreAddresses[3]) -- 0xC0A2: ten thousands and hundred thousands
	
	-- Debug: Always print first few reads to verify addresses
	scoreReadDebugCount = scoreReadDebugCount + 1
	if scoreReadDebugCount <= 5 then
		print(string.format("[Gameboy Score] Memory read #%d: 0x%04X=%02X 0x%04X=%02X 0x%04X=%02X", 
			scoreReadDebugCount,
			config.scoreAddresses[1], byte1,
			config.scoreAddresses[2], byte2,
			config.scoreAddresses[3], byte3))
	end
	
	-- BCD format: each byte contains two digits (little-endian)
	-- byte1 (0xC0A0): low nibble = ones, high nibble = tens
	-- byte2 (0xC0A1): low nibble = hundreds, high nibble = thousands
	-- byte3 (0xC0A2): low nibble = ten thousands, high nibble = hundred thousands
	local ones = bit32.band(byte1, 0x0F)
	local tens = bit32.rshift(bit32.band(byte1, 0xF0), 4)
	local hundreds = bit32.band(byte2, 0x0F)
	local thousands = bit32.rshift(bit32.band(byte2, 0xF0), 4)
	local tenThousands = bit32.band(byte3, 0x0F)
	local hundredThousands = bit32.rshift(bit32.band(byte3, 0xF0), 4)
	
	-- Calculate score
	local score = (hundredThousands * 100000) + (tenThousands * 10000) + (thousands * 1000) + (hundreds * 100) + (tens * 10) + ones
	
	-- Check game state from HRAM (0xFFE1)
	-- Game state values: 00=Title/demo, 01=Playing, 02=Pause, 03=Game over sequence, 04=Score tally/results
	-- HRAM (0xFF00-0xFFFF) must be accessed through io.block, not memory.read_byte
	local gameState: number = 0
	local stateAddress = config.gameStateAddress
	if stateAddress then
		if gameboy.io and gameboy.io.block then
			local success, stateValue = pcall(function()
				return gameboy.io.block[stateAddress]
			end)
			if success and stateValue ~= nil then
				gameState = stateValue
			end
		else
			-- Fallback: try memory.read_byte (but this might not work for HRAM)
			local success, stateValue = pcall(function()
				return gameboy.memory.read_byte(stateAddress)
			end)
			if success and stateValue ~= nil then
				gameState = stateValue
			end
		end
	end
	local isGameOver = (gameState == config.gameStateGameOver) or (gameState == config.gameStateScoreTally)
	
	-- Get game state description
	local stateDescription = "Other"
	if gameState == 0x00 then
		stateDescription = "Title/Demo"
	elseif gameState == 0x01 then
		stateDescription = "Playing"
	elseif gameState == 0x02 then
		stateDescription = "Pause"
	elseif gameState == 0x03 then
		stateDescription = "Game Over"
	elseif gameState == 0x04 then
		stateDescription = "Score Tally"
	end
	
	if scoreReadDebugCount <= 5 then
		print(string.format("[Gameboy Score] Parsed: ones=%d tens=%d hundreds=%d thousands=%d tenThousands=%d hundredThousands=%d score=%d gameState=0x%02X (%s)", 
			ones, tens, hundreds, thousands, tenThousands, hundredThousands, score, gameState, stateDescription))
	end
	
	return score, isGameOver
end

-- Check and save score for a player
local function checkAndSaveScore(player: Player, emulatorData: any)
	if not emulatorData.currentGameId then
		return
	end
	
	local gameId = emulatorData.currentGameId
	local config = gameScoreConfig[gameId]
	if not config then
		-- Debug: print if config not found
		if (emulatorData.scoreCheckCount or 0) < 3 then
			print("[Gameboy Score] No config for gameId:", gameId)
		end
		return -- Game doesn't support score tracking
	end
	
	local gb = emulatorData.gameboy
	local success, score, isGameOver = pcall(function()
		return readTetrisScore(gb)
	end)
	
	if not success then
		-- Score reading failed
		if (emulatorData.scoreCheckCount or 0) < 5 then
			warn("[Gameboy Score] Score reading failed for", player.Name, ":", score)
		end
		return
	end
	
	-- Track check count
	emulatorData.scoreCheckCount = (emulatorData.scoreCheckCount or 0) + 1
	
	-- Debug output for first few checks, or when game over is detected
	if emulatorData.scoreCheckCount <= 10 or isGameOver then
		local stateDescription = "Other"
		if gameState == 0x00 then
			stateDescription = "Title/Demo"
		elseif gameState == 0x01 then
			stateDescription = "Playing"
		elseif gameState == 0x02 then
			stateDescription = "Pause"
		elseif gameState == 0x03 then
			stateDescription = "Game Over"
		elseif gameState == 0x04 then
			stateDescription = "Score Tally"
		else
			stateDescription = "Unknown"
		end
		print(string.format("[Gameboy Score] Check #%d for %s: score=%d, gameState=0x%02X (%s), gameOver=%s", 
			emulatorData.scoreCheckCount or 0, player.Name, score or 0, gameState or 0, stateDescription or "Unknown", tostring(isGameOver)))
	end
	
	if not score or score == 0 then
		-- Score is 0, might mean game hasn't started or addresses are wrong
		if emulatorData.scoreCheckCount <= 5 then
			print("[Gameboy Score] Score is 0 for", player.Name, "- addresses might be wrong or game not started")
		end
		return
	end
	
	-- Update last score
	local previousScore = emulatorData.lastScore or 0
	emulatorData.lastScore = score
	
	-- For Tetris, we'll save the score when it changes significantly (indicating game progress)
	-- or when game over is detected
	-- Save score if it's significantly higher than last saved score (e.g., increased by 1000+)
	local lastSavedScore = emulatorData.lastSavedScore or 0
	local scoreIncrease = score - lastSavedScore
	
	-- Check if game over and score hasn't been saved yet
	if isGameOver and not emulatorData.gameOverDetected then
		-- Get the game state value for logging
		local gb = emulatorData.gameboy
		local finalGameState: number = 0
		if gb.io and gb.io.block then
			local success, stateValue = pcall(function()
				return gb.io.block[config.gameStateAddress]
			end)
			if success and stateValue ~= nil then
				finalGameState = stateValue
			end
		end
		
		local stateDescription = "Unknown"
		if finalGameState == 0x03 then
			stateDescription = "Game Over (0x03)"
		elseif finalGameState == 0x04 then
			stateDescription = "Score Tally (0x04)"
		end
		
		emulatorData.gameOverDetected = true
		emulatorData.lastSavedScore = score
		
		-- Always save the final score when game ends (even if not a new best)
		-- This ensures the leaderboard has the most recent score
		local saveSuccess = GameboyDataStore.saveScore(player, gameId, score)
		if saveSuccess then
			-- Get updated rank
			local bestScore, newRank = GameboyDataStore.getPlayerBestScore(player, gameId)
			local isNewBest = (bestScore == score)
			RemoteEvents.ScoreSubmitted:FireClient(player, gameId, score, newRank)
			print(string.format("[Gameboy] Score saved (game over detected via %s) for %s: %d points%s%s", 
				stateDescription, player.Name, score, 
				newRank and (" (Rank #" .. newRank .. ")") or "",
				isNewBest and " [NEW BEST!]" or ""))
		else
			warn("[Gameboy] Failed to save score for", player.Name, ":", score)
		end
	elseif not isGameOver and emulatorData.gameOverDetected then
		-- Game restarted, reset flag
		emulatorData.gameOverDetected = false
		emulatorData.lastSavedScore = 0
		print("[Gameboy] Game restarted for", player.Name, "- resetting game over flag")
	end
	
	-- Also save periodically when score increases significantly (every 5000 points)
	-- This ensures scores are saved even if game over detection doesn't work
	if scoreIncrease >= 5000 and score > (lastSavedScore + 5000) then
		emulatorData.lastSavedScore = score
		
		local bestScore, rank = GameboyDataStore.getPlayerBestScore(player, gameId)
		if not bestScore or score > bestScore then
			local saveSuccess = GameboyDataStore.saveScore(player, gameId, score)
			if saveSuccess then
				local _, newRank = GameboyDataStore.getPlayerBestScore(player, gameId)
				RemoteEvents.ScoreSubmitted:FireClient(player, gameId, score, newRank)
				print("[Gameboy] Score saved (periodic) for", player.Name, ":", score, "points", newRank and "(Rank #" .. newRank .. ")" or "")
			end
		end
	end
end

-- Convert Game Boy frequency register to Hz
local function gameboyFreqToHz(freqValue: number): number
	if freqValue == 0 or freqValue >= 2048 then
		return 0
	end
	return 131072 / (2048 - freqValue)
end

-- Convert Game Boy volume (0-15) to Roblox volume (0.0-1.0)
local function gameboyVolumeToRoblox(gbVolume: number): number
	return math.max(0, math.min(1.0, gbVolume / 15.0))
end

-- Monitor and update audio channels for a player
local function updateAudioChannels(player: Player, emulatorData: any)
	local gb = emulatorData.gameboy
	if not gb or not gb.io or not gb.io.ram or not gb.io.ports then
		return
	end
	
	local ports = gb.io.ports
	local ram = gb.io.ram
	
	-- Initialize audio state if needed
	if not emulatorData.audioChannels then
		emulatorData.audioChannels = {
			tone1 = { frequency = 0, volume = 0, enabled = false, dutyCycle = 0.5, sweepActive = false },
			tone2 = { frequency = 0, volume = 0, enabled = false, dutyCycle = 0.5 },
			wave3 = { frequency = 0, volume = 0, enabled = false },
			noise4 = { volume = 0, enabled = false, lfsrType = 15 }
		}
		emulatorData.lastAudioRegisters = {}
		emulatorData.lastAudioUpdate = 0
	end
	
	local audioChannels = emulatorData.audioChannels
	local lastRegisters = emulatorData.lastAudioRegisters
	local currentTime = os.clock()
	local updateInterval = (1/30) * 2.5 -- ~83ms (2.5 frames at 30fps)
	local timeSinceLastUpdate = currentTime - (emulatorData.lastAudioUpdate or 0)
	
	-- Check if sound is enabled (NR52 bit 7)
	local nr52 = ram[ports.NR52] or 0
	local soundEnabled = bit32.band(nr52, 0x80) ~= 0
	
	if not soundEnabled then
		-- Sound is off, disable all channels
		if audioChannels.tone1.enabled or audioChannels.tone2.enabled or audioChannels.wave3.enabled or audioChannels.noise4.enabled then
			audioChannels.tone1.enabled = false
			audioChannels.tone2.enabled = false
			audioChannels.wave3.enabled = false
			audioChannels.noise4.enabled = false
			RemoteEvents.AudioReset:FireClient(player)
			emulatorData.lastAudioUpdate = currentTime
		end
		return
	end
	
	-- Read all audio registers
	local nr10 = ram[ports.NR10] or 0
	local nr11 = ram[ports.NR11] or 0
	local nr12 = ram[ports.NR12] or 0
	local nr13 = ram[ports.NR13] or 0
	local nr14 = ram[ports.NR14] or 0
	
	local nr21 = ram[ports.NR21] or 0
	local nr22 = ram[ports.NR22] or 0
	local nr23 = ram[ports.NR23] or 0
	local nr24 = ram[ports.NR24] or 0
	
	local nr30 = ram[ports.NR30] or 0
	local nr31 = ram[ports.NR31] or 0
	local nr32 = ram[ports.NR32] or 0
	local nr33 = ram[ports.NR33] or 0
	local nr34 = ram[ports.NR34] or 0
	
	local nr41 = ram[ports.NR41] or 0
	local nr42 = ram[ports.NR42] or 0
	local nr43 = ram[ports.NR43] or 0
	local nr44 = ram[ports.NR44] or 0
	
	local nr50 = ram[ports.NR50] or 0
	local nr51 = ram[ports.NR51] or 0
	
	-- Detect changes
	local registersChanged = false
	local sweepActive = bit32.band(nr10, 0x70) ~= 0
	local triggerDetected = false
	
	-- Check for register changes
	for port, value in pairs({
		[ports.NR10] = nr10, [ports.NR11] = nr11, [ports.NR12] = nr12, [ports.NR13] = nr13, [ports.NR14] = nr14,
		[ports.NR21] = nr21, [ports.NR22] = nr22, [ports.NR23] = nr23, [ports.NR24] = nr24,
		[ports.NR30] = nr30, [ports.NR31] = nr31, [ports.NR32] = nr32, [ports.NR33] = nr33, [ports.NR34] = nr34,
		[ports.NR41] = nr41, [ports.NR42] = nr42, [ports.NR43] = nr43, [ports.NR44] = nr44,
		[ports.NR50] = nr50, [ports.NR51] = nr51, [ports.NR52] = nr52
	}) do
		if lastRegisters[port] ~= value then
			registersChanged = true
			-- Check for triggers
			if port == ports.NR14 or port == ports.NR24 or port == ports.NR34 or port == ports.NR44 then
				if bit32.band(value, 0x80) ~= 0 then
					triggerDetected = true
				end
			end
			lastRegisters[port] = value
		end
	end
	
	if not registersChanged then
		return -- No changes, skip update
	end
	
	-- Determine if we should send update (immediate for sweep/trigger, throttled for others)
	local shouldUpdate = false
	if sweepActive or triggerDetected then
		-- Immediate update for sweep or trigger
		shouldUpdate = true
	elseif timeSinceLastUpdate >= updateInterval then
		-- Throttled update for other changes
		shouldUpdate = true
	end
	
	if not shouldUpdate then
		return
	end
	
	-- Extract Channel 1 (Tone with Sweep) parameters
	local dutyCycle1 = bit32.rshift(bit32.band(nr11, 0xC0), 6)
	local dutyCycles = { 0.125, 0.25, 0.5, 0.75 }
	local dutyCycle1Value = dutyCycles[dutyCycle1 + 1] or 0.5
	
	local volume1 = bit32.rshift(bit32.band(nr12, 0xF0), 4)
	local freqLow1 = nr13
	local freqHigh1 = bit32.band(nr14, 0x07)
	local freqValue1 = bit32.bor(bit32.lshift(freqHigh1, 8), freqLow1)
	local frequency1 = gameboyFreqToHz(freqValue1)
	
	-- Extract Channel 2 (Tone) parameters
	local dutyCycle2 = bit32.rshift(bit32.band(nr21, 0xC0), 6)
	local dutyCycle2Value = dutyCycles[dutyCycle2 + 1] or 0.5
	
	local volume2 = bit32.rshift(bit32.band(nr22, 0xF0), 4)
	local freqLow2 = nr23
	local freqHigh2 = bit32.band(nr24, 0x07)
	local freqValue2 = bit32.bor(bit32.lshift(freqHigh2, 8), freqLow2)
	local frequency2 = gameboyFreqToHz(freqValue2)
	
	-- Extract Channel 3 (Wave) parameters
	local waveEnabled = bit32.band(nr30, 0x80) ~= 0
	local volumeShift = bit32.rshift(bit32.band(nr32, 0x60), 5)
	local volumeShifts = { 0, 1, 0.5, 0.25 } -- mute, 100%, 50%, 25%
	local volume3 = volumeShifts[volumeShift + 1] or 0
	
	local freqLow3 = nr33
	local freqHigh3 = bit32.band(nr34, 0x07)
	local freqValue3 = bit32.bor(bit32.lshift(freqHigh3, 8), freqLow3)
	local frequency3 = gameboyFreqToHz(freqValue3)
	
	-- Extract Channel 4 (Noise) parameters
	local volume4 = bit32.rshift(bit32.band(nr42, 0xF0), 4)
	local lfsrWide = bit32.band(nr43, 0x08) == 0
	local lfsrType = lfsrWide and 15 or 7
	
	-- Extract channel enable flags (NR51)
	local tone1Left = bit32.band(nr51, 0x01) ~= 0
	local tone1Right = bit32.band(nr51, 0x10) ~= 0
	local tone2Left = bit32.band(nr51, 0x02) ~= 0
	local tone2Right = bit32.band(nr51, 0x20) ~= 0
	local wave3Left = bit32.band(nr51, 0x04) ~= 0
	local wave3Right = bit32.band(nr51, 0x40) ~= 0
	local noise4Left = bit32.band(nr51, 0x08) ~= 0
	local noise4Right = bit32.band(nr51, 0x80) ~= 0
	
	-- Update channel states
	local channelsUpdated = false
	
	-- Channel 1
	if audioChannels.tone1.frequency ~= frequency1 or
	   audioChannels.tone1.volume ~= volume1 or
	   audioChannels.tone1.dutyCycle ~= dutyCycle1Value or
	   audioChannels.tone1.sweepActive ~= sweepActive or
	   audioChannels.tone1.enabled ~= (tone1Left or tone1Right) then
		audioChannels.tone1.frequency = frequency1
		audioChannels.tone1.volume = volume1
		audioChannels.tone1.dutyCycle = dutyCycle1Value
		audioChannels.tone1.sweepActive = sweepActive
		audioChannels.tone1.enabled = (tone1Left or tone1Right)
		channelsUpdated = true
	end
	
	-- Channel 2
	if audioChannels.tone2.frequency ~= frequency2 or
	   audioChannels.tone2.volume ~= volume2 or
	   audioChannels.tone2.dutyCycle ~= dutyCycle2Value or
	   audioChannels.tone2.enabled ~= (tone2Left or tone2Right) then
		audioChannels.tone2.frequency = frequency2
		audioChannels.tone2.volume = volume2
		audioChannels.tone2.dutyCycle = dutyCycle2Value
		audioChannels.tone2.enabled = (tone2Left or tone2Right)
		channelsUpdated = true
	end
	
	-- Channel 3
	if audioChannels.wave3.frequency ~= frequency3 or
	   audioChannels.wave3.volume ~= volume3 or
	   audioChannels.wave3.enabled ~= (wave3Left or wave3Right) then
		audioChannels.wave3.frequency = frequency3
		audioChannels.wave3.volume = volume3
		audioChannels.wave3.enabled = (wave3Left or wave3Right) and waveEnabled
		channelsUpdated = true
	end
	
	-- Channel 4
	if audioChannels.noise4.volume ~= volume4 or
	   audioChannels.noise4.lfsrType ~= lfsrType or
	   audioChannels.noise4.enabled ~= (noise4Left or noise4Right) then
		audioChannels.noise4.volume = volume4
		audioChannels.noise4.lfsrType = lfsrType
		audioChannels.noise4.enabled = (noise4Left or noise4Right)
		channelsUpdated = true
	end
	
	-- Send updates if channels changed
	if channelsUpdated then
		-- Send master volume and panning info
		local masterLeftVolume = bit32.band(nr50, 0x07)
		local masterRightVolume = bit32.rshift(bit32.band(nr50, 0x70), 4)
		
		-- Send channel updates
		RemoteEvents.AudioChannelUpdate:FireClient(player, {
			tone1 = {
				frequency = frequency1,
				volume = gameboyVolumeToRoblox(volume1),
				enabled = (tone1Left or tone1Right),
				dutyCycle = dutyCycle1Value,
				sweepActive = sweepActive,
				panLeft = tone1Left,
				panRight = tone1Right
			},
			tone2 = {
				frequency = frequency2,
				volume = gameboyVolumeToRoblox(volume2),
				enabled = (tone2Left or tone2Right),
				dutyCycle = dutyCycle2Value,
				panLeft = tone2Left,
				panRight = tone2Right
			},
			wave3 = {
				frequency = frequency3,
				volume = volume3, -- Already normalized (0-1)
				enabled = (wave3Left or wave3Right) and waveEnabled,
				panLeft = wave3Left,
				panRight = wave3Right
			},
			noise4 = {
				volume = gameboyVolumeToRoblox(volume4),
				enabled = (noise4Left or noise4Right),
				lfsrType = lfsrType,
				panLeft = noise4Left,
				panRight = noise4Right
			},
			masterVolume = {
				left = gameboyVolumeToRoblox(masterLeftVolume),
				right = gameboyVolumeToRoblox(masterRightVolume)
			}
		})
		
		emulatorData.lastAudioUpdate = currentTime
	end
end

-- Input map (same as original)
local inputMap = {
	[Enum.KeyCode.Up] = "Up",
	[Enum.KeyCode.Down] = "Down",
	[Enum.KeyCode.Left] = "Left",
	[Enum.KeyCode.Right] = "Right",
	[Enum.KeyCode.X] = "A",
	[Enum.KeyCode.Z] = "B",
	[Enum.KeyCode.W] = "Up",
	[Enum.KeyCode.S] = "Down",
	[Enum.KeyCode.A] = "Left",
	[Enum.KeyCode.D] = "Right",
	[Enum.KeyCode.Return] = "Start",
	[Enum.KeyCode.RightShift] = "Select",
	[Enum.KeyCode.DPadUp] = "Up",
	[Enum.KeyCode.DPadDown] = "Down",
	[Enum.KeyCode.DPadLeft] = "Left",
	[Enum.KeyCode.DPadRight] = "Right",
	[Enum.KeyCode.ButtonY] = "A",
	[Enum.KeyCode.ButtonX] = "B",
}

-- Initialize emulator for a player
local function initializePlayerEmulator(player: Player)
	if playerEmulators[player] then
		return playerEmulators[player]
	end

	local gb = Gameboy.new()
	
	-- Set player reference for camera module (server-side)
	if gb.camera and gb.camera.setPlayer then
		gb.camera.setPlayer(player)
	end
	
	local frameBuffer = buffer.create(WIDTH * HEIGHT * 4)
	buffer.fill(frameBuffer, 0, 255)

		local emulatorData = {
		gameboy = gb,
		screen = nil,
		runner = nil,
		frameBuffer = frameBuffer,
		ticker = 0,
		lastTick = os.clock(),
		lastBatteryRamSave = 0,
		lastScore = nil,
		lastScoreCheck = 0,
		gameOverDetected = false,
	}

	playerEmulators[player] = emulatorData
	return emulatorData
end

-- Create ProximityPrompt for a player
local function createSpectatePrompt(player: Player)
	local emulatorData = playerEmulators[player]
	if not emulatorData or emulatorData.proximityPrompt then
		return
	end
	
	local character = player.Character
	if not character then
		return
	end
	
	local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
	local head = character:FindFirstChild("Head")
	if not humanoidRootPart then
		return
	end
	
	-- Use Head if available (it's higher up), otherwise use HumanoidRootPart
	local parentPart = head or humanoidRootPart
	
	-- Create the ProximityPrompt (must be parented to BasePart for replication)
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Spectate (E)"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 50
	prompt.RequiresLineOfSight = false
	prompt.Parent = parentPart
	
	-- Also create a BillboardGui with text label for visual indicator
	-- This ensures all players can see the prompt
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "SpectatePromptIndicator"
	billboard.Size = UDim2.new(0, 200, 0, 50)
	billboard.StudsOffset = Vector3.new(0, 3, 0)
	billboard.AlwaysOnTop = true
	billboard.Enabled = true
	billboard.Adornee = humanoidRootPart
	billboard.Parent = humanoidRootPart
	
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Text = "Spectate (E)"
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextSize = 16
	label.Font = Enum.Font.GothamBold
	label.TextStrokeTransparency = 0.5
	label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	label.Parent = billboard
	
	prompt.Triggered:Connect(function(triggeringPlayer)
		if triggeringPlayer ~= player then
			-- Directly handle spectating (we're already on server)
			-- Check if target player is playing
			local targetEmulatorData = playerEmulators[player]
			if not targetEmulatorData or not targetEmulatorData.runner then
				RemoteEvents.SpectatorUpdate:FireClient(triggeringPlayer, false, nil, "Player is not playing")
				return
			end
			
			-- Initialize spectators table if needed
			if not spectators[player] then
				spectators[player] = {}
			end
			
			-- Add spectator
			spectators[player][triggeringPlayer] = true
			spectating[triggeringPlayer] = player
			
			-- Notify spectator
			RemoteEvents.SpectatorUpdate:FireClient(
				triggeringPlayer,
				true,
				player.Name,
				targetEmulatorData.currentGameTitle or "Unknown Game"
			)
			
			print("[Gameboy] Player", triggeringPlayer.Name, "is now spectating", player.Name)
		end
	end)
	
	emulatorData.proximityPrompt = prompt
	emulatorData.proximityPromptGui = billboard
	
	print("[Gameboy] Created ProximityPrompt for", player.Name, "on", parentPart.Name, "- should be visible to all players")
end

-- Destroy ProximityPrompt for a player
local function destroySpectatePrompt(player: Player)
	local emulatorData = playerEmulators[player]
	if not emulatorData then
		return
	end
	
	if emulatorData.proximityPromptGui then
		emulatorData.proximityPromptGui:Destroy()
		emulatorData.proximityPromptGui = nil
	end
	
	if emulatorData.proximityPrompt then
		emulatorData.proximityPrompt:Destroy()
		emulatorData.proximityPrompt = nil
	end
end

-- Clean up emulator for a player
local function cleanupPlayerEmulator(player: Player)
	local emulatorData = playerEmulators[player]
	if not emulatorData then
		return
	end

	-- Notify all spectators that player stopped playing
	if spectators[player] then
		for spectator in pairs(spectators[player]) do
			if spectator and spectator.Parent then
				RemoteEvents.SpectatorUpdate:FireClient(spectator, false, nil, nil)
				spectating[spectator] = nil
			end
		end
		spectators[player] = nil
	end

	-- Destroy proximity prompt
	destroySpectatePrompt(player)

	if emulatorData.runner then
		task.cancel(emulatorData.runner)
		emulatorData.runner = nil
	end

	if emulatorData.screen then
		emulatorData.screen:Destroy()
		emulatorData.screen = nil
	end

	playerEmulators[player] = nil
end

-- Run emulator thread for a player
local function runEmulatorThread(player: Player)
	local emulatorData = playerEmulators[player]
	if not emulatorData then
		return
	end

	local gb = emulatorData.gameboy
	local screen = emulatorData.screen
	local frameBuffer = emulatorData.frameBuffer
	local self = assert(emulatorData.runner)
	assert(self == coroutine.running())

	while true do
		local now = os.clock()
		local dt = now - emulatorData.lastTick

		emulatorData.lastTick = now
		emulatorData.ticker = math.min(emulatorData.ticker + dt * 60, 3)

		while emulatorData.ticker >= 1 do
			for i = 1, HEIGHT do
				if self ~= emulatorData.runner then
					return
				end

				gb:run_until_hblank()
			end

			emulatorData.ticker -= 1
		end

		-- Read pixels
		local pixels = gb.graphics.game_screen
		local i = 0

		for y = 0, HEIGHT - 1 do
			for x = 0, WIDTH - 1 do
				local pixel = pixels[y][x]
				buffer.writeu8(frameBuffer, i, pixel[1])
				buffer.writeu8(frameBuffer, i + 1, pixel[2])
				buffer.writeu8(frameBuffer, i + 2, pixel[3])
				buffer.writeu8(frameBuffer, i + 3, 255)
				
				i += 4
			end
		end
		
		if screen then
		screen:WritePixelsBuffer(Vector2.zero, size, frameBuffer)
		end

		-- Send frame data to client
		-- Convert buffer to string for transmission
		if RemoteEvents.FrameData then
			local bufferSize = WIDTH * HEIGHT * 4
			local success, frameDataString = pcall(function()
				-- Build string by concatenating bytes directly
				local strParts = {}
				for i = 0, bufferSize - 1 do
					strParts[#strParts + 1] = string.char(buffer.readu8(frameBuffer, i))
				end
				return table.concat(strParts)
			end)
			
			if success and frameDataString and #frameDataString > 0 then
				-- Send to main player
				RemoteEvents.FrameData:FireClient(player, frameDataString)
				
				-- Send to all spectators
				if spectators[player] then
					for spectator in pairs(spectators[player]) do
						if spectator and spectator.Parent then
							RemoteEvents.FrameData:FireClient(spectator, frameDataString)
						end
					end
				end
			else
				warn("[Gameboy] Failed to convert frame buffer:", frameDataString)
			end
		else
			warn("[Gameboy] FrameData RemoteEvent is not available!")
		end

		-- Auto-save battery RAM if dirty (check every 5 seconds)
		if emulatorData.hasBattery and emulatorData.currentGameId then
			local currentTime = os.time()
			if currentTime - (emulatorData.lastBatteryRamSave or 0) >= 5 then
				local externalRam = gb.cartridge.external_ram
				if externalRam and externalRam.dirty then
					local saveSuccess = GameboyDataStore.saveBatteryRam(
						player,
						emulatorData.currentGameId,
						externalRam
					)
					if saveSuccess then
						externalRam.dirty = false
						emulatorData.lastBatteryRamSave = currentTime
						-- Only print occasionally to avoid spam
						if math.random() < 0.1 then
							print("[Gameboy] Auto-saved battery RAM for", player.Name)
						end
					end
				end
			end
		end

		-- Check score periodically (every 3 seconds)
		local currentTime = os.time()
		if currentTime - (emulatorData.lastScoreCheck or 0) >= 3 then
			-- Debug: Always log that we're checking
			if (emulatorData.scoreCheckCount or 0) < 5 then
				print("[Gameboy Score] Starting score check for", player.Name, "gameId:", emulatorData.currentGameId)
			end
			checkAndSaveScore(player, emulatorData)
			emulatorData.lastScoreCheck = currentTime
		end

		-- Update audio channels
		updateAudioChannels(player, emulatorData)

		RunService.Heartbeat:Wait()
	end
end

-- Handle ROM loading
print("[Gameboy] LoadROM RemoteEvent handler connected")
RemoteEvents.LoadROM.OnServerEvent:Connect(function(player: Player, romUrl: string)
	print("[Gameboy] LoadROM RemoteEvent received from", player.Name, "with URL:", romUrl)
	if not enabled then
		warn("[Gameboy] EditableImage is not enabled for", player.Name)
		RemoteEvents.StatusMessage:FireClient(player, "Error: EditableImage API is not enabled in game settings!", false)
		return
	end

	if not HttpService.HttpEnabled then
		warn("[Gameboy] HttpService is not enabled for", player.Name)
		RemoteEvents.StatusMessage:FireClient(player, "Error: HttpService is not enabled in game settings! Enable 'Allow HTTP Requests'.", false)
		return
	end

	-- Validate URL
	if not romUrl or romUrl == "" then
		RemoteEvents.StatusMessage:FireClient(player, "Error: Invalid URL", false)
		return
	end

	RemoteEvents.StatusMessage:FireClient(player, "Fetching ROM from URL...", true)

	local emulatorData = initializePlayerEmulator(player)

	-- Stop current runner if running
	if emulatorData.runner then
		task.cancel(emulatorData.runner)
		emulatorData.runner = nil
	end

	-- Fetch ROM from URL
	print("[Gameboy] Player", player.Name, "requested ROM from:", romUrl)
	
	local success, result = pcall(function()
		local response = HttpService:RequestAsync({
			Url = romUrl,
			Method = "GET"
		})
		
		print("[Gameboy] HTTP Response - Success:", response.Success, "StatusCode:", response.StatusCode)
		
		if response.Success then
			if response.StatusCode == 200 then
				local body = response.Body
				print("[Gameboy] Received ROM data, size:", #body, "bytes")
				return body
			else
				error("HTTP request failed with status code: " .. tostring(response.StatusCode))
			end
		else
			error("HTTP request failed: " .. tostring(response.StatusCode) .. " - " .. tostring(response.StatusMessage))
		end
	end)

	if not success then
		local errorMsg = tostring(result)
		warn("[Gameboy] Failed to load ROM from URL for", player.Name, ":", errorMsg)
		RemoteEvents.StatusMessage:FireClient(player, "Error: " .. errorMsg, false)
		return
	end

	local rom = result

	-- Validate ROM data
	if not rom or #rom == 0 then
		warn("[Gameboy] ROM data is empty for", player.Name)
		RemoteEvents.StatusMessage:FireClient(player, "Error: ROM file is empty or invalid", false)
		return
	end

	print("[Gameboy] ROM size:", #rom, "bytes (", math.ceil(#rom / 1024), "KB )")
	RemoteEvents.StatusMessage:FireClient(player, "Loading ROM (" .. math.ceil(#rom / 1024) .. " KB)...", true)

	-- Load ROM into emulator
	local loadSuccess, loadError = pcall(function()
		print("[Gameboy] Calling cartridge.load...")
		emulatorData.gameboy.cartridge.load(rom)
		print("[Gameboy] Cartridge loaded, calling reset...")
		emulatorData.gameboy:reset()
		print("[Gameboy] Reset complete")
	end)

	if not loadSuccess then
		warn("[Gameboy] Failed to load ROM data for", player.Name, ":", loadError)
		print("[Gameboy] Error details:", tostring(loadError))
		RemoteEvents.StatusMessage:FireClient(player, "Error: Failed to parse ROM file. Make sure it's a valid .gb or .gbc file. Details: " .. tostring(loadError), false)
		return
	end

	-- Extract game metadata from cartridge header
	local cartridge = emulatorData.gameboy.cartridge
	local header = cartridge.header
	local gameTitle = header.title or "Unknown"
	local isColor = header.color or false
	
	-- Check if cartridge has battery support
	local hasBattery = false
	if header.mbc_name then
		hasBattery = string.find(header.mbc_name:upper(), "BATTERY") ~= nil
		-- Also check for MBC3 (often has RTC with battery)
		if not hasBattery and header.mbc_type then
			hasBattery = (header.mbc_type == 0x0F or header.mbc_type == 0x10 or header.mbc_type == 0x11 or header.mbc_type == 0x12 or header.mbc_type == 0x13)
		end
	end
	
	-- Generate game ID
	local gameId = GameboyDataStore.generateGameId(gameTitle, isColor)
	
	-- Store game metadata
	emulatorData.currentGameId = gameId
	emulatorData.currentGameUrl = romUrl
	emulatorData.currentGameTitle = gameTitle
	emulatorData.currentGameIsColor = isColor
	emulatorData.hasBattery = hasBattery
	
	-- Add game to player's library
	GameboyDataStore.addGame(player, gameId, romUrl, gameTitle, isColor)
	print("[Gameboy] Game tracked:", gameTitle, "(" .. (isColor and "GBC" or "GB") .. ")", hasBattery and "with battery" or "no battery")
	
	-- Load battery RAM if available (before reset, so it gets loaded into the cartridge)
	if hasBattery then
		local batteryRam, error = GameboyDataStore.loadBatteryRam(player, gameId)
		if batteryRam then
			-- Restore external RAM to cartridge
			local externalRam = cartridge.external_ram
			for i, v in pairs(batteryRam) do
				if i ~= "dirty" then
					externalRam[i] = v
				end
			end
			externalRam.dirty = false
			print("[Gameboy] Battery RAM loaded for", player.Name, gameTitle)
		elseif error and error ~= "No battery RAM save found" then
			warn("[Gameboy] Failed to load battery RAM for", player.Name, ":", error)
		end
	end
	
	-- Notify client of current game
	print("[Gameboy] Firing CurrentGameUpdate to", player.Name, "with gameId:", gameId)
	RemoteEvents.CurrentGameUpdate:FireClient(player, gameId)

	-- Create EditableImage on server for rendering
	-- Client will create its own EditableImage
	if not emulatorData.screen then
		print("[Gameboy] Creating EditableImage for", player.Name)
		emulatorData.screen = AssetService:CreateEditableImage({ Size = size })
		-- Note: EditableImage inherits from Object, not Instance, so it doesn't have Parent or Name
		print("[Gameboy] EditableImage created on server")
	end

	-- Clear screen
	print("[Gameboy] Clearing screen...")
	emulatorData.screen:DrawRectangle(Vector2.zero, size, Color3.new(), 0, Enum.ImageCombineType.Overwrite)
	
	-- Notify client that ROM is loaded and it should create its EditableImage
	RemoteEvents.StatusMessage:FireClient(player, "ROM loaded! Creating display...", true)

	-- Start emulator thread
	print("[Gameboy] Starting emulator thread for", player.Name)
	emulatorData.runner = task.defer(runEmulatorThread, player)
	
	-- Create ProximityPrompt for spectating (wait for character to load)
	task.spawn(function()
		-- Wait for character
		if not player.Character then
			player.CharacterAdded:Wait()
		end
		-- Wait a bit for character to fully load
		task.wait(2)
		local success, err = pcall(function()
			createSpectatePrompt(player)
		end)
		if not success then
			warn("[Gameboy] Failed to create ProximityPrompt for", player.Name, ":", err)
		end
	end)
	
	RemoteEvents.StatusMessage:FireClient(player, "ROM loaded successfully! Game starting...", true)
	print("[Gameboy] ROM loading complete for", player.Name)
end)

-- Handle player input
RemoteEvents.PlayerInput.OnServerEvent:Connect(function(player: Player, key: string, pressed: boolean)
	local emulatorData = playerEmulators[player]
	if not emulatorData then
		return
	end

	local gb = emulatorData.gameboy
	if pressed then
		gb.input.keys[key] = 1
	else
		gb.input.keys[key] = 0
	end
	gb.input.update()
end)

-- Handle EditableImage request (no longer needed, but keep for compatibility)
RemoteEvents.GetEditableImage.OnServerEvent:Connect(function(player: Player)
	-- EditableImage cannot be sent via RemoteEvent
	-- Client creates its own EditableImage and receives frame data instead
end)

-- Handle save state
RemoteEvents.SaveState.OnServerEvent:Connect(function(player: Player, slotNumber: number, slotName: string?)
	local emulatorData = playerEmulators[player]
	if not emulatorData or not emulatorData.currentGameId then
		RemoteEvents.StatusMessage:FireClient(player, "Error: No game loaded", false)
		return
	end
	
	-- Get save state from emulator
	local state = emulatorData.gameboy:save_state()
	
	-- Include external RAM in save state (for full snapshot)
	local externalRam = emulatorData.gameboy.cartridge.external_ram
	if externalRam then
		-- Convert external_ram to serializable format
		local ramData = {}
		for i, v in pairs(externalRam) do
			if i ~= "dirty" and type(i) == "number" then
				ramData[i] = v
			end
		end
		state.external_ram = ramData
	end
	
	-- Save to DataStore
	local success = GameboyDataStore.saveState(
		player,
		emulatorData.currentGameId,
		slotNumber,
		state,
		slotName
	)
	
	if success then
		RemoteEvents.StatusMessage:FireClient(player, "Game saved to slot " .. slotNumber .. "!", true)
		print("[Gameboy] Save state saved for", player.Name, "game:", emulatorData.currentGameId, "slot:", slotNumber)
	else
		RemoteEvents.StatusMessage:FireClient(player, "Error: Failed to save game state", false)
	end
end)

-- Handle load state
RemoteEvents.LoadState.OnServerEvent:Connect(function(player: Player, slotNumber: number)
	local emulatorData = playerEmulators[player]
	if not emulatorData or not emulatorData.currentGameId then
		RemoteEvents.StatusMessage:FireClient(player, "Error: No game loaded", false)
		return
	end
	
	-- Load state from DataStore
	local state, error = GameboyDataStore.loadState(
		player,
		emulatorData.currentGameId,
		slotNumber
	)
	
	if not state then
		RemoteEvents.StatusMessage:FireClient(player, "Error: " .. (error or "Failed to load save state"), false)
		return
	end
	
	-- Restore external RAM if present in save state
	local externalRamData = state.external_ram
	if externalRamData then
		local externalRam = emulatorData.gameboy.cartridge.external_ram
		if externalRam then
			-- Clear existing RAM
			for i in pairs(externalRam) do
				if i ~= "dirty" and type(i) == "number" then
					externalRam[i] = nil
				end
			end
			-- Restore from save state
			for i, v in pairs(externalRamData) do
				externalRam[i] = v
			end
			externalRam.dirty = false
		end
		-- Remove from state so it doesn't interfere with load_state
		state.external_ram = nil
	end
	
	-- Load state into emulator
	local success, loadError = pcall(function()
		-- Debug: Check PC before loading
		local pcBefore = emulatorData.gameboy.processor.registers.pc
		print("[Gameboy] Loading save state - PC before:", string.format("0x%04X", pcBefore))
		
		-- Ensure cartridge has data (loaded flag might be false after reset, but data is still there)
		if not emulatorData.gameboy.cartridge.header or not emulatorData.gameboy.cartridge.raw_data then
			warn("[Gameboy] WARNING: Cartridge data missing before loading save state!")
			RemoteEvents.StatusMessage:FireClient(player, "Error: Cartridge data missing", false)
			return
		end
		
		emulatorData.gameboy:load_state(state)
		
		-- Debug: Check PC after loading
		local pcAfter = emulatorData.gameboy.processor.registers.pc
		print("[Gameboy] Loading save state - PC after:", string.format("0x%04X", pcAfter))
		
		-- Verify cartridge data is still accessible after loading state
		if not emulatorData.gameboy.cartridge.header or not emulatorData.gameboy.cartridge.raw_data then
			warn("[Gameboy] WARNING: Cartridge data missing after loading save state!")
		else
			emulatorData.gameboy.cartridge.loaded = true
		end
		
		-- Check if PC is valid (not at entry point, which would indicate a reset)
		if pcAfter == 0x100 then
			warn("[Gameboy] WARNING: PC is at entry point (0x100) after loading - state may be invalid!")
		end
		
		-- Verify we can read from the PC address (sanity check)
		local testRead = emulatorData.gameboy.memory.read_byte(pcAfter)
		if testRead == nil then
			warn("[Gameboy] WARNING: Cannot read from PC address after loading state!")
		end
	end)
	
	if success then
		RemoteEvents.StatusMessage:FireClient(player, "Game loaded from slot " .. slotNumber .. "!", true)
		print("[Gameboy] Save state loaded for", player.Name, "game:", emulatorData.currentGameId, "slot:", slotNumber)
	else
		RemoteEvents.StatusMessage:FireClient(player, "Error: Failed to load game state: " .. tostring(loadError), false)
		warn("[Gameboy] Failed to load save state:", loadError)
	end
end)

-- Handle get player games
RemoteEvents.GetPlayerGames.OnServerEvent:Connect(function(player: Player)
	local games = GameboyDataStore.getAllGames(player)
	RemoteEvents.GetPlayerGames:FireClient(player, games)
end)

-- Handle delete save slot
RemoteEvents.DeleteSaveSlot.OnServerEvent:Connect(function(player: Player, gameId: string, slotNumber: number)
	local success = GameboyDataStore.deleteSlot(player, gameId, slotNumber)
	if success then
		RemoteEvents.StatusMessage:FireClient(player, "Save slot deleted", true)
		-- Refresh games list
		local games = GameboyDataStore.getAllGames(player)
		RemoteEvents.GetPlayerGames:FireClient(player, games)
	else
		RemoteEvents.StatusMessage:FireClient(player, "Error: Failed to delete save slot", false)
	end
end)

-- Handle reload game
RemoteEvents.ReloadGame.OnServerEvent:Connect(function(player: Player, gameId: string)
	local games = GameboyDataStore.getAllGames(player)
	local gameData = games[gameId]
	
	if not gameData then
		RemoteEvents.StatusMessage:FireClient(player, "Error: Game not found in library", false)
		return
	end
	
	-- Trigger ROM load with the stored URL
	-- We'll fire the LoadROM event internally
	task.spawn(function()
		-- Wait a frame to avoid recursion issues
		task.wait()
		-- Fire the LoadROM event handler directly
		local success, err = pcall(function()
			-- Get the emulator data
			local emulatorData = playerEmulators[player]
			if not emulatorData then
				emulatorData = initializePlayerEmulator(player)
			end
			
			-- Stop current runner if running
			if emulatorData.runner then
				task.cancel(emulatorData.runner)
				emulatorData.runner = nil
			end
			
			-- Fetch ROM from URL
			local httpSuccess, result = pcall(function()
				local response = HttpService:RequestAsync({
					Url = gameData.url,
					Method = "GET"
				})
				
				if response.Success and response.StatusCode == 200 then
					return response.Body
				else
					error("HTTP request failed with status code: " .. tostring(response.StatusCode))
				end
			end)
			
			if not httpSuccess then
				RemoteEvents.StatusMessage:FireClient(player, "Error: " .. tostring(result), false)
				return
			end
			
			local rom = result
			
			-- Load ROM into emulator
			local loadSuccess, loadError = pcall(function()
				emulatorData.gameboy.cartridge.load(rom)
				emulatorData.gameboy:reset()
			end)
			
			if not loadSuccess then
				RemoteEvents.StatusMessage:FireClient(player, "Error: Failed to load ROM: " .. tostring(loadError), false)
				return
			end
			
			-- Extract game metadata
			local cartridge = emulatorData.gameboy.cartridge
			local header = cartridge.header
			local gameTitle = header.title or "Unknown"
			local isColor = header.color or false
			local gameId = GameboyDataStore.generateGameId(gameTitle, isColor)
			
			-- Store game metadata
			emulatorData.currentGameId = gameId
			emulatorData.currentGameUrl = gameData.url
			emulatorData.currentGameTitle = gameTitle
			emulatorData.currentGameIsColor = isColor
			
			-- Update last played
			GameboyDataStore.addGame(player, gameId, gameData.url, gameTitle, isColor)
			
			-- Clear screen and start emulator
			if emulatorData.screen then
				emulatorData.screen:DrawRectangle(Vector2.zero, size, Color3.new(), 0, Enum.ImageCombineType.Overwrite)
			end
			
			emulatorData.runner = task.defer(runEmulatorThread, player)
			
			-- Notify client of current game (so save button appears)
			RemoteEvents.CurrentGameUpdate:FireClient(player, gameId)
			
			-- Recreate ProximityPrompt
			task.spawn(function()
				if not player.Character then
					player.CharacterAdded:Wait()
				end
				task.wait(1)
				createSpectatePrompt(player)
			end)
			
			RemoteEvents.StatusMessage:FireClient(player, "Game reloaded!", true)
		end)
		
		if not success then
			RemoteEvents.StatusMessage:FireClient(player, "Error reloading game: " .. tostring(err), false)
		end
	end)
end)

-- Handle update slot name
RemoteEvents.UpdateSlotName.OnServerEvent:Connect(function(player: Player, gameId: string, slotNumber: number, newName: string)
	local playerData = GameboyDataStore.getPlayerData(player)
	
	if not playerData.games[gameId] then
		return
	end
	
	local slot = playerData.games[gameId].saveSlots[slotNumber]
	if slot then
		slot.name = newName
		GameboyDataStore.savePlayerData(player, playerData)
		
		-- Refresh games list
		local games = GameboyDataStore.getAllGames(player)
		RemoteEvents.GetPlayerGames:FireClient(player, games)
	end
end)

-- Handle start spectating
RemoteEvents.StartSpectating.OnServerEvent:Connect(function(spectator: Player, targetPlayerId: number)
	local targetPlayer = Players:GetPlayerByUserId(targetPlayerId)
	if not targetPlayer or not targetPlayer.Parent then
		RemoteEvents.SpectatorUpdate:FireClient(spectator, false, nil, "Player not found")
		return
	end
	
	-- Check if target player is playing
	local emulatorData = playerEmulators[targetPlayer]
	if not emulatorData or not emulatorData.runner then
		RemoteEvents.SpectatorUpdate:FireClient(spectator, false, nil, "Player is not playing")
		return
	end
	
	-- Can't spectate yourself
	if spectator == targetPlayer then
		return
	end
	
	-- Initialize spectators table if needed
	if not spectators[targetPlayer] then
		spectators[targetPlayer] = {}
	end
	
	-- Add spectator
	spectators[targetPlayer][spectator] = true
	spectating[spectator] = targetPlayer
	
	-- Notify spectator
	RemoteEvents.SpectatorUpdate:FireClient(
		spectator,
		true,
		targetPlayer.Name,
		emulatorData.currentGameTitle or "Unknown Game"
	)
	
	print("[Gameboy] Player", spectator.Name, "is now spectating", targetPlayer.Name)
end)

-- Handle stop spectating
RemoteEvents.StopSpectating.OnServerEvent:Connect(function(spectator: Player)
	local targetPlayer = spectating[spectator]
	if not targetPlayer then
		return
	end
	
	-- Remove from spectators list
	if spectators[targetPlayer] then
		spectators[targetPlayer][spectator] = nil
	end
	spectating[spectator] = nil
	
	-- Notify spectator
	RemoteEvents.SpectatorUpdate:FireClient(spectator, false, nil, nil)
	
	print("[Gameboy] Player", spectator.Name, "stopped spectating", targetPlayer.Name)
end)

-- Handle camera capture response from client
print("[GB Camera Server] Setting up CameraCaptureResponse OnServerEvent handler...")
local cameraResponseHandler = RemoteEvents.CameraCaptureResponse.OnServerEvent:Connect(function(player: Player, imageData)
	print(string.format("[GB Camera Server] ========================================"))
	print(string.format("[GB Camera Server] OnServerEvent triggered for player %s", player.Name))
	
	local emulatorData = playerEmulators[player]
	if not emulatorData then
		warn(string.format("[GB Camera Server] No emulator data found for player %s", player.Name))
		return
	end
	
	if not emulatorData.gameboy then
		warn(string.format("[GB Camera Server] No gameboy instance found for player %s", player.Name))
		return
	end
	
	if not emulatorData.gameboy.camera then
		warn(string.format("[GB Camera Server] No camera instance found for player %s", player.Name))
		return
	end
	
	print(string.format("[GB Camera Server] Received capture from %s, routing to camera instance", player.Name))
	
	-- Verify imageData structure
	if imageData then
		local rowCount = 0
		for y = 0, 111 do
			if imageData[y] then
				rowCount = rowCount + 1
			end
		end
		print(string.format("[GB Camera Server] Image data received: %d rows", rowCount))
		
		-- Sample center pixel
		if imageData[56] and imageData[56][64] then
			local p = imageData[56][64]
			print(string.format("[GB Camera Server] Center pixel: R=%d G=%d B=%d", p[1] or 0, p[2] or 0, p[3] or 0))
		end
	else
		warn(string.format("[GB Camera Server] Image data is nil for player %s", player.Name))
		return
	end
	
	-- Set pending capture
	if emulatorData.gameboy.camera.setPendingCapture then
		print(string.format("[GB Camera Server] Using setPendingCapture method"))
		emulatorData.gameboy.camera.setPendingCapture(imageData)
	else
		-- Fallback: set directly
		print(string.format("[GB Camera Server] Using direct assignment (fallback)"))
		emulatorData.gameboy.camera.pendingCapture = imageData
		emulatorData.gameboy.camera.captureInProgress = false
	end
	
	print(string.format("[GB Camera Server] Pending capture set successfully"))
	print(string.format("[GB Camera Server] ========================================"))
end)
print(string.format("[GB Camera Server] CameraCaptureResponse handler connected: %s", 
	tostring(cameraResponseHandler)))
print(string.format("[GB Camera Server] RemoteEvent instance: %s", 
	RemoteEvents.CameraCaptureResponse:GetFullName()))

-- Handle get leaderboard
RemoteEvents.GetLeaderboard.OnServerEvent:Connect(function(player: Player, gameId: string)
	local leaderboard = GameboyDataStore.getLeaderboard(gameId, 10)
	RemoteEvents.LeaderboardUpdate:FireClient(player, gameId, leaderboard)
end)

-- Clean up when player leaves
Players.PlayerRemoving:Connect(function(player: Player)
	-- If player was spectating, stop spectating
	if spectating[player] then
		local targetPlayer = spectating[player]
		if spectators[targetPlayer] then
			spectators[targetPlayer][player] = nil
		end
		spectating[player] = nil
	end
	
	-- Clean up emulator (this also handles notifying spectators)
	cleanupPlayerEmulator(player)
end)
