// OdinClientSubsystem.cpp
// Copyright Nguyen Phi Hung. All Rights Reserved.

#include "OdinClientSubsystem.h"

#if PLATFORM_WINDOWS
#include "Windows/AllowWindowsPlatformTypes.h"
#include "Windows/HideWindowsPlatformTypes.h"
#include <windows.h>
#endif

void UOdinClientSubsystem::Initialize(FSubsystemCollectionBase& Collection) {
    Super::Initialize(Collection);
}

void UOdinClientSubsystem::Deinitialize() {
    DisconnectFromOdin();
    Super::Deinitialize();
}

bool UOdinClientSubsystem::ConnectToOdin(FString SharedMemoryName) {
    if (SharedMemory != nullptr) return true;

#if PLATFORM_WINDOWS
    SharedMemoryHandle = OpenFileMappingW(FILE_MAP_ALL_ACCESS, false, *SharedMemoryName);
    if (!SharedMemoryHandle) {
        UE_LOG(LogTemp, Error, TEXT("Failed to open shared memory: %s"), *SharedMemoryName);
        return false;
    }

    SharedMemory = static_cast<FOdinSharedMemoryBlock*>(
        MapViewOfFile(SharedMemoryHandle, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(FOdinSharedMemoryBlock))
    );

    if (!SharedMemory) {
        CloseHandle(SharedMemoryHandle);
        SharedMemoryHandle = nullptr;
        return false;
    }

    UE_LOG(LogTemp, Log, TEXT("Connected to Odin shared memory: %s"), *SharedMemoryName);
    OnConnected.Broadcast();
    return true;
#else
    return false;
#endif
}

void UOdinClientSubsystem::DisconnectFromOdin() {
#if PLATFORM_WINDOWS
    if (SharedMemory) {
        UnmapViewOfFile(SharedMemory);
        SharedMemory = nullptr;
    }
    if (SharedMemoryHandle) {
        CloseHandle(SharedMemoryHandle);
        SharedMemoryHandle = nullptr;
    }
    OnDisconnected.Broadcast();
#endif
}

const FOdinSharedMemoryBlock::FrameSlot* UOdinClientSubsystem::GetLatestFrameSlot() const {
    if (!SharedMemory) return nullptr;

    int32 LatestIndex = FPlatformAtomics::AtomicRead(&SharedMemory->LatestFrameIndex);
    if (LatestIndex < 0 || LatestIndex >= ODIN_RING_BUFFER_SIZE) return nullptr;

    return &SharedMemory->Frames[LatestIndex];
}

// ========================================
// Command Buffer Implementation
// ========================================

FOdinCommand UOdinClientSubsystem::MakeCommand(uint8 Type, float V0, float V1, float V2, float V3, const FString& Data) {
    FOdinCommand Cmd;
    FMemory::Memzero(&Cmd, sizeof(FOdinCommand));
    
    Cmd.Type = Type;
    Cmd.Values[0] = V0;
    Cmd.Values[1] = V1;
    Cmd.Values[2] = V2;
    Cmd.Values[3] = V3;
    
    // Copy string data
    FTCHARToUTF8 Utf8Data(*Data);
    int32 DataLen = FMath::Min(Utf8Data.Length(), ODIN_COMMAND_DATA_SIZE);
    FMemory::Memcpy(Cmd.Data, Utf8Data.Get(), DataLen);
    Cmd.DataLength = static_cast<uint16>(DataLen);
    
    return Cmd;
}

bool UOdinClientSubsystem::PushCommand(TOdinCommandRing<ODIN_INPUT_RING_SIZE>& Ring, const FOdinCommand& Cmd) {
    int32 Head = FPlatformAtomics::AtomicRead(&Ring.Head);
    int32 Tail = FPlatformAtomics::AtomicRead(&Ring.Tail);
    int32 NextHead = (Head + 1) % ODIN_INPUT_RING_SIZE;
    
    if (NextHead == Tail) {
        return false; // Full
    }
    
    Ring.Commands[Head] = Cmd;
    FPlatformAtomics::InterlockedExchange(&Ring.Head, NextHead);
    return true;
}

bool UOdinClientSubsystem::PopCommand(TOdinCommandRing<ODIN_ENTITY_RING_SIZE>& Ring, FOdinCommand& OutCmd) {
    int32 Head = FPlatformAtomics::AtomicRead(&Ring.Head);
    int32 Tail = FPlatformAtomics::AtomicRead(&Ring.Tail);
    
    if (Head == Tail) {
        return false; // Empty
    }
    
    OutCmd = Ring.Commands[Tail];
    FPlatformAtomics::InterlockedExchange(&Ring.Tail, (Tail + 1) % ODIN_ENTITY_RING_SIZE);
    return true;
}

bool UOdinClientSubsystem::PushInputCommand(FName InputName, float AxisX, float AxisY, float Button) {
    if (!SharedMemory) return false;
    
    FOdinCommand Cmd = MakeCommand(ODIN_CMD_INPUT, AxisX, AxisY, Button, 0.f, InputName.ToString());
    return PushCommand(SharedMemory->InputRing, Cmd);
}

bool UOdinClientSubsystem::PushGameCommand(float GameState, FName StateName) {
    if (!SharedMemory) return false;
    
    FOdinCommand Cmd = MakeCommand(ODIN_CMD_GAME, GameState, 0.f, 0.f, 0.f, StateName.ToString());
    return PushCommand(SharedMemory->InputRing, Cmd);
}

bool UOdinClientSubsystem::HasEntityCommand() const {
    if (!SharedMemory) return false;
    
    int32 Head = FPlatformAtomics::AtomicRead(&SharedMemory->EntityRing.Head);
    int32 Tail = FPlatformAtomics::AtomicRead(&SharedMemory->EntityRing.Tail);
    return Head != Tail;
}

bool UOdinClientSubsystem::PopEntityCommand(FOdinCommand& OutCommand) {
    if (!SharedMemory) return false;
    
    return PopCommand(SharedMemory->EntityRing, OutCommand);
}
