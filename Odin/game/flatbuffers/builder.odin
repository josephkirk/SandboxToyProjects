package flatbuffers

import "core:mem"
import "core:fmt"

Offset :: distinct u32

Builder :: struct {
    bytes: [dynamic]byte,
    minalign: int,
    vtable: [dynamic]u16,
    vtables: [dynamic]int, // offsets of used vtables
    object_end: int,
    vt_use: int, // how many fields in current vtable
}

init_builder :: proc() -> Builder {
    return Builder{
        bytes = make([dynamic]byte, 0, 1024),
        minalign = 1,
        vtable = make([dynamic]u16, 0, 16),
        vtables = make([dynamic]int, 0, 16),
    }
}

init_builder_reuse :: proc(b: ^Builder) {
    if b.bytes == nil {
        b.bytes = make([dynamic]byte, 0, 1024)
    } else {
        clear(&b.bytes)
    }
    
    if b.vtable == nil { b.vtable = make([dynamic]u16, 0, 16) }
    else { clear(&b.vtable) }
    
    if b.vtables == nil { b.vtables = make([dynamic]int, 0, 16) }
    else { clear(&b.vtables) }
    
    b.minalign = 1
    b.object_end = 0
    b.vt_use = 0
}

// Helpers to write to back
push_bytes :: proc(b: ^Builder, data: []byte) {
    // Naive forward-growing implementation? 
    // Std Flatbuffers builds back-to-front. 
    // Implementation Detail: This mini-builder uses BACK-TO-FRONT logic simulation 
    // by reversing at the end? NO, standard FB must be back-to-front for offsets to work.
    // So we append to `bytes` but treat it as growing from high address?
    // Let's implement APPEND, and REVERSE? No, easier to just Append Backwards.
    // 'bytes' stores the buffer from [end] to [start].
    // Final buffer = reverse(bytes).
    
    // Simplification for prototype: USE FORWARD BUILDER if schema allows?
    // FB format strictly requires offsets to be relative. 
    // IF we build forward, we don't know offsets of future objects.
    // So BACK-TO-FRONT is required.
    
    // In this Builder, `bytes` contains the data in REVERSE order.
    // i.e. The last byte of the message is bytes[0].
    
    for i := len(data)-1; i >= 0; i -= 1 {
        append(&b.bytes, data[i])
    }
}

push_u32 :: proc(b: ^Builder, v: u32) {
    v_le := v // assume little endian host or todo: swap
    d: [4]byte = transmute([4]byte)v_le
    // Reverse because `push_bytes` reverses again?
    // push_bytes(b, d[:]) calls append(d[3]), then d[2]...
    // So bytes in memory: d[3], d[2], d[1], d[0].
    // If output is reversed: d[0], d[1], d[2], d[3]. Correct LE.
    push_bytes(b, d[:])
}

push_i32 :: proc(b: ^Builder, v: i32) { push_u32(b, transmute(u32)v) }
push_u16 :: proc(b: ^Builder, v: u16) {
    d: [2]byte = transmute([2]byte)v
    push_bytes(b, d[:])
}

// Alignment
pad :: proc(b: ^Builder, n: int) {
    for i in 0..<n { append(&b.bytes, 0) }
}

prep :: proc(b: ^Builder, size: int, additional_bytes: int) {
    // Align based on current size
    // total_len := len(b.bytes) + additional_bytes
    // needed := total_len % size ...
    // This logic is tricky.
    // Simplification: Align to 4 bytes always?
    // Only 4 bytes needed for this schema.
    for (len(b.bytes) + additional_bytes) % size != 0 {
        append(&b.bytes, 0)
    }
}

// Structs
prepend_struct_slot :: proc(b: ^Builder, idx: int, s: $T) {
    prep(b, align_of(T), size_of(T))
    // Raw copy struct
    data := transmute([size_of(T)]byte)s
    push_bytes(b, data[:])
    track_field(b, idx)
}

// Scalars
prepend_int32_slot :: proc(b: ^Builder, idx: int, v: i32, def: i32) {
    if v == def { return }
    prep(b, 4, 0)
    push_i32(b, v)
    track_field(b, idx)
}

