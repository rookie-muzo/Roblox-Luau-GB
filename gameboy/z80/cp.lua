--!native

local function apply(opcodes, opcode_cycles, z80, memory)
    local read_at_hl = z80.read_at_hl
    local read_nn = z80.read_nn
    local reg = z80.registers
    local flags = reg.flags

    -- Optimized: Remove nil checks and use bit32 for modulo
    local cp_with_a = function(value)
        local a = reg.a
        flags.h = bit32.band(a, 0xF) - bit32.band(value, 0xF) < 0
        local temp = a - value
        flags.c = temp < 0
        flags.z = bit32.band(temp, 0xFF) == 0
        flags.n = true
    end

    -- cp A, r
    opcodes[0xB8] = function()
        cp_with_a(reg.b)
    end
    opcodes[0xB9] = function()
        cp_with_a(reg.c)
    end
    opcodes[0xBA] = function()
        cp_with_a(reg.d)
    end
    opcodes[0xBB] = function()
        cp_with_a(reg.e)
    end
    opcodes[0xBC] = function()
        cp_with_a(reg.h)
    end
    opcodes[0xBD] = function()
        cp_with_a(reg.l)
    end
    opcode_cycles[0xBE] = 8
    opcodes[0xBE] = function()
        cp_with_a(read_at_hl())
    end
    opcodes[0xBF] = function()
        cp_with_a(reg.a)
    end

    -- cp A, nn
    opcode_cycles[0xFE] = 8
    opcodes[0xFE] = function()
        cp_with_a(read_nn())
    end
end

return apply
