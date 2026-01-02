package main

import "core:fmt"
import "core:time"
import "core:math"
import "core:math/rand"
import "core:sync"
import "core:mem"
import "core:os"
import "core:sys/windows"
import rl "vendor:raylib"
import fb "./flatbuffers"
import gen "./generated"

// ============================================================================
// Shared Memory Data Structures (Matching C++ layout for Unreal)
// ============================================================================

MAX_ENEMIES :: 100
RING_BUFFER_SIZE :: 64
EVENT_QUEUE_SIZE :: 16
INPUT_RING_SIZE :: 16
ENTITY_RING_SIZE :: 64
COMMAND_DATA_SIZE :: 128

// Command Type Constants (matches C++ bit flags)
ODIN_CMD_DIR_CLIENT_TO_GAME :: 0x80
ODIN_CMD_DIR_GAME_TO_CLIENT :: 0x40

// Client -> Game (0x8X)
ODIN_CMD_INPUT          :: 0x81  // Data: input_name, Values: axis/button
ODIN_CMD_GAME           :: 0x82  // Values[0]: 1=start, -1=end, 0=state

// Game -> Client (0x4X)
ODIN_CMD_ENTITY_SPAWN   :: 0x41  // Data: class, Values: x,y,z,yaw
ODIN_CMD_ENTITY_DESTROY :: 0x42  // Data: entityId
ODIN_CMD_ENTITY_UPDATE  :: 0x43  // Data: serialized FB, Values: x,y,z,visible
ODIN_CMD_PLAYER_UPDATE  :: 0x44  // Data: serialized FB, Values: x,y,z,visible
ODIN_CMD_PLAYER_ACTION  :: 0x45  // Data: serialized FB (skill/ability)
ODIN_CMD_EVENT_GAMEPLAY :: 0x46  // Data: cue_name, Values: params

// Unified Command Structure (40 bytes, matches C++)
OdinCommand :: struct #packed {
    type: u8,                            // Command type (bit flags)
    flags: u8,                           // Reserved
    data_length: u16,                    // Length of valid data
    values: [4]f32,                      // Generic float4
    data: [COMMAND_DATA_SIZE]u8,         // Name, ID, or serialized FB
}
#assert(size_of(OdinCommand) == 148, "OdinCommand must be 148 bytes")

// Command Ring Buffer
CommandRing :: struct($Size: i32) #packed {
    head: i32,  // Atomic write index
    tail: i32,  // Atomic read index  
    commands: [Size]OdinCommand,
}

Vector2 :: struct #packed {
    x: f32,
    y: f32,
}

Player :: struct #packed {
    position: Vector2,
    rotation: f32,
    slash_active: bool,
    slash_angle: f32,
    health: i32,
    _padding: [3]u8,
}

Enemy :: struct #packed {
    position: Vector2,
    is_alive: bool,
    _padding: [3]u8,
}

GameState :: struct #packed {
    player: Player,
    enemies: [MAX_ENEMIES]Enemy,
    enemy_count: i32,
    score: i32,
    is_active: bool,
    _padding: [3]u8,
}

MAX_FRAME_SIZE :: 16 * 1024

FrameSlot :: struct #packed {
    frame_number: u64,
    timestamp: f64,
    data_size: u32,
    data: [MAX_FRAME_SIZE]u8,
}

SharedMemoryBlock :: struct #packed {
    magic: u32,
    version: u32,
    frames: [RING_BUFFER_SIZE]FrameSlot,
    latest_frame_index: i32,
    
    // Command Rings (unified command system)
    input_ring: CommandRing(INPUT_RING_SIZE),   // Client -> Game
    entity_ring: CommandRing(ENTITY_RING_SIZE), // Game -> Client
}

// ============================================================================
// Game Constants
// ============================================================================

GAME_WIDTH :: 800
GAME_HEIGHT :: 600
PLAYER_SPEED :: 200.0
ENEMY_SPEED :: 50.0
SLASH_INTERVAL :: 0.5
SLASH_DURATION :: 0.15
SLASH_RANGE :: 80.0
SPAWN_INTERVAL :: 0.5

