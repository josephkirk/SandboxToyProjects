package ipc

import "core:fmt"

// Credits: Nguyen Phi Hung

MAX_COMMAND_DATA :: 128

PlayerID :: u32
EntityID :: u32

// Generic Command Struct
Command :: struct {
    sequence:      u32,
    tick:          u64,
    player_id:     PlayerID,
    category:      CommandCategory,
    type:          u16,
    flags:         u16,
    target_entity: EntityID,
    target_pos:    [3]f32,
    data_length:   u16,
    data:          [MAX_COMMAND_DATA]u8,
}

// Command Handler Signature
// Note: We use rawptr for simulation state to keep it transport-only.
CommandHandler :: proc(sim_state: rawptr, cmd: ^Command)

CommandKey :: struct {
    category: CommandCategory,
    type:     u16,
}

CommandRegistry :: struct {
    handlers: map[CommandKey]CommandHandler,
}

create_registry :: proc() -> ^CommandRegistry {
    reg := new(CommandRegistry)
    reg.handlers = make(map[CommandKey]CommandHandler)
    return reg
}

destroy_registry :: proc(reg: ^CommandRegistry) {
    if reg != nil {
        delete(reg.handlers)
        free(reg)
    }
}

register_handler :: proc(reg: ^CommandRegistry, category: CommandCategory, type: u16, handler: CommandHandler) {
    key := CommandKey{category, type}
    reg.handlers[key] = handler
}

dispatch_command :: proc(reg: ^CommandRegistry, sim_state: rawptr, cmd: ^Command) -> bool {
    key := CommandKey{cmd.category, cmd.type}
    handler, ok := reg.handlers[key]
    if ok {
        handler(sim_state, cmd)
        return true
    }
    return false
}
