// VampireSurvivalSubsystem.h
// Game Logic Subsystem - Wraps generic connection for typed access
// Copyright Nguyen Phi Hung. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "OdinLinkedSubsystem.h"
#include "Generated/GameStateWrappers.h"
#include "VampireSurvivalSubsystem.generated.h"

UCLASS()
class ODINRENDER_API UVampireSurvivalSubsystem : public UOdinLinkedSubsystem {
    GENERATED_BODY()

public:
    // Initialize handled by Base (Dependency Injection)

    UFUNCTION(BlueprintCallable, Category = "VampireSurvival")
    bool ConnectToOdinDefault(); // Helper for default name

    UFUNCTION(BlueprintCallable, Category = "VampireSurvival")
    void SendStartGame();
    
    UFUNCTION(BlueprintCallable, Category = "VampireSurvival")
    void SendEndGame();
    
    UFUNCTION(BlueprintCallable, Category = "VampireSurvival")
    void SendPlayerInput(float MoveX, float MoveY);

    const FGameStateWrapper& UpdateAndGetState();

    UFUNCTION(BlueprintPure, Category = "VampireSurvival")
    const FGameStateWrapper& GetLatestGameState() const;

    UFUNCTION(BlueprintPure, Category = "VampireSurvival")
    int32 GetLatestFrameNumber() const { return LastReadFrameNumber; }

private:
    UPROPERTY(BlueprintReadOnly, Category = "VampireSurvival", meta = (AllowPrivateAccess = "true"))
    FGameStateWrapper CurrentGameState;
};
