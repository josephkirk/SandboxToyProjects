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

bool UOdinClientSubsystem::SendEvent(int32 Type, float P1, float P2) {
    if (!SharedMemory) return false;

    // Atomic generic event push
    int32 Head = FPlatformAtomics::AtomicRead(&SharedMemory->EventHead);
    int32 Tail = FPlatformAtomics::AtomicRead(&SharedMemory->EventTail);
    int32 NextHead = (Head + 1) % ODIN_EVENT_QUEUE_SIZE;

    if (NextHead == Tail) return false; // Full

    SharedMemory->Events[Head].EventType = Type;
    SharedMemory->Events[Head].Param1 = P1;
    SharedMemory->Events[Head].Param2 = P2;

    FPlatformAtomics::InterlockedExchange(&SharedMemory->EventHead, NextHead);
    return true;
}
