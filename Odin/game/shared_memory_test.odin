package main

import "core:testing"
import "core:fmt"
import "core:sync"
import "../ipc"

// Test: Command Ring Buffer - Basic Push/Pop
@(test)
test_command_ring_buffer_basic :: proc(t: ^testing.T) {
    trans, ok := ipc.create_ipc_transport()
    testing.expect(t, ok, "Should successfully create IPC transport")
    defer ipc.transport_shutdown(trans)
    
    it := (^ipc.IPC_Transport)(trans)
    smb := it.block
    
    cmd_in := ipc.make_command(.Input, CMD_INPUT_MOVE, {1.0, 2.0, 0}, "TestInput")
    
    // Simulate Client Pushing
    tail := smb.input_ring.tail 
    head := smb.input_ring.head
    testing.expect(t, tail == 0, "Tail starts at 0")
    testing.expect(t, head == 0, "Head starts at 0")
    
    next_head := (head + 1) % ipc.INPUT_RING_SIZE
    smb.input_ring.commands[head] = cmd_in
    sync.atomic_store(&smb.input_ring.head, next_head)
    
    buffer: [size_of(ipc.Command)]u8
    _, bytes_read, recv_ok := ipc.transport_recv(trans, buffer[:])
    testing.expect(t, recv_ok, "Should successfully receive command")
    
    popped := (^ipc.Command)(&buffer[0])
    testing.expect(t, popped.type == CMD_INPUT_MOVE, "Command type matches")
    testing.expect(t, popped.target_pos.x == 1.0, "Target x matches")
    
    data_str := string(popped.data[:popped.data_length])
    testing.expect(t, data_str == "TestInput", "Data string matches")
}

// Test: Entity Ring Buffer - Push/Pop (Circular)
@(test)
test_entity_ring_buffer_wrap :: proc(t: ^testing.T) {
    trans, ok := ipc.create_ipc_transport()
    testing.expect(t, ok, "Should successfully create IPC transport")
    defer ipc.transport_shutdown(trans)
    
    it := (^ipc.IPC_Transport)(trans)
    smb := it.block
    
    // Fill buffer to capacity (Size - 1)
    count := ipc.ENTITY_RING_SIZE - 1
    
    for i in 0..<count {
        cmd := ipc.make_command(.Action, CMD_ENTITY_SPAWN, {f32(i), 0, 0}, "Entity")
        ok := ipc.push_entity_command(trans, cmd)
        testing.expect(t, ok, fmt.tprintf("Push should succeed at index %d", i))
    }
    
    // Next push should fail (Full)
    fail_cmd := ipc.make_command(.Action, CMD_ENTITY_SPAWN, {999, 0, 0}, "Full")
    ok_fail := ipc.push_entity_command(trans, fail_cmd)
    testing.expect(t, !ok_fail, "Push should fail when full")
    
    // Consume one (Manual pop simulation)
    tail := smb.entity_ring.tail
    cmd_read := smb.entity_ring.commands[tail]
    sync.atomic_store(&smb.entity_ring.tail, (tail + 1) % ipc.ENTITY_RING_SIZE)
    
    testing.expect(t, cmd_read.target_pos.x == 0, "First value matches")
    
    // Now push should succeed
    ok_retry := ipc.push_entity_command(trans, fail_cmd)
    testing.expect(t, ok_retry, "Push should succeed after pop")
}

// Test: Shared Memory Layout Size
@(test)
test_shared_memory_layout :: proc(t: ^testing.T) {
    fmt.printf("[TEST] Command Size: %d\n", size_of(ipc.Command))
    testing.expect(t, size_of(ipc.Command) == 176, "Command size check")
    testing.expect(t, size_of(ipc.CommandRing(ipc.INPUT_RING_SIZE)) > 176 * 16, "Input Ring size sanity check")
}

// Test: Frame Size Limit
@(test)
test_frame_size_limit :: proc(t: ^testing.T) {
    gs := GameState{
        score = 100000,
        enemy_count = 100,
        is_active = true,
        frame_number = 12345,
    }
    
    size := size_of(GameState)
    fmt.printf("[TEST] GameState raw size: %d bytes (Max Frame Data: %d)\n", size, ipc.MAX_FRAME_SIZE)
    
    testing.expect(t, size < ipc.MAX_FRAME_SIZE, "Frame must fit in Shared Memory")
}
