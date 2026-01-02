#include "GameStateStructs.h"
FPlayerData FPlayerData::Unpack(const VS::Schema::PlayerData* InObj) {
    FPlayerData Result;
    if (!InObj) return Result;

    Result.Forward = InObj->forward();
    Result.Side = InObj->side();
    Result.Up = InObj->up();
    Result.Rotation = InObj->rotation();
    Result.SlashActive = InObj->slash_active();
    Result.SlashAngle = InObj->slash_angle();
    Result.Health = InObj->health();
    Result.Id = InObj->id();
    Result.FrameNumber = InObj->frame_number();
    return Result;
}

FEnemy FEnemy::Unpack(const VS::Schema::Enemy* InObj) {
    FEnemy Result;
    if (!InObj) return Result;

    Result.Forward = InObj->forward();
    Result.Side = InObj->side();
    Result.Up = InObj->up();
    Result.IsAlive = InObj->is_alive();
    Result.Id = InObj->id();
    Result.FrameNumber = InObj->frame_number();
    return Result;
}

FVSGameState FVSGameState::Unpack(const VS::Schema::GameState* InObj) {
    FVSGameState Result;
    if (!InObj) return Result;

    Result.Score = InObj->score();
    Result.EnemyCount = InObj->enemy_count();
    Result.IsActive = InObj->is_active();
    Result.FrameNumber = InObj->frame_number();
    return Result;
}

