local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

-- Get player controls module for movement lock
local playerControlsModule = require(Players.LocalPlayer.PlayerScripts:WaitForChild("PlayerModule"))
local playerControls = playerControlsModule:GetControls()

-- Movement lock state (default: locked)
local movementLocked = true

-- Lock movement by default on startup
task.spawn(function()
	task.wait(0.5) -- Wait for character to load
	if movementLocked then
		playerControls:Disable()
	end
end)

-- Wait for RemoteEvents to be available
local RemoteEvents
local success, err = pcall(function()
	RemoteEvents = require(ReplicatedStorage:WaitForChild("RemoteEvents"))
end)

if not success then
	warn("[Gameboy Client] Failed to load RemoteEvents:", err)
	return
end

-- Verify RemoteEvents are accessible
print("[Gameboy Client] RemoteEvents loaded:")
print("  - LoadROM:", RemoteEvents.LoadROM and "OK" or "MISSING")
print("  - PlayerInput:", RemoteEvents.PlayerInput and "OK" or "MISSING")
print("  - GetEditableImage:", RemoteEvents.GetEditableImage and "OK" or "MISSING")
print("  - StatusMessage:", RemoteEvents.StatusMessage and "OK" or "MISSING")
print("  - CameraCaptureRequest:", RemoteEvents.CameraCaptureRequest and "OK" or "MISSING")
print("  - CameraCaptureResponse:", RemoteEvents.CameraCaptureResponse and "OK" or "MISSING")

-- Double-check by getting from ReplicatedStorage directly
local loadROMCheck = ReplicatedStorage:FindFirstChild("LoadROM")
print("[Gameboy Client] LoadROM in ReplicatedStorage:", loadROMCheck and "Found" or "NOT FOUND")
if loadROMCheck then
	print("[Gameboy Client] LoadROM type:", loadROMCheck.ClassName)
end

local WIDTH = 160
local HEIGHT = 144

-- Create main GUI
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "GameboyEmulator"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

-- Main container frame (full screen with padding)
local mainFrame = Instance.new("Frame")
mainFrame.Name = "MainFrame"
mainFrame.Size = UDim2.new(1, -40, 1, -40)
mainFrame.Position = UDim2.new(0, 20, 0, 20)
mainFrame.BackgroundTransparency = 1
mainFrame.Parent = screenGui

-- Left panel - Emulator Display
local displayPanel = Instance.new("Frame")
displayPanel.Name = "DisplayPanel"
displayPanel.Size = UDim2.new(0, 520, 1, 0)
displayPanel.Position = UDim2.new(0, 0, 0, 0)
displayPanel.BackgroundColor3 = Color3.fromRGB(25, 25, 28)
displayPanel.BorderSizePixel = 0
displayPanel.Parent = mainFrame

local displayCorner = Instance.new("UICorner")
displayCorner.CornerRadius = UDim.new(0, 12)
displayCorner.Parent = displayPanel

-- Title bar for display panel
local displayTitle = Instance.new("Frame")
displayTitle.Name = "TitleBar"
displayTitle.Size = UDim2.new(1, 0, 0, 50)
displayTitle.Position = UDim2.new(0, 0, 0, 0)
displayTitle.BackgroundColor3 = Color3.fromRGB(35, 35, 40)
displayTitle.BorderSizePixel = 0
displayTitle.Parent = displayPanel

local displayTitleCorner = Instance.new("UICorner")
displayTitleCorner.CornerRadius = UDim.new(0, 12)
displayTitleCorner.Parent = displayTitle

-- Fix bottom corners
local displayTitleBottom = Instance.new("Frame")
displayTitleBottom.Size = UDim2.new(1, 0, 0, 12)
displayTitleBottom.Position = UDim2.new(0, 0, 1, -12)
displayTitleBottom.BackgroundColor3 = Color3.fromRGB(35, 35, 40)
displayTitleBottom.BorderSizePixel = 0
displayTitleBottom.Parent = displayTitle

local titleLabel = Instance.new("TextLabel")
titleLabel.Name = "Title"
titleLabel.Size = UDim2.new(1, -80, 1, 0)
titleLabel.Position = UDim2.new(0, 20, 0, 0)
titleLabel.BackgroundTransparency = 1
titleLabel.Text = "Game Boy Emulator"
titleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
titleLabel.TextSize = 18
titleLabel.Font = Enum.Font.GothamBold
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.Parent = displayTitle

-- Minimize button for emulator
local minimizeButton = Instance.new("TextButton")
minimizeButton.Name = "MinimizeButton"
minimizeButton.Size = UDim2.new(0, 40, 0, 32)
minimizeButton.Position = UDim2.new(1, -50, 0, 9)
minimizeButton.BackgroundColor3 = Color3.fromRGB(60, 60, 65)
minimizeButton.BorderSizePixel = 0
minimizeButton.Text = "−"
minimizeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
minimizeButton.TextSize = 24
minimizeButton.Font = Enum.Font.GothamBold
minimizeButton.AutoButtonColor = false
minimizeButton.Parent = displayTitle

local minimizeCorner = Instance.new("UICorner")
minimizeCorner.CornerRadius = UDim.new(0, 6)
minimizeCorner.Parent = minimizeButton

-- Minimized button (shown when UI is minimized)
local minimizedButton = Instance.new("TextButton")
minimizedButton.Name = "MinimizedButton"
minimizedButton.Size = UDim2.new(0, 60, 0, 60)
minimizedButton.Position = UDim2.new(1, -80, 0, 20)
minimizedButton.AnchorPoint = Vector2.new(1, 0)
minimizedButton.BackgroundColor3 = Color3.fromRGB(88, 101, 242)
minimizedButton.BorderSizePixel = 0
minimizedButton.Text = "📱"
minimizedButton.TextColor3 = Color3.fromRGB(255, 255, 255)
minimizedButton.TextSize = 24
minimizedButton.Font = Enum.Font.Gotham
minimizedButton.AutoButtonColor = false
minimizedButton.Visible = false
minimizedButton.ZIndex = 100
minimizedButton.Parent = screenGui

local minimizedCorner = Instance.new("UICorner")
minimizedCorner.CornerRadius = UDim.new(0, 12)
minimizedCorner.Parent = minimizedButton

