// VampireSurvivalSubsystem.h
// Game Instance Subsystem for managing Shared Memory connection to Odin
// Copyright Nguyen Phi Hung. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "Generated/GameStateWrappers.h"
#include "Subsystems/GameInstanceSubsystem.h"
#include "VampireSurvivalSubsystem.generated.h"
#include "VampireSurvivalTypes.h"

DECLARE_DYNAMIC_MULTICAST_DELEGATE(FOnConnectionChanged);

UCLASS()
class ODINRENDERCLIENT_API UVampireSurvivalSubsystem
    : public UGameInstanceSubsystem {
  GENERATED_BODY()

public:
  virtual void Initialize(FSubsystemCollectionBase &Collection) override;
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

  // State Reading (FlatBuffers)
  // Returns the wrapper for the latest frame. Valid until the next call.
  UFUNCTION(BlueprintPure, Category = "VampireSurvival")
  UGameStateWrapper *GetLatestGameState();

  UFUNCTION(BlueprintPure, Category = "VampireSurvival")
  int32 GetLatestFrameNumber() const { return LastReadFrameNumber; }

  UPROPERTY(BlueprintAssignable, Category = "VampireSurvival")
  FOnConnectionChanged OnConnected;

  UPROPERTY(BlueprintAssignable, Category = "VampireSurvival")
  FOnConnectionChanged OnDisconnected;

private:
  void *SharedMemoryHandle = nullptr;
  FVSSharedMemoryBlock *SharedMemory = nullptr;
  int32 LastReadFrameNumber = -1;

  bool SendEvent(const FVSGameEvent &Event);

  UPROPERTY()
  UGameStateWrapper *CurrentStateWrapper = nullptr;
};
