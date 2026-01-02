package generated

import "core:fmt"
import fb "../flatbuffers"

PlayerData :: struct { forward: f32, side: f32, up: f32, rotation: f32, slash_active: bool, slash_angle: f32, health: i32, id: i32, frame_number: i32, }

pack_PlayerData :: proc(b: ^fb.Builder, o: PlayerData) -> fb.Offset {
    fb.start_table(b, 9)
    fb.prepend_float32_slot(b, 0, o.forward, 0.0)
    fb.prepend_float32_slot(b, 1, o.side, 0.0)
    fb.prepend_float32_slot(b, 2, o.up, 0.0)
    fb.prepend_float32_slot(b, 3, o.rotation, 0.0)
    fb.prepend_bool_slot(b, 4, o.slash_active, false)
    fb.prepend_float32_slot(b, 5, o.slash_angle, 0.0)
    fb.prepend_int32_slot(b, 6, o.health, 0)
    fb.prepend_int32_slot(b, 7, o.id, 0)
    fb.prepend_int32_slot(b, 8, o.frame_number, 0)
    return fb.end_table(b)
}

Enemy :: struct { forward: f32, side: f32, up: f32, is_alive: bool, id: i32, frame_number: i32, }

pack_Enemy :: proc(b: ^fb.Builder, o: Enemy) -> fb.Offset {
    fb.start_table(b, 6)
    fb.prepend_float32_slot(b, 0, o.forward, 0.0)
    fb.prepend_float32_slot(b, 1, o.side, 0.0)
    fb.prepend_float32_slot(b, 2, o.up, 0.0)
    fb.prepend_bool_slot(b, 3, o.is_alive, false)
    fb.prepend_int32_slot(b, 4, o.id, 0)
    fb.prepend_int32_slot(b, 5, o.frame_number, 0)
    return fb.end_table(b)
}

GameState :: struct { score: i32, enemy_count: i32, is_active: bool, frame_number: i32, }

pack_GameState :: proc(b: ^fb.Builder, o: GameState) -> fb.Offset {
    fb.start_table(b, 4)
    fb.prepend_int32_slot(b, 0, o.score, 0)
    fb.prepend_int32_slot(b, 1, o.enemy_count, 0)
    fb.prepend_bool_slot(b, 2, o.is_active, false)
    fb.prepend_int32_slot(b, 3, o.frame_number, 0)
    return fb.end_table(b)
}

