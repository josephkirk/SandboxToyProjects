package ipc

import "core:fmt"
import "core:sync"
import "core:mem"
import "core:sys/windows"

// ============================================================================
// Internal Shared Memory Structures (Implementation Detail of IPC_Transport)
// ============================================================================

RING_BUFFER_SIZE :: 64
INPUT_RING_SIZE :: 16
ENTITY_RING_SIZE :: 64
COMMAND_DATA_SIZE :: 128
MAX_FRAME_SIZE :: 16 * 1024

// This must match exactly what main.odin and the C++ client expect
// (OdinCommand removed, using Command from commands.odin)

// Ring Buffer for Commands
CommandRing :: struct($Size: int) {
    head:      i32,
    tail:      i32,
    commands:  [Size]Command,
}

FrameSlot :: struct {
    frame_number: u64,
    timestamp: f64,
    data_size: u32,
    data: [MAX_FRAME_SIZE]u8,
}

// Memory Layout for Shared Memory
SharedMemoryBlock :: struct {
    magic:               u32,
    version:             u32,
    frames:              [RING_BUFFER_SIZE]FrameSlot,
    latest_frame_index:  i32,
    input_ring:          CommandRing(INPUT_RING_SIZE),  // Client -> Game
    entity_ring:         CommandRing(ENTITY_RING_SIZE), // Game -> Client
}

// Windows API
foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "stdcall")
foreign kernel32 {
    CreateFileMappingW :: proc(
        hFile: windows.HANDLE,
        lpFileMappingAttributes: rawptr,
        flProtect: windows.DWORD,
        dwMaximumSizeHigh: windows.DWORD,
        dwMaximumSizeLow: windows.DWORD,
        lpName: windows.LPCWSTR,
    ) -> windows.HANDLE ---

    MapViewOfFile :: proc(
        hFileMappingObject: windows.HANDLE,
        dwDesiredAccess: windows.DWORD,
        dwFileOffsetHigh: windows.DWORD,
        dwFileOffsetLow: windows.DWORD,
        dwNumberOfBytesToMap: windows.SIZE_T,
    ) -> rawptr ---

    UnmapViewOfFile :: proc(lpBaseAddress: rawptr) -> windows.BOOL ---
}

FILE_MAP_ALL_ACCESS :: 0x000F001F
PAGE_READWRITE :: 0x04
SHARED_MEMORY_NAME :: "OdinVampireSurvival"

// ============================================================================
// IPC Transport Implementation
// ============================================================================

IPC_Transport :: struct {
    using base: Transport,
    handle: windows.HANDLE,
    block: ^SharedMemoryBlock,
    events: [1]TransportEvent, // Persistent event buffer for poll
}

IPC_VTABLE := Transport_VTable{
    send       = ipc_send,
    recv       = ipc_recv,
    poll       = ipc_poll,
    accept     = ipc_accept,
    connect    = ipc_connect,
    disconnect = ipc_disconnect,
    shutdown   = ipc_shutdown,
}

create_ipc_transport :: proc() -> (^IPC_Transport, bool) {
    t := new(IPC_Transport)
    
    name_wstring := windows.utf8_to_wstring(SHARED_MEMORY_NAME)
    size := size_of(SharedMemoryBlock)
    
    t.handle = CreateFileMappingW(
        windows.INVALID_HANDLE_VALUE,
        nil,
        PAGE_READWRITE,
        0,
        windows.DWORD(size),
        name_wstring,
    )
    
    if t.handle == nil {
        free(t)
        return nil, false
    }
    
    t.block = (^SharedMemoryBlock)(MapViewOfFile(t.handle, FILE_MAP_ALL_ACCESS, 0, 0, windows.SIZE_T(size)))
    if t.block == nil {
        windows.CloseHandle(t.handle)
        free(t)
        return nil, false
    }
    
    // Initialize vtable
    t.vtable = &IPC_VTABLE
    
    return t, true
}

ipc_send :: proc(t: ^Transport, peer: PeerID, data: []u8) -> bool {
    it := (^IPC_Transport)(t)
    
    // In IPC, send usually means pushing to entity_ring (Game -> Client)
    if len(data) != size_of(Command) {
        fmt.printf("[IPC] Error: Data size mismatch for Command (Got %d, Expected %d)\n", len(data), size_of(Command))
        return false 
    }
    
    cmd := (^Command)(&data[0])^
    
    // Push to entity_ring (Game -> Client)
    head := sync.atomic_load(&it.block.entity_ring.head)
    tail := sync.atomic_load(&it.block.entity_ring.tail)
    next_head := (head + 1) % ENTITY_RING_SIZE
    
    if next_head == tail {
        return false // Full
    }
    
    it.block.entity_ring.commands[head] = cmd
    sync.atomic_store(&it.block.entity_ring.head, next_head)
    return true
}

ipc_recv :: proc(t: ^Transport, buffer: []u8) -> (PeerID, int, bool) {
    it := (^IPC_Transport)(t)
    
    if len(buffer) < size_of(Command) { return 0, 0, false }
    
    // Pop from input_ring (Client -> Game)
    head := sync.atomic_load(&it.block.input_ring.head)
    tail := sync.atomic_load(&it.block.input_ring.tail)
    
    if head == tail {
        return 0, 0, false // Empty
    }
    
    cmd := it.block.input_ring.commands[tail]
    mem.copy(&buffer[0], &cmd, size_of(Command))
    
    sync.atomic_store(&it.block.input_ring.tail, (tail + 1) % INPUT_RING_SIZE)
    
    return 0, size_of(Command), true // PeerID 0 for local client
}

ipc_poll :: proc(t: ^Transport, timeout_ms: i32) -> []TransportEvent {
    // For now, always return Data if anything is in the buffer
    // This is a simplified poll
    it := (^IPC_Transport)(t)
    if it.block.input_ring.head != it.block.input_ring.tail {
        it.events[0] = .Data
        return it.events[:]
    }
    return nil
}

ipc_accept :: proc(t: ^Transport) -> (PeerID, bool) {
    return 0, false // IPC doesn't use accept/connect in the same way
}

ipc_connect :: proc(t: ^Transport, address: string) -> (PeerID, bool) {
    return 0, true // Always "connected" to the shared memory
}

ipc_disconnect :: proc(t: ^Transport, peer: PeerID) {
    // No-op for IPC
}

ipc_shutdown :: proc(t: ^Transport) {
    it := (^IPC_Transport)(t)
    if it.block != nil {
        UnmapViewOfFile(it.block)
    }
    if it.handle != nil {
        windows.CloseHandle(it.handle)
    }
    free(it)
}

// Special method for writing frames (not part of generic interface yet, but needed for transition)
ipc_write_frame :: proc(t: ^Transport, data: []u8, frame_number: u64) {
    it := (^IPC_Transport)(t)
    
    idx := i32(frame_number % RING_BUFFER_SIZE)
    slot := &it.block.frames[idx]
    
    slot.frame_number = frame_number
    slot.timestamp = 0 // Needs real timestamp
    slot.data_size = u32(len(data))
    
    copy_size := min(len(data), MAX_FRAME_SIZE)
    mem.copy(&slot.data[0], &data[0], copy_size)
    
    sync.atomic_store(&it.block.latest_frame_index, idx)
}
