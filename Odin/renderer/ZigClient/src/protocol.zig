const std = @import("std");

// Credits: Nguyen Phi Hung

pub const MAX_COMMAND_DATA = 128;
pub const RING_BUFFER_SIZE = 64;
pub const INPUT_RING_SIZE = 16;
pub const ENTITY_RING_SIZE = 64;
pub const MAX_FRAME_SIZE = 16 * 1024;

pub const CommandCategory = enum(u16) {
    None = 0,
    System = 1,
    Input = 2,
    State = 3,
    Action = 4,
    Movement = 5,
    Event = 6,
};

pub const CMD_SYSTEM_HEARTBEAT = 0x01;
pub const CMD_SYSTEM_SYNC = 0x02;

pub const CMD_INPUT_MOVE = 0x01;
pub const CMD_INPUT_ACTION = 0x02;

pub const CMD_STATE_PLAYER_UPDATE = 0x01;
pub const CMD_STATE_ENEMY_UPDATE = 0x02;
pub const CMD_STATE_GAME_UPDATE = 0x03;

pub const Command = extern struct {
    sequence: u32,
    tick: u64,
    player_id: u32,
    category: CommandCategory,
    type: u16,
    flags: u16,
    target_entity: u32,
    target_pos: [3]f32,
    data_length: u16,
    data: [MAX_COMMAND_DATA]u8,
};

pub fn CommandRing(comptime Size: usize) type {
    return extern struct {
        head: i32,
        tail: i32,
        commands: [Size]Command,
    };
}

pub const FrameSlot = extern struct {
    frame_number: u64,
    timestamp: f64,
    data_size: u32,
    data: [MAX_FRAME_SIZE]u8,
};

pub const SharedMemoryBlock = extern struct {
    magic: u32,
    version: u32,
    frames: [RING_BUFFER_SIZE]FrameSlot,
    latest_frame_index: i32,
    input_ring: CommandRing(INPUT_RING_SIZE),
    entity_ring: CommandRing(ENTITY_RING_SIZE),
};

pub const MAX_ENEMIES = 100;

pub const Vector2 = extern struct {
    x: f32,
    y: f32,
};

pub const Player = extern struct {
    position: Vector2,
    rotation: f32,
    slash_active: bool,
    slash_angle: f32,
    health: i32,
    _padding: [3]u8,
};

pub const Enemy = extern struct {
    position: Vector2,
    is_alive: bool,
    _padding: [3]u8,
};

pub const GameState = extern struct {
    player: Player,
    enemies: [MAX_ENEMIES]Enemy,
    enemy_count: i32,
    score: i32,
    total_kills: i32,
    frame_number: i32,
    is_active: bool,
    _padding: [3]u8,
};

pub const PlayerData = extern struct {
    forward: f32,
    side: f32,
    up: f32,
    rotation: f32,
    slash_active: bool,
    slash_angle: f32,
    health: i32,
    id: i32,
    frame_number: i32,
};

pub const GameStateSummary = extern struct {
    score: i32,
    enemy_count: i32,
    is_active: bool,
    frame_number: i32,
};
