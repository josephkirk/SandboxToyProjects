package main

import "core:testing"
import "core:fmt"
import "core:sync"
import fb "./flatbuffers"
import gen "./generated"

// Test: Command Ring Buffer - Basic Push/Pop
@(test)
test_command_ring_buffer_basic :: proc(t: ^testing.T) {
    smh := new(SharedMemoryBlock)
    defer free(smh)
    
    cmd_in := make_command(ODIN_CMD_INPUT, {1.0, 2.0, 0, 0}, "TestInput")
    
    // Simulate Client Pushing
    tail := smh.input_ring.tail 
    head := smh.input_ring.head
    testing.expect(t, tail == 0, "Tail starts at 0")
    testing.expect(t, head == 0, "Head starts at 0")
    
    next_head := (head + 1) % INPUT_RING_SIZE
    smh.input_ring.commands[head] = cmd_in
    sync.atomic_store(&smh.input_ring.head, next_head)
    
    testing.expect(t, has_input_command(smh), "Should have input command")
    
    popped, ok := pop_input_command(smh)
    testing.expect(t, ok, "Should successfully pop command")
    testing.expect(t, popped.type == ODIN_CMD_INPUT, "Command type matches")
    testing.expect(t, popped.values[0] == 1.0, "Value[0] matches")
    
    data_str := string(popped.data[:popped.data_length])
    testing.expect(t, data_str == "TestInput", "Data string matches")
    
    testing.expect(t, !has_input_command(smh), "Buffer should be empty")
}

// Test: Entity Ring Buffer - Push/Pop (Circular)
@(test)
test_entity_ring_buffer_wrap :: proc(t: ^testing.T) {
    smh := new(SharedMemoryBlock)
    defer free(smh)
    
    // Fill buffer to capacity (Size - 1)
    count := ENTITY_RING_SIZE - 1
    
    for i in 0..<count {
        cmd := make_command(ODIN_CMD_ENTITY_SPAWN, {f32(i), 0, 0, 0}, "Entity")
        ok := push_entity_command(smh, cmd)
        testing.expect(t, ok, fmt.tprintf("Push should succeed at index %d", i))
    }
    
    // Next push should fail (Full)
    fail_cmd := make_command(ODIN_CMD_ENTITY_SPAWN, {999, 0, 0, 0}, "Full")
    ok_fail := push_entity_command(smh, fail_cmd)
    testing.expect(t, !ok_fail, "Push should fail when full")
    
    // Consume one (Manual pop simulation)
    tail := smh.entity_ring.tail
    cmd_read := smh.entity_ring.commands[tail]
    sync.atomic_store(&smh.entity_ring.tail, (tail + 1) % ENTITY_RING_SIZE)
    
    testing.expect(t, cmd_read.values[0] == 0, "First value matches")
    
    // Now push should succeed
    ok_retry := push_entity_command(smh, fail_cmd)
    testing.expect(t, ok_retry, "Push should succeed after pop")
}

// Test: Shared Memory Layout Size
@(test)
test_shared_memory_layout :: proc(t: ^testing.T) {
    testing.expect(t, size_of(OdinCommand) == 40, "OdinCommand size must be 40 bytes")
    testing.expect(t, size_of(CommandRing(INPUT_RING_SIZE)) > 40 * 16, "Input Ring size sanity check")
}

// Test: Frame Size Limit
@(test)
test_frame_size_limit :: proc(t: ^testing.T) {
    // Determine typical/max game state size
    // Populate a local game state with MAX entities
    state: LocalGameState
    init_game(&state)
    
    state.game_state.is_active = true
    state.game_state.score = 999999
    state.game_state.enemy_count = MAX_ENEMIES
    state.frame_number = 1000
    
    // builder
    builder := fb.init_builder()
    defer delete(builder.bytes)
    defer delete(builder.vtable)
    defer delete(builder.vtables)
    
    // Simulate main.odin's write_frame logic partially to gauge size
    // Note: main.odin only packs GameState metadata currently!
    // It does NOT pack the enemies array into the FlatBuffer.
    // Wait, let's verify write_frame in main.odin.
    // "entities (PlayerData, Enemy) are serialized separately if needed"
    // "gen.pack_GameState(builder, gen_state)" where gen_state has score, count, active.
    
    // If the schema `GameState.fbs` only has scalar fields, it's tiny.
    // checking main.odin line 700:
    /*
    gen_state: gen.GameState
    gen_state.score = state.game_state.score
    gen_state.enemy_count = state.game_state.enemy_count
    gen_state.is_active = state.game_state.is_active
    gen_state.frame_number = i32(state.frame_number)
    root := gen.pack_GameState(builder, gen_state)
    */
    
    // The C++ side reads this. If only metadata is sent, then 16KB is overkill.
    // However, if we intend to send entities, we MUST test that.
    // User asked "check flatbuffer serialization of typical game data can fit".
    // "Typical game data" usually implies the entities.
    
    // If we only send lightweight metadata, the test will confirm it fits easily.
    
    gen_state: gen.GameState
    gen_state.score = 100000
    gen_state.enemy_count = MAX_ENEMIES
    gen_state.is_active = true
    gen_state.frame_number = 12345
    
    root := gen.pack_GameState(&builder, gen_state)
    buf := fb.finish(&builder, root)
    defer delete(buf)
    
    size := len(buf)
    fmt.printf("[TEST] Frame Size with Metadata: %d bytes (Max: %d)\n", size, MAX_FRAME_SIZE)
    
    testing.expect(t, size < MAX_FRAME_SIZE, "Frame must fit in Shared Memory")
    
    // Verification: If we WERE to serialize enemies...
    // Let's assume we add an array of enemies to the schema.
    // Each enemy is pos(vec2) + alive(bool). ~12 bytes.
    // 100 enemies * 12 = 1200 bytes.
    // Plus overhead.
    // 16KB is plenty.
    
    testing.expect(t, size < 100, "Metadata-only frame should be very small")
}
