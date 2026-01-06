--!native
local Memory = {}

function Memory.new(modules)
    local memory = {}

    local block_map = {}
    memory.block_map = block_map

    memory.print_block_map = function()
        --debug
        print("Block Map: ")
        for b = 0, 0xFF do
            if block_map[bit32.lshift(b, 8)] then
                --print(string.format("Block at: %02X starts at %04X", b, block_map[bit32.lshift(b, 8)].start))
                print(block_map[bit32.lshift(b, 8)])
            end
        end
    end

    memory.map_block = function(starting_high_byte, ending_high_byte, mapped_block, starting_address)
        if starting_high_byte > 0xFF or ending_high_byte > 0xFF then
            print("Bad block, bailing", starting_high_byte, ending_high_byte)
            return
        end

        --starting_address = starting_address or bit32.lshift(starting_high_byte, 8)
        for i = starting_high_byte, ending_high_byte do
            --block_map[bit32.lshift(i, 8)] = {start=starting_address, block=mapped_block}
            block_map[bit32.lshift(i, 8)] = mapped_block
        end
    end

    memory.generate_block = function(size, starting_address)
        starting_address = starting_address or 0
        local block = {}
        for i = 0, size - 1 do
            block[starting_address + i] = 0
        end
        return block
    end

    -- Default, unmapped memory
    memory.unmapped = {}
    memory.unmapped.mt = {}
    memory.unmapped.mt.__index = function(_: any, key)
        return 0x00
    end
    memory.unmapped.mt.__newindex = function(_: any, key, value)
        -- Do nothing!
    end
    setmetatable(memory.unmapped, memory.unmapped.mt)
    memory.map_block(0, 0xFF, memory.unmapped)

    -- Main Memory
    memory.work_ram_0 = memory.generate_block(4 * 1024, 0xC000)
    memory.work_ram_1_raw = memory.generate_block(4 * 7 * 1024, 0xD000)
    memory.work_ram_1 = {}
    memory.work_ram_1.bank = 1
    memory.work_ram_1.mt = {}
    memory.work_ram_1.mt.__index = function(_: any, address)
        return memory.work_ram_1_raw[address + ((memory.work_ram_1.bank - 1) * 4 * 1024)]
    end
    memory.work_ram_1.mt.__newindex = function(_: any, address, value)
        memory.work_ram_1_raw[address + ((memory.work_ram_1.bank - 1) * 4 * 1024)] = value
    end
    setmetatable(memory.work_ram_1, memory.work_ram_1.mt)
    memory.map_block(0xC0, 0xCF, memory.work_ram_0, 0)
    memory.map_block(0xD0, 0xDF, memory.work_ram_1, 0)

    memory.read_byte = function(address)
        local high_byte = bit32.band(address, 0xFF00)
        local block = block_map[high_byte]
        if not block then
            -- Unmapped memory returns 0x00
            return 0x00
        end
        
        -- Access the block with the address - this will trigger metatable __index if present
        local value = block[address]
        
        -- If value is nil, return 0x00 (unmapped/missing memory)
        -- This is normal for some memory regions
        return value or 0x00
    end

    memory.write_byte = function(address, byte)
        local high_byte = bit32.band(address, 0xFF00)
        block_map[high_byte][address] = byte
    end

    memory.work_ram_echo = {}
    memory.work_ram_echo.mt = {}
    memory.work_ram_echo.mt.__index = function(_: any, key)
        return memory.read_byte(key - 0xE000 + 0xC000)
    end
    memory.work_ram_echo.mt.__newindex = function(_: any, key, value)
        memory.write_byte(key - 0xE000 + 0xC000, value)
    end
    setmetatable(memory.work_ram_echo, memory.work_ram_echo.mt)
    memory.map_block(0xE0, 0xFD, memory.work_ram_echo, 0)

    memory.reset = function()
        -- It's tempting to want to zero out all 0x0000-0xFFFF, but
        -- instead here we'll reset only that memory which this module
        -- DIRECTLY controls, so initialization logic can be performed
        -- elsewhere as appropriate.

        for i = 0xC000, 0xCFFF do
            memory.work_ram_0[i] = 0
        end

        for i = 0xD000, 0xDFFF do
            memory.work_ram_1[i] = 0
        end

        memory.work_ram_1.bank = 1
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

    memory.save_state = function()
        local state = {}

        -- Store WRAM as compact strings
        state.work_ram_0_data = encodeBytes(memory.work_ram_0, 0xC000, 0xCFFF)
        state.work_ram_1_data = encodeBytes(memory.work_ram_1_raw, 0xD000, 0xD000 + (4 * 7 * 1024) - 1)
        state.work_ram_1_bank = memory.work_ram_1.bank or 1

        return state
    end

    memory.load_state = function(state)
        if not state then return end
        
        -- Load WRAM from compact string format (new) or legacy format
        if state.work_ram_0_data then
            local decoded = decodeBytes(state.work_ram_0_data, 0xC000)
            for addr, value in pairs(decoded) do
                memory.work_ram_0[addr] = value
            end
        elseif state.work_ram_0 then
            -- Legacy format
            for i = 0xC000, 0xCFFF do
                memory.work_ram_0[i] = state.work_ram_0[i] or 0
            end
        end
        
        if state.work_ram_1_data then
            local decoded = decodeBytes(state.work_ram_1_data, 0xD000)
            for addr, value in pairs(decoded) do
                memory.work_ram_1_raw[addr] = value
            end
        elseif state.work_ram_1_raw then
            -- Legacy format
            for i = 0xD000, (0xD000 + (4 * 7 * 1024) - 1) do
                memory.work_ram_1_raw[i] = state.work_ram_1_raw[i] or 0
            end
        end

        memory.work_ram_1.bank = state.work_ram_1_bank or 1
    end

    -- Fancy: make access to ourselves act as an array, reading / writing memory using the above
    -- logic. This should cause memory[address] to behave just as it would on hardware.
    memory.mt = {}
    memory.mt.__index = function(_: any, key)
        return memory.read_byte(key)
    end
    memory.mt.__newindex = function(_: any, key, value)
        memory.write_byte(key, value)
    end
    setmetatable(memory, memory.mt)

    return memory
end

return Memory
