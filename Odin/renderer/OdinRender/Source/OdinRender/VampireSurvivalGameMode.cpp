// VampireSurvivalGameMode.cpp
// Copyright Nguyen Phi Hung. All Rights Reserved.

#include "VampireSurvivalGameMode.h"
#include "Kismet/GameplayStatics.h"
#include "VampireSurvivalSubsystem.h"
#include "OdinClientSubsystem.h" 

AVampireSurvivalGameMode::AVampireSurvivalGameMode() {
  PrimaryActorTick.bCanEverTick = true;
  PrimaryActorTick.bStartWithTickEnabled = true;
}

void AVampireSurvivalGameMode::BeginPlay() {
  Super::BeginPlay(); // Handles generic connection

  UGameInstance *GameInstance = GetGameInstance();
  if (GameInstance) {
    Subsystem = GameInstance->GetSubsystem<UVampireSurvivalSubsystem>();
  }
}

void AVampireSurvivalGameMode::Tick(float DeltaTime) {
  Super::Tick(DeltaTime);

  // Send current input every tick (specific to this game mode)
  if (Subsystem && !CurrentMoveInput.IsNearlyZero()) {
    Subsystem->SendPlayerInput(CurrentMoveInput.X, CurrentMoveInput.Y);
  }
}

void AVampireSurvivalGameMode::OnUpdateGameState() {
    if (!Subsystem) return;

    // Get struct (Update happens inside GetLatestGameState if logic moved, or we call accessor)
    const FGameStateWrapper& Latest = Subsystem->UpdateAndGetState();
    CachedGameState = Latest; // Copy for Blueprint access if needed, or just use ref if careful
    
    // Access fields directly from struct
    FVector2D PlayerPos = CachedGameState.Player.Position;
    int32 Health = CachedGameState.Player.Health;
    
    int32 ECount = CachedGameState.Enemy_Count;
    bool bActive = CachedGameState.Is_Active;

    OnGameStateReceived(PlayerPos, Health, CachedGameState.Score, ECount, bActive);
}

void AVampireSurvivalGameMode::HandleMoveInput(FVector2D MoveInput) {
  CurrentMoveInput = MoveInput;
}

void AVampireSurvivalGameMode::StartOdinGame() {
  if (Subsystem) Subsystem->SendStartGame();
}

void AVampireSurvivalGameMode::EndOdinGame() {
  if (Subsystem) Subsystem->SendEndGame();
}