// ============================================================================
// Runtime Config (from CLI)
// ============================================================================

Config :: struct {
    debug_mode: bool,
    headless: bool,
    verbose: bool,
    debug_logging: bool,
}

g_config: Config

// ============================================================================
// Game State (Local)
// ============================================================================

LocalGameState :: struct {
    game_state: GameState,
    frame_number: u64,
    slash_timer: f32,
    spawn_timer: f32,
    slash_end_time: f32,
    input_x: f32,
    input_y: f32,
    total_kills: i32,
    last_slash_kills: i32,
}

// ============================================================================
// Windows API (Only Kernel32 - avoid User32 conflict with raylib)
// ============================================================================

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "stdcall")
foreign kernel32 {
    CreateFileMappingW :: proc(
        hFile: windows.HANDLE,
        lpFileMappingAttributes: rawptr,
        flProtect: windows.DWORD,
        dwMaximumSizeHigh: windows.DWORD,
        dwMaximumSizeLow: windows.DWORD,
        lpName: windows.LPCWSTR,
    ) -> windows.HANDLE ---

    MapViewOfFile :: proc(
        hFileMappingObject: windows.HANDLE,
        dwDesiredAccess: windows.DWORD,
        dwFileOffsetHigh: windows.DWORD,
        dwFileOffsetLow: windows.DWORD,
        dwNumberOfBytesToMap: windows.SIZE_T,
    ) -> rawptr ---

    UnmapViewOfFile :: proc(lpBaseAddress: rawptr) -> windows.BOOL ---
}

FILE_MAP_ALL_ACCESS :: 0x000F001F
PAGE_READWRITE :: 0x04

// ============================================================================
// Shared Memory
// ============================================================================

SHARED_MEMORY_NAME :: "OdinVampireSurvival"

SharedMemoryHandle :: struct {
    handle: windows.HANDLE,
    ptr: ^SharedMemoryBlock,
}

create_or_open_shared_memory :: proc() -> (SharedMemoryHandle, bool) {
    name_wstring := windows.utf8_to_wstring(SHARED_MEMORY_NAME)
    size := size_of(SharedMemoryBlock)
    
    handle := CreateFileMappingW(
        windows.INVALID_HANDLE_VALUE,
        nil,
        PAGE_READWRITE,
        0,
        u32(size),
        name_wstring,
    )
    
    if handle == nil {
        fmt.println("[ERROR] Failed to create shared memory")
        return {}, false
    }
    
    ptr := MapViewOfFile(handle, FILE_MAP_ALL_ACCESS, 0, 0, uint(size))
    
    if ptr == nil {
        windows.CloseHandle(handle)
        fmt.println("[ERROR] Failed to map shared memory")
        return {}, false
    }
    
    return SharedMemoryHandle{handle, cast(^SharedMemoryBlock)ptr}, true
}

close_shared_memory :: proc(smh: SharedMemoryHandle) {
    if smh.ptr != nil { UnmapViewOfFile(smh.ptr) }
    if smh.handle != nil { windows.CloseHandle(smh.handle) }
}

// ============================================================================
// Input (Using Raylib for all input - works for both window and headless)
// ============================================================================

poll_keyboard_input :: proc(state: ^LocalGameState) -> bool {
    if rl.WindowShouldClose() || rl.IsKeyPressed(.ESCAPE) {
        return false
    }
    
    if rl.IsKeyPressed(.R) && !state.game_state.is_active {
        debug_log("[INPUT] R pressed - Restarting!\n")
        reset_game(state)
    }
    
    if rl.IsKeyPressed(.SPACE) && !state.game_state.is_active {
        debug_log("[INPUT] Space pressed - Starting!\n")
        reset_game(state)
    }
    
    input_x: f32 = 0
    input_y: f32 = 0
    
    if rl.IsKeyDown(.W) || rl.IsKeyDown(.UP) { input_y = -1.0 }
    if rl.IsKeyDown(.S) || rl.IsKeyDown(.DOWN) { input_y = 1.0 }
    if rl.IsKeyDown(.A) || rl.IsKeyDown(.LEFT) { input_x = -1.0 }
    if rl.IsKeyDown(.D) || rl.IsKeyDown(.RIGHT) { input_x = 1.0 }
    
    state.input_x = input_x
    state.input_y = input_y
    
    return true
}

