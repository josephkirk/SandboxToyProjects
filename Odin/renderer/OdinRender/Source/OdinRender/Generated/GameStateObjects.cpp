#include "GameStateObjects.h"
#include "flatbuffers/flatbuffers.h"

void UOdinPlayerData::UpdateFromFlatBuffer(const VS::Schema::PlayerData* Root) {
    if (!Root) return;
    
    // Copy struct Vec3 fields
    if (Root->position()) {
        Position.X = Root->position()->x();
        Position.Y = Root->position()->y();
        Position.Z = Root->position()->z();
    }
    Rotation = Root->rotation();
    SlashActive = Root->slash_active();
    SlashAngle = Root->slash_angle();
    Health = Root->health();
    IsVisible = Root->is_visible();
    Id = Root->id();
}

AOdinPlayerDataActor::AOdinPlayerDataActor() {
    DataObject = CreateDefaultSubobject<UOdinPlayerData>(TEXT("PlayerDataData"));
}

void UOdinEnemy::UpdateFromFlatBuffer(const VS::Schema::Enemy* Root) {
    if (!Root) return;
    
    // Copy struct Vec3 fields
    if (Root->position()) {
        Position.X = Root->position()->x();
        Position.Y = Root->position()->y();
        Position.Z = Root->position()->z();
    }
    IsAlive = Root->is_alive();
    IsVisible = Root->is_visible();
    Id = Root->id();
}

AOdinEnemyActor::AOdinEnemyActor() {
    DataObject = CreateDefaultSubobject<UOdinEnemy>(TEXT("EnemyData"));
}

void UOdinGameState::UpdateFromOdinData(const uint8* Buffer, int32 Size) {
    if (!Buffer || Size == 0) return;
    
    flatbuffers::Verifier Verifier(Buffer, Size);
    if (!VS::Schema::VerifyGameStateBuffer(Verifier)) return;
    
    const VS::Schema::GameState* Root = VS::Schema::GetGameState(Buffer);
    if (!Root) return;
    
    Score = Root->score();
    EnemyCount = Root->enemy_count();
    IsActive = Root->is_active();
    FrameNumber = Root->frame_number();
}

AOdinGameStateActor::AOdinGameStateActor() {
    DataObject = CreateDefaultSubobject<UOdinGameState>(TEXT("GameStateData"));
}

