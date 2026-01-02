package session

import "../ipc"

// Credits: Nguyen Phi Hung

Synchronizer :: struct {
    vtable: ^Sync_VTable,
    data:   rawptr, // Instance data for the specific strategy
}

Sync_VTable :: struct {
    on_command_received: proc(s: ^Synchronizer, cmd: ^ipc.Command),
    can_advance:         proc(s: ^Synchronizer, tick: u64) -> bool,
    get_confirmed_tick:  proc(s: ^Synchronizer) -> u64,
    on_tick_completed:   proc(s: ^Synchronizer, tick: u64),
}

// Helper dispatchers
sync_on_command_received :: proc(s: ^Synchronizer, cmd: ^ipc.Command) {
    if s != nil && s.vtable != nil && s.vtable.on_command_received != nil {
        s.vtable.on_command_received(s, cmd)
    }
}

sync_can_advance :: proc(s: ^Synchronizer, tick: u64) -> bool {
    if s != nil && s.vtable != nil && s.vtable.can_advance != nil {
        return s.vtable.can_advance(s, tick)
    }
    return true
}

sync_get_confirmed_tick :: proc(s: ^Synchronizer) -> u64 {
    if s != nil && s.vtable != nil && s.vtable.get_confirmed_tick != nil {
        return s.vtable.get_confirmed_tick(s)
    }
    return 0
}

sync_on_tick_completed :: proc(s: ^Synchronizer, tick: u64) {
    if s != nil && s.vtable != nil && s.vtable.on_tick_completed != nil {
        s.vtable.on_tick_completed(s, tick)
    }
}
