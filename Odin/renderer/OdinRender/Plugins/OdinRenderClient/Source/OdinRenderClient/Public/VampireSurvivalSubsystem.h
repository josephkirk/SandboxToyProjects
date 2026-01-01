// VampireSurvivalSubsystem.h
// Game Instance Subsystem for managing Shared Memory connection to Odin
// Copyright Nguyen Phi Hung. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "Subsystems/GameInstanceSubsystem.h"
#include "VampireSurvivalTypes.h"
#include "VampireSurvivalSubsystem.generated.h"

DECLARE_DYNAMIC_MULTICAST_DELEGATE(FOnConnectionChanged);

UCLASS()
class ODINRENDERCLIENT_API UVampireSurvivalSubsystem : public UGameInstanceSubsystem
{
    GENERATED_BODY()

public:
    virtual void Initialize(FSubsystemCollectionBase& Collection) override;
    virtual void Deinitialize() override;

    UFUNCTION(BlueprintCallable, Category = "VampireSurvival")
    bool ConnectToOdin();

    UFUNCTION(BlueprintCallable, Category = "VampireSurvival")
    void DisconnectFromOdin();

    UFUNCTION(BlueprintPure, Category = "VampireSurvival")
    bool IsConnected() const { return SharedMemory != nullptr; }

    UFUNCTION(BlueprintCallable, Category = "VampireSurvival")
    void SendStartGame();

    UFUNCTION(BlueprintCallable, Category = "VampireSurvival")
    void SendEndGame();

    UFUNCTION(BlueprintCallable, Category = "VampireSurvival")
    void SendPlayerInput(float MoveX, float MoveY);

    // State Reading (C++ only - returns packed struct)
    bool ReadLatestGameState(FVSGameState& OutState);

    UFUNCTION(BlueprintPure, Category = "VampireSurvival")
    int32 GetLatestFrameNumber() const { return LastReadFrameNumber; }

    UPROPERTY(BlueprintAssignable, Category = "VampireSurvival")
    FOnConnectionChanged OnConnected;

    UPROPERTY(BlueprintAssignable, Category = "VampireSurvival")
    FOnConnectionChanged OnDisconnected;

private:
    void* SharedMemoryHandle = nullptr;
    FVSSharedMemoryBlock* SharedMemory = nullptr;
    int32 LastReadFrameNumber = -1;

    bool SendEvent(const FVSGameEvent& Event);
};