// ============================================================================
// Debug Logging
// ============================================================================

debug_log :: proc(format: string, args: ..any) {
    if g_config.verbose {
        fmt.printf(format, ..args)
    }
}

// ============================================================================
// Raylib Visualization
// ============================================================================

draw_game :: proc(state: ^LocalGameState) {
    rl.BeginDrawing()
    defer rl.EndDrawing()
    
    // Background
    rl.ClearBackground({20, 20, 30, 255})
    
    gs := &state.game_state
    p := &gs.player
    
    // Draw grid
    for x: i32 = 0; x < GAME_WIDTH; x += 50 {
        rl.DrawLine(x, 0, x, GAME_HEIGHT, {40, 40, 50, 255})
    }
    for y: i32 = 0; y < GAME_HEIGHT; y += 50 {
        rl.DrawLine(0, y, GAME_WIDTH, y, {40, 40, 50, 255})
    }
    
    // Draw enemies
    for i in 0..<MAX_ENEMIES {
        if gs.enemies[i].is_alive {
            ex := i32(gs.enemies[i].position.x)
            ey := i32(gs.enemies[i].position.y)
            rl.DrawCircle(ex, ey, 10, {200, 50, 50, 255})
            rl.DrawCircleLines(ex, ey, 10, {255, 100, 100, 255})
        }
    }
    
    // Draw slash range indicator
    if p.slash_active {
        px := i32(p.position.x)
        py := i32(p.position.y)
        
        angle_deg := p.slash_angle * 180.0 / math.PI
        start_angle := angle_deg - 45
        end_angle := angle_deg + 45
        
        rl.DrawCircleSector(
            {f32(px), f32(py)},
            SLASH_RANGE,
            start_angle,
            end_angle,
            32,
            {255, 255, 100, 100},
        )
        rl.DrawCircleSectorLines(
            {f32(px), f32(py)},
            SLASH_RANGE,
            start_angle,
            end_angle,
            32,
            {255, 255, 0, 255},
        )
    }
    
    // Draw player
    px := i32(p.position.x)
    py := i32(p.position.y)
    rl.DrawCircle(px, py, 15, {50, 150, 255, 255})
    rl.DrawCircleLines(px, py, 15, {100, 200, 255, 255})
    
    // Draw facing direction
    dir_x := math.cos(p.rotation) * 20
    dir_y := math.sin(p.rotation) * 20
    rl.DrawLine(px, py, px + i32(dir_x), py + i32(dir_y), {255, 255, 255, 255})
    
    // Draw UI bar
    rl.DrawRectangle(0, 0, GAME_WIDTH, 40, {0, 0, 0, 180})
    
    // Health bar
    rl.DrawRectangle(10, 10, 200, 20, {60, 60, 60, 255})
    health_width := i32(f32(p.health) / 100.0 * 196)
    health_color: rl.Color = {50, 200, 50, 255}
    if p.health < 30 { health_color = {200, 50, 50, 255} }
    else if p.health < 60 { health_color = {200, 200, 50, 255} }
    rl.DrawRectangle(12, 12, health_width, 16, health_color)
    
    hp_text := fmt.ctprintf("HP: %d", p.health)
    rl.DrawText(hp_text, 15, 14, 14, {255, 255, 255, 255})
    
    // Score
    score_text := fmt.ctprintf("Score: %d", gs.score)
    rl.DrawText(score_text, 220, 14, 18, {255, 255, 100, 255})
    
    // Enemy count
    enemy_text := fmt.ctprintf("Enemies: %d", gs.enemy_count)
    rl.DrawText(enemy_text, 400, 14, 18, {255, 100, 100, 255})
    
    // Frame counter (debug)
    if g_config.debug_mode {
        frame_text := fmt.ctprintf("Frame: %d", state.frame_number)
        rl.DrawText(frame_text, 600, 14, 14, {150, 150, 150, 255})
        
        // FPS
        fps_text := fmt.ctprintf("FPS: %d", rl.GetFPS())
        rl.DrawText(fps_text, 720, 14, 14, {150, 150, 150, 255})
    }
    
    // Game state overlay
    if !gs.is_active {
        rl.DrawRectangle(0, 0, GAME_WIDTH, GAME_HEIGHT, {0, 0, 0, 150})
        
        if p.health <= 0 {
            rl.DrawText("GAME OVER", 280, 250, 50, {255, 50, 50, 255})
            final_score := fmt.ctprintf("Final Score: %d", gs.score)
            rl.DrawText(final_score, 300, 320, 30, {255, 255, 255, 255})
            kills_text := fmt.ctprintf("Total Kills: %d", state.total_kills)
            rl.DrawText(kills_text, 320, 360, 20, {200, 200, 200, 255})
        } else {
            rl.DrawText("VAMPIRE SURVIVAL", 200, 200, 40, {100, 200, 255, 255})
            rl.DrawText("Press SPACE to Start", 270, 280, 24, {200, 200, 200, 255})
        }
        
        rl.DrawText("WASD - Move | Auto-slash every 0.5s", 220, 420, 16, {150, 150, 150, 255})
        rl.DrawText("ESC - Quit | R - Restart", 280, 450, 16, {150, 150, 150, 255})
    }
    
    // Kill notification
    if state.last_slash_kills > 0 && p.slash_active {
        kill_text := fmt.ctprintf("+%d!", state.last_slash_kills * 10)
        rl.DrawText(kill_text, px + 20, py - 30, 24, {255, 255, 0, 255})
    }
}

