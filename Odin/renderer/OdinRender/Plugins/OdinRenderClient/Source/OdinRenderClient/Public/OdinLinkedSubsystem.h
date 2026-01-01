// OdinLinkedSubsystem.h
// Generic Base Class for Subsystems that consume Odin Data
// Copyright Nguyen Phi Hung. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "Subsystems/GameInstanceSubsystem.h"
#include "OdinClientSubsystem.h"
#include "OdinLinkedSubsystem.generated.h"

// Abstract base class - must be subclassed for specific game logic
UCLASS(Abstract)
class ODINRENDERCLIENT_API UOdinLinkedSubsystem : public UGameInstanceSubsystem {
    GENERATED_BODY()

public:
    virtual void Initialize(FSubsystemCollectionBase& Collection) override;
    virtual void Deinitialize() override;

    UFUNCTION(BlueprintPure, Category = "OdinClient")
    bool IsConnected() const;

    UFUNCTION(BlueprintCallable, Category = "OdinClient")
    bool ConnectToOdin(FString SharedMemoryName);

protected:
    UPROPERTY()
    UOdinClientSubsystem* OdinClient = nullptr;

    int32 LastReadFrameNumber = -1;

    // Helper: Returns slot only if connected, valid, and newer than last read.
    // Does NOT update LastReadFrameNumber (Caller must do that after successful parse)
    const FOdinSharedMemoryBlock::FrameSlot* TryGetNewFrameSlot() const;
};
