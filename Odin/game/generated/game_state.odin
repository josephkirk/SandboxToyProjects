package generated

import "core:fmt"
import fb "../flatbuffers"

Vec2 :: struct { x: f32, y: f32, }

Player :: struct { position: Vec2, rotation: f32, slash_active: bool, slash_angle: f32, health: i32, }

pack_Player :: proc(b: ^fb.Builder, o: Player) -> fb.Offset {
    fb.start_table(b, 5)
    fb.prepend_struct_slot(b, 0, o.position)
    fb.prepend_float32_slot(b, 1, o.rotation, 0.0)
    fb.prepend_bool_slot(b, 2, o.slash_active, false)
    fb.prepend_float32_slot(b, 3, o.slash_angle, 0.0)
    fb.prepend_int32_slot(b, 4, o.health, 0)
    return fb.end_table(b)
}

Enemy :: struct { position: Vec2, is_alive: bool, }

pack_Enemy :: proc(b: ^fb.Builder, o: Enemy) -> fb.Offset {
    fb.start_table(b, 2)
    fb.prepend_struct_slot(b, 0, o.position)
    fb.prepend_bool_slot(b, 1, o.is_alive, false)
    return fb.end_table(b)
}

GameState :: struct { player: Player, enemies: [dynamic]Enemy, score: i32, enemy_count: i32, is_active: bool, }

pack_GameState :: proc(b: ^fb.Builder, o: GameState) -> fb.Offset {
    vec_enemies: fb.Offset = 0
    if len(o.enemies) > 0 {
        offsets := make([dynamic]fb.Offset, len(o.enemies), context.temp_allocator)
        for e, i in o.enemies { offsets[i] = pack_Enemy(b, e) }
        fb.start_vector(b, 4, len(o.enemies), 4)
        for i := len(offsets)-1; i >= 0; i -= 1 { fb.prepend_offset(b, offsets[i]) }
        vec_enemies = fb.end_vector(b, len(o.enemies))
    }
    fb.start_table(b, 5)
    if vec_enemies != 0 { fb.prepend_offset_slot(b, 1, vec_enemies) }
    fb.prepend_int32_slot(b, 2, o.score, 0)
    fb.prepend_int32_slot(b, 3, o.enemy_count, 0)
    fb.prepend_bool_slot(b, 4, o.is_active, false)
    return fb.end_table(b)
}