-- Tooltip for minimized button
local tooltip = Instance.new("TextLabel")
tooltip.Name = "Tooltip"
tooltip.Size = UDim2.new(0, 150, 0, 30)
tooltip.Position = UDim2.new(1, 10, 0, 0)
tooltip.AnchorPoint = Vector2.new(0, 0.5)
tooltip.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
tooltip.BorderSizePixel = 0
tooltip.Text = "Click to open emulator"
tooltip.TextColor3 = Color3.fromRGB(255, 255, 255)
tooltip.TextSize = 12
tooltip.Font = Enum.Font.Gotham
tooltip.Visible = false
tooltip.ZIndex = 101
tooltip.Parent = minimizedButton

local tooltipCorner = Instance.new("UICorner")
tooltipCorner.CornerRadius = UDim.new(0, 6)
tooltipCorner.Parent = tooltip

local tooltipPadding = Instance.new("UIPadding")
tooltipPadding.PaddingLeft = UDim.new(0, 8)
tooltipPadding.PaddingRight = UDim.new(0, 8)
tooltipPadding.Parent = tooltip

-- Show tooltip on hover
minimizedButton.MouseEnter:Connect(function()
	tooltip.Visible = true
end)

minimizedButton.MouseLeave:Connect(function()
	tooltip.Visible = false
end)

-- Track minimized state
local isMinimized = false

-- Minimize/maximize functionality
local function toggleMinimize()
	isMinimized = not isMinimized
	mainFrame.Visible = not isMinimized
	minimizedButton.Visible = isMinimized
	
	if isMinimized then
		minimizeButton.Text = "+"
	else
		minimizeButton.Text = "−"
	end
end

minimizeButton.MouseButton1Click:Connect(toggleMinimize)
minimizedButton.MouseButton1Click:Connect(toggleMinimize)

-- Emulator screen container
local screenContainer = Instance.new("Frame")
screenContainer.Name = "ScreenContainer"
screenContainer.Size = UDim2.new(1, -40, 1, -90)
screenContainer.Position = UDim2.new(0, 20, 0, 70)
screenContainer.BackgroundColor3 = Color3.fromRGB(15, 15, 18)
screenContainer.BorderSizePixel = 0
screenContainer.Parent = displayPanel

local screenCorner = Instance.new("UICorner")
screenCorner.CornerRadius = UDim.new(0, 8)
screenCorner.Parent = screenContainer

-- Emulator display (scaled to fit nicely)
local displayFrame = Instance.new("Frame")
displayFrame.Name = "DisplayFrame"
displayFrame.Size = UDim2.new(0, WIDTH * 2.8, 0, HEIGHT * 2.8)
displayFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
displayFrame.AnchorPoint = Vector2.new(0.5, 0.5)
displayFrame.BackgroundColor3 = Color3.new(0, 0, 0)
displayFrame.BorderSizePixel = 0
displayFrame.Parent = screenContainer

local displayCorner2 = Instance.new("UICorner")
displayCorner2.CornerRadius = UDim.new(0, 4)
displayCorner2.Parent = displayFrame

local screenImage = Instance.new("ImageLabel")
screenImage.Name = "Screen"
screenImage.Size = UDim2.new(1, 0, 1, 0)
screenImage.Position = UDim2.new(0, 0, 0, 0)
screenImage.BackgroundTransparency = 1
screenImage.ResampleMode = Enum.ResamplerMode.Pixelated
screenImage.Parent = displayFrame

local aspectRatio = Instance.new("UIAspectRatioConstraint")
aspectRatio.AspectRatio = WIDTH / HEIGHT
aspectRatio.Parent = screenImage

-- Right panel - Controls and Info
local controlPanel = Instance.new("Frame")
controlPanel.Name = "ControlPanel"
controlPanel.Size = UDim2.new(1, -540, 1, 0)
controlPanel.Position = UDim2.new(0, 540, 0, 0)
controlPanel.BackgroundTransparency = 1
controlPanel.Parent = mainFrame

-- ============================================
-- COMBINED ROM & Actions Container
-- ============================================
local combinedSection = Instance.new("Frame")
combinedSection.Name = "CombinedSection"
combinedSection.Size = UDim2.new(1, 0, 0, 300)
combinedSection.Position = UDim2.new(0, 0, 0, 0)
combinedSection.BackgroundColor3 = Color3.fromRGB(25, 25, 28)
combinedSection.BorderSizePixel = 0
combinedSection.ClipsDescendants = true
combinedSection.Parent = controlPanel

local combinedCorner = Instance.new("UICorner")
combinedCorner.CornerRadius = UDim.new(0, 12)
combinedCorner.Parent = combinedSection

-- Title bar for combined section
local combinedTitleBar = Instance.new("Frame")
combinedTitleBar.Name = "TitleBar"
combinedTitleBar.Size = UDim2.new(1, 0, 0, 40)
combinedTitleBar.Position = UDim2.new(0, 0, 0, 0)
combinedTitleBar.BackgroundColor3 = Color3.fromRGB(35, 35, 40)
combinedTitleBar.BorderSizePixel = 0
combinedTitleBar.Parent = combinedSection

local combinedTitleCorner = Instance.new("UICorner")
combinedTitleCorner.CornerRadius = UDim.new(0, 12)
combinedTitleCorner.Parent = combinedTitleBar

-- Fix bottom corners
local combinedTitleBottom = Instance.new("Frame")
combinedTitleBottom.Size = UDim2.new(1, 0, 0, 12)
combinedTitleBottom.Position = UDim2.new(0, 0, 1, -12)
combinedTitleBottom.BackgroundColor3 = Color3.fromRGB(35, 35, 40)
combinedTitleBottom.BorderSizePixel = 0
combinedTitleBottom.Parent = combinedTitleBar

local combinedTitleLabel = Instance.new("TextLabel")
combinedTitleLabel.Name = "Title"
combinedTitleLabel.Size = UDim2.new(1, -60, 1, 0)
combinedTitleLabel.Position = UDim2.new(0, 15, 0, 0)
combinedTitleLabel.BackgroundTransparency = 1
combinedTitleLabel.Text = "ROM & Actions"
combinedTitleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
combinedTitleLabel.TextSize = 14
combinedTitleLabel.Font = Enum.Font.GothamBold
combinedTitleLabel.TextXAlignment = Enum.TextXAlignment.Left
combinedTitleLabel.Parent = combinedTitleBar