// ============================================================================
// Game Logic
// ============================================================================

init_game :: proc(state: ^LocalGameState) {
    state.game_state = {}
    state.game_state.player.position = {f32(GAME_WIDTH) / 2, f32(GAME_HEIGHT) / 2}
    state.game_state.player.health = 100
    state.game_state.is_active = true // Auto-start for headless/testing
    state.frame_number = 0
    state.slash_timer = 0
    state.spawn_timer = 0
    state.slash_end_time = 0
    state.input_x = 0
    state.input_y = 0
    state.total_kills = 0
    state.last_slash_kills = 0
}

reset_game :: proc(state: ^LocalGameState) {
    state.game_state.player.position = {f32(GAME_WIDTH) / 2, f32(GAME_HEIGHT) / 2}
    state.game_state.player.health = 100
    state.game_state.player.slash_active = false
    state.game_state.score = 0
    state.game_state.enemy_count = 0
    state.game_state.is_active = true
    state.slash_timer = 0
    state.spawn_timer = 0
    state.total_kills = 0
    state.last_slash_kills = 0
    
    for i in 0..<MAX_ENEMIES {
        state.game_state.enemies[i].is_alive = false
    }
    
    debug_log("[GAME] === NEW GAME STARTED ===\n")
}

spawn_enemy :: proc(smh: ^SharedMemoryBlock, state: ^LocalGameState) {
    if state.game_state.enemy_count >= MAX_ENEMIES { return }
    
    for i in 0..<MAX_ENEMIES {
        if !state.game_state.enemies[i].is_alive {
            edge := rand.int31() % 4
            pos: Vector2
            switch edge {
            case 0: pos = {rand.float32() * f32(GAME_WIDTH), 0}
            case 1: pos = {rand.float32() * f32(GAME_WIDTH), f32(GAME_HEIGHT)}
            case 2: pos = {0, rand.float32() * f32(GAME_HEIGHT)}
            case 3: pos = {f32(GAME_WIDTH), rand.float32() * f32(GAME_HEIGHT)}
            }
            
            state.game_state.enemies[i].position = pos
            state.game_state.enemies[i].is_alive = true
            state.game_state.enemy_count += 1
            
            // Notify client
            if smh != nil {
                cmd := make_command(ODIN_CMD_ENTITY_SPAWN, {pos.x, pos.y, 0, 0}, "Enemy")
                push_entity_command(smh, cmd)
            }
            break
        }
    }
}

