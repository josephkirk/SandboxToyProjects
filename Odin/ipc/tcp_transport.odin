package ipc

import "core:net"
import "core:fmt"
import "core:mem"

// Credits: Nguyen Phi Hung

TCP_Transport :: struct {
    using base: Transport,
    listener:   net.TCP_Socket,
    socket:     net.TCP_Socket, // For client mode
    clients:    [dynamic]net.TCP_Socket,
    events:     [1]TransportEvent, // Local event buffer
}

TCP_VTABLE := Transport_VTable {
    send = tcp_send,
    recv = tcp_recv,
    poll = tcp_poll,
    accept = tcp_accept,
    connect = tcp_connect,
    disconnect = tcp_disconnect,
    shutdown = tcp_shutdown,
}

create_tcp_transport :: proc() -> (^Transport, bool) {
    t := new(TCP_Transport)
    t.vtable = &TCP_VTABLE
    t.clients = make([dynamic]net.TCP_Socket)
    return &t.base, true
}

tcp_send :: proc(t: ^Transport, peer: PeerID, data: []u8) -> bool {
    tt := (^TCP_Transport)(t)
    target: net.TCP_Socket
    
    // Peer 0 is usually the server in client mode, or the first client in server mode
    // This needs a better mapping logic
    if len(tt.clients) > 0 {
        if int(peer) < len(tt.clients) {
            target = tt.clients[peer]
        }
    } else {
        target = tt.socket
    }

    if target == 0 { return false }
    
    _, err := net.send_tcp(target, data)
    return err == nil
}

tcp_recv :: proc(t: ^Transport, buffer: []u8) -> (PeerID, int, bool) {
    tt := (^TCP_Transport)(t)
    
    if len(tt.clients) > 0 {
        for client, i in tt.clients {
            bytes, err := net.recv_tcp(client, buffer)
            if err == nil && bytes > 0 {
                return PeerID(i), bytes, true
            }
        }
    } else if tt.socket != 0 {
        bytes, err := net.recv_tcp(tt.socket, buffer)
        if err == nil && bytes > 0 {
            return 0, bytes, true
        }
    }
    return 0, 0, false
}

tcp_poll :: proc(t: ^Transport, timeout_ms: i32) -> []TransportEvent {
    // NOTE: Real non-blocking polling requires select/epoll
    // For now we return None to satisfy interface
    tt := (^TCP_Transport)(t)
    tt.events[0] = .None
    return tt.events[:]
}

tcp_accept :: proc(t: ^Transport) -> (PeerID, bool) {
    tt := (^TCP_Transport)(t)
    if tt.listener == 0 { return 0, false }
    
    client, addr, err := net.accept_tcp(tt.listener)
    if err != nil { return 0, false }
    
    id := PeerID(len(tt.clients))
    append(&tt.clients, client)
    return id, true
}

tcp_connect :: proc(t: ^Transport, address: string) -> (PeerID, bool) {
    tt := (^TCP_Transport)(t)
    ep, ok := net.parse_endpoint(address)
    if !ok { return 0, false }
    
    sock, err := net.dial_tcp(ep)
    if err != nil { return 0, false }
    
    tt.socket = sock
    return 0, true // Peer 0 is the server
}

tcp_disconnect :: proc(t: ^Transport, peer: PeerID) {
    tt := (^TCP_Transport)(t)
    if int(peer) < len(tt.clients) {
        net.close(tt.clients[peer])
        // Potentially remove from list
    }
}

tcp_shutdown :: proc(t: ^Transport) {
    tt := (^TCP_Transport)(t)
    if tt.listener != 0 { net.close(tt.listener) }
    if tt.socket != 0 { net.close(tt.socket) }
    for client in tt.clients {
        net.close(client)
    }
    delete(tt.clients)
}

// Add a listen helper that isn't in the vtable but used to setup tt.listener
tcp_listen :: proc(t: ^Transport, address: string) -> bool {
    tt := (^TCP_Transport)(t)
    ep, ok := net.parse_endpoint(address)
    if !ok { return false }
    
    sock, err := net.listen_tcp(ep)
    if err != nil { return false }
    
    tt.listener = sock
    return true
}