-- Minimize button for combined section
local combinedMinimizeBtn = Instance.new("TextButton")
combinedMinimizeBtn.Name = "MinimizeButton"
combinedMinimizeBtn.Size = UDim2.new(0, 32, 0, 26)
combinedMinimizeBtn.Position = UDim2.new(1, -42, 0, 7)
combinedMinimizeBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 65)
combinedMinimizeBtn.BorderSizePixel = 0
combinedMinimizeBtn.Text = "−"
combinedMinimizeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
combinedMinimizeBtn.TextSize = 20
combinedMinimizeBtn.Font = Enum.Font.GothamBold
combinedMinimizeBtn.AutoButtonColor = false
combinedMinimizeBtn.Parent = combinedTitleBar

local combinedMinimizeCorner = Instance.new("UICorner")
combinedMinimizeCorner.CornerRadius = UDim.new(0, 4)
combinedMinimizeCorner.Parent = combinedMinimizeBtn

-- Content container (inside combined section)
local combinedContent = Instance.new("Frame")
combinedContent.Name = "Content"
combinedContent.Size = UDim2.new(1, -30, 1, -55)
combinedContent.Position = UDim2.new(0, 15, 0, 48)
combinedContent.BackgroundTransparency = 1
combinedContent.Parent = combinedSection

-- URL input
local urlTextBox = Instance.new("TextBox")
urlTextBox.Name = "URLTextBox"
urlTextBox.Size = UDim2.new(1, 0, 0, 36)
urlTextBox.Position = UDim2.new(0, 0, 0, 0)
urlTextBox.BackgroundColor3 = Color3.fromRGB(35, 35, 40)
urlTextBox.BorderSizePixel = 0
urlTextBox.Text = ""
urlTextBox.PlaceholderText = "Enter ROM URL..."
urlTextBox.TextColor3 = Color3.new(1, 1, 1)
urlTextBox.TextSize = 12
urlTextBox.Font = Enum.Font.Gotham
urlTextBox.TextXAlignment = Enum.TextXAlignment.Left
urlTextBox.ClearTextOnFocus = false
urlTextBox.Parent = combinedContent

local urlCorner = Instance.new("UICorner")
urlCorner.CornerRadius = UDim.new(0, 6)
urlCorner.Parent = urlTextBox

local urlPadding = Instance.new("UIPadding")
urlPadding.PaddingLeft = UDim.new(0, 10)
urlPadding.PaddingRight = UDim.new(0, 10)
urlPadding.Parent = urlTextBox

-- Load ROM button
local loadButton = Instance.new("TextButton")
loadButton.Name = "LoadButton"
loadButton.Size = UDim2.new(1, 0, 0, 36)
loadButton.Position = UDim2.new(0, 0, 0, 42)
loadButton.BackgroundColor3 = Color3.fromRGB(88, 101, 242)
loadButton.BorderSizePixel = 0
loadButton.Text = "Load ROM"
loadButton.TextColor3 = Color3.new(1, 1, 1)
loadButton.TextSize = 13
loadButton.Font = Enum.Font.GothamBold
loadButton.AutoButtonColor = false
loadButton.Parent = combinedContent

local loadCorner = Instance.new("UICorner")
loadCorner.CornerRadius = UDim.new(0, 6)
loadCorner.Parent = loadButton

-- Separator line
local separator = Instance.new("Frame")
separator.Name = "Separator"
separator.Size = UDim2.new(1, 0, 0, 1)
separator.Position = UDim2.new(0, 0, 0, 90)
separator.BackgroundColor3 = Color3.fromRGB(50, 50, 55)
separator.BorderSizePixel = 0
separator.Parent = combinedContent

-- Library button
local dashboardButton = Instance.new("TextButton")
dashboardButton.Name = "DashboardButton"
dashboardButton.Size = UDim2.new(1, 0, 0, 36)
dashboardButton.Position = UDim2.new(0, 0, 0, 102)
dashboardButton.BackgroundColor3 = Color3.fromRGB(87, 75, 144)
dashboardButton.BorderSizePixel = 0
dashboardButton.Text = "📚 Library"
dashboardButton.TextColor3 = Color3.new(1, 1, 1)
dashboardButton.TextSize = 13
dashboardButton.Font = Enum.Font.GothamBold
dashboardButton.AutoButtonColor = false
dashboardButton.Parent = combinedContent

local dashboardCorner = Instance.new("UICorner")
dashboardCorner.CornerRadius = UDim.new(0, 6)
dashboardCorner.Parent = dashboardButton

-- Save button
local saveButton = Instance.new("TextButton")
saveButton.Name = "SaveButton"
saveButton.Size = UDim2.new(1, 0, 0, 36)
saveButton.Position = UDim2.new(0, 0, 0, 144)
saveButton.BackgroundColor3 = Color3.fromRGB(67, 181, 129)
saveButton.BorderSizePixel = 0
saveButton.Text = "💾 Save Game"
saveButton.TextColor3 = Color3.new(1, 1, 1)
saveButton.TextSize = 13
saveButton.Font = Enum.Font.GothamBold
saveButton.Visible = false
saveButton.AutoButtonColor = false
saveButton.Parent = combinedContent

local saveCorner = Instance.new("UICorner")
saveCorner.CornerRadius = UDim.new(0, 6)
saveCorner.Parent = saveButton

-- Leaderboard button
local leaderboardButton = Instance.new("TextButton")
leaderboardButton.Name = "LeaderboardButton"
leaderboardButton.Size = UDim2.new(1, 0, 0, 36)
leaderboardButton.Position = UDim2.new(0, 0, 0, 186)
leaderboardButton.BackgroundColor3 = Color3.fromRGB(255, 165, 0)
leaderboardButton.BorderSizePixel = 0
leaderboardButton.Text = "🏆 Leaderboard"
leaderboardButton.TextColor3 = Color3.new(1, 1, 1)
leaderboardButton.TextSize = 13
leaderboardButton.Font = Enum.Font.GothamBold
leaderboardButton.Visible = false
leaderboardButton.AutoButtonColor = false
leaderboardButton.Parent = combinedContent

local leaderboardCorner = Instance.new("UICorner")
leaderboardCorner.CornerRadius = UDim.new(0, 6)
leaderboardCorner.Parent = leaderboardButton

-- Track combined section minimized state
local isCombinedMinimized = false
local combinedExpandedHeight = 300
local combinedMinimizedHeight = 40

