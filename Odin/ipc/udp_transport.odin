package ipc

import "core:net"
import "core:fmt"
import "core:mem"

// Credits: Nguyen Phi Hung

UDP_Transport :: struct {
    using base: Transport,
    socket:     net.UDP_Socket,
    endpoint:   net.Endpoint,
    peers:      [dynamic]net.Endpoint,
    events:     [1]TransportEvent,
}

UDP_VTABLE := Transport_VTable {
    send = udp_send,
    recv = udp_recv,
    poll = udp_poll,
    accept = udp_accept,
    connect = udp_connect,
    disconnect = udp_disconnect,
    shutdown = udp_shutdown,
}

create_udp_transport :: proc() -> (^Transport, bool) {
    t := new(UDP_Transport)
    t.vtable = &UDP_VTABLE
    t.peers = make([dynamic]net.Endpoint)
    return &t.base, true
}

udp_send :: proc(t: ^Transport, peer: PeerID, data: []u8) -> bool {
    tt := (^UDP_Transport)(t)
    if int(peer) < len(tt.peers) {
        // Line 243: send_udp :: proc(socket: UDP_Socket, buf: []byte, to: Endpoint)
        _, err := net.send_udp(tt.socket, data, tt.peers[int(peer)])
        return err == nil
    }
    return false
}

udp_recv :: proc(t: ^Transport, buffer: []u8) -> (PeerID, int, bool) {
    tt := (^UDP_Transport)(t)
    
    // Line 200: recv_udp :: proc(socket: UDP_Socket, buf: []byte) -> (bytes_read: int, remote_endpoint: Endpoint, err: UDP_Recv_Error)
    bytes, ep, err := net.recv_udp(tt.socket, buffer)
    if err != nil || bytes <= 0 { return 0, 0, false }
    
    // Find or add peer
    for p, i in tt.peers {
        if p == ep { return PeerID(i), bytes, true }
    }
    
    id := PeerID(len(tt.peers))
    append(&tt.peers, ep)
    return id, bytes, true
}

udp_poll :: proc(t: ^Transport, timeout_ms: i32) -> []TransportEvent {
    tt := (^UDP_Transport)(t)
    tt.events[0] = .None
    return tt.events[:]
}

udp_accept :: proc(t: ^Transport) -> (PeerID, bool) {
    return 0, false
}

udp_connect :: proc(t: ^Transport, address: string) -> (PeerID, bool) {
    tt := (^UDP_Transport)(t)
    ep, ok := net.parse_endpoint(address)
    if !ok { return 0, false }
    
    id := PeerID(len(tt.peers))
    append(&tt.peers, ep)
    
    // Also create the socket if it doesn't exist (unbound)
    if tt.socket == 0 {
        // Line 139: make_unbound_udp_socket :: proc(family: Address_Family)
        // family_from_address is used in line 158
        // For simplicity we use IP4 family as default
        sock, err := net.make_unbound_udp_socket(.IP4)
        if err == nil {
            tt.socket = sock
        }
    }
    
    return id, true
}

udp_disconnect :: proc(t: ^Transport, peer: PeerID) {
}

udp_shutdown :: proc(t: ^Transport) {
    tt := (^UDP_Transport)(t)
    if tt.socket != 0 { net.close(tt.socket) }
    delete(tt.peers)
}

// Bind helper
udp_bind :: proc(t: ^Transport, address: string) -> bool {
    tt := (^UDP_Transport)(t)
    ep, ok := net.parse_endpoint(address)
    if !ok { return false }
    
    // Line 154: make_bound_udp_socket :: proc(bound_address: Address, port: int)
    sock, err := net.make_bound_udp_socket(ep.address, ep.port)
    if err != nil { return false }
    
    tt.socket = sock
    tt.endpoint = ep
    return true
}
