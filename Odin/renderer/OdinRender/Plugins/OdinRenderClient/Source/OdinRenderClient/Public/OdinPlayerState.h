// OdinPlayerState.h
// PlayerState that synchronizes player data from Odin
// Copyright Nguyen Phi Hung. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "GameFramework/PlayerState.h"
#include "OdinPlayerState.generated.h"

// Player state data struct for Odin sync (distinct from generated UOdinPlayerData)
USTRUCT(BlueprintType)
struct ODINRENDERCLIENT_API FOdinPlayerStateData {
    GENERATED_BODY()

    UPROPERTY(BlueprintReadWrite, Category = "OdinPlayer")
    FVector2D Position = FVector2D::ZeroVector;

    UPROPERTY(BlueprintReadWrite, Category = "OdinPlayer")
    float Rotation = 0.0f;

    UPROPERTY(BlueprintReadWrite, Category = "OdinPlayer")
    int32 Health = 100;

    UPROPERTY(BlueprintReadWrite, Category = "OdinPlayer")
    int32 MaxHealth = 100;

    UPROPERTY(BlueprintReadWrite, Category = "OdinPlayer")
    bool bIsAlive = true;
};

DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FOdinPlayerDataChanged, const FOdinPlayerStateData&, NewData);
DECLARE_DYNAMIC_MULTICAST_DELEGATE_TwoParams(FOdinPlayerHealthChanged, int32, NewHealth, int32, MaxHealth);
DECLARE_DYNAMIC_MULTICAST_DELEGATE(FOdinPlayerDied);

UCLASS()
class ODINRENDERCLIENT_API AOdinPlayerState : public APlayerState {
    GENERATED_BODY()

public:
    AOdinPlayerState();

    // Update player data from Odin (called by GameMode)
    UFUNCTION(BlueprintCallable, Category = "OdinPlayer")
    void UpdateFromOdinData(FVector2D Position, float Rotation, int32 Health);

    // Full data update
    UFUNCTION(BlueprintCallable, Category = "OdinPlayer")
    void SetPlayerData(const FOdinPlayerStateData& NewData);

    // Get current player data
    UFUNCTION(BlueprintPure, Category = "OdinPlayer")
    const FOdinPlayerStateData& GetPlayerData() const { return PlayerData; }

    // Convenience accessors
    UFUNCTION(BlueprintPure, Category = "OdinPlayer")
    FVector2D GetOdinPosition() const { return PlayerData.Position; }

    UFUNCTION(BlueprintPure, Category = "OdinPlayer")
    float GetOdinRotation() const { return PlayerData.Rotation; }

    UFUNCTION(BlueprintPure, Category = "OdinPlayer")
    int32 GetOdinHealth() const { return PlayerData.Health; }

    UFUNCTION(BlueprintPure, Category = "OdinPlayer")
    bool IsOdinPlayerAlive() const { return PlayerData.bIsAlive; }

    // Events
    UPROPERTY(BlueprintAssignable, Category = "OdinPlayer|Events")
    FOdinPlayerDataChanged OnPlayerDataChanged;

    UPROPERTY(BlueprintAssignable, Category = "OdinPlayer|Events")
    FOdinPlayerHealthChanged OnHealthChanged;

    UPROPERTY(BlueprintAssignable, Category = "OdinPlayer|Events")
    FOdinPlayerDied OnPlayerDied;

protected:
    UPROPERTY(BlueprintReadOnly, Category = "OdinPlayer")
    FOdinPlayerStateData PlayerData;

    // Track previous health for change detection
    int32 PreviousHealth = 100;
};