local function toggleCombinedMinimize()
	isCombinedMinimized = not isCombinedMinimized
	
	if isCombinedMinimized then
		combinedMinimizeBtn.Text = "+"
		TweenService:Create(combinedSection, TweenInfo.new(0.2), {
			Size = UDim2.new(1, 0, 0, combinedMinimizedHeight)
		}):Play()
	else
		combinedMinimizeBtn.Text = "−"
		TweenService:Create(combinedSection, TweenInfo.new(0.2), {
			Size = UDim2.new(1, 0, 0, combinedExpandedHeight)
		}):Play()
	end
	
	-- Update controls section position
	task.spawn(function()
		task.wait(0.21)
		if isCombinedMinimized then
			controlsSection.Position = UDim2.new(0, 0, 0, combinedMinimizedHeight + 20)
			controlsSection.Size = UDim2.new(1, 0, 1, -(combinedMinimizedHeight + 20))
		else
			controlsSection.Position = UDim2.new(0, 0, 0, combinedExpandedHeight + 20)
			controlsSection.Size = UDim2.new(1, 0, 1, -(combinedExpandedHeight + 20))
		end
	end)
end

combinedMinimizeBtn.MouseButton1Click:Connect(toggleCombinedMinimize)

-- ============================================
-- Controls Section (with movement toggle)
-- ============================================
local controlsSection = Instance.new("Frame")
controlsSection.Name = "ControlsSection"
controlsSection.Size = UDim2.new(1, 0, 1, -320)
controlsSection.Position = UDim2.new(0, 0, 0, 320)
controlsSection.BackgroundColor3 = Color3.fromRGB(25, 25, 28)
controlsSection.BorderSizePixel = 0
controlsSection.Parent = controlPanel

local controlsCorner = Instance.new("UICorner")
controlsCorner.CornerRadius = UDim.new(0, 12)
controlsCorner.Parent = controlsSection

local controlsPadding = Instance.new("UIPadding")
controlsPadding.PaddingTop = UDim.new(0, 15)
controlsPadding.PaddingBottom = UDim.new(0, 15)
controlsPadding.PaddingLeft = UDim.new(0, 15)
controlsPadding.PaddingRight = UDim.new(0, 15)
controlsPadding.Parent = controlsSection

local controlsTitle = Instance.new("TextLabel")
controlsTitle.Name = "Title"
controlsTitle.Size = UDim2.new(1, 0, 0, 20)
controlsTitle.Position = UDim2.new(0, 0, 0, 0)
controlsTitle.BackgroundTransparency = 1
controlsTitle.Text = "Controls"
controlsTitle.TextColor3 = Color3.fromRGB(200, 200, 200)
controlsTitle.TextSize = 14
controlsTitle.Font = Enum.Font.GothamBold
controlsTitle.TextXAlignment = Enum.TextXAlignment.Left
controlsTitle.Parent = controlsSection

local controlsInfo = Instance.new("TextLabel")
controlsInfo.Name = "Info"
controlsInfo.Size = UDim2.new(1, 0, 0, 80)
controlsInfo.Position = UDim2.new(0, 0, 0, 25)
controlsInfo.BackgroundTransparency = 1
controlsInfo.Text = "Arrow Keys / WASD - D-Pad\nX - A Button\nZ - B Button\nEnter - Start\nRight Shift - Select"
controlsInfo.TextColor3 = Color3.fromRGB(160, 160, 160)
controlsInfo.TextSize = 11
controlsInfo.Font = Enum.Font.Gotham
controlsInfo.TextXAlignment = Enum.TextXAlignment.Left
controlsInfo.TextYAlignment = Enum.TextYAlignment.Top
controlsInfo.TextWrapped = true
controlsInfo.Parent = controlsSection

-- Movement Toggle Button
local movementToggleBtn = Instance.new("TextButton")
movementToggleBtn.Name = "MovementToggle"
movementToggleBtn.Size = UDim2.new(1, 0, 0, 36)
movementToggleBtn.Position = UDim2.new(0, 0, 0, 115)
movementToggleBtn.BackgroundColor3 = Color3.fromRGB(200, 80, 80)
movementToggleBtn.BorderSizePixel = 0
movementToggleBtn.Text = "🔒 Movement Locked"
movementToggleBtn.TextColor3 = Color3.new(1, 1, 1)
movementToggleBtn.TextSize = 12
movementToggleBtn.Font = Enum.Font.GothamBold
movementToggleBtn.AutoButtonColor = false
movementToggleBtn.Parent = controlsSection

local movementToggleCorner = Instance.new("UICorner")
movementToggleCorner.CornerRadius = UDim.new(0, 6)
movementToggleCorner.Parent = movementToggleBtn

-- Movement hint
local movementHint = Instance.new("TextLabel")
movementHint.Name = "MovementHint"
movementHint.Size = UDim2.new(1, 0, 0, 24)
movementHint.Position = UDim2.new(0, 0, 0, 155)
movementHint.BackgroundTransparency = 1
movementHint.Text = "Unlock to use GB Camera & explore"
movementHint.TextColor3 = Color3.fromRGB(120, 120, 120)
movementHint.TextSize = 10
movementHint.Font = Enum.Font.Gotham
movementHint.TextXAlignment = Enum.TextXAlignment.Center
movementHint.Parent = controlsSection

-- Movement toggle function
local function toggleMovement()
	movementLocked = not movementLocked
	
	if movementLocked then
		playerControls:Disable()
		movementToggleBtn.Text = "🔒 Movement Locked"
		movementToggleBtn.BackgroundColor3 = Color3.fromRGB(200, 80, 80)
		movementHint.Text = "Unlock to use GB Camera & explore"
	else
		playerControls:Enable()
		movementToggleBtn.Text = "🔓 Movement Unlocked"
		movementToggleBtn.BackgroundColor3 = Color3.fromRGB(80, 180, 100)
		movementHint.Text = "Lock to prevent accidental movement"
	end
end

movementToggleBtn.MouseButton1Click:Connect(toggleMovement)

-- Status label (overlay on display)
local statusLabel = Instance.new("TextLabel")
statusLabel.Name = "StatusLabel"
statusLabel.Size = UDim2.new(1, -40, 0, 40)
statusLabel.Position = UDim2.new(0, 20, 1, -60)
statusLabel.BackgroundColor3 = Color3.fromRGB(40, 40, 45)
statusLabel.BackgroundTransparency = 0.1
statusLabel.BorderSizePixel = 0
statusLabel.Text = ""
statusLabel.TextColor3 = Color3.new(1, 1, 1)
statusLabel.TextSize = 12
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.TextYAlignment = Enum.TextYAlignment.Center
statusLabel.Visible = false
statusLabel.ZIndex = 10
statusLabel.Parent = displayPanel

