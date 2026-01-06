--!native

local apply_arithmetic = require(script.arithmetic)
local apply_bitwise = require(script.bitwise)
local apply_call = require(script.call)
local apply_cp = require(script.cp)
local apply_inc_dec = require(script.inc_dec)
local apply_jp = require(script.jp)
local apply_ld = require(script.ld)
local apply_rl_rr_cb = require(script.rl_rr_cb)
local apply_stack = require(script.stack)

local Registers = require(script.registers)

local Z80 = {}

function Z80.new(modules)
    local z80 = {}

    local interrupts = modules.interrupts
    local io = modules.io
    local memory = modules.memory
    local timers = modules.timers

    -- local references, for shorter code
    local read_byte = memory.read_byte
    local write_byte = memory.write_byte

    z80.registers = Registers.new()
    local reg = z80.registers
    local flags = reg.flags

    -- Intentionally bad naming convention: I am NOT typing "registers"
    -- a bazillion times. The exported symbol uses the full name as a
    -- reasonable compromise.
    z80.halted = 0

    local add_cycles_normal = function(cycles)
        timers.system_clock = timers.system_clock + cycles
    end

    local add_cycles_double = function(cycles)
        timers.system_clock = timers.system_clock + cycles / 2
    end

    z80.add_cycles = add_cycles_normal

    z80.double_speed = false

    z80.reset = function(gameboy)
        -- Initialize registers to what the GB's
        -- iternal state would be after executing
        -- BIOS code

        flags.z = true
        flags.n = false
        flags.h = true
        flags.c = true

        if gameboy.type == gameboy.types.color then
            reg.a = 0x11
        else
            reg.a = 0x01
        end

        reg.b = 0x00
        reg.c = 0x13
        reg.d = 0x00
        reg.e = 0xD8
        reg.h = 0x01
        reg.l = 0x4D
        reg.pc = 0x100 --entrypoint for GB games
        reg.sp = 0xFFFE

        z80.halted = 0

        z80.double_speed = false
        z80.add_cycles = add_cycles_normal
        timers:set_normal_speed()
    end

    z80.save_state = function()
        local state = {}
        state.double_speed = z80.double_speed
        -- Save registers explicitly (don't save functions, only data)
        state.registers = {
            a = reg.a,
            b = reg.b,
            c = reg.c,
            d = reg.d,
            e = reg.e,
            h = reg.h,
            l = reg.l,
            pc = reg.pc,
            sp = reg.sp,
            flags = {
                z = flags.z,
                n = flags.n,
                h = flags.h,
                c = flags.c,
            }
        }
        state.halted = z80.halted
        return state
    end

    z80.load_state = function(state)
        if not state or not state.registers then
            warn("[Z80] Invalid state structure in load_state")
            return
        end
        
        flags.z = state.registers.flags and state.registers.flags.z or false
        flags.n = state.registers.flags and state.registers.flags.n or false
        flags.h = state.registers.flags and state.registers.flags.h or false
        flags.c = state.registers.flags and state.registers.flags.c or false

        z80.registers.a = state.registers.a or 0
        z80.registers.b = state.registers.b or 0
        z80.registers.c = state.registers.c or 0
        z80.registers.d = state.registers.d or 0
        z80.registers.e = state.registers.e or 0
        z80.registers.h = state.registers.h or 0
        z80.registers.l = state.registers.l or 0
        
        local pc = state.registers.pc or 0x100
        if pc < 0 or pc > 0xFFFF then
            warn("[Z80] Invalid PC value in save state:", pc, "- resetting to 0x100")
            pc = 0x100
        end
        z80.registers.pc = pc
        
        local sp = state.registers.sp or 0xFFFE
        if sp < 0 or sp > 0xFFFF then
            warn("[Z80] Invalid SP value in save state:", sp, "- resetting to 0xFFFE")
            sp = 0xFFFE
        end
        z80.registers.sp = sp

        z80.double_speed = state.double_speed or false
        if z80.double_speed then
            timers:set_double_speed()
        else
            timers:set_normal_speed()
        end
        z80.halted = state.halted or 0
        if z80.halted ~= 0 and z80.halted ~= 1 then
            z80.halted = 0
        end
    end

    io.write_mask[0x4D] = 0x01

    local opcodes = {}
    local opcode_cycles = {}

    -- Initialize the opcode_cycles table with 4 as a base cycle, so we only
    -- need to care about variations going forward
    for i = 0x00, 0xFF do
        opcode_cycles[i] = 4
    end

    -- Optimized: Cache block_map locally and remove nil checks
    -- Registers are always valid during normal operation
    local block_map = memory.block_map
    
    function z80.read_at_hl()
        local addr = reg.h * 256 + reg.l
        return block_map[bit32.band(addr, 0xFF00)][addr]
    end

    function z80.set_at_hl(value)
        local addr = reg.h * 256 + reg.l
        block_map[bit32.band(addr, 0xFF00)][addr] = value
    end

    function z80.read_nn()
        local nn = read_byte(reg.pc)
        reg.pc = reg.pc + 1
        return nn
    end

    local read_nn = z80.read_nn

    apply_arithmetic(opcodes, opcode_cycles, z80, memory)
    apply_bitwise(opcodes, opcode_cycles, z80, memory)
    apply_call(opcodes, opcode_cycles, z80, memory, interrupts)
    apply_cp(opcodes, opcode_cycles, z80, memory)
    apply_inc_dec(opcodes, opcode_cycles, z80, memory)
    apply_jp(opcodes, opcode_cycles, z80, memory)
    apply_ld(opcodes, opcode_cycles, z80, memory)
    apply_rl_rr_cb(opcodes, opcode_cycles, z80, memory)
    apply_stack(opcodes, opcode_cycles, z80, memory)

    -- ====== GMB CPU-Controlcommands ======
    -- ccf
    opcodes[0x3F] = function()
        flags.c = not flags.c
        flags.n = false
        flags.h = false
    end

    -- scf
    opcodes[0x37] = function()
        flags.c = true
        flags.n = false
        flags.h = false
    end

    -- nop
    opcodes[0x00] = function() end

    -- halt
    opcodes[0x76] = function()
        --if interrupts_enabled == 1 then
        --print("Halting!")
        z80.halted = 1
        --else
        --print("Interrupts not enabled! Not actually halting...")
        --end
    end

    -- stop
    opcodes[0x10] = function()
        -- The stop opcode should always, for unknown reasons, be followed
        -- by an 0x00 data byte. If it isn't, this may be a sign that the
        -- emulator has run off the deep end, and this isn't a real STOP
        -- instruction.
        -- TODO: Research real hardware's behavior in these cases
        local stop_value = read_nn()

        if stop_value == 0x00 then
            print("STOP instruction not followed by NOP!")
        else
            print("Unimplemented WEIRDNESS after 0x10")
        end

        local speed_register = io.ram[0x4D] or 0
        if bit32.band(speed_register, 0x01) ~= 0 then
            --speed switch!
            print("Switching speeds!")
            if z80.double_speed then
                z80.add_cycles = add_cycles_normal
                z80.double_speed = false
                io.ram[0x4D] = bit32.band(speed_register, 0x7E) + 0x00
                timers:set_normal_speed()
                print("Switched to Normal Speed")
            else
                z80.add_cycles = add_cycles_double
                z80.double_speed = true
                io.ram[0x4D] = bit32.band(speed_register, 0x7E) + 0x80
                timers:set_double_speed()
                print("Switched to Double Speed")
            end
        end
    end

    -- di
    opcodes[0xF3] = function()
        interrupts.disable()
        --print("Disabled interrupts with DI")
    end

    z80.service_interrupt = function()
        -- Handle nil values (can occur during save state loading)
        local if_register = io.ram[0xFF] or 0
        local ie_register = io.ram[0x0F] or 0
        local fired = bit32.band(if_register, ie_register)
        if fired ~= 0 then
            z80.halted = 0
            if interrupts.enabled ~= 0 then
                -- First, disable interrupts to prevent nesting routines (unless the program explicitly re-enables them later)
                interrupts.disable()

                -- Now, figure out which interrupt this is, and call the corresponding
                -- interrupt vector
                local vector = 0x40
                local count = 0
                while bit32.band(fired, 0x1) == 0 and count < 5 do
                    vector = vector + 0x08
                    fired = bit32.rshift(fired, 1)
                    count = count + 1
                end
                -- we need to clear the corresponding bit first, to avoid infinite loops
                io.ram[0x0F] = bit32.bxor(bit32.lshift(0x1, count), ie_register)

                local sp = reg.sp or 0xFFFE
                local pc = reg.pc or 0x100
                reg.sp = bit32.band(0xFFFF, sp - 1)
                write_byte(reg.sp, bit32.rshift(bit32.band(pc, 0xFF00), 8))
                reg.sp = bit32.band(0xFFFF, reg.sp - 1)
                write_byte(reg.sp, bit32.band(pc, 0xFF))

                reg.pc = vector

                z80.add_cycles(12)
                return true
            end
        end
        return false
    end

    -- ei
    opcodes[0xFB] = function()
        interrupts.enable()
        --print("Enabled interrupts with EI")
        z80.service_interrupt()
    end

    -- register this as a callback with the interrupts module
    interrupts.service_handler = z80.service_interrupt

    -- For any opcodes that at this point are undefined,
    -- go ahead and "define" them with the following panic
    -- function
    local function undefined_opcode()
        local opcode = read_byte(bit32.band(reg.pc - 1, 0xFFFF))
        print(string.format("Unhandled opcode!: %x", opcode))
    end

    for i = 0, 0xFF do
        if not opcodes[i] then
            opcodes[i] = undefined_opcode
        end
    end

    -- Optimized: Remove defensive nil checks from hot path.
    -- All opcodes are guaranteed to be defined by initialization.
    -- read_byte always returns a valid value (0x00 for unmapped).
    z80.process_instruction = function()
        if z80.halted == 0 then
            local opcode = read_byte(reg.pc)
            reg.pc = bit32.band(reg.pc + 1, 0xFFFF)
            opcodes[opcode]()
            z80.add_cycles(opcode_cycles[opcode])
        else
            z80.add_cycles(4)
        end
    end

    return z80
end

return Z80
