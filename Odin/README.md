A project demonstrate writing simple platform game , write to shared memory then use Unreal Engine 5 via Plugin contain gamemode that read shared memory to spawn actor to render the game.

The Strategy: Circular Buffer of States
Instead of two buffers, you create a ring of, say, 64 buffers in shared memory. Each buffer is tagged with a Frame Number (Sequence Number) and a Timestamp.

Odin (Producer): Constantly writes new frames into the next available slot in the ring.

Unreal (Consumer): Tracks which FrameNumber it last rendered. If it hitches for 50ms, it looks at the buffer, sees it is 3 frames behind, and can decide to either "skip to latest" or "playback" the missing frames to maintain smooth animation.

2. Odin Implementation (The Recorder)
In Odin, you manage the "Head" of the circular buffer.

Code snippet

SharedState :: struct {
    latest_index: i32,             // Atomic: The very latest frame produced
    frames: [64]FrameSlot,         // The ring of data
}

FrameSlot :: struct {
    frame_number: u64,
    timestamp:    f64,
    data:         [1024 * 512]u8, // FlatBuffer blob
}

// Odin Core Loop
update_shared_memory :: proc(state: ^SharedState, fb_data: []u8, frame_num: u64) {
    // 1. Calculate the next slot in the ring
    next_idx := (state.latest_index + 1) % 64
    
    // 2. Copy data into the slot
    slot := &state.frames[next_idx]
    slot.frame_number = frame_num
    slot.timestamp    = current_time()
    copy(slot.data[:], fb_data)
    
    // 3. Atomically update the latest index
    intrinsics.atomic_store(&state.latest_index, next_idx)
}
3. Unreal Implementation (The Playback Engine)
Unreal acts as the "Time Manager." If it detects it's behind, it can "catch up" gracefully.

C++

// Unreal C++ Tick
void AMyRenderer::Tick(float DeltaTime) {
    int32 LatestIdx = SharedStatePtr->latest_index;
    u64 LatestFrameNum = SharedStatePtr->frames[LatestIdx].frame_number;

    if (LatestFrameNum > LastRenderedFrameNum) {
        // Option A: Skip to latest (Teleport)
        // LastRenderedFrameNum = LatestFrameNum;
        
        // Option B: Process all missed frames (Playback/Simulation)
        for (u64 f = LastRenderedFrameNum + 1; f <= LatestFrameNum; ++f) {
            int32 SlotIdx = FindSlotByFrameNumber(f); // Check the ring for this frame
            auto FrameData = EngineProtocol::GetFramePacket(SharedStatePtr->frames[SlotIdx].data);
            
            // Apply physics/logic updates for this missed frame
            SimulateFrame(FrameData);
        }
        LastRenderedFrameNum = LatestFrameNum;
    }
}
4. Why this handles "Hitches" and "Playback"
Catch-up Logic: If Unreal freezes for 10 frames, when it wakes up, it sees LatestFrameNum is 10 higher than its last check. Because you have a Circular Buffer, those 10 frames are still sitting in memory waiting to be read.

Interpolation: With a history of frames, Unreal can actually interpolate between Frame 100 and Frame 101. This makes the game look like it's running at 144Hz even if your Odin logic core is only ticking at 60Hz.

Network Replay: This is the exact same foundation used for Rollback Netcode. If a network packet arrives late, you look back into your history buffer, find the frame where the input happened, and "re-simulate" forward.

5. Input 
Input should be setup in Unreal using Enhance Input system then send to odin game