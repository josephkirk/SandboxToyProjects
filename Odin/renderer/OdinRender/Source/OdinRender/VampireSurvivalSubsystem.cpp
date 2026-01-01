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
    if (OdinClient) OdinClient->SendEvent(1, 0, 0); // 1 = StartGame
}

void UVampireSurvivalSubsystem::SendEndGame() {
    if (OdinClient) OdinClient->SendEvent(2, 0, 0); // 2 = EndGame
}

void UVampireSurvivalSubsystem::SendPlayerInput(float MoveX, float MoveY) {
    if (OdinClient) OdinClient->SendEvent(3, MoveX, MoveY); // 3 = PlayerInput
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
