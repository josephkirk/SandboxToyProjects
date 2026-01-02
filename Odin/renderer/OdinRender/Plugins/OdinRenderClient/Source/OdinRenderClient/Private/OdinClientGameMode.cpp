// OdinClientGameMode.cpp
// Copyright Nguyen Phi Hung. All Rights Reserved.

#include "OdinClientGameMode.h"
#include "OdinClientSubsystem.h"
#include "OdinClientActorManagerComponent.h"
#include "OdinPlayerState.h"
#include "OdinPlayerController.h"
#include "Kismet/GameplayStatics.h"

AOdinClientGameMode::AOdinClientGameMode() {
    PrimaryActorTick.bCanEverTick = true;
    
    ActorManager = CreateDefaultSubobject<UOdinClientActorManagerComponent>(TEXT("OdinActorManager"));

    // Set default classes
    PlayerStateClass = AOdinPlayerState::StaticClass();
    PlayerControllerClass = AOdinPlayerController::StaticClass();
}

void AOdinClientGameMode::BeginPlay() {
    Super::BeginPlay();
    
    // Initialize player state
    InitializeOdinPlayerState();
    
    UOdinClientSubsystem* Subsystem = GetOdinSubsystem();
    if (Subsystem) {
        Subsystem->OnConnected.AddDynamic(this, &AOdinClientGameMode::HandleConnected);
        Subsystem->OnDisconnected.AddDynamic(this, &AOdinClientGameMode::HandleDisconnected);
        Subsystem->OnPlayerUpdate.AddDynamic(this, &AOdinClientGameMode::HandlePlayerUpdate);
        
        // Auto Connect
        Subsystem->ConnectToOdin(SharedMemoryName);
    }
}

void AOdinClientGameMode::EndPlay(const EEndPlayReason::Type EndPlayReason) {
    EndOdinGame();
    
    // Clean up player
    if (PlayerActor) {
        PlayerActor->Destroy();
        PlayerActor = nullptr;
    }
    
    // Player state is managed by GameState/Level
    OdinPlayerState = nullptr;
    
    UOdinClientSubsystem* Subsystem = GetOdinSubsystem();
    if (Subsystem) {
        Subsystem->OnConnected.RemoveDynamic(this, &AOdinClientGameMode::HandleConnected);
        Subsystem->OnDisconnected.RemoveDynamic(this, &AOdinClientGameMode::HandleDisconnected);
        Subsystem->OnPlayerUpdate.RemoveDynamic(this, &AOdinClientGameMode::HandlePlayerUpdate);
        Subsystem->DisconnectFromOdin();
    }
    Super::EndPlay(EndPlayReason);
}

UOdinClientSubsystem* AOdinClientGameMode::GetOdinSubsystem() const {
    return UOdinClientSubsystem::Get(this);
}

void AOdinClientGameMode::HandlePlayerUpdate(const FBPOdinCommand& Cmd) {
    if (!PlayerActor) return;

    // Cmd.Values has X, Y, Z, Yaw
    FVector NewLocation(Cmd.Values.X, Cmd.Values.Y, Cmd.Values.Z);
    FRotator NewRotation(0, Cmd.Values.W, 0);

    // Simple interpolation could be added here, but for now direct set
    PlayerActor->SetActorLocation(NewLocation);
    PlayerActor->SetActorRotation(NewRotation);

    // If using OdinPlayerState, update it too
    if (OdinPlayerState) {
        // OdinPlayerState->SetPlayerInfo(...) // If such method exists
    }
}

void AOdinClientGameMode::StartOdinGame() {
    UOdinClientSubsystem* Subsystem = GetOdinSubsystem();
    if (Subsystem) {
        Subsystem->PushGameCommand(1.0f, NAME_None); // 1 = Start
    }
}

void AOdinClientGameMode::EndOdinGame() {
    UOdinClientSubsystem* Subsystem = GetOdinSubsystem();
    if (Subsystem) {
        Subsystem->PushGameCommand(-1.0f, NAME_None); // -1 = End
    }
}

void AOdinClientGameMode::InitializeOdinPlayerState() {
    UWorld* World = GetWorld();
    if (!World) return;
    
    // Should typically rely on Engine's creation of PlayerState via PlayerController login, 
    // but explicit spawn was requested in previous code. 
    // If using DefaultPlayerStateClass, the Engine creates it.
    // We'll keep explicit reference if we want to bypass Controller login or for distinct logic.
    // But since we set PlayerStateClass, we might just want to grab it from there.
    // For now, preserving original logic of spawning specific actor if needed.
    
    // Actually, user said: "use ... By Default". Setting PlayerStateClass is enough for the engine.
    // But we want to cast it and store reference in OdinPlayerState.
    // We'll wait for PostLogin or just assume it exists if we are the server (which we aren't really).
    // Let's just spawn it manually as an extra helper if it's not the main one.
    
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

void AOdinClientGameMode::HandleConnected() {
    StartOdinGame();
    OnOdinConnected();
}

void AOdinClientGameMode::HandleDisconnected() { 
    OnOdinDisconnected(); 
}
