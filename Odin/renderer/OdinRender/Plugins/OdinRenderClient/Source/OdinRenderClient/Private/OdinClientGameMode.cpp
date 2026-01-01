// OdinClientGameMode.cpp
// Copyright Nguyen Phi Hung. All Rights Reserved.

#include "OdinClientGameMode.h"
#include "OdinClientSubsystem.h"
#include "OdinActorPoolComponent.h"
#include "OdinPlayerState.h"
#include "Kismet/GameplayStatics.h"

AOdinClientGameMode::AOdinClientGameMode() {
    PrimaryActorTick.bCanEverTick = true;
    
    // Create Actor Pool Component
    ActorPoolComponent = CreateDefaultSubobject<UOdinActorPoolComponent>(TEXT("ActorPoolComponent"));
}

void AOdinClientGameMode::BeginPlay() {
    Super::BeginPlay();
    
    // Initialize player state
    InitializeOdinPlayerState();
    
    UGameInstance* GI = GetGameInstance();
    if (GI) {
        OdinSubsystem = GI->GetSubsystem<UOdinClientSubsystem>();
        if (OdinSubsystem) {
            OdinSubsystem->OnConnected.AddDynamic(this, &AOdinClientGameMode::HandleConnected);
            OdinSubsystem->OnDisconnected.AddDynamic(this, &AOdinClientGameMode::HandleDisconnected);
            
            // Auto Connect
            OdinSubsystem->ConnectToOdin(SharedMemoryName);
        }
    }
}

void AOdinClientGameMode::EndPlay(const EEndPlayReason::Type EndPlayReason) {
    // Clean up player
    if (PlayerActor) {
        PlayerActor->Destroy();
        PlayerActor = nullptr;
    }
    
    // Player state is managed by GameState, no need to destroy
    OdinPlayerState = nullptr;
    
    if (OdinSubsystem) {
        OdinSubsystem->OnConnected.RemoveDynamic(this, &AOdinClientGameMode::HandleConnected);
        OdinSubsystem->OnDisconnected.RemoveDynamic(this, &AOdinClientGameMode::HandleDisconnected);
        OdinSubsystem->DisconnectFromOdin();
    }
    Super::EndPlay(EndPlayReason);
}

void AOdinClientGameMode::Tick(float DeltaTime) {
    Super::Tick(DeltaTime);

    if (OdinSubsystem && OdinSubsystem->IsConnected()) {
        StatePollingTimer += DeltaTime;
        if (StatePollingTimer >= StatePollingInterval) {
            StatePollingTimer = 0.0f;
            OnUpdateGameState();
        }
    }
}

void AOdinClientGameMode::OnUpdateGameState() {
    // Override in subclass
}

void AOdinClientGameMode::InitializeOdinPlayerState() {
    UWorld* World = GetWorld();
    if (!World) return;
    
    // Spawn a new OdinPlayerState actor
    FActorSpawnParameters SpawnParams;
    SpawnParams.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AlwaysSpawn;
    OdinPlayerState = World->SpawnActor<AOdinPlayerState>(AOdinPlayerState::StaticClass(), SpawnParams);
}

AActor* AOdinClientGameMode::SpawnPlayerActor(TSubclassOf<AActor> PlayerClass, FTransform SpawnTransform) {
    if (!PlayerClass) return nullptr;
    
    UWorld* World = GetWorld();
    if (!World) return nullptr;
    
    // Destroy existing player if any
    if (PlayerActor) {
        PlayerActor->Destroy();
        PlayerActor = nullptr;
    }
    
    FActorSpawnParameters SpawnParams;
    SpawnParams.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AdjustIfPossibleButAlwaysSpawn;
    
    PlayerActor = World->SpawnActor<AActor>(PlayerClass, SpawnTransform, SpawnParams);
    
    return PlayerActor;
}

void AOdinClientGameMode::HandleConnected() { OnOdinConnected(); }
void AOdinClientGameMode::HandleDisconnected() { OnOdinDisconnected(); }

