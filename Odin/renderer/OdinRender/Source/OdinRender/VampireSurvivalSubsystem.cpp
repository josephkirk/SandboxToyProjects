// VampireSurvivalSubsystem.cpp
// Copyright Nguyen Phi Hung. All Rights Reserved.

#include "VampireSurvivalSubsystem.h"

void UVampireSurvivalSubsystem::Initialize(FSubsystemCollectionBase& Collection) {
    Super::Initialize(Collection);
    
    // Create the game state object
    GameState = NewObject<UOdinGameState>(this, TEXT("GameState"));
}

bool UVampireSurvivalSubsystem::ConnectToOdinDefault() {
    return ConnectToOdin(TEXT("OdinVampireSurvival"));
}

void UVampireSurvivalSubsystem::SendStartGame() {
    if (OdinClient) OdinClient->PushGameCommand(1.0f, NAME_None); // 1 = Start
}

void UVampireSurvivalSubsystem::SendEndGame() {
    if (OdinClient) OdinClient->PushGameCommand(-1.0f, NAME_None); // -1 = End
}

void UVampireSurvivalSubsystem::SendPlayerInput(float MoveX, float MoveY) {
    if (OdinClient) OdinClient->PushInputCommand(FName("Move"), MoveX, MoveY, 0.f);
}

UOdinGameState* UVampireSurvivalSubsystem::UpdateAndGetState() {
    const FOdinSharedMemoryBlock::FrameSlot* Slot = TryGetNewFrameSlot();
    
    if (!Slot || !GameState) {
        return GameState;
    }

    // Update game state from raw buffer
    GameState->UpdateFromOdinData(Slot->Data, Slot->DataSize);
    
    LastReadFrameNumber = static_cast<int32>(Slot->FrameNumber);
    return GameState;
}
