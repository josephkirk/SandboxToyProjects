#include "GameStateWrappers.h"
void FPlayerWrapper::UpdateFrom(const VS::Schema::Player* InBuffer)
{
    if (!InBuffer) return;
    if (InBuffer->position()) Position = FVector2D(InBuffer->position()->x(), InBuffer->position()->y());
    Rotation = InBuffer->rotation();
    Slash_Active = InBuffer->slash_active();
    Slash_Angle = InBuffer->slash_angle();
    Health = InBuffer->health();
}

void FEnemyWrapper::UpdateFrom(const VS::Schema::Enemy* InBuffer)
{
    if (!InBuffer) return;
    if (InBuffer->position()) Position = FVector2D(InBuffer->position()->x(), InBuffer->position()->y());
    Is_Alive = InBuffer->is_alive();
}

void FGameStateWrapper::UpdateFrom(const VS::Schema::GameState* InBuffer)
{
    if (!InBuffer) return;
    if (InBuffer->player()) Player.UpdateFrom(InBuffer->player());
    if (InBuffer->enemies()) {
        Enemies.SetNum(InBuffer->enemies()->size());
        for (uint32 i = 0; i < InBuffer->enemies()->size(); ++i) {
            if (InBuffer->enemies()->Get(i)) {
                Enemies[i].UpdateFrom(InBuffer->enemies()->Get(i));
            }
        }
    }
    Score = InBuffer->score();
    Enemy_Count = InBuffer->enemy_count();
    Is_Active = InBuffer->is_active();
}

