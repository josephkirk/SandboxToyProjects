// VampireSurvivalGameState.h
// Copyright Nguyen Phi Hung. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "GameFramework/GameStateBase.h"
#include "Generated/GameStateStructs.h"
#include "VampireSurvivalGameState.generated.h"

class UOdinClientSubsystem;

UCLASS()
class ODINRENDER_API AVampireSurvivalGameState : public AGameStateBase {
    GENERATED_BODY()

public:
    AVampireSurvivalGameState();
    
    virtual void BeginPlay() override;
    virtual void EndPlay(const EEndPlayReason::Type EndPlayReason) override;

    UFUNCTION(BlueprintPure, Category = "VampireSurvival")
    const FVSGameState& GetOdinGameState() const { return CachedState; }

protected:
    UPROPERTY(BlueprintReadOnly, Category = "VampireSurvival")
    FVSGameState CachedState;
    
    UFUNCTION()
    void HandleFrameReceived(const int64 FrameNumber);
};