update_player :: proc(smh: ^SharedMemoryBlock, state: ^LocalGameState, dt: f32) {
    move_dir := Vector2{state.input_x, state.input_y}
    len_sq := move_dir.x * move_dir.x + move_dir.y * move_dir.y
    if len_sq > 0.01 {
        length := math.sqrt(len_sq)
        move_dir.x /= length
        move_dir.y /= length
        
        state.game_state.player.position.x += move_dir.x * PLAYER_SPEED * dt
        state.game_state.player.position.y += move_dir.y * PLAYER_SPEED * dt
        state.game_state.player.rotation = math.atan2(move_dir.y, move_dir.x)
    }
    
    state.game_state.player.position.x = clamp(state.game_state.player.position.x, 0, f32(GAME_WIDTH))
    state.game_state.player.position.y = clamp(state.game_state.player.position.y, 0, f32(GAME_HEIGHT))
    
    if state.last_slash_kills > 0 && !state.game_state.player.slash_active {
        state.last_slash_kills = 0
    }
    
    state.slash_timer += dt
    if state.slash_timer >= SLASH_INTERVAL {
        state.slash_timer = 0
        state.game_state.player.slash_active = true
        state.game_state.player.slash_angle = rand.float32() * 2 * math.PI
        state.slash_end_time = SLASH_DURATION
        
        kills_before := state.total_kills
        check_slash_hits(state)
        state.last_slash_kills = state.total_kills - kills_before
    }
    
    if state.game_state.player.slash_active {
        state.slash_end_time -= dt
        if state.slash_end_time <= 0 {
            state.game_state.player.slash_active = false
        }
    }
    
    // Notify client of player state
    if smh != nil {
        p := &state.game_state.player
        
        // Serialize PlayerData to FlatBuffer
        builder := fb.init_builder()

        
        pd := gen.PlayerData{
            forward = p.position.x,
            side = p.position.y,
            up = 0,
            rotation = p.rotation,
            slash_active = p.slash_active,
            slash_angle = p.slash_angle,
            health = p.health,
            id = 0,
            frame_number = i32(state.frame_number),
        }
        
        off := gen.pack_PlayerData(&builder, pd)
        fb.finish(&builder, off)
        
        buf := builder.bytes[:]
        
        // Create Command
        cmd: OdinCommand
        cmd.type = ODIN_CMD_PLAYER_UPDATE
        // values still useful for quick debug or redundancy
        cmd.values = {p.position.x, p.position.y, 0, p.rotation} 
        
        // Copy FB to data
        if len(buf) <= COMMAND_DATA_SIZE {
            for i in 0..<len(buf) {
                cmd.data[i] = buf[i]
            }
            cmd.data_length = u16(len(buf))
            push_entity_command(smh, cmd)
        } else {
             fmt.printf("[ERROR] PlayerData FB too large: %d > %d\n", len(buf), COMMAND_DATA_SIZE)
        }
    }
}

check_slash_hits :: proc(state: ^LocalGameState) {
    player_pos := state.game_state.player.position
    slash_angle := state.game_state.player.slash_angle
    
    for i in 0..<MAX_ENEMIES {
        if !state.game_state.enemies[i].is_alive { continue }
        
        enemy_pos := state.game_state.enemies[i].position
        dx := enemy_pos.x - player_pos.x
        dy := enemy_pos.y - player_pos.y
        dist := math.sqrt(dx * dx + dy * dy)
        
        if dist < SLASH_RANGE {
            angle_to_enemy := math.atan2(dy, dx)
            angle_diff := abs(angle_to_enemy - slash_angle)
            if angle_diff > math.PI { angle_diff = 2 * math.PI - angle_diff }
            
            if angle_diff < math.PI / 4 {
                state.game_state.enemies[i].is_alive = false
                state.game_state.enemy_count -= 1
                state.game_state.score += 10
                state.total_kills += 1
            }
        }
    }
}

