--!native
local Gameboy = {}

Gameboy.audio = require(script.audio)
Gameboy.camera = require(script.camera)
Gameboy.cartridge = require(script.cartridge)
Gameboy.dma = require(script.dma)
Gameboy.graphics = require(script.graphics)
Gameboy.input = require(script.input)
Gameboy.interrupts = require(script.interrupts)
Gameboy.io = require(script.io)
Gameboy.memory = require(script.memory)
Gameboy.timers = require(script.timers)
Gameboy.processor = require(script.z80)

function Gameboy:initialize()
    self.audio.initialize()
    self.graphics.initialize(self)
    self.camera.initialize(self)
    self.cartridge.initialize(self)

    self:reset()
end

Gameboy.types = {}
Gameboy.types.dmg = 0
Gameboy.types.sgb = 1
Gameboy.types.color = 2

Gameboy.type = Gameboy.types.color

function Gameboy:reset()
    -- Resets the gameboy's internal state to just after the power-on and boot sequence
    -- (Does NOT unload the cartridge)

    -- Note: IO needs to come first here, as some subsequent modules
    -- manipulate IO registers during reset / initialization
    self.audio.reset()
    self.io.reset(self)
    self.memory.reset()
    self.camera.reset()
    self.cartridge.reset()
    self.graphics.reset() -- Note to self: this needs to come AFTER resetting IO
    self.timers:reset()
    self.processor.reset(self)

    self.interrupts.enabled = 1
end

-- Save state version for compatibility checking
local SAVESTATE_VERSION = 2

function Gameboy:save_state()
    local state = {}
    
    -- Version and metadata for compatibility checking
    state.version = SAVESTATE_VERSION
    state.gameboy_type = self.type
    state.timestamp = os.time and os.time() or 0
    
    -- Save all subsystem states
    state.audio = self.audio.save_state()
    state.cartridge = self.cartridge.save_state()
    state.io = self.io.save_state()
    state.memory = self.memory.save_state()
    state.graphics = self.graphics.save_state()
    state.timers = self.timers:save_state()
    state.processor = self.processor.save_state()

    -- Note: the underscore
    state.interrupts_enabled = self.interrupts.enabled
    
    return state
end

function Gameboy:load_state(state)
    -- Validate state structure
    if not state then
        error("Cannot load state: state is nil")
    end
    
    -- Version compatibility check
    local state_version = state.version or 1
    if state_version > SAVESTATE_VERSION then
        warn(string.format("[Gameboy] Save state version %d is newer than supported version %d, may cause issues", 
            state_version, SAVESTATE_VERSION))
    end
    
    -- Ensure cartridge has data (loaded flag might be false after reset, but data is still there)
    if not self.cartridge.header or not self.cartridge.raw_data then
        error("Cannot load state: cartridge data is missing")
    end
    
    -- Load subsystem states in correct order
    -- IO should be loaded before graphics (graphics depends on IO registers)
    self.io.load_state(state.io)
    
    -- Memory next
    self.memory.load_state(state.memory)
    
    -- Audio state
    self.audio.load_state(state.audio)
    
    -- Cartridge state loading is safe even if state.cartridge is nil (for MBC None)
    if state.cartridge then
        self.cartridge.load_state(state.cartridge)
    end
    
    -- Graphics depends on IO and memory being loaded first
    self.graphics.load_state(state.graphics)
    
    -- Timer state
    self.timers:load_state(state.timers)
    
    -- Processor state last
    self.processor.load_state(state.processor)

    -- Note: the underscore
    self.interrupts.enabled = state.interrupts_enabled or 1
    
    -- Ensure cartridge is marked as loaded if data is present
    if self.cartridge.header and self.cartridge.raw_data then
        self.cartridge.loaded = true
    end
    
    -- After all state is loaded, update tilemap references based on LCDC register
    -- This is needed because the tilemap selection depends on LCDC bits
    local ports = self.io.ports
    local lcdc = self.io.ram[ports.LCDC]
    
    if lcdc then
        -- Update window tilemap based on LCDC bit 6
        if bit32.band(0x40, lcdc) ~= 0 then
            self.graphics.registers.window_tilemap = self.graphics.cache.map_1
            self.graphics.registers.window_attr = self.graphics.cache.map_1_attr
        else
            self.graphics.registers.window_tilemap = self.graphics.cache.map_0
            self.graphics.registers.window_attr = self.graphics.cache.map_0_attr
        end
        
        -- Update background tilemap based on LCDC bit 3
        if bit32.band(0x08, lcdc) ~= 0 then
            self.graphics.registers.background_tilemap = self.graphics.cache.map_1
            self.graphics.registers.background_attr = self.graphics.cache.map_1_attr
        else
            self.graphics.registers.background_tilemap = self.graphics.cache.map_0
            self.graphics.registers.background_attr = self.graphics.cache.map_0_attr
        end
        
        -- Update tile select based on LCDC bit 4
        if bit32.band(0x10, lcdc) ~= 0 then
            self.graphics.registers.tile_select = 0x8000
        else
            self.graphics.registers.tile_select = 0x9000
        end
    end
    
    -- Refresh LCD status to ensure consistency
    self.graphics.refresh_lcdstat()
