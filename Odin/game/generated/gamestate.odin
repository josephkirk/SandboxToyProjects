package generated

import "core:fmt"
import fb "../flatbuffers"

Vec3 :: struct { x: f32, y: f32, z: f32, }

PlayerData :: struct { position: Vec3, rotation: f32, slash_active: bool, slash_angle: f32, health: i32, is_visible: bool, id: i32, }

pack_PlayerData :: proc(b: ^fb.Builder, o: PlayerData) -> fb.Offset {
    fb.start_table(b, 7)
    fb.prepend_struct_slot(b, 0, o.position)
    fb.prepend_float32_slot(b, 1, o.rotation, 0.0)
    fb.prepend_bool_slot(b, 2, o.slash_active, false)
    fb.prepend_float32_slot(b, 3, o.slash_angle, 0.0)
    fb.prepend_int32_slot(b, 4, o.health, 0)
    fb.prepend_bool_slot(b, 5, o.is_visible, false)
    fb.prepend_int32_slot(b, 6, o.id, 0)
    return fb.end_table(b)
}

Enemy :: struct { position: Vec3, is_alive: bool, is_visible: bool, id: i32, }

pack_Enemy :: proc(b: ^fb.Builder, o: Enemy) -> fb.Offset {
    fb.start_table(b, 4)
    fb.prepend_struct_slot(b, 0, o.position)
    fb.prepend_bool_slot(b, 1, o.is_alive, false)
    fb.prepend_bool_slot(b, 2, o.is_visible, false)
    fb.prepend_int32_slot(b, 3, o.id, 0)
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