local statusCorner = Instance.new("UICorner")
statusCorner.CornerRadius = UDim.new(0, 6)
statusCorner.Parent = statusLabel

local statusPadding = Instance.new("UIPadding")
statusPadding.PaddingLeft = UDim.new(0, 15)
statusPadding.PaddingRight = UDim.new(0, 15)
statusPadding.Parent = statusLabel

-- Button hover effects
local function addHoverEffect(button: TextButton, normalColor: Color3, hoverColor: Color3)
	button.MouseEnter:Connect(function()
		TweenService:Create(button, TweenInfo.new(0.2), {BackgroundColor3 = hoverColor}):Play()
	end)
	button.MouseLeave:Connect(function()
		TweenService:Create(button, TweenInfo.new(0.2), {BackgroundColor3 = normalColor}):Play()
	end)
end

addHoverEffect(loadButton, Color3.fromRGB(88, 101, 242), Color3.fromRGB(98, 111, 252))
addHoverEffect(dashboardButton, Color3.fromRGB(87, 75, 144), Color3.fromRGB(97, 85, 154))
addHoverEffect(saveButton, Color3.fromRGB(67, 181, 129), Color3.fromRGB(77, 191, 139))
addHoverEffect(leaderboardButton, Color3.fromRGB(255, 165, 0), Color3.fromRGB(255, 180, 30))
addHoverEffect(combinedMinimizeBtn, Color3.fromRGB(60, 60, 65), Color3.fromRGB(80, 80, 85))
addHoverEffect(minimizeButton, Color3.fromRGB(60, 60, 65), Color3.fromRGB(80, 80, 85))

-- Input map (same as server)
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

