package session

import "../ipc"

// Credits: Nguyen Phi Hung

AuthoritativeSynchronizer :: struct {
    sync: Synchronizer,
}

AUTHORITATIVE_VTABLE := Sync_VTable {
    on_command_received = proc(s: ^Synchronizer, cmd: ^ipc.Command) {
        // Authoritative server processes commands immediately (already handled by registry dispatch)
    },
    can_advance = proc(s: ^Synchronizer, tick: u64) -> bool {
        return true // Always advance in authoritative mode
    },
    get_confirmed_tick = proc(s: ^Synchronizer) -> u64 {
        return 0 // Not strictly used for lockstep confirmation
    },
    on_tick_completed = proc(s: ^Synchronizer, tick: u64) {
        // Could trigger state snapshot broadcast here
    },
}

create_authoritative_synchronizer :: proc() -> ^Synchronizer {
    as := new(AuthoritativeSynchronizer)
    as.sync.vtable = &AUTHORITATIVE_VTABLE
    as.sync.data = as
    return &as.sync
}
