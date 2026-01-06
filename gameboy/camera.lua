--!native
-- Game Boy Camera Capture Module for Roblox
-- Captures the Roblox world from first-person view and converts to Game Boy Camera format

local Camera = {}

-- Camera dimensions matching Game Boy Camera
Camera.WIDTH = 128
Camera.HEIGHT = 112

function Camera.new(modules)
    local camera = {}
    
    -- Reference to gameboy modules
    camera.gameboy = nil
    
    -- Roblox services (will be set during initialization)
    camera.Players = nil
    camera.RunService = nil
    camera.Workspace = nil
    
    -- ViewportFrame for capturing (created on client side)
    camera.viewportFrame = nil
    camera.worldModel = nil
    camera.viewportCamera = nil
    
    -- Cached image buffer
    camera.imageBuffer = {}
    for y = 0, Camera.HEIGHT - 1 do
        camera.imageBuffer[y] = {}
        for x = 0, Camera.WIDTH - 1 do
            camera.imageBuffer[y][x] = {128, 128, 128}  -- Default mid-gray
        end
    end
    
    -- Flag to track if running on client
    camera.isClient = false
    
    -- Server-side: RemoteEvents and pending capture buffer
    camera.RemoteEvents = nil
    camera.pendingCapture = nil
    camera.captureRequestId = 0
    camera.player = nil
    camera.captureInProgress = false
    camera.lastCaptureTime = 0
    camera.firstCaptureAttempted = false
    
    -- Initialize the camera module
    camera.initialize = function(gameboy)
        camera.gameboy = gameboy
        
        -- Try to get Roblox services
        local success = pcall(function()
            camera.Players = game:GetService("Players")
            camera.RunService = game:GetService("RunService")
            camera.Workspace = game:GetService("Workspace")
        end)
        
        if not success then
            warn("[GB Camera] Failed to get Roblox services")
            return
        end
        
        -- Check if we're on client
        camera.isClient = camera.RunService:IsClient()
        
        if camera.isClient then
            camera.setupViewport()
            camera.setupClientHandlers()
        else
            -- Server-side: setup RemoteEvents
            camera.setupServerHandlers()
        end
    end
    
    -- Setup client-side RemoteEvent handlers
    camera.setupClientHandlers = function()
        local ReplicatedStorage = game:GetService("ReplicatedStorage")
        local RemoteEvents = require(ReplicatedStorage:WaitForChild("RemoteEvents"))
        
        -- Handle capture request from server
        RemoteEvents.CameraCaptureRequest.OnClientEvent:Connect(function()
            local imageData = camera.captureImage()
            if imageData then
                -- Convert image data to a serializable format
                local serialized = {}
                for y = 0, Camera.HEIGHT - 1 do
                    serialized[y] = {}
                    for x = 0, Camera.WIDTH - 1 do
                        serialized[y][x] = imageData[y][x]
                    end
                end
                RemoteEvents.CameraCaptureResponse:FireServer(serialized)
            end
        end)
        
        print("[GB Camera] Client handlers setup complete")
    end
    
    -- Setup server-side RemoteEvent handlers
    camera.setupServerHandlers = function()
        local ReplicatedStorage = game:GetService("ReplicatedStorage")
        local RemoteEvents = require(ReplicatedStorage:WaitForChild("RemoteEvents"))
        camera.RemoteEvents = RemoteEvents
        
        -- Verify RemoteEvents are available
        if not RemoteEvents.CameraCaptureRequest then
            warn("[GB Camera] CameraCaptureRequest not found in RemoteEvents!")
        else
            print("[GB Camera] CameraCaptureRequest RemoteEvent verified")
        end
        
        if not RemoteEvents.CameraCaptureResponse then
            warn("[GB Camera] CameraCaptureResponse not found in RemoteEvents!")
        else
            print("[GB Camera] CameraCaptureResponse RemoteEvent verified")
        end
        
        -- Handle capture response from client (optimized for live preview)
        RemoteEvents.CameraCaptureResponse.OnServerEvent:Connect(function(player, imageData)
            -- Only accept captures from the correct player
            if camera.player and player ~= camera.player then
                return  -- Ignore captures from other players
            end
            
            -- Store the captured image for live preview
            if imageData then
                camera.pendingCapture = imageData
                camera.captureInProgress = false
            end
        end)
        
        print("[GB Camera] Server handlers setup complete")
    end
    
    -- Set the player for server-side capture requests
    camera.setPlayer = function(player)
        camera.player = player
        print(string.format("[GB Camera] Player set to: %s", player and player.Name or "nil"))
    end
    
    -- Set pending capture (called from server handler)
    camera.setPendingCapture = function(imageData)
        camera.pendingCapture = imageData
        camera.captureInProgress = false
        print(string.format("[GB Camera] Pending capture set, rows: %d", 
            imageData and (function()
                local count = 0
                for y = 0, Camera.HEIGHT - 1 do
                    if imageData[y] then count = count + 1 end
                end
                return count
            end)() or 0))
    end
    
    -- Setup ViewportFrame for capturing on client
    camera.setupViewport = function()
        -- Create a hidden ViewportFrame for capturing the world
        local player = camera.Players.LocalPlayer
        if not player then
            warn("[GB Camera] No local player found")
            return
        end
        
        local playerGui = player:WaitForChild("PlayerGui", 5)
        if not playerGui then
            warn("[GB Camera] PlayerGui not found")
            return
        end
        
        -- Create ScreenGui to hold ViewportFrame
        local screenGui = Instance.new("ScreenGui")
        screenGui.Name = "GBCameraViewport"
        screenGui.Enabled = false  -- Hidden
        screenGui.ResetOnSpawn = false
        screenGui.Parent = playerGui
        
        -- Create ViewportFrame
        camera.viewportFrame = Instance.new("ViewportFrame")
        camera.viewportFrame.Name = "CameraCapture"
        camera.viewportFrame.Size = UDim2.new(0, Camera.WIDTH, 0, Camera.HEIGHT)
        camera.viewportFrame.Position = UDim2.new(0, 0, 0, 0)
        camera.viewportFrame.BackgroundColor3 = Color3.new(0.5, 0.5, 0.5)
        camera.viewportFrame.BackgroundTransparency = 0
        camera.viewportFrame.Parent = screenGui
        
        -- Create camera for the viewport
        camera.viewportCamera = Instance.new("Camera")
        camera.viewportCamera.Name = "GBCamera"
        camera.viewportCamera.Parent = camera.viewportFrame
        camera.viewportFrame.CurrentCamera = camera.viewportCamera
        
        -- Create WorldModel to clone world objects into
        camera.worldModel = Instance.new("WorldModel")
        camera.worldModel.Name = "CapturedWorld"
        camera.worldModel.Parent = camera.viewportFrame
        
        print("[GB Camera] Viewport setup complete")
    end
    
    -- Capture the current view and return image data
    camera.captureImage = function()
        if not camera.isClient then
            -- On server, use async capture mechanism for LIVE PREVIEW
            -- Keep the last good capture to prevent flickering
            
            -- Request a NEW capture from client for the next frame (live preview)
            if camera.RemoteEvents and camera.player then
                -- Only request new capture if enough time has passed (rate limiting)
                local timeSinceLastCapture = tick() - camera.lastCaptureTime
                
                -- For first capture, wait a bit longer to ensure client is ready
                local minWaitTime = 0.1  -- 100ms = ~10 fps max for live preview
                if not camera.firstCaptureAttempted then
                    minWaitTime = 0.5  -- Wait 500ms for first capture to ensure client is ready
                    camera.firstCaptureAttempted = true
                end
                
                if timeSinceLastCapture > minWaitTime and not camera.captureInProgress then  -- Rate limit requests
                    -- Request capture from client (non-blocking) - reduced logging for performance
                    local success, err = pcall(function()
                        local ReplicatedStorage = game:GetService("ReplicatedStorage")
                        local replicatedEvent = ReplicatedStorage:FindFirstChild("CameraCaptureRequest")
                        
                        if replicatedEvent and replicatedEvent:IsA("RemoteEvent") then
                            replicatedEvent:FireClient(camera.player)
                            camera.captureInProgress = true
                            camera.lastCaptureTime = tick()
                        end
                    end)
                    if not success then
                        warn("[GB Camera] Failed to fire capture request:", err)
                    end
                end
            end
            
            -- If we've been waiting too long (>2 seconds), reset and try again
            if camera.captureInProgress and (tick() - camera.lastCaptureTime) > 2.0 then
                camera.captureInProgress = false
            end
            
            -- Return the last good capture if we have one (prevents flickering)
            -- Only return simulated if we've NEVER received a capture
            if camera.pendingCapture then
                return camera.pendingCapture
            else
                -- Return simulated image only on first frame before client responds
                return camera.captureSimulated()
            end
        end
        
        -- Client-side: Update viewport with current world state
        camera.updateViewport()
        
        -- For now, we'll use raycasting to sample the world
        -- since ViewportFrame doesn't have direct pixel reading
        return camera.captureViaRaycasting()
    end
    
    -- Update viewport to match player's first-person view
    camera.updateViewport = function()
        if not camera.viewportCamera then
            return
        end
        
        local player = camera.Players.LocalPlayer
        if not player then
            return
        end
        
        local character = player.Character
        if not character then
            return
        end
        
        -- Get head position for first-person view
        local head = character:FindFirstChild("Head")
        if not head then
            return
        end
        
        -- Use workspace camera's CFrame but position at head
        local workspaceCamera = camera.Workspace.CurrentCamera
        if workspaceCamera then
            camera.viewportCamera.CFrame = CFrame.new(head.Position) * 
                (workspaceCamera.CFrame - workspaceCamera.CFrame.Position)
            camera.viewportCamera.FieldOfView = workspaceCamera.FieldOfView
        else
            camera.viewportCamera.CFrame = head.CFrame
            camera.viewportCamera.FieldOfView = 70
        end
    end
    
    -- Capture using raycasting to sample the world (simplified approach)
    camera.captureViaRaycasting = function()
        local player = camera.Players.LocalPlayer
        if not player then
            return camera.captureSimulated()
        end
        
        local character = player.Character
        if not character then
            return camera.captureSimulated()
        end
        
        local head = character:FindFirstChild("Head")
        if not head then
            return camera.captureSimulated()
        end
        
        -- Get camera orientation
        local workspaceCamera = camera.Workspace.CurrentCamera
        local cameraCFrame
        if workspaceCamera then
            cameraCFrame = CFrame.new(head.Position) * 
                (workspaceCamera.CFrame - workspaceCamera.CFrame.Position)
        else
            cameraCFrame = head.CFrame
        end
        
        local fov = workspaceCamera and workspaceCamera.FieldOfView or 70
        local aspectRatio = Camera.WIDTH / Camera.HEIGHT
        
        -- Raycast parameters
        local raycastParams = RaycastParams.new()
        raycastParams.FilterDescendantsInstances = {character}
        raycastParams.FilterType = Enum.RaycastFilterType.Exclude
        
        local maxDistance = 500
        
        -- Sample the scene using raycasting
        for y = 0, Camera.HEIGHT - 1 do
            for x = 0, Camera.WIDTH - 1 do
                -- Convert pixel coordinates to normalized device coordinates (-1 to 1)
                local ndcX = (x / Camera.WIDTH) * 2 - 1
                local ndcY = 1 - (y / Camera.HEIGHT) * 2  -- Flip Y
                
                -- Calculate ray direction based on FOV
                local halfFov = math.rad(fov / 2)
                local tanHalfFov = math.tan(halfFov)
                
                local dirX = ndcX * tanHalfFov * aspectRatio
                local dirY = ndcY * tanHalfFov
                local dirZ = -1  -- Forward
                
                -- Transform direction to world space
                local localDir = Vector3.new(dirX, dirY, dirZ).Unit
                local worldDir = cameraCFrame:VectorToWorldSpace(localDir)
                
                -- Perform raycast
                local result = camera.Workspace:Raycast(cameraCFrame.Position, worldDir * maxDistance, raycastParams)
                
                if result then
                    -- Get color from hit part
                    local color = camera.getPartColor(result.Instance, result.Position, result.Normal)
                    camera.imageBuffer[y][x] = color
                else
                    -- Sky/background color (light blue-ish gray)
                    camera.imageBuffer[y][x] = {180, 200, 220}
                end
            end
        end
        
        return camera.imageBuffer
    end
    
    -- Get color from a part, considering materials and lighting
    camera.getPartColor = function(part, hitPosition, hitNormal)
        if not part then
            return {128, 128, 128}
        end
        
        local baseColor
        
        -- Get base color from part
        if part:IsA("BasePart") then
            baseColor = part.Color
        elseif part:IsA("Terrain") then
            -- Terrain - use a default earthy color
            baseColor = Color3.fromRGB(120, 140, 100)
        else
            baseColor = Color3.new(0.5, 0.5, 0.5)
        end
        
        -- Simple lighting simulation based on normal direction
        -- Assume light coming from above and slightly forward
        local lightDir = Vector3.new(0.3, 0.8, 0.2).Unit
        local lightIntensity = math.max(0, hitNormal:Dot(lightDir))
        
        -- Ambient light contribution
        local ambient = 0.3
        local diffuse = 0.7 * lightIntensity
        local totalLight = ambient + diffuse
        
        -- Apply lighting to color
        local r = math.floor(baseColor.R * 255 * totalLight)
        local g = math.floor(baseColor.G * 255 * totalLight)
        local b = math.floor(baseColor.B * 255 * totalLight)
        
        -- Clamp values
        r = math.min(255, math.max(0, r))
        g = math.min(255, math.max(0, g))
        b = math.min(255, math.max(0, b))
        
        return {r, g, b}
    end
    
    -- Simulated capture for server-side or when viewport isn't available
    camera.captureSimulated = function()
        -- Generate a visible test pattern (checkerboard with gradient)
        for y = 0, Camera.HEIGHT - 1 do
            for x = 0, Camera.WIDTH - 1 do
                -- Create a checkerboard pattern with gradient
                local checker = bit32.band(bit32.rshift(x, 4) + bit32.rshift(y, 4), 1)
                local gray
                if checker ~= 0 then
                    -- Dark squares
                    gray = math.floor(64 + (x / Camera.WIDTH) * 64)
                else
                    -- Light squares  
                    gray = math.floor(128 + (y / Camera.HEIGHT) * 64)
                end
                
                camera.imageBuffer[y][x] = {gray, gray, gray}
            end
        end
        
        return camera.imageBuffer
    end
    
    -- Alternative: Capture from EditableImage if available (Roblox beta feature)
    camera.captureFromEditableImage = function()
        -- This would use EditableImage:ReadPixels if available
        -- For now, fallback to raycasting
        return camera.captureViaRaycasting()
    end
    
    -- Reset camera state
    camera.reset = function()
        -- Reset image buffer to mid-gray
        for y = 0, Camera.HEIGHT - 1 do
            for x = 0, Camera.WIDTH - 1 do
                camera.imageBuffer[y][x] = {128, 128, 128}
            end
        end
    end
    
    -- Cleanup
    camera.destroy = function()
        if camera.viewportFrame then
            local parent = camera.viewportFrame.Parent
            if parent then
                parent:Destroy()
            end
            camera.viewportFrame = nil
            camera.viewportCamera = nil
            camera.worldModel = nil
        end
    end
    
    return camera
end

return Camera

