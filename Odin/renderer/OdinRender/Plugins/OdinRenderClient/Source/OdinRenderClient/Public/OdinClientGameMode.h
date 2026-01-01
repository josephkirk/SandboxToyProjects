// OdinClientGameMode.h
// Generic GameMode for Odin Client Plugin
// Copyright Nguyen Phi Hung. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "GameFramework/GameModeBase.h"
#include "OdinClientGameMode.generated.h"

class UOdinClientSubsystem;

UCLASS()
class ODINRENDERCLIENT_API AOdinClientGameMode : public AGameModeBase {
    GENERATED_BODY()

public:
    AOdinClientGameMode();
    virtual void BeginPlay() override;
    virtual void EndPlay(const EEndPlayReason::Type EndPlayReason) override;

protected:
    UPROPERTY(BlueprintReadOnly, Category = "OdinClient")
    UOdinClientSubsystem* OdinSubsystem;

    UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, Category = "OdinClient")
    FString SharedMemoryName = TEXT("OdinVampireSurvival"); // Default, override in BP

    UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, Category = "OdinClient")
    float StatePollingInterval = 0.016f;

    float StatePollingTimer = 0.0f;

    // Virtual function to be implemented by child classes to fetch and process game state
    virtual void OnUpdateGameState();

    UFUNCTION()
    void HandleConnected();

    UFUNCTION()
    void HandleDisconnected();

    UFUNCTION(BlueprintImplementableEvent, Category = "OdinClient")
    void OnOdinConnected();

    UFUNCTION(BlueprintImplementableEvent, Category = "OdinClient")
    void OnOdinDisconnected();

    // Tick for polling
    virtual void Tick(float DeltaTime) override;
};
