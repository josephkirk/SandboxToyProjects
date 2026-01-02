// OdinClientGameMode.h
// Generic GameMode for Odin Client Plugin with Player Spawning and Actor Pooling
// Copyright Nguyen Phi Hung. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "GameFramework/GameModeBase.h"
#include "OdinClientGameMode.generated.h"

class UOdinClientSubsystem;
class AOdinPlayerState;

UCLASS()
class ODINRENDERCLIENT_API AOdinClientGameMode : public AGameModeBase {
    GENERATED_BODY()

public:
    AOdinClientGameMode();

    virtual void BeginPlay() override;
    virtual void EndPlay(const EEndPlayReason::Type EndPlayReason) override;
    
    // ========== Game Lifecycle (Odin) ==========
    
    UFUNCTION(BlueprintCallable, Category = "OdinClient|Lifecycle")
    void StartOdinGame();

    UFUNCTION(BlueprintCallable, Category = "OdinClient|Lifecycle")
    void EndOdinGame();

    // ========== Player Management ==========
    
    // Spawn the player actor (override in subclass for custom player class)
    UFUNCTION(BlueprintCallable, Category = "OdinClient|Player")
    virtual AActor* SpawnPlayerActor(TSubclassOf<AActor> PlayerClass, FTransform SpawnTransform);
    
    // Get the spawned player actor
    UFUNCTION(BlueprintPure, Category = "OdinClient|Player")
    AActor* GetPlayerActor() const { return PlayerActor; }
    
    // Get the Odin player state (created automatically)
    UFUNCTION(BlueprintPure, Category = "OdinClient|Player")
    AOdinPlayerState* GetOdinPlayerState() const { return OdinPlayerState; }

protected:
    UPROPERTY(VisibleAnywhere, BlueprintReadOnly, Category = "Odin")
    class UOdinClientActorManagerComponent* ActorManager;

    UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, Category = "OdinClient")
    FString SharedMemoryName = TEXT("OdinVampireSurvival");
    
    // The spawned player actor
    UPROPERTY(BlueprintReadOnly, Category = "OdinClient|Player")
    AActor* PlayerActor;
    
    // The Odin player state for data synchronization
    UPROPERTY(BlueprintReadOnly, Category = "OdinClient|Player")
    AOdinPlayerState* OdinPlayerState;

    // Helper to get subsystem without storing it
    UOdinClientSubsystem* GetOdinSubsystem() const;
    
    UFUNCTION()
    void HandleConnected();

    UFUNCTION()
    void HandleDisconnected();

    UFUNCTION(BlueprintImplementableEvent, Category = "OdinClient")
    void OnOdinConnected();

    UFUNCTION(BlueprintImplementableEvent, Category = "OdinClient")
    void OnOdinDisconnected();

    UFUNCTION()
    void HandlePlayerUpdate(const FBPOdinCommand& Cmd);

    virtual void InitializeOdinPlayerState();
};

