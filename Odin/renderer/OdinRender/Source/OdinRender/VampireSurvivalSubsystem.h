// VampireSurvivalSubsystem.h
// Game Logic Subsystem - Wraps generic connection for typed access
// Copyright Nguyen Phi Hung. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "Subsystems/GameInstanceSubsystem.h"
#include "OdinClientSubsystem.h"
#include "Generated/GameStateWrappers.h"
#include "VampireSurvivalSubsystem.generated.h"

UCLASS()
class ODINRENDER_API UVampireSurvivalSubsystem : public UGameInstanceSubsystem {
    GENERATED_BODY()

public:
    virtual void Initialize(FSubsystemCollectionBase& Collection) override;
    virtual void Deinitialize() override;

    UFUNCTION(BlueprintPure, Category = "VampireSurvival")
    bool IsConnected() const;

    UFUNCTION(BlueprintCallable, Category = "VampireSurvival")
    bool ConnectToOdin(); // Helper to connect via generic subsystem

    UFUNCTION(BlueprintCallable, Category = "VampireSurvival")
    void SendStartGame();
    
    UFUNCTION(BlueprintCallable, Category = "VampireSurvival")
    void SendEndGame();
    
    UFUNCTION(BlueprintCallable, Category = "VampireSurvival")
    void SendPlayerInput(float MoveX, float MoveY);

    const FGameStateWrapper& UpdateAndGetState();

    // Typed State Access - Returns copy for BP or reference
    // Better to return by const ref for C++, but for BP we might need value or const ref wrapper?
    // USTRUCTs in BP are passed by value usually.
    UFUNCTION(BlueprintPure, Category = "VampireSurvival")
    const FGameStateWrapper& GetLatestGameState() const;

    UFUNCTION(BlueprintPure, Category = "VampireSurvival")
    int32 GetLatestFrameNumber() const { return LastReadFrameNumber; }

private:
    UPROPERTY()
    UOdinClientSubsystem* OdinClient = nullptr;

    UPROPERTY(BlueprintReadOnly, Category = "VampireSurvival", meta = (AllowPrivateAccess = "true"))
    FGameStateWrapper CurrentGameState;
    
    int32 LastReadFrameNumber = -1;
};
