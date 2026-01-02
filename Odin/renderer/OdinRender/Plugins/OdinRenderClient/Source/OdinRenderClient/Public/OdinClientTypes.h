// OdinClientTypes.h
// Generic definitions for Odin Render Client Plugin
// Copyright Nguyen Phi Hung. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "OdinClientTypes.generated.h"

// Ring Buffer Constants
#define ODIN_RING_BUFFER_SIZE 64
#define ODIN_INPUT_RING_SIZE 16
#define ODIN_ENTITY_RING_SIZE 64
#define ODIN_EVENT_QUEUE_SIZE 16
#define ODIN_MAX_FRAME_SIZE (1024 * 16)
#define ODIN_COMMAND_DATA_SIZE 20

// Command Type Bit Flags
// Direction bits (high nibble)
#define ODIN_CMD_DIR_CLIENT_TO_GAME  0x80
#define ODIN_CMD_DIR_GAME_TO_CLIENT  0x40

// Client -> Game Commands (0x8X)
#define ODIN_CMD_INPUT           0x81  // Data: input_name, Values: axis/button
#define ODIN_CMD_GAME            0x82  // Values[0]: 1=start, -1=end, 0=state; Data: state_name

// Game -> Client Commands (0x4X)
#define ODIN_CMD_ENTITY_SPAWN    0x41  // Data: class, Values: x,y,z,yaw
#define ODIN_CMD_ENTITY_DESTROY  0x42  // Data: entityId
#define ODIN_CMD_ENTITY_UPDATE   0x43  // Data: serialized FB, Values: x,y,z,visible
#define ODIN_CMD_PLAYER_UPDATE   0x44  // Data: serialized FB, Values: x,y,z,visible
#define ODIN_CMD_PLAYER_ACTION   0x45  // Data: serialized FB (skill/ability)
#define ODIN_CMD_EVENT_GAMEPLAY  0x46  // Data: cue_name, Values: params

// Unified Command Structure (40 bytes) - Shared Memory Layout (POD)
#pragma pack(push, 1)
struct FOdinCommand {
    uint8 Type;                          // Command type (bit flags)
    uint8 Flags;                         // Reserved for future use
    uint16 DataLength;                   // Length of valid data in Data field
    float Values[4];                     // Generic float4 (position, axis, params)
    char Data[ODIN_COMMAND_DATA_SIZE];   // Name, ID, or serialized FlatBuffer
};
#pragma pack(pop)
static_assert(sizeof(FOdinCommand) == 40, "FOdinCommand must be 40 bytes");

// Blueprint-friendly Command Struct
USTRUCT(BlueprintType)
struct FBPOdinCommand {
    GENERATED_BODY()

    UPROPERTY(BlueprintReadOnly, Category = "Odin")
    uint8 Type = 0;

    UPROPERTY(BlueprintReadOnly, Category = "Odin")
    int32 DataLength = 0;

    UPROPERTY(BlueprintReadOnly, Category = "Odin")
    FVector4 Values = FVector4(0,0,0,0);

    UPROPERTY(BlueprintReadOnly, Category = "Odin")
    FString DataString;
    
    // Helper to convert from raw
    static FBPOdinCommand FromRaw(const FOdinCommand& Raw) {
        FBPOdinCommand Cmd;
        Cmd.Type = Raw.Type;
        Cmd.DataLength = Raw.DataLength;
        Cmd.Values = FVector4(Raw.Values[0], Raw.Values[1], Raw.Values[2], Raw.Values[3]);
        if (Raw.DataLength > 0) {
            Cmd.DataString = FString(UTF8_TO_TCHAR(Raw.Data));
        }
        return Cmd;
    }
};

// Command Ring Buffer
#pragma pack(push, 1)
template<int32 Size>
struct TOdinCommandRing {
    volatile int32 Head;
    volatile int32 Tail;
    FOdinCommand Commands[Size];
};
#pragma pack(pop)

// Shared Memory Layout
struct FOdinSharedMemoryBlock {

    struct FrameSlot {
        uint64 FrameNumber;
        double Timestamp;
        uint32 DataSize;
        uint8 Data[ODIN_MAX_FRAME_SIZE]; // Raw FlatBuffer bytes
    };

    FrameSlot Frames[ODIN_RING_BUFFER_SIZE];
    int32 LatestFrameIndex; // Atomic

    // Command Rings (unified command system)
    TOdinCommandRing<ODIN_INPUT_RING_SIZE> InputRing;   // Client -> Game
    TOdinCommandRing<ODIN_ENTITY_RING_SIZE> EntityRing; // Game -> Client
};

// Delegates
DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FOdinCommandDelegate, const FBPOdinCommand&, Command);
DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FOdinEntitySpawnDelegate, const FBPOdinCommand&, Command);
DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FOdinEntityDestroyDelegate, const FBPOdinCommand&, Command);
DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FOdinEntityUpdateDelegate, const FBPOdinCommand&, Command);
DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FOdinPlayerUpdateDelegate, const FBPOdinCommand&, Command);
DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FOdinGameplayEventDelegate, const FBPOdinCommand&, Command);
DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FOdinFrameReceivedDelegate, const int64, FrameNumber);

