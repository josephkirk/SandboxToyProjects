package simulation

import "core:fmt"
import "core:time"

// Credits: Nguyen Phi Hung

TickMode :: enum {
    RealTimeContinuous, // Variable timestep (dt)
    RealTimeDiscrete,   // Fixed timestep with accumulator
    TurnBased,          // Explicit phases
}

TurnPhase :: enum {
    Planning,
    Execution,
    Cleanup,
}

TickController :: struct {
    mode:           TickMode,
    tick_rate:      f64,        // Ticks per second (for Discrete)
    accumulator:    f64,        // Time accumulated for Discrete
    current_tick:   u64,
    
    // Turn-based state
    turn_phase:     TurnPhase,
    current_player: u32,
    player_count:   u32,
    
    // Stats
    total_time:     f64,
}

create_tick_controller :: proc(mode: TickMode, tick_rate: f64 = 60.0) -> ^TickController {
    tc := new(TickController)
    tc.mode = mode
    tc.tick_rate = tick_rate
    tc.player_count = 1 // Default
    return tc
}

destroy_tick_controller :: proc(tc: ^TickController) {
    if tc != nil {
        free(tc)
    }
}

// Tick Result tells the simulation how many times to update
TickResult :: struct {
    ticks_to_run: int,
    dt:           f64,
}

is_tick_ready :: proc(tc: ^TickController) -> bool {
    if tc.mode == .TurnBased {
        return tc.turn_phase == .Execution
    }
    return true
}

update_tick :: proc(tc: ^TickController, frame_dt: f64) -> TickResult {
    tc.total_time += frame_dt
    
    switch tc.mode {
    case .RealTimeContinuous:
        tc.current_tick += 1
        return { 1, frame_dt }
        
    case .RealTimeDiscrete:
        tc.accumulator += frame_dt
        tick_time := 1.0 / tc.tick_rate
        ticks := 0
        for tc.accumulator >= tick_time {
            tc.accumulator -= tick_time
            tc.current_tick += 1
            ticks += 1
        }
        return { ticks, tick_time }
        
    case .TurnBased:
        // Turn-based ticks are manually triggered or phase-dependent
        return { 0, 0 }
    }
    
    return { 0, 0 }
}

advance_phase :: proc(tc: ^TickController) {
    if tc.mode != .TurnBased { return }
    
    switch tc.turn_phase {
    case .Planning:
        tc.turn_phase = .Execution
    case .Execution:
        tc.turn_phase = .Cleanup
    case .Cleanup:
        tc.turn_phase = .Planning
        tc.current_player = (tc.current_player + 1) % tc.player_count
        tc.current_tick += 1
    }
}
