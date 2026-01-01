// OdinLinkedSubsystem.cpp
// Copyright Nguyen Phi Hung. All Rights Reserved.

#include "OdinLinkedSubsystem.h"

void UOdinLinkedSubsystem::Initialize(FSubsystemCollectionBase& Collection) {
    Super::Initialize(Collection);
    OdinClient = Collection.InitializeDependency<UOdinClientSubsystem>();
    // Note: We don't auto-connect here; explicit ConnectToOdin required (or via GameMode)
}

void UOdinLinkedSubsystem::Deinitialize() {
    Super::Deinitialize();
}

bool UOdinLinkedSubsystem::IsConnected() const {
    return OdinClient && OdinClient->IsConnected();
}

bool UOdinLinkedSubsystem::ConnectToOdin(FString SharedMemoryName) {
    if (OdinClient) {
        return OdinClient->ConnectToOdin(SharedMemoryName);
    }
    return false;
}

const FOdinSharedMemoryBlock::FrameSlot* UOdinLinkedSubsystem::TryGetNewFrameSlot() const {
    if (!OdinClient) return nullptr;
    
    const FOdinSharedMemoryBlock::FrameSlot* Slot = OdinClient->GetLatestFrameSlot();
    if (!Slot) return nullptr;

    if (static_cast<int32>(Slot->FrameNumber) <= LastReadFrameNumber) {
        return nullptr;
    }

    return Slot;
}
