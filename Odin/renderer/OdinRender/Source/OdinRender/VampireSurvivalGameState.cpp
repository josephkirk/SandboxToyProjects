// VampireSurvivalGameState.cpp
// Copyright Nguyen Phi Hung. All Rights Reserved.

#include "VampireSurvivalGameState.h"
#include "OdinClientSubsystem.h"
#include "Kismet/GameplayStatics.h"

AVampireSurvivalGameState::AVampireSurvivalGameState() {
    PrimaryActorTick.bCanEverTick = false; // Event driven
}

void AVampireSurvivalGameState::BeginPlay() {
    Super::BeginPlay();
    
    UOdinClientSubsystem* Subsystem = UOdinClientSubsystem::Get(this);
    if (Subsystem) {
        Subsystem->OnFrameReceived.AddDynamic(this, &AVampireSurvivalGameState::HandleFrameReceived);
    }
}

void AVampireSurvivalGameState::EndPlay(const EEndPlayReason::Type EndPlayReason) {
    UOdinClientSubsystem* Subsystem = UOdinClientSubsystem::Get(this);
    if (Subsystem) {
        Subsystem->OnFrameReceived.RemoveDynamic(this, &AVampireSurvivalGameState::HandleFrameReceived);
    }
    Super::EndPlay(EndPlayReason);
}

void AVampireSurvivalGameState::HandleFrameReceived(const int64 FrameNumber) {
    UOdinClientSubsystem* Subsystem = UOdinClientSubsystem::Get(this);
    if (!Subsystem) return;
    
    const FOdinSharedMemoryBlock::FrameSlot* Slot = Subsystem->GetLatestFrameSlot();
    if (Slot && Slot->FrameNumber == FrameNumber) {
        const VS::Schema::GameState* Root = VS::Schema::GetGameState(Slot->Data);
        if (Root) {
            CachedState = FVSGameState::Unpack(Root);
            
            // Broadcast/Update UI or other systems here if needed
        }
    }
}

