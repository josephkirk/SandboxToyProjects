// VampireSurvivalSubsystem.cpp
// Copyright Nguyen Phi Hung. All Rights Reserved.

#include "VampireSurvivalSubsystem.h"
#include "Kismet/GameplayStatics.h"

// FlatBuffers
#include "flatbuffers/flatbuffers.h"
#include "Generated/GameState_flatbuffer.h"

void UVampireSurvivalSubsystem::Initialize(FSubsystemCollectionBase& Collection) {
    Super::Initialize(Collection);
    OdinClient = Collection.InitializeDependency<UOdinClientSubsystem>();
    UE_LOG(LogTemp, Log, TEXT("VampireSurvivalSubsystem initialized"));
}

void UVampireSurvivalSubsystem::Deinitialize() {
    Super::Deinitialize();
}

bool UVampireSurvivalSubsystem::IsConnected() const {
    return OdinClient && OdinClient->IsConnected();
}

bool UVampireSurvivalSubsystem::ConnectToOdin() {
    if (OdinClient) {
        return OdinClient->ConnectToOdin(TEXT("OdinVampireSurvival"));
    }
    return false;
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

const FGameStateWrapper& UVampireSurvivalSubsystem::UpdateAndGetState() {
    if (!OdinClient) return CurrentGameState;

    const FOdinSharedMemoryBlock::FrameSlot* Slot = OdinClient->GetLatestFrameSlot();
    if (!Slot) return CurrentGameState;

    if (static_cast<int32>(Slot->FrameNumber) <= LastReadFrameNumber) {
        return CurrentGameState;
    }

    // Verify
    flatbuffers::Verifier Verifier(Slot->Data, Slot->DataSize);
    if (!VS::Schema::VerifyGameStateBuffer(Verifier)) {
        return CurrentGameState;
    }

    // Deserialize into UStruct
    const VS::Schema::GameState* Root = VS::Schema::GetGameState(Slot->Data);
    CurrentGameState.UpdateFrom(Root);

    LastReadFrameNumber = static_cast<int32>(Slot->FrameNumber);
    return CurrentGameState;
}

const FGameStateWrapper& UVampireSurvivalSubsystem::GetLatestGameState() const {
    return CurrentGameState;
}
