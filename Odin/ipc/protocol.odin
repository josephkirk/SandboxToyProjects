package ipc

// Credit: Nguyen Phi Hung

// Command Type Constants
// Command Category
CommandCategory :: enum u16 {
    None     = 0,
    System   = 1,
    Input    = 2,
    State    = 3,
    Action   = 4,
    Movement = 5,
    Event    = 6,
}

// Command Types (Categorized)
// System (0x0X)
CMD_SYSTEM_HEARTBEAT :: 0x01
CMD_SYSTEM_SYNC      :: 0x02

// Game (0x8X - Legacy mapping for compatibility check)
// Moved to game/game_protocol.odin

// ============================================================================
// Protocol Structures (Shared between Odin/Zig/C++)
// ============================================================================
