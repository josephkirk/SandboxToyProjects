package ipc

import "core:fmt"

// Credits: Nguyen Phi Hung

HybridTransport :: struct {
    using base: Transport,
    tcp: ^Transport,
    udp: ^Transport,
}

HYBRID_VTABLE := Transport_VTable {
    send       = hybrid_send,
    recv       = hybrid_recv,
    poll       = hybrid_poll,
    accept     = hybrid_accept,
    connect    = hybrid_connect,
    disconnect = hybrid_disconnect,
    shutdown   = hybrid_shutdown,
}

create_hybrid_transport :: proc(tcp, udp: ^Transport) -> (^Transport, bool) {
    t := new(HybridTransport)
    t.vtable = &HYBRID_VTABLE
    t.tcp = tcp
    t.udp = udp
    return &t.base, true
}

hybrid_send :: proc(t: ^Transport, peer: PeerID, data: []u8) -> bool {
    tt := (^HybridTransport)(t)
    
    // Inspect data to see if it's a Command
    if len(data) >= size_of(Command) {
        cmd := (^Command)(&data[0])
        if cmd.category == .State {
            return transport_send(tt.udp, peer, data)
        }
    }
    
    return transport_send(tt.tcp, peer, data)
}

hybrid_recv :: proc(t: ^Transport, buffer: []u8) -> (PeerID, int, bool) {
    tt := (^HybridTransport)(t)
    
    // Prioritize TCP for commands, then catch up on UDP state
    if peer, bytes, ok := transport_recv(tt.tcp, buffer); ok {
        return peer, bytes, true
    }
    
    return transport_recv(tt.udp, buffer)
}

hybrid_poll :: proc(t: ^Transport, timeout_ms: i32) -> []TransportEvent {
    tt := (^HybridTransport)(t)
    // Combined polling? For now just one or the other.
    return transport_poll(tt.tcp, timeout_ms)
}

hybrid_accept :: proc(t: ^Transport) -> (PeerID, bool) {
    tt := (^HybridTransport)(t)
    return transport_accept(tt.tcp)
}

hybrid_connect :: proc(t: ^Transport, address: string) -> (PeerID, bool) {
    tt := (^HybridTransport)(t)
    return transport_connect(tt.tcp, address)
}

hybrid_disconnect :: proc(t: ^Transport, peer: PeerID) {
    tt := (^HybridTransport)(t)
    transport_disconnect(tt.tcp, peer)
}

hybrid_shutdown :: proc(t: ^Transport) {
    tt := (^HybridTransport)(t)
    transport_shutdown(tt.tcp)
    transport_shutdown(tt.udp)
}
