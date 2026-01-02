package main

MAX_ENEMIES :: 100

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