prepend_float32_slot :: proc(b: ^Builder, idx: int, v: f32, def: f32) {
    if v == def { return }
    prep(b, 4, 0)
    push_u32(b, transmute(u32)v)
    track_field(b, idx)
}

prepend_bool_slot :: proc(b: ^Builder, idx: int, v: bool, def: bool) {
    if v == def { return }
    prep(b, 1, 0)
    val: byte = 0; if v { val = 1 }
    append(&b.bytes, val)
    track_field(b, idx)
}

// Offsets (Tables/Strings)
prepend_offset :: proc(b: ^Builder, off: Offset) {
    prep(b, 4, 0)
    // Relative offset: (Current Buf Size) - off + 4 (sizeof offset)
    // Wait, off is "bytes from TAIL". 
    // We are writing at HEAD. 
    // Relative offset = (Current Pos) - (Target Pos).
    // Current Pos = len(b.bytes).
    // offset to write = len(b.bytes) - off + 4? No.
    // Let's assume `off` is index in `bytes`. 
    // Relative = len(b.bytes) - off.
    
    rel := u32(len(b.bytes)) - u32(off) + 4
    push_u32(b, rel)
}

prepend_offset_slot :: proc(b: ^Builder, idx: int, off: Offset) {
    if off == 0 { return }
    prepend_offset(b, off)
    track_field(b, idx)
}

// Tables
start_table :: proc(b: ^Builder, num_fields: int) {
    b.object_end = len(b.bytes)
    clear(&b.vtable)
    resize(&b.vtable, num_fields)
    b.vt_use = num_fields
}

track_field :: proc(b: ^Builder, idx: int) {
    // Current offset from object_end
    off := u16(len(b.bytes) - b.object_end)
    if idx < len(b.vtable) {
        b.vtable[idx] = off
    }
}

end_table :: proc(b: ^Builder) -> Offset {
    // Write VTable
    // Compact: Trim trailing zeros
    // Write VTable header (size of vt, size of obj)
    
    // Simplification: Write standard vtable
    // 1. Prepend vtable bytes
    // 2. Prepend vtable offset
    
    // Write vtable entries (reversed)
    for i := len(b.vtable)-1; i >= 0; i -= 1 {
        push_u16(b, b.vtable[i])
    }
    
    // Write header
    vt_len := u16((len(b.vtable) + 2) * 2)
    obj_len := u16(len(b.bytes) - b.object_end)
    push_u16(b, obj_len)
    push_u16(b, vt_len)
    
    vt_off := u32(len(b.bytes))
    
    // Write SOF (Scalar Offset to Field? No, SOF to VTable)
    // We need to write the Offset to Vtable at the beginning of the object.
    
    // This is getting complex to reimplement perfectly.
    // TRICK: Just write inline vtable for now? 
    // Standard FB dedupes vtables. We won't dedupe for V1.
    
    // Patch the object: we need to write an i32 offset to THIS vtable
    // at b.object_end location? No.
    // Use `prepend_int32` is for fields.
    
    // The table starts with `SOF` (i32 offset to vtable).
    // We just wrote vtable. It is at `vt_off`.
    // We need to write `vt_off - object_end` as an i32.
    
    rel_vt := i32(vt_off) - i32(b.object_end)
    push_i32(b, rel_vt)
    
    return Offset(b.object_end) 
}

// Vectors
start_vector :: proc(b: ^Builder, elem_size: int, num_elems: int, align: int) {
    prep(b, align, elem_size * num_elems)
}

end_vector :: proc(b: ^Builder, num_elems: int) -> Offset {
    push_u32(b, u32(num_elems))
    return Offset(len(b.bytes))
}

// Finish
finish :: proc(b: ^Builder, root: Offset) -> []byte {
    prep(b, 4, 0) // Align
    // Write root table offset
    rel := u32(len(b.bytes)) - u32(root) + 4
    push_u32(b, rel)
    
    // Reverse bytes
    res := make([]byte, len(b.bytes))
    for i in 0..<len(b.bytes) {
        res[i] = b.bytes[len(b.bytes)-1-i]
    }
    return res
}
