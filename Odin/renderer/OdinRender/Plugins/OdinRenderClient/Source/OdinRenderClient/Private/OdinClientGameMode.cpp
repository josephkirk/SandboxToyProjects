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

void AOdinClientGameMode::HandleConnected() { OnOdinConnected(); }
void AOdinClientGameMode::HandleDisconnected() { OnOdinDisconnected(); }
