package ipc

import "core:fmt"
import "core:mem"

// PeerID represents a unique identifier for a connected client or the server itself.
PeerID :: distinct u32

// TransportEvent represents something that happened on the transport.
TransportEvent :: enum {
    None,
    Connect,
    Disconnect,
    Data,
}

// Transport is the generic interface for all communication layers.
Transport :: struct {
    vtable: ^Transport_VTable,
    userdata: rawptr,
}

Transport_VTable :: struct {
    send:       proc(t: ^Transport, peer: PeerID, data: []u8) -> bool,
    recv:       proc(t: ^Transport, buffer: []u8) -> (PeerID, int, bool),
    poll:       proc(t: ^Transport, timeout_ms: i32) -> []TransportEvent,
    accept:     proc(t: ^Transport) -> (PeerID, bool),
    connect:    proc(t: ^Transport, address: string) -> (PeerID, bool),
    disconnect: proc(t: ^Transport, peer: PeerID),
    shutdown:   proc(t: ^Transport),
}

// Helper wrappers for cleaner calls
transport_send :: proc(t: ^Transport, peer: PeerID, data: []u8) -> bool {
    return t.vtable.send(t, peer, data)
}

transport_recv :: proc(t: ^Transport, buffer: []u8) -> (PeerID, int, bool) {
    return t.vtable.recv(t, buffer)
}

transport_poll :: proc(t: ^Transport, timeout_ms: i32) -> []TransportEvent {
    return t.vtable.poll(t, timeout_ms)
}

transport_accept :: proc(t: ^Transport) -> (PeerID, bool) {
    return t.vtable.accept(t)
}

transport_connect :: proc(t: ^Transport, address: string) -> (PeerID, bool) {
    return t.vtable.connect(t, address)
}

transport_disconnect :: proc(t: ^Transport, peer: PeerID) {
    t.vtable.disconnect(t, peer)
}

transport_shutdown :: proc(t: ^Transport) {
    t.vtable.shutdown(t)
}

// Command Helpers
push_entity_command :: proc(trans: ^Transport, cmd: Command) -> bool {
    data := mem.slice_to_bytes([]Command{cmd})
    return transport_send(trans, 0, data)
}

make_command :: proc(category: CommandCategory, cmd_type: u16, values: [3]f32 = {}, data_str: string = "") -> Command {
    cmd: Command
    cmd.category = category
    cmd.type = cmd_type
    cmd.target_pos = values
    
    data_len := min(len(data_str), MAX_COMMAND_DATA)
    for i in 0..<data_len {
        cmd.data[i] = data_str[i]
    }
    cmd.data_length = u16(data_len)
    
    return cmd
}
