# Roblox-Luau-GB

A Game Boy emulator for Roblox, ported from [LuaGB](https://github.com/zeta0134/LuaGB) by zeta0134. This implementation uses Roblox's EditableImage API for rendering and includes multiplayer features like game libraries, save states, leaderboards, and spectating.

## Features

- Full Game Boy and Game Boy Color emulation
- Save state system with 5 slots per game
- Game library dashboard with automatic game tracking
- Battery-backed RAM support for in-game saves
- Leaderboard system for score-based games
- Spectating mode to watch other players
- Audio synthesis using waveform assets
- Per-player emulator instances

## Requirements

- Roblox Studio with EditableImage API enabled (Game Settings > Security > Allow Mesh / Image APIs)
- HttpService enabled for loading ROMs from URLs (Game Settings > Security > Allow HTTP Requests)
- Rojo for building the project

## Installation

1. Clone this repository
2. Install [Rojo](https://rojo.space/)
3. Build the project using Rojo:
   ```
   rojo build -o Gameboy.rbxm
   ```
4. Import the `Gameboy.rbxm` file into your Roblox place

or just live sync the project and save via Roblox studio.

## Audio Assets

The emulator uses pre-generated waveform audio assets for hardware-accurate sound synthesis. Generate these assets by running:

```
python generate_gameboy_waveforms.py
```

This creates waveform files in the `gb_apu_assets` directory. Upload these to Roblox and update the Asset IDs in `AudioClient.lua`.

## Usage

Players can load ROMs by entering a URL in the UI. The emulator automatically:
- Tracks games in the player's library
- Extracts game titles and device types from ROM headers
- Manages save states and battery RAM
- Updates leaderboards for supported games

The dashboard provides access to:
- Game library with reload functionality
- Save state management (save, load, delete, rename slots)
- Leaderboards for score-based games
- Spectating other players

## Project Structure

- `gameboy/` - Core emulator implementation (ported from LuaGB)
- `main.server.lua` - Server-side emulator management
- `GameboyClient.client.lua` - Client-side UI and input handling
- `AudioClient.lua` - Audio synthesis system
- `GameboyDashboard.lua` - Game library and save state UI
- `GameboyLeaderboard.lua` - Leaderboard UI
- `GameboyDataStore.lua` - Data persistence layer
- `SpectatorClient.client.lua` - Spectating functionality

## Technical Details

The emulator core is based on LuaGB and implements:
- Z80 CPU emulation
- Memory management with MBC support (MBC1, MBC2, MBC3, MBC5)
- Graphics rendering via EditableImage
- Audio Processing Unit (APU) emulation
- DMA and interrupt handling

Audio synthesis uses a wavetable approach with pre-generated assets for pulse waves, wave channel, and LFSR noise. The audio system attempts to match the original Game Boy's output characteristics within Roblox's limitations.

## License

See LICENSE.txt for details.

## Credits
- Based off: [Luau-GB](https://github.com/MaximumADHD/Roblox-Luau-GB) by MaximumADHD
- Which is a fork of: [LuaGB](https://github.com/zeta0134/LuaGB) by zeta0134

Special thanks to both!
