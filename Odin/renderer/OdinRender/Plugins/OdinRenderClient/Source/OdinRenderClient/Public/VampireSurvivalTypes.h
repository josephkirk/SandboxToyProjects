// VampireSurvivalTypes.h
// Shared Memory structures matching Odin layout
// Copyright Nguyen Phi Hung. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"

// Must match Odin struct packing
#ifndef FLATBUFFERS_GENERATED_GAMESTATE_VS_SCHEMA_H_
// Forward declare generated types if header not included locally,
// but we just include it for simplicity in this types header as it's the
// central point.
#include "Generated/GameState_flatbuffer.h"
#endif

// Shared Memory Name
#define VS_SHARED_MEMORY_NAME TEXT("OdinVampireSurvival")

struct FVSSharedMemoryBlock {
  // Ring Buffer for Game State (Odin -> Unreal)
  // Instead of fixed array of structs, we now store raw bytes or aligned
  // FlatBuffers. However, the Ring Buffer structure itself might still be fixed
  // size slots? Or do we stream variable sized buffers?

  // Current Architecture Assumption: Fixed Size Slots.
  // We need a 'Max Frame Size' constant.
  static constexpr int32 MAX_FRAME_SIZE = 1024 * 16; // 16KB per frame limit

  struct FrameSlot {
    uint64 FrameNumber;
    double Timestamp;
    uint32 DataSize;
    uint8 Data[MAX_FRAME_SIZE]; // FlatBuffer binary data
  };

  FrameSlot Frames[RING_BUFFER_SIZE];
  int32 LatestFrameIndex; // Atomic

  // Event Queue (Unreal -> Odin) - Keep as simple packed struct for now?
  // Or convert to FB? Spec didn't explicitly mandate 2-way FB immediately for
  // Input, but let's keep it simple: FB for State (Odin->Unreal), Packed/Simple
  // for Events (Unreal->Odin) to minimize scope creep unless required.
  FVSGameEvent Events[EVENT_QUEUE_SIZE];
  int32 EventHead;
  int32 EventTail;
};

// Shared Memory Name (must match Odin)
#define VS_SHARED_MEMORY_NAME TEXT("OdinVampireSurvival")
