// VampireSurvivalSubsystem.h
// Game Logic Subsystem - Wraps generic connection for typed access
// Copyright Nguyen Phi Hung. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "OdinLinkedSubsystem.h"
#include "Generated/GameStateObjects.h"
#include "VampireSurvivalSubsystem.generated.h"

UCLASS()
class ODINRENDER_API UVampireSurvivalSubsystem : public UOdinLinkedSubsystem {
    GENERATED_BODY()

public:
    virtual void Initialize(FSubsystemCollectionBase& Collection) override;

    UFUNCTION(BlueprintCallable, Category = "VampireSurvival")
    bool ConnectToOdinDefault();

    UFUNCTION(BlueprintCallable, Category = "VampireSurvival")
    void SendStartGame();
    
    UFUNCTION(BlueprintCallable, Category = "VampireSurvival")
    void SendEndGame();
    
    UFUNCTION(BlueprintCallable, Category = "VampireSurvival")
    void SendPlayerInput(float MoveX, float MoveY);

    // Update and get current game state
    UFUNCTION(BlueprintCallable, Category = "VampireSurvival")
    UOdinGameState* UpdateAndGetState();

    UFUNCTION(BlueprintPure, Category = "VampireSurvival")
    UOdinGameState* GetLatestGameState() const { return GameState; }

    UFUNCTION(BlueprintPure, Category = "VampireSurvival")
    int32 GetLatestFrameNumber() const { return LastReadFrameNumber; }

private:
    UPROPERTY()
    UOdinGameState* GameState = nullptr;
};
