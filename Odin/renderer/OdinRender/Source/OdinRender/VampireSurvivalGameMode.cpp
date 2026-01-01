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
  Super::BeginPlay();

  UGameInstance *GameInstance = GetGameInstance();
  if (GameInstance) {
    Subsystem = GameInstance->GetSubsystem<UVampireSurvivalSubsystem>();
    UOdinClientSubsystem* OdinSys = GameInstance->GetSubsystem<UOdinClientSubsystem>();
    
    if (Subsystem && OdinSys) {
      // Bind delegates from OdinSys
      OdinSys->OnConnected.AddDynamic(this, &AVampireSurvivalGameMode::OnConnectedCallback);
      //OdinSys->OnDisconnected.AddDynamic(this, &AVampireSurvivalGameMode::OnDisconnectedCallback); 
      // Need impl for Disconnected callback binding if we want it

      // Try to connect logic is inside Subsystem->Connect or we call it here?
      if (Subsystem->ConnectToOdin()) {
         // Log handled in Connect
      }
    }
  }
}

void AVampireSurvivalGameMode::EndPlay(const EEndPlayReason::Type EndPlayReason) {
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

    // Get struct (Update happens inside GetLatestGameState if logic moved, or we call accessor)
    // We changed Subsystem to return const ref, so we copy it to CachedGameState for BP exposure?
    // Or just ref it.
    CachedGameState = Subsystem->GetLatestGameState();
    
    // Access fields directly from struct
    FVector2D PlayerPos = CachedGameState.Player.Position;
    int32 Health = CachedGameState.Player.Health;
    
    int32 ECount = CachedGameState.Enemy_Count;
    bool bActive = CachedGameState.Is_Active;

    OnGameStateReceived(PlayerPos, Health, CachedGameState.Score, ECount, bActive);
  }
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

void AVampireSurvivalGameMode::OnConnectedCallback() { OnOdinConnected(); }
// void AVampireSurvivalGameMode::OnDisconnectedCallback() { OnOdinDisconnected(); }
