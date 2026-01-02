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
CMD_GAME_START :: 0x81
CMD_GAME_END   :: 0x82

// Input (0x2X)
CMD_INPUT_MOVE   :: 0x01
CMD_INPUT_ACTION :: 0x02
CMD_INPUT_LOOK   :: 0x03

// Action (0x4X)
CMD_ACTION_SPAWN   :: 0x01
CMD_ACTION_DESTROY :: 0x02
CMD_ACTION_UPDATE  :: 0x03

// State (0x6X)
CMD_STATE_PLAYER_UPDATE :: 0x01
CMD_STATE_ENEMY_UPDATE  :: 0x02
CMD_STATE_GAME_UPDATE   :: 0x03

// Event (0x7X)
CMD_EVENT_GAMEPLAY :: 0x01

// ============================================================================
// Protocol Structures (Shared between Odin/Zig/C++)
// ============================================================================

MAX_ENEMIES :: 100

Vector2 :: struct {
    x: f32,
    y: f32,
}

Player :: struct {
    position:     Vector2,
    rotation:     f32,
    slash_active: bool,
    slash_angle:  f32,
    health:       i32,
    _padding:     [3]u8,
}

Enemy :: struct {
    position: Vector2,
    is_alive: bool,
    _padding: [3]u8,
}

GameState :: struct {
    player:      Player,
    enemies:     [MAX_ENEMIES]Enemy,
    enemy_count: i32,
    score:       i32,
    total_kills: i32,
    frame_number: i32,
    is_active:   bool,
    _padding:    [3]u8,
}

PlayerData :: struct {
    forward: f32,
    side: f32,
    up: f32,
    rotation: f32,
    slash_active: bool,
    slash_angle: f32,
    health: i32,
    id: i32,
    frame_number: i32,
}

// Summary data for legacy/minimal updates
GameStateSummary :: struct {
    score: i32,
    enemy_count: i32,
    is_active: bool,
    frame_number: i32,
}
