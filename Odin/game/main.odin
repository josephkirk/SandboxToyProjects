package main

import "core:fmt"
import "core:time"
import "core:math"
import "core:math/rand"
import "core:sync"
import "core:mem"
import "core:os"
import "core:sys/windows"
import "core:strconv"
import rl "vendor:raylib"
import "../ipc"
import "../simulation"
import "../session"

// ============================================================================
// Shared Memory Data Structures (Matching C++ layout for Unreal)
// ============================================================================

// (Moved to ipc/ipc_transport.odin)

// Command Categories & Types
// Game -> Client Commands
CMD_ENTITY_SPAWN   :: CMD_ACTION_SPAWN
CMD_ENTITY_DESTROY :: CMD_ACTION_DESTROY
CMD_ENTITY_UPDATE  :: CMD_ACTION_UPDATE
CMD_PLAYER_UPDATE  :: CMD_STATE_PLAYER_UPDATE
CMD_PLAYER_ACTION  :: CMD_INPUT_ACTION
// CMD_EVENT_GAMEPLAY is defined in game_protocol.odin
CMD_INPUT          :: CMD_INPUT_MOVE
CMD_GAME           :: CMD_GAME_START


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

// Type Aliases
// Type Aliases
Category :: ipc.CommandCategory
// GameState, Player, Enemy are now local in game_protocol.odin


// ============================================================================
// Runtime Config (from CLI)
// ============================================================================

Config :: struct {
    debug_mode:     bool,
    headless:       bool,
    verbose:        bool,
    debug_logging:  bool,
    tick_mode:      simulation.TickMode,
    tick_rate:      f64,
    sync_mode:      string,
    transport_type: string,
    address:        string,
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
    registry: ^ipc.CommandRegistry,
    tick_ctrl: ^simulation.TickController,
    sync_strat: ^session.Synchronizer,
    client_connected: bool,
}

// (Windows API moved to ipc/ipc_transport.odin)

// ============================================================================
// Shared Memory
// ============================================================================


// (Moved to ipc/ipc_transport.odin)

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

spawn_enemy :: proc(trans: ^ipc.Transport, state: ^LocalGameState) {
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
            if trans != nil {
                cmd := ipc.make_command(.Action, CMD_ENTITY_SPAWN, {pos.x, pos.y, 0}, "Enemy")
                ipc.push_entity_command(trans, cmd)
            }
            break
        }
    }
}