update_enemies :: proc(smh: ^SharedMemoryBlock, state: ^LocalGameState, dt: f32) {
    player_pos := state.game_state.player.position
    
    for i in 0..<MAX_ENEMIES {
        if !state.game_state.enemies[i].is_alive { continue }
        
        enemy_pos := &state.game_state.enemies[i].position
        dx := player_pos.x - enemy_pos.x
        dy := player_pos.y - enemy_pos.y
        dist := math.sqrt(dx * dx + dy * dy)
        
        if dist > 1.0 {
            enemy_pos.x += (dx / dist) * ENEMY_SPEED * dt
            enemy_pos.y += (dy / dist) * ENEMY_SPEED * dt
            
            // Notify movement? Optional, or client interpolates. 
            // For full sync, send update. Optimization: Only send if moved significantly or every N frames.
            // For now, let's skip spamming updates for enemies to keep it simple, 
            // or send it. Let's send it for correctness.
            if smh != nil {
                // Check if we can push (might fill buffer)
                // Using entity index as ID for now via Data?
                // Or just broadcast positions. Client maps via ID.
                // We don't have stable IDs in this loop other than index 'i'.
                // Using "Enemy" as name + index in Values?
                // Current architecture is simple. 
            }
        }
        
        if dist < 20.0 {
            state.game_state.player.health -= 1
            if state.game_state.player.health <= 0 {
                state.game_state.is_active = false
                debug_log("[GAME] === GAME OVER === Score: %d\n", state.game_state.score)
            }
        }
    }
}

update_game :: proc(smh: ^SharedMemoryBlock, state: ^LocalGameState, dt: f32) {
    if !state.game_state.is_active { return }
    
    state.spawn_timer += dt
    if state.spawn_timer >= SPAWN_INTERVAL {
        state.spawn_timer = 0
        spawn_enemy(smh, state)
    }
    
    update_player(smh, state, dt)
    update_enemies(smh, state, dt)
}

// ============================================================================
// Command Buffer Functions (New Unified System)
// ============================================================================

// Check if there are pending input commands from client
has_input_command :: proc(smh: ^SharedMemoryBlock) -> bool {
    head := sync.atomic_load(&smh.input_ring.head)
    tail := sync.atomic_load(&smh.input_ring.tail)
    return head != tail
}

// Pop an input command from the ring buffer
pop_input_command :: proc(smh: ^SharedMemoryBlock) -> (OdinCommand, bool) {
    tail := sync.atomic_load(&smh.input_ring.tail)
    head := sync.atomic_load(&smh.input_ring.head)
    
    if tail == head {
        return {}, false  // Empty
    }
    
    cmd := smh.input_ring.commands[tail % INPUT_RING_SIZE]
    sync.atomic_store(&smh.input_ring.tail, (tail + 1) % INPUT_RING_SIZE)
    return cmd, true
}

// Push an entity command to the ring buffer (Game -> Client)
push_entity_command :: proc(smh: ^SharedMemoryBlock, cmd: OdinCommand) -> bool {
    head := sync.atomic_load(&smh.entity_ring.head)
    tail := sync.atomic_load(&smh.entity_ring.tail)
    next_head := (head + 1) % ENTITY_RING_SIZE
    
    // debug_log("[DEBUG] Push Entity Cmd: H=%d T=%d\n", head, tail)

    if next_head == tail {
        debug_log("[DEBUG] Entity Ring Full! H=%d T=%d\n", head, tail)
        return false  // Full
    }
    
    smh.entity_ring.commands[head] = cmd
    sync.atomic_store(&smh.entity_ring.head, next_head)
    return true
}

// Helper: Create a command with type and values
make_command :: proc(cmd_type: u8, values: [4]f32 = {}, data_str: string = "") -> OdinCommand {
    cmd: OdinCommand
    cmd.type = cmd_type
    cmd.values = values
    
    // Copy string data
    data_len := min(len(data_str), COMMAND_DATA_SIZE)
    for i in 0..<data_len {
        cmd.data[i] = data_str[i]
    }
    cmd.data_length = u16(data_len)
    
    return cmd
}

