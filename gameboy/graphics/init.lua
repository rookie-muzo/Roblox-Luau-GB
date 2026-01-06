--!native

local Cache = require(script.cache)
local Palette = require(script.palette)
local Registers = require(script.registers)

local Graphics = {}

function Graphics.new(modules)
    local interrupts = modules.interrupts
    local dma = modules.dma
    local io = modules.io
    local memory = modules.memory
    local timers = modules.timers

    local graphics = {}
    graphics.cache = Cache.new(graphics)
    graphics.palette = Palette.new(graphics, modules)
    graphics.registers = Registers.new(graphics, modules, graphics.cache)

    --just for shortening access
    local ports = io.ports

    -- Internal Variables
    graphics.vblank_count = 0
    graphics.last_edge = 0
    graphics.next_edge = 0
    graphics.lcdstat = false

    graphics.game_screen = {}

    graphics.clear_screen = function()
        for y = 0, 143 do
            graphics.game_screen[y] = {}
            for x = 0, 159 do
                graphics.game_screen[y][x] = { 255, 255, 255 }
            end
        end
    end

    graphics.lcd = {}

    -- Initialize VRAM blocks in main memory
    graphics.vram = memory.generate_block(16 * 2 * 1024, 0x8000)
    graphics.vram.bank = 0
    graphics.vram_map = {}
    graphics.vram_map.mt = {}
    graphics.vram_map.mt.__index = function(_: any, address: number)
        return graphics.vram[address + (16 * 1024 * graphics.vram.bank)]
    end
    graphics.vram_map.mt.__newindex = function(_: any, address, value)
        graphics.vram[address + (16 * 1024 * graphics.vram.bank)] = value
        if address >= 0x8000 and address <= 0x97FF then
            graphics.cache.refreshTile(address, graphics.vram.bank)
        end
        if address >= 0x9800 and address <= 0x9BFF then
            local x = address % 32
            local y = math.floor((address - 0x9800) / 32)
            if graphics.vram.bank == 1 then
                graphics.cache.refreshAttributes(graphics.cache.map_0_attr, x, y, address)
            end
            graphics.cache.refreshTileIndex(x, y, 0x9800, graphics.cache.map_0, graphics.cache.map_0_attr)
        end
        if address >= 0x9C00 and address <= 0x9FFF then
            local x = address % 32
            local y = math.floor((address - 0x9C00) / 32)
            if graphics.vram.bank == 1 then
                graphics.cache.refreshAttributes(graphics.cache.map_1_attr, x, y, address)
            end
            graphics.cache.refreshTileIndex(x, y, 0x9C00, graphics.cache.map_1, graphics.cache.map_1_attr)
        end
    end

    setmetatable(graphics.vram_map, graphics.vram_map.mt)
    memory.map_block(0x80, 0x9F, graphics.vram_map, 0)

    graphics.oam_raw = memory.generate_block(0xA0, 0xFE00)
    graphics.oam = {}
    graphics.oam.mt = {}

    graphics.oam.mt.__index = function(_: any, address)
        if address <= 0xFE9F then
            local value = graphics.oam_raw[address]
            -- Return 0x00 if value is nil (can happen during save state loading)
            return value or 0x00
        end
        -- out of range? So sorry, return nothing
        return 0x00
    end
    graphics.oam.mt.__newindex = function(_: any, address, byte)
        if address <= 0xFE9F then
            graphics.oam_raw[address] = byte
            graphics.cache.refreshOamEntry(math.floor((address - 0xFE00) / 4))
        end
        -- out of range? So sorry, discard the write
        return
    end
    setmetatable(graphics.oam, graphics.oam.mt)
    memory.map_block(0xFE, 0xFE, graphics.oam, 0)

    io.write_logic[0x4F] = function(byte)
        local gameboy = rawget(graphics, "gameboy")

        if gameboy.type == gameboy.types.color then
            io.ram[0x4F] = bit32.band(0x1, byte)
            graphics.vram.bank = bit32.band(0x1, byte)
        else
            -- Not sure if the write mask should apply in DMG / SGB mode
            io.ram[0x4F] = byte
        end
    end

    graphics.reset = function()
        graphics.cache.reset()
        graphics.palette.reset()

        -- zero out all of VRAM:
        for i = 0x8000, (0x8000 + (16 * 2 * 1024) - 1) do
            graphics.vram[i] = 0
        end

        -- zero out all of OAM
        for i = 0xFE00, 0xFE9F do
            graphics.oam[i] = 0
        end

        graphics.vblank_count = 0
        graphics.last_edge = 0
        graphics.vram.bank = 0
        graphics.lcdstat = false

        graphics.clear_screen()
        graphics.registers.status.SetMode(2)
    end

    graphics.initialize = function(gameboy)
        graphics.gameboy = gameboy
        graphics.registers.status.SetMode(2)
        graphics.clear_screen()
        graphics.reset()
    end

    -- Base64 encoding table
    local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    
    -- Helper to encode byte array as base64 string (JSON-safe for DataStore)
    local function encodeBytes(data, startAddr, endAddr)
        local bytes = {}
        for i = startAddr, endAddr do
            bytes[#bytes + 1] = data[i] or 0
        end
        
        -- Base64 encode
        local result = {}
        local n = #bytes
        for i = 1, n, 3 do
            local b1 = bytes[i] or 0
            local b2 = bytes[i + 1] or 0
            local b3 = bytes[i + 2] or 0
            
            local c1 = bit32.rshift(b1, 2)
            local c2 = bit32.bor(bit32.lshift(bit32.band(b1, 3), 4), bit32.rshift(b2, 4))
            local c3 = bit32.bor(bit32.lshift(bit32.band(b2, 15), 2), bit32.rshift(b3, 6))
            local c4 = bit32.band(b3, 63)
            
            result[#result + 1] = string.sub(b64chars, c1 + 1, c1 + 1)
            result[#result + 1] = string.sub(b64chars, c2 + 1, c2 + 1)
            if i + 1 <= n then
                result[#result + 1] = string.sub(b64chars, c3 + 1, c3 + 1)
            else
                result[#result + 1] = "="
            end
            if i + 2 <= n then
                result[#result + 1] = string.sub(b64chars, c4 + 1, c4 + 1)
            else
                result[#result + 1] = "="
            end
        end
        return table.concat(result)
    end
    
    -- Helper to decode base64 string back to byte array
    local function decodeBytes(str, startAddr)
        local data = {}
        local b64lookup = {}
        for i = 1, 64 do
            b64lookup[string.sub(b64chars, i, i)] = i - 1
        end
        b64lookup["="] = 0
        
        local bytes = {}
        for i = 1, #str, 4 do
            local c1 = b64lookup[string.sub(str, i, i)] or 0
            local c2 = b64lookup[string.sub(str, i + 1, i + 1)] or 0
            local c3 = b64lookup[string.sub(str, i + 2, i + 2)] or 0
            local c4 = b64lookup[string.sub(str, i + 3, i + 3)] or 0
            
            bytes[#bytes + 1] = bit32.bor(bit32.lshift(c1, 2), bit32.rshift(c2, 4))
            if string.sub(str, i + 2, i + 2) ~= "=" then
                bytes[#bytes + 1] = bit32.band(bit32.bor(bit32.lshift(c2, 4), bit32.rshift(c3, 2)), 255)
            end
            if string.sub(str, i + 3, i + 3) ~= "=" then
                bytes[#bytes + 1] = bit32.band(bit32.bor(bit32.lshift(c3, 6), c4), 255)
            end
        end
        
        for i, v in ipairs(bytes) do
            data[startAddr + i - 1] = v
        end
        return data
    end

    graphics.save_state = function()
        local state = {}

        -- Store VRAM as compact string (0-based for efficient storage)
        state.vram_data = encodeBytes(graphics.vram, 0x8000, 0x8000 + (16 * 2 * 1024) - 1)
        state.vram_bank = graphics.vram.bank

        -- Store OAM as compact string
        state.oam_data = encodeBytes(graphics.oam, 0xFE00, 0xFE9F)

        state.vblank_count = graphics.vblank_count
        state.last_edge = graphics.last_edge
        state.next_edge = graphics.next_edge  -- Critical timing field
        state.lcdstat = graphics.lcdstat
        state.mode = graphics.registers.status.mode

        state.palette = {}
        state.palette.bg = graphics.palette.bg
        state.palette.obj0 = graphics.palette.obj0
        state.palette.obj1 = graphics.palette.obj1

        state.color_bg = {}
        state.color_obj = {}
        state.color_bg_raw = {}
        state.color_obj_raw = {}

        for p = 0, 7 do
            state.color_bg[p] = graphics.palette.color_bg[p]
            state.color_obj[p] = graphics.palette.color_obj[p]
        end

        for i = 0, 63 do
            state.color_bg_raw[i] = graphics.palette.color_bg_raw[i]
            state.color_obj_raw[i] = graphics.palette.color_obj_raw[i]
        end

        -- Save register state
        state.registers = {
            display_enabled = graphics.registers.display_enabled,
            window_enabled = graphics.registers.window_enabled,
            large_sprites = graphics.registers.large_sprites,
            sprites_enabled = graphics.registers.sprites_enabled,
            background_enabled = graphics.registers.background_enabled,
            oam_priority = graphics.registers.oam_priority,
            tile_select = graphics.registers.tile_select,
            status = {
                mode = graphics.registers.status.mode,
                lyc_interrupt_enabled = graphics.registers.status.lyc_interrupt_enabled,
                oam_interrupt_enabled = graphics.registers.status.oam_interrupt_enabled,
                vblank_interrupt_enabled = graphics.registers.status.vblank_interrupt_enabled,
                hblank_interrupt_enabled = graphics.registers.status.hblank_interrupt_enabled,
            }
        }
        
        -- Save frame data (critical for window internal line counter)
        state.frame_data = {
            window_pos_y = graphics.frame_data and graphics.frame_data.window_pos_y or 0,
            window_draw_y = graphics.frame_data and graphics.frame_data.window_draw_y or 0,
        }

        return state
    end

    graphics.load_state = function(state)
        if not state then
            warn("[Graphics] Invalid state in load_state")
            return
        end
        
        -- Load VRAM from compact string format (new) or legacy format
        if state.vram_data then
            -- New compact format
            local decoded = decodeBytes(state.vram_data, 0x8000)
            for addr, value in pairs(decoded) do
                graphics.vram[addr] = value
            end
        elseif state.vram then
            -- Legacy format (sparse array)
            for i = 0x8000, (0x8000 + (16 * 2 * 1024) - 1) do
                graphics.vram[i] = state.vram[i] or 0
            end
        end

        graphics.vram.bank = state.vram_bank or 0

        -- Load OAM from compact string format (new) or legacy format
        if state.oam_data then
            -- New compact format
            local decoded = decodeBytes(state.oam_data, 0xFE00)
            for addr, value in pairs(decoded) do
                graphics.oam_raw[addr] = value
            end
        elseif state.oam then
            -- Legacy format
            for i = 0xFE00, 0xFE9F do
                graphics.oam_raw[i] = state.oam[i] or 0x00
            end
        end
        
        graphics.vblank_count = state.vblank_count or 0
        graphics.last_edge = state.last_edge or 0
        graphics.next_edge = state.next_edge or 0  -- Critical timing field
        graphics.lcdstat = state.lcdstat or false
        graphics.registers.status.mode = state.mode or 2

        -- Restore DMG palettes (fix JSON numeric key to string key conversion)
        -- JSON converts numeric keys to strings, so we try both
        local function restorePaletteEntry(savedPalette)
            local result = {}
            for i = 0, 3 do
                local entry = savedPalette[i] or savedPalette[tostring(i)]
                if entry then
                    -- Entry is {r, g, b} but might have string keys
                    result[i] = {
                        entry[1] or entry["1"] or 255,
                        entry[2] or entry["2"] or 255,
                        entry[3] or entry["3"] or 255
                    }
                else
                    result[i] = {255, 255, 255}  -- Default white
                end
            end
            return result
        end
        
        if state.palette and state.palette.bg then
            local restored = restorePaletteEntry(state.palette.bg)
            for i = 0, 3 do
                graphics.palette.bg[i] = restored[i]
            end
        end
        if state.palette and state.palette.obj0 then
            local restored = restorePaletteEntry(state.palette.obj0)
            for i = 0, 3 do
                graphics.palette.obj0[i] = restored[i]
            end
        end
        if state.palette and state.palette.obj1 then
            local restored = restorePaletteEntry(state.palette.obj1)
            for i = 0, 3 do
                graphics.palette.obj1[i] = restored[i]
            end
        end

        -- Note: GBC color palettes are rebuilt from raw values below, 
        -- so we skip the potentially corrupted state.color_bg/color_obj tables

        for i = 0, 63 do
            -- Handle JSON string key conversion
            local bg_val = state.color_bg_raw and (state.color_bg_raw[i] or state.color_bg_raw[tostring(i)])
            if bg_val then
                graphics.palette.color_bg_raw[i] = bg_val
            end
            local obj_val = state.color_obj_raw and (state.color_obj_raw[i] or state.color_obj_raw[tostring(i)])
            if obj_val then
                graphics.palette.color_obj_raw[i] = obj_val
            end
        end
        
        -- Rebuild color palettes from raw values (JSON may corrupt nested tables)
        for p = 0, 7 do
            if not graphics.palette.color_bg[p] then
                graphics.palette.color_bg[p] = {}
            end
            if not graphics.palette.color_obj[p] then
                graphics.palette.color_obj[p] = {}
            end
            for c = 0, 3 do
                -- Rebuild BG palette from raw bytes
                local bg_raw_idx = p * 8 + c * 2
                local bg_low = graphics.palette.color_bg_raw[bg_raw_idx] or 0
                local bg_high = graphics.palette.color_bg_raw[bg_raw_idx + 1] or 0
                local bg_rgb5 = bit32.lshift(bg_high, 8) + bg_low
                local bg_r = bit32.band(bg_rgb5, 0x001F) * 8
                local bg_g = bit32.rshift(bit32.band(bg_rgb5, 0x03E0), 5) * 8
                local bg_b = bit32.rshift(bit32.band(bg_rgb5, 0x7C00), 10) * 8
                graphics.palette.color_bg[p][c] = { bg_r, bg_g, bg_b }
                
                -- Rebuild OBJ palette from raw bytes
                local obj_raw_idx = p * 8 + c * 2
                local obj_low = graphics.palette.color_obj_raw[obj_raw_idx] or 0
                local obj_high = graphics.palette.color_obj_raw[obj_raw_idx + 1] or 0
                local obj_rgb5 = bit32.lshift(obj_high, 8) + obj_low
                local obj_r = bit32.band(obj_rgb5, 0x001F) * 8
                local obj_g = bit32.rshift(bit32.band(obj_rgb5, 0x03E0), 5) * 8
                local obj_b = bit32.rshift(bit32.band(obj_rgb5, 0x7C00), 10) * 8
                graphics.palette.color_obj[p][c] = { obj_r, obj_g, obj_b }
            end
        end
        
        -- Restore frame data (critical for window internal line counter)
        if state.frame_data and graphics.frame_data then
            graphics.frame_data.window_pos_y = state.frame_data.window_pos_y or 0
            graphics.frame_data.window_draw_y = state.frame_data.window_draw_y or 0
        end

        -- Refresh all graphics cache after loading (tiles, maps, OAM)
        -- Wrap in pcall to catch any errors during cache refresh
        local cacheSuccess, cacheError = pcall(function()
            graphics.cache.refreshAll()
        end)
        if not cacheSuccess then
            warn("[Graphics] Cache refresh failed during load_state:", cacheError)
        end
        
        -- Restore register state directly (saved as part of state)
        if state.registers then
            graphics.registers.display_enabled = state.registers.display_enabled ~= nil and state.registers.display_enabled or true
            graphics.registers.window_enabled = state.registers.window_enabled ~= nil and state.registers.window_enabled or true
            graphics.registers.large_sprites = state.registers.large_sprites ~= nil and state.registers.large_sprites or false
            graphics.registers.sprites_enabled = state.registers.sprites_enabled ~= nil and state.registers.sprites_enabled or true
            graphics.registers.background_enabled = state.registers.background_enabled ~= nil and state.registers.background_enabled or true
            graphics.registers.oam_priority = state.registers.oam_priority ~= nil and state.registers.oam_priority or false
            graphics.registers.tile_select = state.registers.tile_select or 0x9000
            
            -- Tilemap references will be restored in Gameboy:load_state after IO is loaded
            -- For now, set defaults (will be corrected later)
            graphics.registers.background_tilemap = graphics.cache.map_0
            graphics.registers.background_attr = graphics.cache.map_0_attr
            graphics.registers.window_tilemap = graphics.cache.map_0
            graphics.registers.window_attr = graphics.cache.map_0_attr
            
            -- Restore status register state
            if state.registers.status then
                graphics.registers.status.mode = state.registers.status.mode or 2
                graphics.registers.status.lyc_interrupt_enabled = state.registers.status.lyc_interrupt_enabled or false
                graphics.registers.status.oam_interrupt_enabled = state.registers.status.oam_interrupt_enabled or false
                graphics.registers.status.vblank_interrupt_enabled = state.registers.status.vblank_interrupt_enabled or false
                graphics.registers.status.hblank_interrupt_enabled = state.registers.status.hblank_interrupt_enabled or false
            end
        end
    end

    local scanline_data = {}
    scanline_data.x = 0
    scanline_data.bg_tile_x = 0
    scanline_data.bg_tile_y = 0
    scanline_data.sub_x = 0
    scanline_data.sub_y = 0
    scanline_data.active_tile = nil
    scanline_data.active_attr = nil
    scanline_data.current_map = nil
    scanline_data.current_map_attr = nil
    scanline_data.window_active = false
    scanline_data.bg_index = {}
    scanline_data.bg_priority = {}
    scanline_data.active_palette = nil

    graphics.refresh_lcdstat = function()
        local lcdstat = false
        local status = graphics.registers.status

        lcdstat = (status.lyc_interrupt_enabled and io.ram[ports.LY] == io.ram[ports.LYC])
            or (status.oam_interrupt_enabled and status.mode == 2)
            or (status.vblank_interrupt_enabled and status.mode == 1)
            or (status.hblank_interrupt_enabled and status.mode == 0)

        -- If this is a *rising* edge, raise the LCDStat interrupt
        if graphics.lcdstat == false and lcdstat == true then
            interrupts.raise(interrupts.LCDStat)
        end

        graphics.lcdstat = lcdstat
    end

    local frame_data = {}
    frame_data.window_pos_y = 0
    frame_data.window_draw_y = 0
    graphics.frame_data = frame_data  -- Expose for save_state access

    graphics.initialize_frame = function()
        -- latch WY at the beginning of the *frame*
        frame_data.window_pos_y = io.ram[ports.WY]
        frame_data.window_draw_y = 0
    end

    graphics.initialize_scanline = function()
        scanline_data.x = 0

        scanline_data.bg_tile_x = math.floor(io.ram[ports.SCX] / 8)
        scanline_data.bg_tile_y = math.floor((io.ram[ports.LY] + io.ram[ports.SCY]) / 8)
        if scanline_data.bg_tile_y >= 32 then
            scanline_data.bg_tile_y = scanline_data.bg_tile_y - 32
        end

        -- Handle nil values (can occur during save state loading)
        local scx = io.ram[ports.SCX] or 0
        local ly = io.ram[ports.LY] or 0
        local scy = io.ram[ports.SCY] or 0
        scanline_data.sub_x = scx % 8
        scanline_data.sub_y = (ly + scy) % 8

        scanline_data.current_map = graphics.registers.background_tilemap
        scanline_data.current_map_attr = graphics.registers.background_attr

        scanline_data.active_attr = scanline_data.current_map_attr[scanline_data.bg_tile_x][scanline_data.bg_tile_y]
        -- Apply vertical flip for the FIRST background tile (tile fetch code only runs after first 8 pixels)
        if scanline_data.active_attr.vertical_flip then
            scanline_data.sub_y = 7 - scanline_data.sub_y
        end
        scanline_data.active_tile = scanline_data.current_map[scanline_data.bg_tile_x][scanline_data.bg_tile_y]
        scanline_data.window_active = false
    end

    graphics.switch_to_window = function()
        local ly = io.ram[ports.LY]
        local w_x = io.ram[ports.WX] - 7
        if graphics.registers.window_enabled and scanline_data.x >= w_x and ly >= frame_data.window_pos_y then
            -- switch to window map
            scanline_data.current_map = graphics.registers.window_tilemap
            scanline_data.current_map_attr = graphics.registers.window_attr
            scanline_data.bg_tile_x = math.floor((scanline_data.x - w_x) / 8)
            scanline_data.bg_tile_y = math.floor(frame_data.window_draw_y / 8)
            scanline_data.sub_x = (scanline_data.x - w_x) % 8
            scanline_data.sub_y = frame_data.window_draw_y % 8
            frame_data.window_draw_y = frame_data.window_draw_y + 1
            if frame_data.window_draw_y > 143 then
                frame_data.window_draw_y = 143
            end

            scanline_data.active_attr = scanline_data.current_map_attr[scanline_data.bg_tile_x][scanline_data.bg_tile_y]
            -- Apply vertical flip for the FIRST window tile (tile fetch code only runs after first 8 pixels)
            if scanline_data.active_attr.vertical_flip then
                scanline_data.sub_y = 7 - scanline_data.sub_y
            end
            scanline_data.active_tile = scanline_data.current_map[scanline_data.bg_tile_x][scanline_data.bg_tile_y]
            scanline_data.window_active = true
        end
    end

    -- Optimized: Cache locals, reduce table lookups, remove nil checks from hot path
    -- IMPORTANT: scanline_data.x must be kept in sync for switch_to_window() checks
    graphics.draw_next_pixels = function(duration)
        local ly = io.ram[ports.LY]
        local scanline_row = graphics.game_screen[ly]
        local bg_enabled = graphics.registers.background_enabled
        local sd = scanline_data
        local sd_x = sd.x
        local sd_sub_x = sd.sub_x
        local sd_sub_y = sd.sub_y
        local sd_bg_tile_x = sd.bg_tile_x
        local sd_bg_tile_y = sd.bg_tile_y
        local active_tile = sd.active_tile
        local active_attr = sd.active_attr
        local current_map = sd.current_map
        local current_map_attr = sd.current_map_attr
        local bg_index_arr = sd.bg_index
        local bg_priority_arr = sd.bg_priority
        local window_active = sd.window_active
        local scy = io.ram[ports.SCY]

        while sd_x < duration and sd_x < 160 do
            if not window_active then
                -- CRITICAL: Update scanline_data.x BEFORE switch_to_window() check
                -- switch_to_window() reads scanline_data.x to determine window activation
                sd.x = sd_x
                graphics.switch_to_window()
                window_active = sd.window_active
                if window_active then
                    -- Reload cached values after window switch
                    sd_sub_x = sd.sub_x
                    sd_sub_y = sd.sub_y
                    sd_bg_tile_x = sd.bg_tile_x
                    sd_bg_tile_y = sd.bg_tile_y
                    active_tile = sd.active_tile
                    active_attr = sd.active_attr
                    current_map = sd.current_map
                    current_map_attr = sd.current_map_attr
                end
            end

            local bg_index = 0
            if bg_enabled then
                bg_index = active_tile[sd_sub_x][sd_sub_y] or 0
                local pixel = scanline_row[sd_x]
                local color = active_attr.palette[bg_index]
                pixel[1] = color[1]
                pixel[2] = color[2]
                pixel[3] = color[3]
            end

            bg_index_arr[sd_x] = bg_index
            bg_priority_arr[sd_x] = active_attr.priority

            sd_x = sd_x + 1
            sd_sub_x = sd_sub_x + 1
            if sd_sub_x > 7 then
                sd_sub_x = 0
                sd_bg_tile_x = sd_bg_tile_x + 1
                if sd_bg_tile_x >= 32 then
                    sd_bg_tile_x = sd_bg_tile_x - 32
                end
                if not window_active then
                    sd_sub_y = (ly + scy) % 8
                    sd_bg_tile_y = math.floor((ly + scy) / 8)
                    if sd_bg_tile_y >= 32 then
                        sd_bg_tile_y = sd_bg_tile_y - 32
                    end
                else
                    -- For window, recalculate sub_y from base value before applying flip
                    -- (window_draw_y was incremented after setting sub_y, so subtract 1)
                    sd_sub_y = (frame_data.window_draw_y - 1) % 8
                end

                local tile_attr = current_map_attr[sd_bg_tile_x][sd_bg_tile_y]
                if tile_attr.vertical_flip then
                    sd_sub_y = 7 - sd_sub_y
                end

                active_attr = tile_attr
                active_tile = current_map[sd_bg_tile_x][sd_bg_tile_y]
            end
        end

        -- Write back to scanline_data
        sd.x = sd_x
        sd.sub_x = sd_sub_x
        sd.sub_y = sd_sub_y
        sd.bg_tile_x = sd_bg_tile_x
        sd.bg_tile_y = sd_bg_tile_y
        sd.active_tile = active_tile
        sd.active_attr = active_attr
        sd.window_active = window_active
    end

    graphics.getIndexFromTilemap = function(map, tile_data, x, y)
        local tile_x = bit32.rshift(x, 3)
        local tile_y = bit32.rshift(y, 3)
        local tile_index = map[tile_x][tile_y]

        local subpixel_x = x - (tile_x * 8)
        local subpixel_y = y - (tile_y * 8)

        if tile_data == 0x9000 then
            if tile_index > 127 then
                tile_index = tile_index - 256
            end
            -- add offset to re-root at tile 256 (so effectively, we read from tile 192 - 384)
            tile_index = tile_index + 256
        end

        if graphics.gameboy.type == graphics.gameboy.types.color then
            local map_attr = graphics.cache.map_0_attr
            if map == graphics.cache.map_1 then
                map_attr = graphics.cache.map_1_attr
            end
            local tile_attributes = map_attr[tile_x][tile_y]
            tile_index = tile_index + tile_attributes.bank * 384

            if tile_attributes.horizontal_flip == true then
                subpixel_x = (7 - subpixel_x)
            end

            if tile_attributes.vertical_flip == true then
                subpixel_y = (7 - subpixel_y)
            end
        end

        return graphics.cache.tiles[tile_index][subpixel_x][subpixel_y]
    end

    -- Optimized: Cache locals, reduce table lookups in inner loops
    graphics.draw_sprites_into_scanline = function(scanline, bg_index, bg_priority)
        local regs = graphics.registers
        if not regs.sprites_enabled then
            return
        end
        
        local oam_cache = graphics.cache.oam
        local sprite_size = regs.large_sprites and 16 or 8
        local active_sprites = {}
        local active_count = 0

        -- Collect up to 10 sprites on this scanline
        for i = 0, 39 do
            local sprite = oam_cache[i]
            local sprite_y = sprite.y
            if scanline >= sprite_y and scanline < sprite_y + sprite_size then
                if active_count < 10 then
                    active_count = active_count + 1
                    active_sprites[active_count] = i
                else
                    -- Find lowest priority sprite to potentially replace
                    local lowest_priority = i
                    local lowest_priority_index = nil
                    local lowest_x = sprite.x
                    for j = 1, 10 do
                        local candidate_x = oam_cache[active_sprites[j]].x
                        if candidate_x > lowest_x then
                            lowest_x = candidate_x
                            lowest_priority = active_sprites[j]
                            lowest_priority_index = j
                        end
                    end
                    if lowest_priority_index then
                        active_sprites[lowest_priority_index] = i
                    end
                end
            end
        end

        -- DMG sprite priority: Sort by X-coordinate (lower X = higher priority = drawn last)
        -- For CGB, OAM order is used (no sort needed since we collect in OAM order)
        -- Secondary sort by OAM index for sprites with same X
        if graphics.gameboy.type ~= graphics.gameboy.types.color then
            -- Sort active_sprites by X ASCENDING (lower X at front = index 1)
            -- Drawing loop is j = active_count → 1, so index 1 is drawn LAST (on top)
            -- This means lower X = drawn last = higher priority (correct DMG behavior)
            -- Use insertion sort for small arrays (max 10 elements)
            for i = 2, active_count do
                local j = i
                while j > 1 do
                    local curr_oam = active_sprites[j]
                    local prev_oam = active_sprites[j - 1]
                    local curr_x = oam_cache[curr_oam].x
                    local prev_x = oam_cache[prev_oam].x
                    -- Sort by X ascending, then by OAM index ascending (lower values first)
                    -- Lower X at front (index 1) → drawn last → appears on top
                    if curr_x < prev_x or (curr_x == prev_x and curr_oam < prev_oam) then
                        active_sprites[j] = prev_oam
                        active_sprites[j - 1] = curr_oam
                        j = j - 1
                    else
                        break
                    end
                end
            end
        end

        -- Draw sprites (back to front for proper priority)
        local game_screen = graphics.game_screen
        local scanline_row = game_screen[scanline]
        local oam_priority = regs.oam_priority
        
        for j = active_count, 1, -1 do
            local sprite = oam_cache[active_sprites[j]]
            local sprite_x = sprite.x
            local sub_y = scanline - sprite.y
            
            if sprite.vertical_flip then
                sub_y = sprite_size - 1 - sub_y
            end

            local tile
            if sprite_size == 16 then
                if sub_y >= 8 then
                    tile = sprite.lower_tile
                    sub_y = sub_y - 8
                else
                    tile = sprite.upper_tile
                end
            else
                tile = sprite.tile
            end

            local sprite_palette = sprite.palette
            local sprite_bg_priority = sprite.bg_priority
            
            for x = 0, 7 do
                local display_x = sprite_x + x
                if display_x >= 0 and display_x < 160 then
                    local idx = tile[x][sub_y]
                    if idx > 0 then
                        if oam_priority or bg_index[display_x] == 0 or (not bg_priority[display_x] and not sprite_bg_priority) then
                            local color = sprite_palette[idx]
                            local pixel = scanline_row[display_x]
                            pixel[1] = color[1]
                            pixel[2] = color[2]
                            pixel[3] = color[3]
                        end
                    end
                end
            end
        end
    end

    io.write_logic[ports.LY] = function(byte)
        -- LY, writes reset the counter
        io.ram[ports.LY] = 0
        graphics.refresh_lcdstat()
    end

    io.write_logic[ports.LYC] = function(byte)
        -- LY, writes reset the counter
        io.ram[ports.LYC] = byte
        graphics.refresh_lcdstat()
    end

    -- HBlank: Period between scanlines
    local handle_mode = {}
    handle_mode[0] = function()
        if timers.system_clock - graphics.last_edge > 204 then
            graphics.last_edge = graphics.last_edge + 204
            -- Handle nil values (can occur during save state loading)
            local ly = io.ram[ports.LY] or 0
            io.ram[ports.LY] = ly + 1
            local lyc = io.ram[ports.LYC] or 0
            if io.ram[ports.LY] == lyc then
                -- set the LY compare bit
                io.ram[ports.STAT] = bit32.bor(io.ram[ports.STAT], 0x4)
            else
                -- clear the LY compare bit
                io.ram[ports.STAT] = bit32.band(io.ram[ports.STAT], 0xFB)
            end

            if io.ram[ports.LY] >= 144 then
                graphics.registers.status.SetMode(1)
                graphics.vblank_count = graphics.vblank_count + 1
                interrupts.raise(interrupts.VBlank)
            else
                graphics.registers.status.SetMode(2)
            end

            graphics.refresh_lcdstat()
        else
            graphics.next_edge = graphics.last_edge + 204
        end
    end

    --VBlank: nothing to do except wait for the next frame
    handle_mode[1] = function()
        if timers.system_clock - graphics.last_edge > 456 then
            graphics.last_edge = graphics.last_edge + 456
            -- Handle nil values (can occur during save state loading)
            local ly = io.ram[ports.LY] or 0
            io.ram[ports.LY] = ly + 1
            graphics.refresh_lcdstat()
        else
            graphics.next_edge = graphics.last_edge + 456
        end

        if io.ram[ports.LY] >= 154 then
            io.ram[ports.LY] = 0
            graphics.initialize_frame()
            graphics.registers.status.SetMode(2)
            graphics.refresh_lcdstat()
        end

        if io.ram[ports.LY] == io.ram[ports.LYC] then
            -- set the LY compare bit
            io.ram[ports.STAT] = bit32.bor(io.ram[ports.STAT], 0x4)
        else
            -- clear the LY compare bit
            io.ram[ports.STAT] = bit32.band(io.ram[ports.STAT], 0xFB)
        end
    end

    -- OAM Read: OAM cannot be accessed
    handle_mode[2] = function()
        if timers.system_clock - graphics.last_edge > 80 then
            graphics.last_edge = graphics.last_edge + 80
            graphics.initialize_scanline()
            graphics.registers.status.SetMode(3)
            graphics.refresh_lcdstat()
        else
            graphics.next_edge = graphics.last_edge + 80
        end
    end
    -- VRAM Read: Neither VRAM, OAM, nor CGB palettes can be read
    handle_mode[3] = function()
        local duration = timers.system_clock - graphics.last_edge
        graphics.draw_next_pixels(duration)
        if timers.system_clock - graphics.last_edge > 172 then
            graphics.last_edge = graphics.last_edge + 172
            graphics.draw_sprites_into_scanline(io.ram[ports.LY], scanline_data.bg_index, scanline_data.bg_priority)
            graphics.registers.status.SetMode(0)
            -- If enabled, fire an HBlank interrupt
            graphics.refresh_lcdstat()
            -- If the hblank dma is active, copy the next block
            dma.do_hblank()
        else
            graphics.next_edge = graphics.last_edge + 172
        end
    end

    graphics.update = function()
        if graphics.registers.display_enabled then
            handle_mode[graphics.registers.status.mode]()
        else
            -- erase our clock debt, so we don't do stupid timing things when the
            -- display is enabled again later
            graphics.last_edge = timers.system_clock
            graphics.next_edge = timers.system_clock
            graphics.registers.status.SetMode(0)
            io.ram[ports.LY] = 0
            graphics.refresh_lcdstat()
        end
    end

    return graphics
end

return Graphics
