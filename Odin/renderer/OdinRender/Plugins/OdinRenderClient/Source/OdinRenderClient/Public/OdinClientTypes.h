// OdinClientTypes.h
// Generic definitions for Odin Render Client Plugin
// Copyright Nguyen Phi Hung. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "OdinClientTypes.generated.h"

// Ring Buffer Constants
#define ODIN_RING_BUFFER_SIZE 64
#define ODIN_EVENT_QUEUE_SIZE 16

// Max frame size defined here for generic buffer, must match Odin writer
#define ODIN_MAX_FRAME_SIZE (1024 * 16)

// Generic Event Structure
USTRUCT(BlueprintType)
struct FOdinGameEvent {
    GENERATED_BODY()

    UPROPERTY(BlueprintReadWrite, Category = "Odin")
    int32 EventType;
    
    UPROPERTY(BlueprintReadWrite, Category = "Odin")
    float Param1;
    
    UPROPERTY(BlueprintReadWrite, Category = "Odin")
    float Param2;
};

// Generic Shared Memory Layout (Header + Data Slots)
struct FOdinSharedMemoryBlock {

    struct FrameSlot {
        uint64 FrameNumber;
        double Timestamp;
        uint32 DataSize;
        uint8 Data[ODIN_MAX_FRAME_SIZE]; // Raw FlatBuffer bytes
    };

    FrameSlot Frames[ODIN_RING_BUFFER_SIZE];
    int32 LatestFrameIndex; // Atomic

    // Event Queue (Unreal -> Odin)
    FOdinGameEvent Events[ODIN_EVENT_QUEUE_SIZE];
    int32 EventHead;
    int32 EventTail;
};