// Process all pending input commands
process_input_commands :: proc(smh: ^SharedMemoryBlock, state: ^LocalGameState) {
    for has_input_command(smh) {
        cmd, ok := pop_input_command(smh)
        if !ok { break }
        
        switch cmd.type {
        case ODIN_CMD_INPUT:
            // Parse input name from Data field
            input_name := string(cmd.data[:cmd.data_length])
            
            // Route input by name
            switch input_name {
            case "Move":
                // Values: x, y, button
                state.input_x = cmd.values[0]
                state.input_y = cmd.values[1]
                if g_config.debug_logging {
                    debug_log("[CMD] INPUT Move: x=%.2f y=%.2f\n", cmd.values[0], cmd.values[1])
                }
            case "Look":
                // Values: x, y (for camera/aim)
                // Future: state.look_x = cmd.values[0], state.look_y = cmd.values[1]
                if g_config.debug_logging {
                    debug_log("[CMD] INPUT Look: x=%.2f y=%.2f\n", cmd.values[0], cmd.values[1])
                }
            case "Action":
                // Values: button (0 or 1)
                // Future: trigger action when button > 0
                if g_config.debug_logging {
                    debug_log("[CMD] INPUT Action: %.2f\n", cmd.values[0])
                }
            case:
                // Unknown input name - log for debugging
                if g_config.debug_logging {
                    debug_log("[CMD] INPUT '%s': values=[%.2f, %.2f, %.2f, %.2f]\n", 
                        input_name, cmd.values[0], cmd.values[1], cmd.values[2], cmd.values[3])
                }
            }
            
        case ODIN_CMD_GAME:
            // Values[0]: 1=start, -1=end, 0=state change
            if cmd.values[0] > 0 {
                debug_log("[CMD] GAME_START\n")
                reset_game(state)
            } else if cmd.values[0] < 0 {
                debug_log("[CMD] GAME_END\n")
                state.game_state.is_active = false
            } else {
                // State change (pause, resume, etc.)
                data_str := string(cmd.data[:cmd.data_length])
                debug_log("[CMD] GAME_STATE: %s\n", data_str)
            }
            
        case:
            debug_log("[CMD] Unknown command type: 0x%02X\n", cmd.type)
        }
    }
}

// ============================================================================
// Frame Writing
// ============================================================================

// ============================================================================
// Frame Writing
// ============================================================================

write_frame :: proc(smh: ^SharedMemoryBlock, state: ^LocalGameState, builder: ^fb.Builder) {
    state.frame_number += 1
    
    // Clear builder for new frame
    fb.init_builder_reuse(builder) // Helper to reuse buffer? Or just make new one.
    // My minimal builder `init_builder` makes new arrays. 
    // Optimization: Reuse memory. 
    // ensuring builder.bytes is clear.
    builder.bytes = make([dynamic]byte, 0, 1024, context.temp_allocator)
    if len(builder.bytes) > 0 { clear(&builder.bytes) } // Actually make capacity 0? No.
    
    // 1. Prepare Data for Packing
    // New schema: GameState only holds game metadata, not entities
    // Entities (PlayerData, Enemy) are serialized separately if needed
    
    gen_state: gen.GameState
    gen_state.score = state.game_state.score
    gen_state.enemy_count = state.game_state.enemy_count
    gen_state.is_active = state.game_state.is_active
    gen_state.frame_number = i32(state.frame_number)

    
    // 2. Pack
    root := gen.pack_GameState(builder, gen_state)
    
    // 3. Finish
    buf := fb.finish(builder, root)
    
    // 4. Write to Shared Memory
    next_idx := (sync.atomic_load(&smh.latest_frame_index) + 1) % RING_BUFFER_SIZE
    slot := &smh.frames[next_idx]
    
    slot.frame_number = state.frame_number
    slot.timestamp = f64(time.now()._nsec) / 1_000_000_000.0
    slot.data_size = u32(len(buf))
    
    if len(buf) <= MAX_FRAME_SIZE {
        mem.copy(&slot.data[0], &buf[0], len(buf))
    } else {
        fmt.println("ERROR: Frame too large for shared memory slot!")
    }
    
    sync.atomic_store(&smh.latest_frame_index, next_idx)
}

