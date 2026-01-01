// VampireSurvivalGameMode.h
// Sample GameMode demonstrating Odin integration
// Copyright Nguyen Phi Hung. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "GameFramework/GameModeBase.h"
#include "OdinClientGameMode.h"
#include "Generated/GameStateWrappers.h"
#include "VampireSurvivalGameMode.generated.h"

class UVampireSurvivalSubsystem;

UCLASS()
class ODINRENDER_API AVampireSurvivalGameMode : public AOdinClientGameMode {
  GENERATED_BODY()

public:
  AVampireSurvivalGameMode();

  virtual void BeginPlay() override;
  virtual void Tick(float DeltaTime) override;
  // EndPlay handled by Parent

  // Override Generic Upgrade
  virtual void OnUpdateGameState() override;

  // Blueprint Events
  UFUNCTION(BlueprintImplementableEvent, Category = "VampireSurvival")
  void OnGameStateReceived(FVector2D PlayerPosition, int32 PlayerHealth,
                           int32 Score, int32 EnemyCount, bool bIsActive);

  // Input handling
  UFUNCTION(BlueprintCallable, Category = "VampireSurvival")
  void HandleMoveInput(FVector2D MoveInput);

  UFUNCTION(BlueprintCallable, Category = "VampireSurvival")
  void StartOdinGame();

  UFUNCTION(BlueprintCallable, Category = "VampireSurvival")
  void EndOdinGame();

  // Get raw game state
  UFUNCTION(BlueprintCallable, Category = "VampireSurvival")
  const FGameStateWrapper& GetCachedGameState() const { return CachedGameState; }

protected:
  UPROPERTY()
  UVampireSurvivalSubsystem *Subsystem;

  FVector2D CurrentMoveInput;

  UPROPERTY(BlueprintReadOnly, Category = "VampireSurvival")
  FGameStateWrapper CachedGameState;


  
  // Note: Subsystem now handles delegating connection events
};
