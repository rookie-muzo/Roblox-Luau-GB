--!native
-- Game Boy Camera (PocketCam) MBC Implementation
-- Based on mGBA's pocket-cam.c implementation
-- MBC type: 0xFC

local PocketCam = {}

-- Camera dimensions
PocketCam.GBCAM_WIDTH = 128
PocketCam.GBCAM_HEIGHT = 112

function PocketCam.new()
    local pocketcam = {}
    pocketcam.raw_data = {}
    pocketcam.external_ram = {}
    pocketcam.header = {}
    
    -- MBC state
    pocketcam.rom_bank = 1
    pocketcam.ram_bank = 0
    -- PocketCam: RAM enabled by default since camera requires SRAM for image storage
    -- The game may not explicitly enable RAM before reading captured images
    pocketcam.ram_enable = true
    
    -- Camera-specific state
    pocketcam.registersActive = false
    pocketcam.registers = {}
    for i = 0, 0x35 do
        pocketcam.registers[i] = 0
    end
    
    -- Camera capture callback (set externally)
    pocketcam.captureCallback = nil
    
    pocketcam.mt = {}
    
    -- Read handler
    pocketcam.mt.__index = function(self, address)
        -- Allow access to non-memory properties via rawget
        if type(address) ~= "number" then
            -- First check if it's a known property that should bypass memory access
            local rawValue = rawget(self, address)
            if rawValue ~= nil then
                return rawValue
            end
            -- Try to convert to number for memory access
            address = tonumber(address) or 0
        end
        
        -- Lower 16k: return the first bank, always
        if address <= 0x3FFF then
            return self.raw_data[address] or 0
        end
        
        -- Upper 16k: return the currently selected bank
        if address >= 0x4000 and address <= 0x7FFF then
            local rom_bank = self.rom_bank
            return self.raw_data[(rom_bank * 16 * 1024) + (address - 0x4000)] or 0
        end
        
        -- External RAM / Camera registers (0xA000-0xBFFF) - optimized for live preview
        if address >= 0xA000 and address <= 0xBFFF then
            if self.registersActive then
                -- When camera registers are active, only register 0 is readable
                if bit32.band(address, 0x7F) == 0 then
                    return self.registers[0]
                end
                return 0
            end
            
            -- Normal SRAM access
            local ram_offset = (address - 0xA000) + (self.ram_bank * 8 * 1024)
            return self.external_ram[ram_offset] or 0
        end
        
        return 0x00
    end
    
    -- Write handler
    pocketcam.mt.__newindex = function(self, address, value)
        -- Allow setting non-memory properties via rawset
        if type(address) ~= "number" then
            -- Check if it's a property assignment (not memory write)
            local numAddress = tonumber(address)
            if numAddress == nil then
                -- It's a property name like "external_ram", "raw_data", etc.
                rawset(self, address, value)
                return
            end
            address = numAddress
        end
        -- Ensure value is a number (could be boolean from metatable quirks)
        if type(value) ~= "number" then
            value = tonumber(value) or 0
        end
        
        -- 0x0000-0x1FFF: RAM enable (optimized - no logging)
        if address <= 0x1FFF then
            local lowerNibble = bit32.band(value, 0x0F)
            if lowerNibble == 0x0A then
                self.ram_enable = true
            elseif value == 0 then
                self.ram_enable = false
            end
            return
        end
        
        -- 0x2000-0x3FFF: ROM bank select (lower 6 bits)
        if address >= 0x2000 and address <= 0x3FFF then
            local bank = bit32.band(value, 0x3F)
            if bank == 0 then
                bank = 1
            end
            self.rom_bank = bank
            return
        end
        
        -- 0x4000-0x5FFF: RAM bank select / camera register mode (optimized - no logging)
        if address >= 0x4000 and address <= 0x5FFF then
            if value < 0x10 then
                -- Normal SRAM bank selection
                self.ram_bank = value
                self.registersActive = false
            else
                -- Enable camera register mode
                self.registersActive = true
            end
            return
        end
        
        -- 0x6000-0x7FFF: Not used on PocketCam
        if address >= 0x6000 and address <= 0x7FFF then
            return
        end
        
        -- 0xA000-0xBFFF: SRAM or camera register writes (optimized for live preview)
        if address >= 0xA000 and address <= 0xBFFF then
            if self.registersActive then
                -- Camera register writes
                local reg_address = bit32.band(address, 0x7F)
                
                -- Check if capture is triggered (register 0, bit 0)
                if reg_address == 0 and bit32.band(value, 1) ~= 0 then
                    -- Trigger capture, then clear the capture bit
                    value = bit32.band(value, 6)  -- Keep bits 1-2, clear bit 0
                    self:capture()
                end
                
                -- Store register value
                if reg_address < 0x36 then
                    self.registers[reg_address] = value
                end
            else
                -- Normal SRAM write
                local ram_offset = (address - 0xA000) + (self.ram_bank * 8 * 1024)
                self.external_ram[ram_offset] = value
                self.external_ram.dirty = true
            end
            return
        end
    end
    
    -- Camera capture function (optimized for live preview)
    pocketcam.capture = function(self)
        -- Rate limit: Don't process if we just processed recently (prevents flickering)
        local now = tick()
        local lastProcessTime = rawget(self, "_lastProcessTime") or 0
        local timeSinceLastProcess = now - lastProcessTime
        
        -- Only process if at least 50ms has passed (20 fps max processing rate)
        -- This prevents processing the same image multiple times rapidly
        if timeSinceLastProcess < 0.05 then
            return  -- Skip processing, keep existing SRAM data
        end
        
        -- Use rawget to bypass metatable and get the actual callback
        local callback = rawget(self, "captureCallback")
        
        if not callback or type(callback) ~= "function" then
            -- No camera available, fill with test pattern
            self:fillTestPattern()
            rawset(self, "_lastProcessTime", now)
            return
        end
        
        -- Request image from the camera module
        local success, imageData = pcall(callback)
        
        if not success or not imageData then
            self:fillTestPattern()
            rawset(self, "_lastProcessTime", now)
            return
        end
        
        -- Process the captured image and store in SRAM
        self:processImage(imageData)
        rawset(self, "_lastProcessTime", now)
    end
    
    -- Fill SRAM with a test pattern when no camera is available
    pocketcam.fillTestPattern = function(self)
        -- Clear the entire image area first
        for i = 0x100, 0x100 + 0xE00 do
            self.external_ram[i] = 0
        end
        
        -- Create HORIZONTAL STRIPES pattern
        -- GB Camera: 128x112 pixels, 16x14 tiles, each tile 8x8 pixels = 16 bytes
        for tileY = 0, 13 do
            for tileX = 0, 15 do
                local tileAddr = 0x100 + (tileY * 16 + tileX) * 16
                local isBlackTile = (tileY % 2) == 1
                
                for row = 0, 7 do
                    local byteVal = isBlackTile and 0x00 or 0xFF
                    self.external_ram[tileAddr + row * 2] = byteVal
                    self.external_ram[tileAddr + row * 2 + 1] = byteVal
                end
            end
        end
        
        self.external_ram.dirty = true
    end
    
    -- Process captured image data and store in SRAM format
    pocketcam.processImage = function(self, imageData)
        -- imageData should be a 2D array: imageData[y][x] = {r, g, b} (0-255)
        
        if not imageData then
            warn("[GB Camera] processImage called with nil imageData")
            return
        end
        
        -- Get exposure from registers 2-3 (big endian)
        local gameExposure = bit32.lshift(self.registers[2] or 0, 8) + (self.registers[3] or 0)
        -- Default exposure if not set
        if gameExposure == 0 then
            gameExposure = 0x100  -- Default exposure
        end
        
        -- Default dithering matrix (from reverse engineering docs)
        -- This is a 4x4 pattern with 3 thresholds per position (48 values total)
        -- Values are in the range 0x8C-0xE7 (140-231), which is too high for our normalized range
        -- We'll use simpler, more reasonable thresholds that work with normalized 0-255 range
        local defaultMatrix = {
            0x40, 0x80, 0xC0, 0x45, 0x85, 0xC5, 0x42, 0x82, 0xC2, 0x47, 0x87, 0xC7,
            0x48, 0x88, 0xC8, 0x43, 0x83, 0xC3, 0x4A, 0x8A, 0xCA, 0x41, 0x81, 0xC1,
            0x44, 0x84, 0xC4, 0x49, 0x89, 0xC9, 0x46, 0x86, 0xC6, 0x4B, 0x8B, 0xCB,
            0x4C, 0x8C, 0xCC, 0x4D, 0x8D, 0xCD, 0x4E, 0x8E, 0xCE, 0x4F, 0x8F, 0xCF
        }
        
        -- Get dithering matrix from registers 6-53, or use defaults
        local function getMatrixThreshold(x, y, thresholdIndex)
            -- thresholdIndex: 0, 1, or 2 (for the 3 thresholds)
            local blockX = bit32.band(x, 3)  -- 0-3
            local blockY = bit32.band(y, 3)  -- 0-3
            local matrixEntry = 3 * (blockX + 4 * blockY) + thresholdIndex
            local regIndex = 6 + matrixEntry
            
            if regIndex < 0x36 and self.registers[regIndex] and self.registers[regIndex] ~= 0 then
                -- Use register value, but scale it to match normalized range (0-255)
                -- Game Boy Camera registers use values in range 0x8C-0xE7 (140-231) for dithering
                -- We need to map these to 0-255 range for our normalized grayscale values
                local regValue = self.registers[regIndex]
                if regValue >= 0x8C and regValue <= 0xE7 then
                    -- Scale from 0x8C-0xE7 range to 0x40-0xC0 range (64-192)
                    -- This gives us reasonable thresholds for normalized 0-255 values
                    regValue = 0x40 + math.floor((regValue - 0x8C) * (0xC0 - 0x40) / (0xE7 - 0x8C))
                elseif regValue > 0xE7 then
                    -- Very high values - scale down more aggressively
                    regValue = 0xC0 + math.floor((regValue - 0xE7) * 0.2)
                elseif regValue < 0x8C and regValue > 0 then
                    -- Low values - use as-is but ensure minimum
                    regValue = math.max(0x20, regValue)
                end
                return regValue
            else
                -- Use default matrix (1-indexed in Lua)
                local defaultValue = defaultMatrix[matrixEntry + 1]
                if not defaultValue or defaultValue == 0 then
                    -- Fallback: use evenly spaced thresholds based on position for dithering
                    local baseThreshold
                    if thresholdIndex == 0 then
                        baseThreshold = 0x40  -- 64
                    elseif thresholdIndex == 1 then
                        baseThreshold = 0x80  -- 128
                    else
                        baseThreshold = 0xC0  -- 192
                    end
                    -- Add slight variation based on position for dithering effect
                    local ditherOffset = ((blockX + blockY * 4) % 4) - 2
                    return math.max(0, math.min(255, baseThreshold + ditherOffset * 4))
                end
                return defaultValue
            end
        end
        
        -- Clear the image area in SRAM
        for i = 0x100, 0x100 + (PocketCam.GBCAM_HEIGHT * PocketCam.GBCAM_WIDTH / 4) - 1 do
            self.external_ram[i] = 0
        end
        
        -- First pass: calculate brightness statistics for normalization
        local minGray = 255
        local maxGray = 0
        local graySum = 0
        local pixelCount = 0
        
        for y = 0, PocketCam.GBCAM_HEIGHT - 1 do
            for x = 0, PocketCam.GBCAM_WIDTH - 1 do
                local pixel = imageData[y] and imageData[y][x]
                if pixel then
                    local r = pixel[1] or 128
                    local g = pixel[2] or 128
                    local b = pixel[3] or 128
                    local gray = math.floor(0.299 * r + 0.587 * g + 0.114 * b)
                    minGray = math.min(minGray, gray)
                    maxGray = math.max(maxGray, gray)
                    graySum = graySum + gray
                    pixelCount = pixelCount + 1
                end
            end
        end
        
        -- Debug brightness statistics
        local avgGray = pixelCount > 0 and (graySum / pixelCount) or 128
        local grayRange = maxGray - minGray
        
        -- Verify we actually have image data
        if pixelCount == 0 then
            warn("[GB Camera] No valid pixels found in image data!")
            return
        end
        
        -- Verify we have valid image data (reduced logging for live preview performance)
        
        -- Calculate normalization parameters
        -- Always normalize to use full dynamic range, but be smart about it
        local scale, offset
        local targetMin, targetMax
        
        if grayRange < 5 then
            -- Extremely low contrast - force some variation
            targetMin = 50
            targetMax = 200
            scale = (targetMax - targetMin) / math.max(grayRange, 1)
            offset = targetMin - minGray * scale
        elseif grayRange < 30 then
            -- Low contrast - aggressive stretching
            targetMin = 30
            targetMax = 225
            scale = (targetMax - targetMin) / grayRange
            offset = targetMin - minGray * scale
        else
            -- Good contrast - normalize to use most of the range
            targetMin = 20
            targetMax = 235
            scale = (targetMax - targetMin) / grayRange
            offset = targetMin - minGray * scale
        end
        
        -- Process each pixel
        for y = 0, PocketCam.GBCAM_HEIGHT - 1 do
            for x = 0, PocketCam.GBCAM_WIDTH - 1 do
                -- Get pixel color (default to mid-gray if not available)
                local pixel = imageData[y] and imageData[y][x]
                local inputGray, gray
                
                if pixel then
                    -- Convert RGB to grayscale using standard luminance weights
                    local r = pixel[1] or 128
                    local g = pixel[2] or 128
                    local b = pixel[3] or 128
                    inputGray = math.floor(0.299 * r + 0.587 * g + 0.114 * b)
                    
                    -- Normalize brightness
                    gray = math.floor(inputGray * scale + offset)
                    gray = math.min(gray, 255)
                    gray = math.max(gray, 0)
                    
                    -- If input had very low contrast, add positional variation to ensure dithering works
                    if grayRange < 5 then
                        -- Add a subtle gradient pattern based on position to create variation
                        local positionVariation = math.floor((x + y * 2) % 8) * 4  -- 0-28 variation
                        gray = gray + positionVariation - 14  -- Center the variation
                        gray = math.min(gray, 255)
                        gray = math.max(gray, 0)
                    end
                    
                    -- Apply exposure adjustment (similar to mGBA: gray = (gray + 1) * exposure / 0x100)
                    -- Clamp exposure to reasonable range to prevent overexposure
                    local clampedExposure = math.max(0x80, math.min(0x200, gameExposure))
                    gray = math.floor((gray + 1) * clampedExposure / 0x100)
                    gray = math.min(gray, 255)
                    gray = math.max(gray, 0)
                else
                    inputGray = 128
                    gray = 128
                end
                
                -- Get dithering thresholds for this pixel position (4x4 pattern)
                local threshold1 = getMatrixThreshold(x, y, 0)  -- Darkest threshold
                local threshold2 = getMatrixThreshold(x, y, 1)  -- Dark threshold
                local threshold3 = getMatrixThreshold(x, y, 2)  -- Light threshold
                
                -- FORCE thresholds to reasonable values for normalized 0-255 range
                -- Ignore game's register values - they're calibrated for real camera sensors
                -- Use evenly spaced thresholds: 64, 128, 192 (with slight dithering variation)
                local base1, base2, base3 = 64, 128, 192
                
                -- Add slight dithering variation based on position (4x4 pattern)
                local blockX = bit32.band(x, 3)
                local blockY = bit32.band(y, 3)
                local ditherOffset = ((blockX + blockY * 4) % 4) - 1.5  -- -1.5 to 1.5
                
                threshold1 = math.floor(base1 + ditherOffset * 8)  -- 56-72 range
                threshold2 = math.floor(base2 + ditherOffset * 8)  -- 120-136 range
                threshold3 = math.floor(base3 + ditherOffset * 8)  -- 184-200 range
                
                -- Ensure proper spacing and clamp to valid range
                threshold1 = math.max(32, math.min(80, threshold1))
                threshold2 = math.max(threshold1 + 40, math.min(160, threshold2))
                threshold3 = math.max(threshold2 + 40, math.min(220, threshold3))
                
                -- Quantize to 4 levels using dithering matrix thresholds (following reference code)
                -- Matrix process returns: 0x00 (darkest), 0x40, 0x80, 0xC0 (lightest)
                local matrixValue
                if gray < threshold1 then
                    matrixValue = 0x00  -- Darkest
                elseif gray < threshold2 then
                    matrixValue = 0x40  -- Dark
                elseif gray < threshold3 then
                    matrixValue = 0x80  -- Light
                else
                    matrixValue = 0xC0  -- Lightest
                end
                
                -- Convert matrix value to outcolor (0-3): outcolor = 3 - (matrixValue >> 6)
                -- 0x00 -> 3 (black), 0x40 -> 2 (dark gray), 0x80 -> 1 (light gray), 0xC0 -> 0 (white)
                local outcolor = 3 - bit32.rshift(matrixValue, 6)
                
                -- Convert outcolor to bit pattern for tile storage
                -- IMPORTANT: Game Boy Camera uses INVERTED color mapping compared to standard GB!
                -- In GB Camera: color 0 (0x000) = BLACK, color 3 (0x101) = WHITE
                -- So we map: dark input → low color index (black), light input → high color index (white)
                -- outcolor 0 (lightest input) -> 0x101, 1 -> 0x100, 2 -> 0x001, 3 (darkest input) -> 0x000
                local quantized
                if outcolor == 0 then
                    quantized = 0x101  -- Lightest input: both bits set (displays as white in GB Camera)
                elseif outcolor == 1 then
                    quantized = 0x100  -- Light gray: bit 8 set (high plane)
                elseif outcolor == 2 then
                    quantized = 0x001  -- Dark gray: bit 0 set (low plane)
                else -- outcolor == 3
                    quantized = 0x000  -- Darkest input: no bits set (displays as black in GB Camera)
                end
                
                -- Calculate coordinate in SRAM using the Game Boy Camera's tile format
                -- Following reference code: basetileaddr = ((y>>3)*16+(x>>3)) * 16
                -- baselineaddr = basetileaddr + ((y&7) << 1)
                local tileX = bit32.rshift(x, 3)  -- x / 8
                local tileY = bit32.rshift(y, 3)  -- y / 8
                local basetileaddr = (tileY * 16 + tileX) * 16
                local baselineaddr = basetileaddr + bit32.lshift(bit32.band(y, 0x7), 1)  -- (y & 7) << 1
                local coord = baselineaddr
                
                -- Read existing 16-bit value (little endian)
                local low = self.external_ram[0x100 + coord] or 0
                local high = self.external_ram[0x100 + coord + 1] or 0
                local existing = low + high * 256
                
                -- OR in the new pixel data (following reference: if(outcolor & 1) and if(outcolor & 2))
                local shift = 7 - bit32.band(x, 7)
                local newBits = bit32.lshift(quantized, shift)
                existing = bit32.bor(existing, newBits)
                
                -- Store back (little endian)
                self.external_ram[0x100 + coord] = bit32.band(existing, 0xFF)
                self.external_ram[0x100 + coord + 1] = bit32.band(bit32.rshift(existing, 8), 0xFF)
            end
        end
        
        self.external_ram.dirty = true
    end
    
    pocketcam.reset = function(self)
        self.rom_bank = 1
        self.ram_bank = 0
        self.ram_enable = false
        self.registersActive = false
        
        for i = 0, 0x35 do
            self.registers[i] = 0
        end
    end
    
    pocketcam.save_state = function(self)
        local registers_copy = {}
        for i = 0, 0x35 do
            registers_copy[i] = self.registers[i]
        end
        
        return {
            rom_bank = self.rom_bank,
            ram_bank = self.ram_bank,
            ram_enable = self.ram_enable,
            registersActive = self.registersActive,
            registers = registers_copy,
        }
    end
    
    pocketcam.load_state = function(self, state_data)
        self:reset()
        
        if state_data then
            self.rom_bank = state_data.rom_bank or 1
            self.ram_bank = state_data.ram_bank or 0
            self.ram_enable = state_data.ram_enable or false
            self.registersActive = state_data.registersActive or false
            
            if state_data.registers then
                for i = 0, 0x35 do
                    self.registers[i] = state_data.registers[i] or 0
                end
            end
        end
    end
    
    -- Set the camera capture callback
    pocketcam.setCaptureCallback = function(self, callback)
        -- Use rawset to bypass metatable and set the actual callback
        rawset(self, "captureCallback", callback)
    end
    
    setmetatable(pocketcam, pocketcam.mt)
    
    return pocketcam
end

return PocketCam