update_player :: proc(trans: ^ipc.Transport, state: ^LocalGameState, dt: f32) {
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
    if trans != nil {
        p := &state.game_state.player
        
        pd := PlayerData{
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
        
        // Create Command
        cmd: ipc.Command
        cmd.category = .State
        cmd.type = CMD_STATE_PLAYER_UPDATE
        cmd.target_pos = {p.position.x, p.position.y, 0} 
        
        // Copy struct to data
        mem.copy(&cmd.data[0], &pd, size_of(PlayerData))
        cmd.data_length = u16(size_of(PlayerData))
        ipc.push_entity_command(trans, cmd)
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

update_enemies :: proc(trans: ^ipc.Transport, state: ^LocalGameState, dt: f32) {
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
            if trans != nil {
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

update_game :: proc(trans: ^ipc.Transport, state: ^LocalGameState, dt: f32) {
    if !state.game_state.is_active { return }
    
    state.spawn_timer += dt
    if state.spawn_timer >= SPAWN_INTERVAL {
        state.spawn_timer = 0
        spawn_enemy(trans, state)
    }
    
    update_player(trans, state, dt)
    update_enemies(trans, state, dt)
}

// ============================================================================
// Command Buffer Functions (New Unified System)
// ============================================================================

// (Moved to ipc package)

// (Moved to ipc package)

// Command Handlers
handle_input_move :: proc(sim_state: rawptr, cmd: ^ipc.Command) {
    state := (^LocalGameState)(sim_state)
    state.input_x = cmd.target_pos.x
    state.input_y = cmd.target_pos.y
    
    if g_config.debug_logging {
        debug_log("[CMD] INPUT Move: x=%.2f y=%.2f\n", cmd.target_pos.x, cmd.target_pos.y)
    }
}

handle_game_control :: proc(sim_state: rawptr, cmd: ^ipc.Command) {
    state := (^LocalGameState)(sim_state)
    // cmd.target_pos.x: 1=start, -1=end, 0=state change
    if cmd.target_pos.x > 0 {
        debug_log("[CMD] GAME_START\n")
        reset_game(state)
    } else if cmd.target_pos.x < 0 {
        debug_log("[CMD] GAME_END\n")
        state.game_state.is_active = false
    } else {
        data_str := string(cmd.data[:cmd.data_length])
        debug_log("[CMD] GAME_STATE: %s\n", data_str)
    }
}

init_registry :: proc(state: ^LocalGameState) {
    state.registry = ipc.create_registry()
    ipc.register_handler(state.registry, .Input, CMD_INPUT, handle_input_move)
    ipc.register_handler(state.registry, .System, CMD_GAME, handle_game_control)
}

// Process all pending input commands
process_input_commands :: proc(trans: ^ipc.Transport, state: ^LocalGameState) {
    buffer: [size_of(ipc.Command)]u8
    
    for {
        _, bytes_read, ok := ipc.transport_recv(trans, buffer[:])
        if !ok || bytes_read == 0 { break }
        
        cmd := (^ipc.Command)(&buffer[0])
        
        // Feed to sync strategy
        session.sync_on_command_received(state.sync_strat, cmd)
        
        if !ipc.dispatch_command(state.registry, state, cmd) {
            debug_log("[CMD] No handler for Category:%v Type:%d\n", cmd.category, cmd.type)
        } else {
             if !state.client_connected {
                 state.client_connected = true
                 fmt.println("[HEADLESS] Client connected! Receiving commands...")
             }
        }
    }
}

// ============================================================================
// Frame Writing
// ============================================================================

write_frame :: proc(trans: ^ipc.Transport, state: ^LocalGameState) {
    state.frame_number += 1
    state.game_state.frame_number = i32(state.frame_number)
    state.game_state.total_kills = state.total_kills
    
    // Copy full GameState to buffer
    buf := mem.slice_to_bytes([]GameState{state.game_state})
    ipc.ipc_write_frame(trans, buf, state.frame_number)
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
    fmt.println("  vampire_survival.exe --sync lockstep   # Use lockstep sync")
    fmt.println("  vampire_survival.exe --transport tcp   # Use TCP networking")
    fmt.println("  vampire_survival.exe --address :8080   # Listen on/Connect to port 8080")
}

parse_args :: proc() -> bool {
    g_config.tick_rate = 60.0
    g_config.sync_mode = "auth"
    g_config.transport_type = "ipc"
    g_config.address = "127.0.0.1:8080"
    
    for i := 1; i < len(os.args); i += 1 {
        arg := os.args[i]
        if arg == "--headless" {
            g_config.headless = true
        } else if arg == "--verbose" {
            g_config.verbose = true
        } else if arg == "--debug" || arg == "-d" {
            g_config.debug_mode = true
        } else if arg == "--log" {
            g_config.debug_logging = true
        } else if arg == "--continuous" {
            g_config.tick_mode = .RealTimeContinuous
        } else if arg == "--discrete" {
            g_config.tick_mode = .RealTimeDiscrete
        } else if arg == "--sync" {
            if i + 1 < len(os.args) {
                g_config.sync_mode = os.args[i+1]
                i += 1
            } else {
                fmt.println("Error: --sync requires a value (auth, lockstep, turn).")
                print_usage()
                return false
            }
        } else if arg == "--tick-rate" {
            if i + 1 < len(os.args) {
                rate, ok := strconv.parse_f64(os.args[i+1])
                if ok {
                    g_config.tick_rate = rate
                }
                i += 1
            } else {
                fmt.println("Error: --tick-rate requires a value.")
                print_usage()
                return false
            }
        } else if arg == "--transport" {
            if i + 1 < len(os.args) {
                g_config.transport_type = os.args[i+1]
                i += 1
            }
        } else if arg == "--address" {
            if i + 1 < len(os.args) {
                g_config.address = os.args[i+1]
                i += 1
            }
        } else if arg == "--help" || arg == "-h" {
            print_usage()
            return false
        } else {
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
    
    trans: ^ipc.Transport
    ok: bool
    
    switch g_config.transport_type {
    case "ipc":
        trans, ok = ipc.create_ipc_transport()
        if ok {
            // Set Magic and Version for IPC
            ti := (^ipc.IPC_Transport)(trans)
            ti.block.magic = 0x12345678
            ti.block.version = 2
        }
    case "tcp":
        trans, ok = ipc.create_tcp_transport()
        if ok {
            if g_config.headless {
                ipc.tcp_listen(trans, g_config.address)
            } else {
                ipc.tcp_connect(trans, g_config.address)
            }
        }
    case "udp":
        trans, ok = ipc.create_udp_transport()
        if ok {
            if g_config.headless {
                ipc.udp_bind(trans, g_config.address)
            } else {
                ipc.udp_connect(trans, g_config.address)
            }
        }
    case "hybrid":
        tcp, _ := ipc.create_tcp_transport()
        udp, _ := ipc.create_udp_transport()
        trans, ok = ipc.create_hybrid_transport(tcp, udp)
        if ok {
            if g_config.headless {
                ipc.tcp_listen(tcp, g_config.address)
                // udp port might need offset
                ipc.udp_bind(udp, g_config.address) 
            } else {
                ipc.tcp_connect(tcp, g_config.address)
                ipc.udp_connect(udp, g_config.address)
            }
        }
    case:
        trans, ok = ipc.create_ipc_transport()
    }

    if !ok {
        fmt.println("[ERROR] Failed to initialize transport:", g_config.transport_type)
        return
    }
    defer ipc.transport_shutdown(trans)
    
    fmt.printf("[INIT] Transport active: %s\n", g_config.transport_type)
    fmt.println("")
    
    local_state: LocalGameState
    init_game(&local_state)
    init_registry(&local_state)
    
    // Initialize Sync Strategy
    switch g_config.sync_mode {
    case "auth":
        local_state.sync_strat = session.create_authoritative_synchronizer()
    case "lockstep":
        local_state.sync_strat = session.create_lockstep_synchronizer(1) // Single player for sim
    case "turn":
        local_state.sync_strat = session.create_turn_synchronizer(1)
    case:
        local_state.sync_strat = session.create_authoritative_synchronizer()
    }
    
    local_state.tick_ctrl = simulation.create_tick_controller(g_config.tick_mode, g_config.tick_rate)
    defer simulation.destroy_tick_controller(local_state.tick_ctrl)
    defer ipc.destroy_registry(local_state.registry)
    
    if g_config.headless {
        // Headless mode - just write frames for Unreal
        fmt.println("[HEADLESS] Running in server mode. Press Ctrl+C to exit.")
        fmt.println("[HEADLESS] Waiting for client input...")
        
        target_tick_rate := time.Duration(16666667) // ~60 Hz (16.67ms) in nanoseconds
        last_time := time.now()
        
        for {
            current_time := time.now()
            dt := time.duration_seconds(time.diff(last_time, current_time))
            last_time = current_time
            
            if session.sync_can_advance(local_state.sync_strat, local_state.tick_ctrl.current_tick) {
                res := simulation.update_tick(local_state.tick_ctrl, dt)
                for i in 0..<res.ticks_to_run {
                    process_input_commands(trans, &local_state)
                    update_game(trans, &local_state, f32(res.dt))
                    session.sync_on_tick_completed(local_state.sync_strat, local_state.tick_ctrl.current_tick)
                }
            }
            write_frame(trans, &local_state)
            
            // Sleep to maintain roughly 60Hz to avoid spinning 100% CPU
            // Simple sleep for now, as we use measured dt to correct simulation speed
            work_dur := time.diff(current_time, time.now())
            if work_dur < target_tick_rate {
                 time.sleep(target_tick_rate - work_dur)
            }
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
            
            if session.sync_can_advance(local_state.sync_strat, local_state.tick_ctrl.current_tick) {
                res := simulation.update_tick(local_state.tick_ctrl, f64(rl.GetFrameTime()))
                for i in 0..<res.ticks_to_run {
                    process_input_commands(trans, &local_state)
                    update_game(trans, &local_state, f32(res.dt))
                    session.sync_on_tick_completed(local_state.sync_strat, local_state.tick_ctrl.current_tick)
                }
            }
            write_frame(trans, &local_state)
            draw_game(&local_state)
        }
    }
    
    fmt.println("\n[EXIT] Game server shutting down...")
    fmt.printf("[EXIT] Final Score: %d | Total Kills: %d\n", 
        local_state.game_state.score, local_state.total_kills)
}