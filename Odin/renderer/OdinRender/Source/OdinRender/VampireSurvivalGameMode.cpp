// VampireSurvivalGameMode.cpp
// Copyright Nguyen Phi Hung. All Rights Reserved.

#include "VampireSurvivalGameMode.h"
#include "Kismet/GameplayStatics.h"
#include "VampireSurvivalSubsystem.h"
#include "OdinClientSubsystem.h"
#include "OdinPlayerState.h"

AVampireSurvivalGameMode::AVampireSurvivalGameMode() {
  PrimaryActorTick.bCanEverTick = true;
  PrimaryActorTick.bStartWithTickEnabled = true;
}

void AVampireSurvivalGameMode::BeginPlay() {
  Super::BeginPlay(); // Handles generic connection + PlayerState init

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

    // Get game state (now only contains metadata, not entities)
    CachedGameState = Subsystem->UpdateAndGetState();
    
    if (!CachedGameState) return;
    
    // New schema: GameState only has metadata (score, enemy_count, is_active, frame_number)
    // Player and Enemy data would come from separate entity updates
    int32 ECount = CachedGameState->EnemyCount;
    bool bActive = CachedGameState->IsActive;
    int32 Score = CachedGameState->Score;

    // For now, use placeholder values for player data
    // TODO: Implement separate player data stream
    FVector2D PlayerPos = FVector2D::ZeroVector;
    int32 Health = 100;
    
    OnGameStateReceived(PlayerPos, Health, Score, ECount, bActive);
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
