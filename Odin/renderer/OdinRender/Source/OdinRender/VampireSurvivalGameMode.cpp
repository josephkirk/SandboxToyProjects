// VampireSurvivalGameMode.cpp
// Copyright Nguyen Phi Hung. All Rights Reserved.

#include "VampireSurvivalGameMode.h"
#include "VampireSurvivalGameState.h"
#include "OdinClientSubsystem.h"
#include "OdinPlayerState.h"
#include "Enemy.h"
#include "OdinClientActorManagerComponent.h"

AVampireSurvivalGameMode::AVampireSurvivalGameMode() {
  PrimaryActorTick.bCanEverTick = true;
  GameStateClass = AVampireSurvivalGameState::StaticClass();
}

void AVampireSurvivalGameMode::BeginPlay() {
    Super::BeginPlay();
    
    // Register Enemy Mapping
    if (ActorManager && EnemyActorClass) {
        ActorManager->RegisterEntityMapping(TEXT("Enemy"), EnemyActorClass);
    }
}

void AVampireSurvivalGameMode::Tick(float DeltaTime) {
  Super::Tick(DeltaTime);
}
