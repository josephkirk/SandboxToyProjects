package session

import "core:sync"
import "../ipc"

// Credits: Nguyen Phi Hung

LockstepSynchronizer :: struct {
    sync:           Synchronizer,
    player_count:   int,
    ready_players:  [8]bool, // Commands received for current tick
    confirmed_tick: u64,
}

LOCKSTEP_VTABLE := Sync_VTable {
    on_command_received = proc(s: ^Synchronizer, cmd: ^ipc.Command) {
        ls := (^LockstepSynchronizer)(s.data)
        if int(cmd.player_id) < ls.player_count {
            ls.ready_players[cmd.player_id] = true
        }
    },
    can_advance = proc(s: ^Synchronizer, tick: u64) -> bool {
        ls := (^LockstepSynchronizer)(s.data)
        
        // Check if all players have sent commands for the current confirmed tick
        for i in 0..<ls.player_count {
            if !ls.ready_players[i] {
                return false
            }
        }
        return true
    },
    get_confirmed_tick = proc(s: ^Synchronizer) -> u64 {
        ls := (^LockstepSynchronizer)(s.data)
        return ls.confirmed_tick
    },
    on_tick_completed = proc(s: ^Synchronizer, tick: u64) {
        ls := (^LockstepSynchronizer)(s.data)
        ls.confirmed_tick = tick
        // Clear ready flags for next tick
        for i in 0..<ls.player_count {
            ls.ready_players[i] = false
        }
    },
}

create_lockstep_synchronizer :: proc(player_count: int) -> ^Synchronizer {
    ls := new(LockstepSynchronizer)
    ls.sync.vtable = &LOCKSTEP_VTABLE
    ls.sync.data = ls
    ls.player_count = player_count
    return &ls.sync
}