-- Handle input
local function onInputBegan(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end

	local key = inputMap[input.KeyCode]
	if key then
		RemoteEvents.PlayerInput:FireServer(key, true)
	end
end

local function onInputEnded(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end

	local key = inputMap[input.KeyCode]
	if key then
		RemoteEvents.PlayerInput:FireServer(key, false)
	end
end

UserInputService.InputBegan:Connect(onInputBegan)
UserInputService.InputEnded:Connect(onInputEnded)

-- Handle ROM loading
local function onLoadRom()
	if not urlTextBox then
		warn("[Gameboy Client] urlTextBox is nil!")
		return
	end
	
	local url = urlTextBox.Text or ""
	print("[Gameboy Client] Load ROM clicked, URL:", url)
	
	if url == "" or url == "Enter ROM URL..." then
		if statusLabel then
			statusLabel.Text = "Please enter a ROM URL"
			statusLabel.TextColor3 = Color3.fromRGB(255, 200, 100)
			statusLabel.Visible = true
			task.spawn(function()
				task.wait(3)
				if statusLabel then
					statusLabel.Visible = false
				end
			end)
		end
		return
	end

	print("[Gameboy Client] Firing LoadROM RemoteEvent with URL:", url)
	
	loadButton.Text = "Loading..."
	loadButton.BackgroundColor3 = Color3.fromRGB(100, 100, 100)
	loadButton.Active = false

	local success = pcall(function()
		RemoteEvents.LoadROM:FireServer(url)
	end)
	
	if not success then
		warn("[Gameboy Client] Failed to fire LoadROM RemoteEvent")
		if statusLabel then
			statusLabel.Text = "Error: Failed to send request to server"
			statusLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
			statusLabel.Visible = true
		end
		loadButton.Text = "Load ROM"
		loadButton.BackgroundColor3 = Color3.fromRGB(88, 101, 242)
		loadButton.Active = true
		return
	end

	-- Reset button after a delay (server will handle errors)
	task.spawn(function()
		task.wait(5)
		loadButton.Text = "Load ROM"
		loadButton.BackgroundColor3 = Color3.fromRGB(88, 101, 242)
		loadButton.Active = true
	end)
end

loadButton.MouseButton1Click:Connect(onLoadRom)
urlTextBox.FocusLost:Connect(function(enterPressed)
	if enterPressed then
		onLoadRom()
	end
end)

-- Track current game (declare before handlers)
local currentGameId: string? = nil
local currentGameLoaded = false

-- Handle status messages from server
RemoteEvents.StatusMessage.OnClientEvent:Connect(function(message: string, isInfo: boolean)
	if message and message ~= "" then
		statusLabel.Text = message
		statusLabel.Visible = true
		if isInfo then
			statusLabel.TextColor3 = Color3.fromRGB(100, 200, 255)
		else
			statusLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
		end
		
		-- Show save button when game starts or reloads
		if message:find("Game starting") or message:find("Game reloaded") then
			print("[Gameboy Client] Game loaded/reloaded detected, showing save button")
			currentGameLoaded = true
			saveButton.Visible = true
		end
		
		-- Hide status after delay
		task.spawn(function()
			task.wait(5)
			if statusLabel.Text == message then
				statusLabel.Visible = false
				statusLabel.Text = ""
			end
		end)
	end
end)

-- Create EditableImage on client
local AssetService = game:GetService("AssetService")
print("[Gameboy Client] Creating EditableImage...")
local clientScreen = AssetService:CreateEditableImage({ Size = Vector2.new(WIDTH, HEIGHT) })
screenImage.ImageContent = Content.fromObject(clientScreen)
print("[Gameboy Client] EditableImage created and set to screen")

-- Verify FrameData RemoteEvent exists
local frameDataCheck = ReplicatedStorage:FindFirstChild("FrameData")
print("[Gameboy Client] FrameData in ReplicatedStorage:", frameDataCheck and "Found" or "NOT FOUND")

-- Track if we're spectating
local isSpectating = false

-- Handle spectating updates
RemoteEvents.SpectatorUpdate.OnClientEvent:Connect(function(spectating: boolean, playerName: string?, gameTitle: string?)
	isSpectating = spectating
	-- Hide main UI when spectating, but keep minimized button visible if minimized
	if spectating then
		mainFrame.Visible = false
		minimizedButton.Visible = false
	else
		-- Restore previous minimized state
		mainFrame.Visible = not isMinimized
		minimizedButton.Visible = isMinimized
	end
end)

-- Handle frame data from server
local frameCount = 0
RemoteEvents.FrameData.OnClientEvent:Connect(function(frameDataString)
	-- Don't process frame data if we're spectating (spectator client handles it)
	if isSpectating then
		return
	end
	
	frameCount = frameCount + 1
	if frameCount == 1 then
		print("[Gameboy Client] Received first frame data, size:", #frameDataString, "bytes")
	end
	
	if frameDataString and #frameDataString > 0 then
		-- Convert string back to buffer
		local success, frameBuffer = pcall(function()
			local buf = buffer.create(WIDTH * HEIGHT * 4)
			local expectedSize = WIDTH * HEIGHT * 4
			
			if #frameDataString ~= expectedSize then
				warn("[Gameboy Client] Frame data size mismatch! Expected:", expectedSize, "Got:", #frameDataString)
			end
			
			-- Convert string bytes to buffer
			for i = 0, math.min(#frameDataString - 1, expectedSize - 1) do
				buffer.writeu8(buf, i, string.byte(frameDataString, i + 1))
			end
			
			return buf
		end)
		
		if success and frameBuffer then
			-- Update EditableImage with frame data
			clientScreen:WritePixelsBuffer(Vector2.zero, Vector2.new(WIDTH, HEIGHT), frameBuffer)
			if frameCount == 1 then
				print("[Gameboy Client] First frame written to EditableImage successfully")
			end
		else
			warn("[Gameboy Client] Failed to convert frame data:", frameBuffer)
		end
	else
		if frameCount <= 3 then
			warn("[Gameboy Client] Received empty frame data")
		end
	end
end)

print("[Gameboy Client] FrameData handler connected")

-- Get dashboard module from ReplicatedStorage
local dashboardModule
local dashSuccess, dashErr = pcall(function()
	dashboardModule = require(ReplicatedStorage:WaitForChild("GameboyDashboard"))
end)

if not dashSuccess then
	warn("[Gameboy Client] Failed to load dashboard module:", dashErr)
end

-- Dashboard button click
dashboardButton.MouseButton1Click:Connect(function()
	print("[Gameboy Client] Library button clicked")
	if dashboardModule then
		print("[Gameboy Client] Calling toggleDashboard")
		dashboardModule.toggleDashboard()
	else
		warn("[Gameboy Client] Dashboard module not available")
	end
end)

-- Save button click
saveButton.MouseButton1Click:Connect(function()
	print("[Gameboy Client] Save button clicked")
	if dashboardModule then
		print("[Gameboy Client] Calling showSaveUI")
		dashboardModule.showSaveUI()
	else
		warn("[Gameboy Client] Dashboard module not available")
	end
end)

-- Show save button when game loads
RemoteEvents.CurrentGameUpdate.OnClientEvent:Connect(function(gameId: string)
	print("[Gameboy Client] CurrentGameUpdate received, showing save button")
	currentGameLoaded = true
	currentGameId = gameId
	saveButton.Visible = true
	leaderboardButton.Visible = true
	
	-- Start audio when game loads
	if audioClient then
		audioClient.start()
	end
end)

-- Get leaderboard module
local leaderboardModule
local leaderboardSuccess, leaderboardErr = pcall(function()
	leaderboardModule = require(ReplicatedStorage:WaitForChild("GameboyLeaderboard"))
end)

if not leaderboardSuccess then
	warn("[Gameboy Client] Failed to load leaderboard module:", leaderboardErr)
end

-- Get audio client module
local audioClient
local audioSuccess, audioErr = pcall(function()
	audioClient = require(script:WaitForChild("AudioClient"))
end)

if not audioSuccess then
	warn("[Gameboy Client] Failed to load audio client:", audioErr)
end

-- Leaderboard button click
leaderboardButton.MouseButton1Click:Connect(function()
	print("[Gameboy Client] Leaderboard button clicked, currentGameId:", currentGameId)
	if leaderboardModule and currentGameId then
		leaderboardModule.show(currentGameId)
	else
		if not currentGameId then
			warn("[Gameboy Client] No game loaded - currentGameId is nil")
		else
			warn("[Gameboy Client] Leaderboard module not available")
		end
	end
end)

-- Handle score submission notification
RemoteEvents.ScoreSubmitted.OnClientEvent:Connect(function(gameId: string, score: number, rank: number?)
	if statusLabel then
		local message = "Score saved: " .. tostring(score)
		if rank then
			message = message .. " (Rank #" .. tostring(rank) .. ")"
		end
		statusLabel.Text = message
		statusLabel.TextColor3 = Color3.fromRGB(100, 255, 100)
		statusLabel.Visible = true
		
		-- Hide after delay
		task.spawn(function()
			task.wait(5)
			if statusLabel.Text == message then
				statusLabel.Visible = false
			end
		end)
	end
end)

-- Game Boy Camera capture handler
local CameraService = Players
local WorkspaceService = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local CAMERA_WIDTH = 128
local CAMERA_HEIGHT = 112

-- Camera capture function (first-person view)
local function captureCameraImage()
    local player = CameraService.LocalPlayer
    if not player then
        warn("[GB Camera Client] No local player")
        return nil
    end
    
    local character = player.Character
    if not character then
        warn("[GB Camera Client] No character")
        return nil
    end
    
    local head = character:FindFirstChild("Head")
    local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
    local cameraOrigin = head or humanoidRootPart
    
    if not cameraOrigin then
        warn("[GB Camera Client] No camera origin (head/HRP)")
        return nil
    end
    
    -- Get camera orientation - use the actual workspace camera
    local workspaceCamera = WorkspaceService.CurrentCamera
    local cameraCFrame
    
    if workspaceCamera then
        -- Use the actual camera CFrame but position at character's eye level
        local eyeOffset = Vector3.new(0, 0.5, 0)  -- Slightly above head
        cameraCFrame = CFrame.new(cameraOrigin.Position + eyeOffset) * 
            workspaceCamera.CFrame.Rotation
    else
        cameraCFrame = cameraOrigin.CFrame
    end
    
    local fov = workspaceCamera and workspaceCamera.FieldOfView or 70
    local cameraAspectRatio = CAMERA_WIDTH / CAMERA_HEIGHT
    
    -- Raycast parameters - exclude the local character
    local raycastParams = RaycastParams.new()
    raycastParams.FilterDescendantsInstances = {character}
    raycastParams.FilterType = Enum.RaycastFilterType.Exclude
    
    local maxDistance = 1000  -- Increased distance
    
    -- Image buffer - use 1-indexed for proper serialization
    local imageData = {}
    
    -- Track hit statistics for debugging
    local hitCount = 0
    local skyCount = 0
    
    -- Sample the scene using raycasting
    for y = 0, CAMERA_HEIGHT - 1 do
        imageData[y] = {}
        for x = 0, CAMERA_WIDTH - 1 do
            -- Convert pixel coordinates to normalized device coordinates (-1 to 1)
            -- Center of pixel
            local ndcX = ((x + 0.5) / CAMERA_WIDTH) * 2 - 1
            local ndcY = 1 - ((y + 0.5) / CAMERA_HEIGHT) * 2  -- Flip Y
            
            -- Calculate ray direction based on FOV
            local halfFov = math.rad(fov / 2)
            local tanHalfFov = math.tan(halfFov)
            
            -- Local space direction (camera looks down -Z in Roblox)
            local dirX = ndcX * tanHalfFov * cameraAspectRatio
            local dirY = ndcY * tanHalfFov
            local dirZ = -1  -- Forward in camera space
            
            -- Transform direction to world space
            local localDir = Vector3.new(dirX, dirY, dirZ).Unit
            local worldDir = cameraCFrame:VectorToWorldSpace(localDir)
            
            -- Perform raycast
            local result = WorkspaceService:Raycast(cameraCFrame.Position, worldDir * maxDistance, raycastParams)
            
            if result then
                hitCount = hitCount + 1
                -- Get color from hit part
                local part = result.Instance
                local baseColor
                
                if part:IsA("BasePart") then
                    baseColor = part.Color
                elseif part:IsA("Terrain") then
                    -- Get terrain material color
                    local material = result.Material
                    if material == Enum.Material.Grass then
                        baseColor = Color3.fromRGB(80, 120, 60)
                    elseif material == Enum.Material.Sand then
                        baseColor = Color3.fromRGB(180, 160, 120)
                    elseif material == Enum.Material.Rock then
                        baseColor = Color3.fromRGB(100, 100, 100)
                    elseif material == Enum.Material.Water then
                        baseColor = Color3.fromRGB(60, 100, 140)
                    else
                        baseColor = Color3.fromRGB(100, 120, 80)
                    end
                else
                    baseColor = Color3.new(0.5, 0.5, 0.5)
                end
                
                -- Simple lighting simulation based on surface normal
                local lightDir = Vector3.new(0.3, 0.8, 0.2).Unit
                local lightIntensity = math.max(0, result.Normal:Dot(lightDir))
                local ambient = 0.4  -- Increased ambient for better visibility
                local diffuse = 0.6 * lightIntensity
                local totalLight = ambient + diffuse
                
                local r = math.floor(baseColor.R * 255 * totalLight)
                local g = math.floor(baseColor.G * 255 * totalLight)
                local b = math.floor(baseColor.B * 255 * totalLight)
                
                -- Clamp values
                r = math.min(255, math.max(0, r))
                g = math.min(255, math.max(0, g))
                b = math.min(255, math.max(0, b))
                
                imageData[y][x] = {r, g, b}
            else
                skyCount = skyCount + 1
                -- Sky/background - use a darker sky color that varies with position
                -- This creates a gradient and ensures the image isn't all the same color
                local skyBrightness = 120 + math.floor((1 - y / CAMERA_HEIGHT) * 60)  -- Darker at top
                imageData[y][x] = {skyBrightness, skyBrightness + 10, skyBrightness + 20}
            end
        end
    end
    
    -- Debug output - only log occasionally
    local totalPixels = CAMERA_WIDTH * CAMERA_HEIGHT
    print(string.format("[GB Camera Client] Captured: %d hits (%.1f%%), %d sky (%.1f%%)", 
        hitCount, hitCount/totalPixels*100, skyCount, skyCount/totalPixels*100))
    
    -- Sample a few pixels for debugging
    if imageData[56] and imageData[56][64] then
        local centerPixel = imageData[56][64]
        print(string.format("[GB Camera Client] Center pixel: R=%d G=%d B=%d", 
            centerPixel[1], centerPixel[2], centerPixel[3]))
    end
    
    return imageData
end

-- Handle camera capture request from server
-- Use WaitForChild directly from ReplicatedStorage to ensure we get the same instance
-- Store the RemoteEvent in a module-level variable so we can verify it later
local cameraCaptureRequestEvent = nil

local function setupCameraHandler()
    -- Get RemoteEvent directly from ReplicatedStorage (more reliable)
    local captureRequest = ReplicatedStorage:WaitForChild("CameraCaptureRequest", 10)
    if not captureRequest then
        warn("[GB Camera Client] CameraCaptureRequest not found in ReplicatedStorage after waiting!")
        task.spawn(function()
            task.wait(1)
            setupCameraHandler()
        end)
        return nil
    end
    
    if not captureRequest:IsA("RemoteEvent") then
        warn(string.format("[GB Camera Client] CameraCaptureRequest is not a RemoteEvent! Type: %s", captureRequest.ClassName))
        return nil
    end
    
    -- Store the instance for later verification
    cameraCaptureRequestEvent = captureRequest
    
    print("[GB Camera Client] CameraCaptureRequest RemoteEvent found, connecting handler...")
    print(string.format("[GB Camera Client] RemoteEvent: %s (Parent: %s)", 
        captureRequest.Name, captureRequest.Parent and captureRequest.Parent.Name or "nil"))
    
    -- Also verify it matches the one from RemoteEvents module
    if RemoteEvents and RemoteEvents.CameraCaptureRequest then
        if RemoteEvents.CameraCaptureRequest == captureRequest then
            print("[GB Camera Client] RemoteEvent matches module reference - OK")
        else
            warn("[GB Camera Client] RemoteEvent from ReplicatedStorage differs from module reference!")
            print(string.format("[GB Camera Client] Module instance: %s, ReplicatedStorage instance: %s",
                RemoteEvents.CameraCaptureRequest:GetFullName(),
                captureRequest:GetFullName()))
        end
    end
    
    -- Test connection by checking if we can access the event
    print(string.format("[GB Camera Client] Setting up OnClientEvent handler for %s", captureRequest:GetFullName()))
    
    -- Connect to the RemoteEvent
    -- Note: If this is called multiple times, we'll have multiple handlers
    -- but that's okay for now - they'll all fire and we can handle it
    local connection = captureRequest.OnClientEvent:Connect(function()
        print("[GB Camera Client] ========================================")
        print("[GB Camera Client] *** Capture requested from server ***")
        print(string.format("[GB Camera Client] Connection object: %s, RemoteEvent: %s", 
            tostring(connection), captureRequest:GetFullName()))
        print(string.format("[GB Camera Client] RemoteEvent Parent: %s", 
            captureRequest.Parent and captureRequest.Parent.Name or "nil"))
        print(string.format("[GB Camera Client] RemoteEvent instance ID: %s", 
            tostring(captureRequest)))
        print("[GB Camera Client] ========================================")
        
        -- Immediately log that we're entering the handler
        print("[GB Camera Client] Handler function executing...")
        
        local captureSuccess, captureErr = pcall(function()
            print("[GB Camera Client] Inside pcall, starting image capture...")
            local imageData = captureCameraImage()
            print(string.format("[GB Camera Client] captureCameraImage returned: %s", 
                imageData and "non-nil" or "nil"))
            
            if not imageData then
                warn("[GB Camera Client] captureCameraImage returned nil - cannot send to server")
                return
            end
            
            if imageData then
                -- Count actual rows (0-indexed table)
                local rowCount = 0
                local pixelCount = 0
                for camY = 0, CAMERA_HEIGHT - 1 do
                    if imageData[camY] then
                        rowCount = rowCount + 1
                        for camX = 0, CAMERA_WIDTH - 1 do
                            if imageData[camY][camX] then
                                pixelCount = pixelCount + 1
                            end
                        end
                    end
                end
                print(string.format("[GB Camera Client] Captured image: %d rows, %d pixels", rowCount, pixelCount))
                
                -- Debug: log center pixel before sending
                if imageData[56] and imageData[56][64] then
                    local p = imageData[56][64]
                    print(string.format("[GB Camera Client] Center pixel before send: R=%d G=%d B=%d", p[1], p[2], p[3]))
                end
                
                -- Verify RemoteEvent exists before firing
                -- CRITICAL: Use the instance directly from ReplicatedStorage to ensure it's the same one the server is listening to
                local responseEvent = ReplicatedStorage:WaitForChild("CameraCaptureResponse", 1)
                
                if not responseEvent then
                    warn("[GB Camera Client] CameraCaptureResponse not found in ReplicatedStorage!")
                    -- Fallback to module instance
                    if RemoteEvents and RemoteEvents.CameraCaptureResponse then
                        responseEvent = RemoteEvents.CameraCaptureResponse
                        warn("[GB Camera Client] Using module instance as fallback")
                    else
                        warn("[GB Camera Client] CameraCaptureResponse RemoteEvent not found anywhere!")
                        return
                    end
                end
                
                if not responseEvent:IsA("RemoteEvent") then
                    warn(string.format("[GB Camera Client] CameraCaptureResponse is not a RemoteEvent! Type: %s", 
                        responseEvent.ClassName))
                    return
                end
                
                print(string.format("[GB Camera Client] Firing CameraCaptureResponse to server using: %s", 
                    responseEvent:GetFullName()))
                local fireSuccess, fireErr = pcall(function()
                    responseEvent:FireServer(imageData)
                end)
                if not fireSuccess then
                    warn("[GB Camera Client] Failed to FireServer:", fireErr)
                else
                    print("[GB Camera Client] Successfully fired CameraCaptureResponse to server")
                end
            else
                warn("[GB Camera Client] Failed to capture image - captureCameraImage returned nil")
            end
        end)
        if not captureSuccess then
            warn(string.format("[GB Camera Client] Error in capture handler: %s", tostring(captureErr)))
            warn(string.format("[GB Camera Client] Error type: %s", type(captureErr)))
            if type(captureErr) == "table" then
                for k, v in pairs(captureErr) do
                    warn(string.format("[GB Camera Client] Error[%s] = %s", tostring(k), tostring(v)))
                end
            end
        else
            print("[GB Camera Client] Capture handler completed successfully")
        end
    end)
    
    -- Verify connection was made
    if connection then
        print("[Gameboy Client] Camera capture handler connected successfully")
        print(string.format("[GB Camera Client] Connection object: %s", tostring(connection)))
        print(string.format("[GB Camera Client] Connection.Connected: %s", tostring(connection.Connected)))
    else
        warn("[GB Camera Client] Failed to create connection!")
    end
    
    return connection
end

-- Setup camera handler (with retry logic)
local cameraConnection = setupCameraHandler()

-- Periodic check to verify connection is still active
task.spawn(function()
    task.wait(5) -- Wait for everything to initialize
    if cameraConnection then
        print(string.format("[GB Camera Client] Connection check: Connected=%s, Valid=%s", 
            tostring(cameraConnection.Connected),
            tostring(cameraConnection and typeof(cameraConnection) == "RBXScriptConnection")))
    else
        warn("[GB Camera Client] Connection check: Connection is nil!")
        -- Try to reconnect
        print("[GB Camera Client] Attempting to reconnect...")
        cameraConnection = setupCameraHandler()
    end
end)

-- Test: Verify RemoteEvent is accessible and can receive events
task.spawn(function()
    task.wait(2) -- Wait for everything to initialize
    local testEvent = ReplicatedStorage:FindFirstChild("CameraCaptureRequest")
    if testEvent then
        print(string.format("[GB Camera Client] Test: RemoteEvent found: %s, Parent: %s, ClassName: %s", 
            testEvent.Name, 
            testEvent.Parent and testEvent.Parent.Name or "nil",
            testEvent.ClassName))
        
        -- Verify it's the same instance we're listening to
        if cameraCaptureRequestEvent and testEvent == cameraCaptureRequestEvent then
            print("[GB Camera Client] Test: RemoteEvent instance matches handler - OK")
        else
            warn("[GB Camera Client] Test: RemoteEvent instance MISMATCH! Handler may not work!")
            if cameraCaptureRequestEvent then
                print(string.format("[GB Camera Client] Test: Handler instance: %s, Test instance: %s",
                    cameraCaptureRequestEvent:GetFullName(),
                    testEvent:GetFullName()))
            else
                warn("[GB Camera Client] Test: cameraCaptureRequestEvent is nil - handler not set up!")
            end
        end
        
        -- Try to manually trigger to test connection
        -- (This is just for debugging - we can't actually fire it from client)
        print(string.format("[GB Camera Client] Test: Connection object exists: %s", 
            testEvent.OnClientEvent and "YES" or "NO"))
    else
        warn("[GB Camera Client] Test: CameraCaptureRequest NOT FOUND in ReplicatedStorage!")
    end
end)
