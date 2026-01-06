--!native

local function apply(opcodes, opcode_cycles, z80, memory)
    local reg = z80.registers
    local flags = reg.flags

    local read_byte = memory.read_byte
    local write_byte = memory.write_byte

    -- Optimized: Remove nil checks and inline modulo for half-carry detection
    local set_inc_flags = function(value: number)
        flags.z = value == 0
        flags.h = bit32.band(value, 0xF) == 0
        flags.n = false
    end

    local set_dec_flags = function(value: number)
        flags.z = value == 0
        flags.h = bit32.band(value, 0xF) == 0xF
        flags.n = true
    end

    -- inc r
    opcodes[0x04] = function()
        reg.b = bit32.band(reg.b + 1, 0xFF)
        set_inc_flags(reg.b)
    end
    opcodes[0x0C] = function()
        reg.c = bit32.band(reg.c + 1, 0xFF)
        set_inc_flags(reg.c)
    end
    opcodes[0x14] = function()
        reg.d = bit32.band(reg.d + 1, 0xFF)
        set_inc_flags(reg.d)
    end
    opcodes[0x1C] = function()
        reg.e = bit32.band(reg.e + 1, 0xFF)
        set_inc_flags(reg.e)
    end
    opcodes[0x24] = function()
        reg.h = bit32.band(reg.h + 1, 0xFF)
        set_inc_flags(reg.h)
    end
    opcodes[0x2C] = function()
        reg.l = bit32.band(reg.l + 1, 0xFF)
        set_inc_flags(reg.l)
    end
    opcode_cycles[0x34] = 12
    opcodes[0x34] = function()
        local addr = reg.hl()
        local val = bit32.band(read_byte(addr) + 1, 0xFF)
        write_byte(addr, val)
        set_inc_flags(val)
    end
    opcodes[0x3C] = function()
        reg.a = bit32.band(reg.a + 1, 0xFF)
        set_inc_flags(reg.a)
    end

    -- dec r
    opcodes[0x05] = function()
        reg.b = bit32.band(reg.b - 1, 0xFF)
        set_dec_flags(reg.b)
    end
    opcodes[0x0D] = function()
        reg.c = bit32.band(reg.c - 1, 0xFF)
        set_dec_flags(reg.c)
    end
    opcodes[0x15] = function()
        reg.d = bit32.band(reg.d - 1, 0xFF)
        set_dec_flags(reg.d)
    end
    opcodes[0x1D] = function()
        reg.e = bit32.band(reg.e - 1, 0xFF)
        set_dec_flags(reg.e)
    end
    opcodes[0x25] = function()
        reg.h = bit32.band(reg.h - 1, 0xFF)
        set_dec_flags(reg.h)
    end
    opcodes[0x2D] = function()
        reg.l = bit32.band(reg.l - 1, 0xFF)
        set_dec_flags(reg.l)
    end
    opcode_cycles[0x35] = 12
    opcodes[0x35] = function()
        local addr = reg.hl()
        local val = bit32.band(read_byte(addr) - 1, 0xFF)
        write_byte(addr, val)
        set_dec_flags(val)
    end
    opcodes[0x3D] = function()
        reg.a = bit32.band(reg.a - 1, 0xFF)
        set_dec_flags(reg.a)
    end
end

return apply
