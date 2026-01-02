package session

import "../ipc"

// Credits: Nguyen Phi Hung

TurnSyncSynchronizer :: struct {
    sync:         Synchronizer,
    player_count: int,
    turns_ended:  [8]bool,
}

TURNSYNC_VTABLE := Sync_VTable {
    on_command_received = proc(s: ^Synchronizer, cmd: ^ipc.Command) {
        ts := (^TurnSyncSynchronizer)(s.data)
        // Check if command is "EndTurn" (CMD_SYSTEM_SYNC with value < 0 or specific type)
        if cmd.category == .System && cmd.type == ipc.CMD_SYSTEM_SYNC && cmd.target_pos.x < 0 {
            if int(cmd.player_id) < ts.player_count {
                ts.turns_ended[cmd.player_id] = true
            }
        }
    },
    can_advance = proc(s: ^Synchronizer, tick: u64) -> bool {
        ts := (^TurnSyncSynchronizer)(s.data)
        // In turn-based, can advance phase if all players ended turn
        for i in 0..<ts.player_count {
            if !ts.turns_ended[i] {
                return false
            }
        }
        return true
    },
    get_confirmed_tick = proc(s: ^Synchronizer) -> u64 {
        return 0
    },
    on_tick_completed = proc(s: ^Synchronizer, tick: u64) {
        ts := (^TurnSyncSynchronizer)(s.data)
        for i in 0..<ts.player_count {
            ts.turns_ended[i] = false
        }
    },
}

create_turn_synchronizer :: proc(player_count: int) -> ^Synchronizer {
    ts := new(TurnSyncSynchronizer)
    ts.sync.vtable = &TURNSYNC_VTABLE
    ts.sync.data = ts
    ts.player_count = player_count
    return &ts.sync
}
