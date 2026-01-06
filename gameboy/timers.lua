--!native
local Timers = {}

function Timers.new(modules)
    local io = modules.io
    local interrupts = modules.interrupts

    local timers = {}

    local system_clocks_per_second = 4194304

    timers.system_clock = 0

    timers.clock_rates = {}

    function timers:set_normal_speed()
        self.clock_rates[0] = math.floor(system_clocks_per_second / 4096)
        self.clock_rates[1] = math.floor(system_clocks_per_second / 262144)
        self.clock_rates[2] = math.floor(system_clocks_per_second / 65536)
        self.clock_rates[3] = math.floor(system_clocks_per_second / 16384)
    end

    function timers:set_double_speed()
        self.clock_rates[0] = math.floor(system_clocks_per_second / 4096 / 2)
        self.clock_rates[1] = math.floor(system_clocks_per_second / 262144 / 2)
        self.clock_rates[2] = math.floor(system_clocks_per_second / 65536 / 2)
        self.clock_rates[3] = math.floor(system_clocks_per_second / 16384 / 2)
    end

    timers.div_base = 0
    timers.timer_offset = 0
    timers.timer_enabled = false

    io.write_logic[io.ports.DIV] = function(byte)
        -- Reset the DIV timer, in this case by re-basing it to the
        -- current system clock, which will roll it back to 0 on this cycle
        timers.div_base = timers.system_clock
    end

    io.read_logic[io.ports.DIV] = function()
        return bit32.band(bit32.rshift(timers.system_clock - timers.div_base, 8), 0xFF)
    end

    io.write_logic[io.ports.TAC] = function(byte)
        io.ram[io.ports.TAC] = byte
        timers.timer_enabled = (bit32.band(byte, 0x4) == 0x4)
        timers.timer_offset = timers.system_clock
    end

    -- Optimized: Cache ports and remove nil checks
    local ports = io.ports
    local TIMA = ports.TIMA
    local TMA = ports.TMA
    local TAC = ports.TAC
    
    function timers:update()
        if self.timer_enabled then
            local ram = io.ram
            local rate = self.clock_rates[bit32.band(ram[TAC], 0x3)]
            local system_clock = self.system_clock
            local timer_offset = self.timer_offset
            
            while system_clock > timer_offset + rate do
                local tima = bit32.band(ram[TIMA] + 1, 0xFF)
                ram[TIMA] = tima
                timer_offset = timer_offset + rate

                if tima == 0 then
                    ram[TIMA] = ram[TMA]
                    interrupts.raise(interrupts.Timer)
                end
            end
            self.timer_offset = timer_offset
        end
    end

    function timers:reset()
        self.system_clock = 0
        self.div_base = 0
        self.timer_offset = 0
        self.timer_enabled = false
    end

    function timers:save_state()
        return {
            system_clock = self.system_clock,
            div_base = self.div_base,
            timer_offset = self.timer_offset,
            timer_enabled = self.timer_enabled,
        }
    end

    function timers:load_state(state)
        self.system_clock = state.system_clock
        self.div_base = state.div_base
        self.timer_offset = state.timer_offset
        self.timer_enabled = state.timer_enabled
    end

    return timers
end

return Timers
