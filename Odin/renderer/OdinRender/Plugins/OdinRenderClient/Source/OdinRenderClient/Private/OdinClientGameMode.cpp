// OdinClientGameMode.cpp
// Copyright Nguyen Phi Hung. All Rights Reserved.

#include "OdinClientGameMode.h"
#include "OdinClientSubsystem.h"
#include "Kismet/GameplayStatics.h"

AOdinClientGameMode::AOdinClientGameMode() {
    PrimaryActorTick.bCanEverTick = true;
}

void AOdinClientGameMode::BeginPlay() {
    Super::BeginPlay();
    
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

void AOdinClientGameMode::HandleConnected() { OnOdinConnected(); }
void AOdinClientGameMode::HandleDisconnected() { OnOdinDisconnected(); }