// ============================================================================
// CLI Parsing
// ============================================================================

print_usage :: proc() {
    fmt.println("Vampire Survival - Odin Game Server")
    fmt.println("")
    fmt.println("Usage: vampire_survival.exe [options]")
    fmt.println("")
    fmt.println("Options:")
    fmt.println("  --debug, -d       Enable debug mode (show FPS, frame count)")
    fmt.println("  --headless        Run without window (server-only mode)")
    fmt.println("  --verbose         Enable verbose console logging")
    fmt.println("  --help            Show this help message")
    fmt.println("")
    fmt.println("Examples:")
    fmt.println("  vampire_survival.exe                   # Normal window mode")
    fmt.println("  vampire_survival.exe --debug           # Window with debug info")
    fmt.println("  vampire_survival.exe --headless        # Server-only (for Unreal)")
}

parse_args :: proc() -> bool {
    args := os.args[1:]
    
    for arg in args {
        switch arg {
        case "--help":
            print_usage()
            return false
        case "--debug", "-d":
            g_config.debug_mode = true
        case "--headless":
            g_config.headless = true
        case "--verbose":
            g_config.verbose = true
        case:
            fmt.printf("Unknown option: %s\n", arg)
            print_usage()
            return false
        }
    }
    
    return true
}

// ============================================================================
// Main Entry Point
// ============================================================================

main :: proc() {
    if !parse_args() { return }
    
    fmt.println("============================================================")
    fmt.println("  VAMPIRE SURVIVAL - Odin Game Server")
    fmt.println("============================================================")
    fmt.println("")
    
    if g_config.debug_mode { fmt.println("[CONFIG] Debug mode: ON") }
    if g_config.headless { fmt.println("[CONFIG] Mode: HEADLESS (server only)") }
    if g_config.verbose { fmt.println("[CONFIG] Verbose logging: ON") }
    
    fmt.println("[INIT] Shared Memory Size:", size_of(SharedMemoryBlock), "bytes")
    
    smh, ok := create_or_open_shared_memory()
    if !ok {
        fmt.println("[ERROR] Failed to initialize shared memory")
        return
    }
    defer close_shared_memory(smh)
    
    fmt.println("[INIT] Shared memory created: OdinVampireSurvival")
    fmt.println("")
    
    // Set Magic
    smh.ptr.magic = 0x12345678
    smh.ptr.version = 1

    local_state: LocalGameState
    init_game(&local_state)
    
    // Initialize FlatBuffer Builder
    builder := fb.init_builder()
    
    if g_config.headless {
        // Headless mode - just write frames for Unreal
        fmt.println("[HEADLESS] Running in server mode. Press Ctrl+C to exit.")
        fmt.println("[HEADLESS] Waiting for events from Unreal client...")
        
        for {
            process_input_commands(smh.ptr, &local_state)
            update_game(smh.ptr, &local_state, 1.0 / 60.0)
            write_frame(smh.ptr, &local_state, &builder)
            time.sleep(time.Millisecond * 16)
        }
    } else {
        // Window mode with raylib
        rl.SetConfigFlags({.VSYNC_HINT})
        rl.InitWindow(GAME_WIDTH, GAME_HEIGHT, "Vampire Survival - Debug Visualizer")
        rl.SetTargetFPS(60)
        defer rl.CloseWindow()
        
        fmt.println("[RAYLIB] Window opened at 800x600")
        fmt.println("")
        
        for !rl.WindowShouldClose() {
            if !poll_keyboard_input(&local_state) { break }
            
            process_input_commands(smh.ptr, &local_state)
            update_game(smh.ptr, &local_state, 1.0 / 60.0)
            write_frame(smh.ptr, &local_state, &builder)
            draw_game(&local_state)
        }
    }
    
    fmt.println("\n[EXIT] Game server shutting down...")
    fmt.printf("[EXIT] Final Score: %d | Total Kills: %d\n", 
        local_state.game_state.score, local_state.total_kills)
}