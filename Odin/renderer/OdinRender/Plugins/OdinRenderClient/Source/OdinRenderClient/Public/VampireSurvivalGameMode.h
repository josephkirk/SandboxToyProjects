// VampireSurvivalGameMode.h
// Sample GameMode demonstrating Odin integration
// Copyright Nguyen Phi Hung. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "GameFramework/GameModeBase.h"
#include "VampireSurvivalTypes.h"
#include "VampireSurvivalGameMode.generated.h"

class UVampireSurvivalSubsystem;

UCLASS()
class ODINRENDERCLIENT_API AVampireSurvivalGameMode : public AGameModeBase
{
    GENERATED_BODY()

public:
    AVampireSurvivalGameMode();

    virtual void BeginPlay() override;
    virtual void EndPlay(const EEndPlayReason::Type EndPlayReason) override;
    virtual void Tick(float DeltaTime) override;

    // Blueprint Events (using simple types instead of packed struct)
    UFUNCTION(BlueprintImplementableEvent, Category = "VampireSurvival")
    void OnGameStateReceived(FVector2D PlayerPosition, int32 PlayerHealth, int32 Score, int32 EnemyCount, bool bIsActive);

    UFUNCTION(BlueprintImplementableEvent, Category = "VampireSurvival")
    void OnOdinConnected();

    UFUNCTION(BlueprintImplementableEvent, Category = "VampireSurvival")
    void OnOdinDisconnected();

    // Input handling - call from Enhanced Input
    UFUNCTION(BlueprintCallable, Category = "VampireSurvival")
    void HandleMoveInput(FVector2D MoveInput);

    UFUNCTION(BlueprintCallable, Category = "VampireSurvival")
    void StartOdinGame();

    UFUNCTION(BlueprintCallable, Category = "VampireSurvival")
    void EndOdinGame();

    // Get raw game state (C++ only)
    const FVSGameState& GetLatestGameState() const { return CachedGameState; }

protected:
    UPROPERTY()
    UVampireSurvivalSubsystem* Subsystem;

    FVector2D CurrentMoveInput;

    UPROPERTY(EditDefaultsOnly, Category = "VampireSurvival")
    float StatePollingInterval = 0.016f;

    float StatePollingTimer = 0.0f;

    FVSGameState CachedGameState;

private:
    UFUNCTION()
    void OnConnectedCallback();

    UFUNCTION()
    void OnDisconnectedCallback();
};