end

-- Optimized: Cache module references for hot path
function Gameboy:step()
    local timers = self.timers
    timers:update()
    if timers.system_clock > self.graphics.next_edge then
        self.graphics.update()
    end
    self.processor.process_instruction()
end

function Gameboy:run_until_vblank()
    local io_ram = self.io.ram
    local ly_port = self.io.ports.LY
    local timers = self.timers
    local graphics = self.graphics
    local processor = self.processor
    local process_instruction = processor.process_instruction
    local timers_update = timers.update
    local graphics_update = graphics.update
    
    local instructions = 0
    while io_ram[ly_port] == 144 and instructions < 100000 do
        timers_update(timers)
        if timers.system_clock > graphics.next_edge then
            graphics_update()
        end
        process_instruction()
        instructions += 1
    end
    while io_ram[ly_port] ~= 144 and instructions < 100000 do
        timers_update(timers)
        if timers.system_clock > graphics.next_edge then
            graphics_update()
        end
        process_instruction()
        instructions += 1
    end
    self.audio.update()
end

function Gameboy:run_until_hblank()
    local io_ram = self.io.ram
    local ly_port = self.io.ports.LY
    local old_scanline = io_ram[ly_port]
    local timers = self.timers
    local graphics = self.graphics
    local processor = self.processor
    local process_instruction = processor.process_instruction
    local timers_update = timers.update
    local graphics_update = graphics.update
    
    local instructions = 0
    while old_scanline == io_ram[ly_port] and instructions < 100000 do
        timers_update(timers)
        if timers.system_clock > graphics.next_edge then
            graphics_update()
        end
        process_instruction()
        instructions += 1
    end
    self.audio.update()
end

local call_opcodes = { [0xCD] = true, [0xC4] = true, [0xD4] = true, [0xCC] = true, [0xDC] = true }
local rst_opcodes = { [0xC7] = true, [0xCF] = true, [0xD7] = true, [0xDF] = true, [0xE7] = true, [0xEF] = true, [0xF7] = true, [0xFF] = true }

function Gameboy:step_over()
    -- Make sure the *current* opcode is a CALL / RST
    local instructions = 0
    local pc = self.processor.registers.pc
    local opcode = self.memory[pc]
    if call_opcodes[opcode] then
        local return_address = bit32.band(pc + 3, 0xFFFF)
        while self.processor.registers.pc ~= return_address and instructions < 10000000 do
            self:step()
            instructions = instructions + 1
        end
        return
    end
    if rst_opcodes[opcode] then
        local return_address = bit32.band(pc + 1, 0xFFFF)
        while self.processor.registers.pc ~= return_address and instructions < 10000000 do
            self:step()
            instructions = instructions + 1
        end
        return
    end
    print("Not a CALL / RST opcode! Bailing.")
end

local ret_opcodes = { [0xC9] = true, [0xC0] = true, [0xD0] = true, [0xC8] = true, [0xD8] = true, [0xD9] = true }

function Gameboy:run_until_ret()
    local instructions = 0
    while ret_opcodes[self.memory[self.processor.registers.pc]] ~= true and instructions < 10000000 do
        self:step()
        instructions = instructions + 1
    end
end

local gameboy_defaults = {}

for k, v in pairs(Gameboy) do
    gameboy_defaults[k] = v
end

Gameboy.new = function()
    local new_gameboy = {}

    for k, v in Gameboy do
        new_gameboy[k] = v
    end

    new_gameboy.memory = Gameboy.memory.new(new_gameboy)
    new_gameboy.io = Gameboy.io.new(new_gameboy)
    new_gameboy.interrupts = Gameboy.interrupts.new(new_gameboy)
    new_gameboy.timers = Gameboy.timers.new(new_gameboy)

    new_gameboy.audio = Gameboy.audio.new(new_gameboy)
    new_gameboy.camera = Gameboy.camera.new(new_gameboy)
    new_gameboy.cartridge = Gameboy.cartridge.new(new_gameboy)
    new_gameboy.dma = Gameboy.dma.new(new_gameboy)
    new_gameboy.graphics = Gameboy.graphics.new(new_gameboy)
    new_gameboy.input = Gameboy.input.new(new_gameboy)
    new_gameboy.processor = Gameboy.processor.new(new_gameboy)

    Gameboy.initialize(new_gameboy)

    return new_gameboy
end

return Gameboy
