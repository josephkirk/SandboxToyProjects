// OdinClientGameMode.h
// Generic GameMode for Odin Client Plugin with Player Spawning and Actor Pooling
// Copyright Nguyen Phi Hung. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "GameFramework/GameModeBase.h"
#include "OdinClientGameMode.generated.h"

class UOdinClientSubsystem;
class UOdinActorPoolComponent;
class AOdinDataActor;
class AOdinPlayerState;

UCLASS()
class ODINRENDERCLIENT_API AOdinClientGameMode : public AGameModeBase {
    GENERATED_BODY()

public:
    AOdinClientGameMode();
    virtual void BeginPlay() override;
    virtual void EndPlay(const EEndPlayReason::Type EndPlayReason) override;

    // ========== Actor Pooling ==========
    
    // Get the actor pool component
    UFUNCTION(BlueprintPure, Category = "OdinClient|Pooling")
    UOdinActorPoolComponent* GetActorPool() const { return ActorPoolComponent; }
    
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
    // Actor Pool Component
    UPROPERTY(VisibleAnywhere, BlueprintReadOnly, Category = "OdinClient|Pooling")
    UOdinActorPoolComponent* ActorPoolComponent;
    
    UPROPERTY(BlueprintReadOnly, Category = "OdinClient")
    UOdinClientSubsystem* OdinSubsystem;

    UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, Category = "OdinClient")
    FString SharedMemoryName = TEXT("OdinVampireSurvival");

    UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, Category = "OdinClient")
    float StatePollingInterval = 0.016f;

    float StatePollingTimer = 0.0f;
    
    // The spawned player actor
    UPROPERTY(BlueprintReadOnly, Category = "OdinClient|Player")
    AActor* PlayerActor;
    
    // The Odin player state for data synchronization
    UPROPERTY(BlueprintReadOnly, Category = "OdinClient|Player")
    AOdinPlayerState* OdinPlayerState;

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
    
    // Create and initialize the player state
    virtual void InitializeOdinPlayerState();
};

