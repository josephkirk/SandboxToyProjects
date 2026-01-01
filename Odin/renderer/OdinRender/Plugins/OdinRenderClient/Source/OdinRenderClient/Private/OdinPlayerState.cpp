// OdinPlayerState.cpp
// Copyright Nguyen Phi Hung. All Rights Reserved.

#include "OdinPlayerState.h"

AOdinPlayerState::AOdinPlayerState() {
    // Default values set in struct
}

void AOdinPlayerState::UpdateFromOdinData(FVector2D Position, float Rotation, int32 Health) {
    FOdinPlayerStateData NewData = PlayerData;
    NewData.Position = Position;
    NewData.Rotation = Rotation;
    NewData.Health = Health;
    NewData.bIsAlive = Health > 0;
    
    SetPlayerData(NewData);
}

void AOdinPlayerState::SetPlayerData(const FOdinPlayerStateData& NewData) {
    bool bHealthChanged = (NewData.Health != PlayerData.Health);
    bool bDied = (PlayerData.bIsAlive && !NewData.bIsAlive);
    
    PreviousHealth = PlayerData.Health;
    PlayerData = NewData;
    
    // Broadcast events
    OnPlayerDataChanged.Broadcast(PlayerData);
    
    if (bHealthChanged) {
        OnHealthChanged.Broadcast(PlayerData.Health, PlayerData.MaxHealth);
    }
    
    if (bDied) {
        OnPlayerDied.Broadcast();
    }
}
