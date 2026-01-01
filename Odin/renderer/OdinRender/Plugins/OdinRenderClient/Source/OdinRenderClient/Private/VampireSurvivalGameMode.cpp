// VampireSurvivalGameMode.cpp
// Copyright Nguyen Phi Hung. All Rights Reserved.

#include "VampireSurvivalGameMode.h"
#include "Kismet/GameplayStatics.h"
#include "VampireSurvivalSubsystem.h"

AVampireSurvivalGameMode::AVampireSurvivalGameMode() {
  PrimaryActorTick.bCanEverTick = true;
  PrimaryActorTick.bStartWithTickEnabled = true;
}

void AVampireSurvivalGameMode::BeginPlay() {
  Super::BeginPlay();

  // Get the subsystem
  UGameInstance *GameInstance = UGameplayStatics::GetGameInstance(this);
  if (GameInstance) {
    Subsystem = GameInstance->GetSubsystem<UVampireSurvivalSubsystem>();
    if (Subsystem) {
      // Bind delegates
      Subsystem->OnConnected.AddDynamic(
          this, &AVampireSurvivalGameMode::OnConnectedCallback);
      Subsystem->OnDisconnected.AddDynamic(
          this, &AVampireSurvivalGameMode::OnDisconnectedCallback);

      // Try to connect
      if (Subsystem->ConnectToOdin()) {
        UE_LOG(LogTemp, Log,
               TEXT("VampireSurvivalGameMode: Connected to Odin on BeginPlay"));
      } else {
        UE_LOG(LogTemp, Warning,
               TEXT("VampireSurvivalGameMode: Failed to connect. Start Odin "
                    "first."));
      }
    }
  }
}

void AVampireSurvivalGameMode::EndPlay(
    const EEndPlayReason::Type EndPlayReason) {
  if (Subsystem) {
    Subsystem->OnConnected.RemoveDynamic(
        this, &AVampireSurvivalGameMode::OnConnectedCallback);
    Subsystem->OnDisconnected.RemoveDynamic(
        this, &AVampireSurvivalGameMode::OnDisconnectedCallback);
    Subsystem->DisconnectFromOdin();
  }

  Super::EndPlay(EndPlayReason);
}

void AVampireSurvivalGameMode::Tick(float DeltaTime) {
  Super::Tick(DeltaTime);

  if (!Subsystem || !Subsystem->IsConnected()) {
    return;
  }

  // Send current input every tick
  if (!CurrentMoveInput.IsNearlyZero()) {
    Subsystem->SendPlayerInput(CurrentMoveInput.X, CurrentMoveInput.Y);
  }

  // Poll game state at configured rate
  StatePollingTimer += DeltaTime;
  if (StatePollingTimer >= StatePollingInterval) {
    StatePollingTimer = 0.0f;

    if (Subsystem->ReadLatestGameState(CachedGameState)) {
      FVector2D PlayerPos(CachedGameState.Player.Position.X,
                          CachedGameState.Player.Position.Y);
      OnGameStateReceived(PlayerPos, CachedGameState.Player.Health,
                          CachedGameState.Score, CachedGameState.EnemyCount,
                          CachedGameState.bIsActive);
    }
  }
}

void AVampireSurvivalGameMode::HandleMoveInput(FVector2D MoveInput) {
  CurrentMoveInput = MoveInput;
}

void AVampireSurvivalGameMode::StartOdinGame() {
  if (Subsystem && Subsystem->IsConnected()) {
    Subsystem->SendStartGame();
    UE_LOG(LogTemp, Log, TEXT("VampireSurvivalGameMode: Sent StartGame"));
  }
}

void AVampireSurvivalGameMode::EndOdinGame() {
  if (Subsystem && Subsystem->IsConnected()) {
    Subsystem->SendEndGame();
    UE_LOG(LogTemp, Log, TEXT("VampireSurvivalGameMode: Sent EndGame"));
  }
}

void AVampireSurvivalGameMode::OnConnectedCallback() { OnOdinConnected(); }

void AVampireSurvivalGameMode::OnDisconnectedCallback() {
  OnOdinDisconnected();
}
