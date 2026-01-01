// OdinClientSubsystem.h
// Generic Subsystem for managing Shared Memory connection to Odin
// Copyright Nguyen Phi Hung. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "Subsystems/GameInstanceSubsystem.h"
#include "OdinClientTypes.h"
#include "OdinClientSubsystem.generated.h"

DECLARE_DYNAMIC_MULTICAST_DELEGATE(FOdinConnectionDelegate);

UCLASS()
class ODINRENDERCLIENT_API UOdinClientSubsystem : public UGameInstanceSubsystem {
    GENERATED_BODY()

public:
    virtual void Initialize(FSubsystemCollectionBase& Collection) override;
    virtual void Deinitialize() override;

    UFUNCTION(BlueprintCallable, Category = "OdinClient")
    bool ConnectToOdin(FString SharedMemoryName);

    UFUNCTION(BlueprintCallable, Category = "OdinClient")
    void DisconnectFromOdin();

    UFUNCTION(BlueprintPure, Category = "OdinClient")
    bool IsConnected() const { return SharedMemory != nullptr; }

    // Raw Data Access
    const FOdinSharedMemoryBlock::FrameSlot* GetLatestFrameSlot() const;

    // Generic Event Sending
    UFUNCTION(BlueprintCallable, Category = "OdinClient")
    bool SendEvent(int32 Type, float P1, float P2);

    UPROPERTY(BlueprintAssignable, Category = "OdinClient")
    FOdinConnectionDelegate OnConnected;

    UPROPERTY(BlueprintAssignable, Category = "OdinClient")
    FOdinConnectionDelegate OnDisconnected;

private:
    void* SharedMemoryHandle = nullptr;
    FOdinSharedMemoryBlock* SharedMemory = nullptr;
};
