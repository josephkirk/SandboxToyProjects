package main

import "core:fmt"
import "core:time"
import "core:math"
import "core:math/rand"
import "core:sync"
import "core:os"
import "core:sys/windows"
import rl "vendor:raylib"

// ============================================================================
// Shared Memory Data Structures (Matching C++ layout for Unreal)
// ============================================================================

MAX_ENEMIES :: 100
RING_BUFFER_SIZE :: 64
EVENT_QUEUE_SIZE :: 16

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

FrameSlot :: struct #packed {
    frame_number: u64,
    timestamp: f64,
    state: GameState,
}

GameEventType :: enum i32 {
    None = 0,
    StartGame = 1,
    EndGame = 2,
    PlayerInput = 3,
}

GameEvent :: struct #packed {
    event_type: GameEventType,
    move_x: f32,
    move_y: f32,
}

SharedMemoryBlock :: struct #packed {
    frames: [RING_BUFFER_SIZE]FrameSlot,
    latest_frame_index: i32,
    events: [EVENT_QUEUE_SIZE]GameEvent,
    event_head: i32,
    event_tail: i32,
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
    state.game_state.is_active = false
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

spawn_enemy :: proc(state: ^LocalGameState) {
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
            break
        }
    }
}

update_player :: proc(state: ^LocalGameState, dt: f32) {
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

update_enemies :: proc(state: ^LocalGameState, dt: f32) {
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

update_game :: proc(state: ^LocalGameState, dt: f32) {
    if !state.game_state.is_active { return }
    
    state.spawn_timer += dt
    if state.spawn_timer >= SPAWN_INTERVAL {
        state.spawn_timer = 0
        spawn_enemy(state)
    }
    
    update_player(state, dt)
    update_enemies(state, dt)
}

// ============================================================================
// Event Processing (For Unreal Client)
// ============================================================================

process_events :: proc(smh: ^SharedMemoryBlock, state: ^LocalGameState) {
    for {
        tail := sync.atomic_load(&smh.event_tail)
        head := sync.atomic_load(&smh.event_head)
        
        if tail == head { break }
        
        event := smh.events[tail % EVENT_QUEUE_SIZE]
        
        switch event.event_type {
        case .StartGame:
            debug_log("[EVENT] StartGame from Unreal\n")
            reset_game(state)
        case .EndGame:
            debug_log("[EVENT] EndGame from Unreal\n")
            state.game_state.is_active = false
        case .PlayerInput:
            // Can use Unreal input when not using keyboard
        case .None:
        }
        
        sync.atomic_store(&smh.event_tail, (tail + 1) % EVENT_QUEUE_SIZE)
    }
}

// ============================================================================
// Frame Writing
// ============================================================================

write_frame :: proc(smh: ^SharedMemoryBlock, state: ^LocalGameState) {
    state.frame_number += 1
    
    next_idx := (sync.atomic_load(&smh.latest_frame_index) + 1) % RING_BUFFER_SIZE
    
    slot := &smh.frames[next_idx]
    slot.frame_number = state.frame_number
    slot.timestamp = f64(time.now()._nsec) / 1_000_000_000.0
    slot.state = state.game_state
    
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
    
    local_state: LocalGameState
    init_game(&local_state)
    
    if g_config.headless {
        // Headless mode - just write frames for Unreal
        fmt.println("[HEADLESS] Running in server mode. Press Ctrl+C to exit.")
        fmt.println("[HEADLESS] Waiting for events from Unreal client...")
        
        for {
            process_events(smh.ptr, &local_state)
            update_game(&local_state, 1.0 / 60.0)
            write_frame(smh.ptr, &local_state)
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
            
            process_events(smh.ptr, &local_state)
            update_game(&local_state, 1.0 / 60.0)
            write_frame(smh.ptr, &local_state)
            draw_game(&local_state)
        }
    }
    
    fmt.println("\n[EXIT] Game server shutting down...")
    fmt.printf("[EXIT] Final Score: %d | Total Kills: %d\n", 
        local_state.game_state.score, local_state.total_kills)
}