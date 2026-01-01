#pragma once
#include "CoreMinimal.h"
#include "UObject/NoExportTypes.h"
#include "GameState_flatbuffer.h"
#include "GameStateWrappers.generated.h"

UCLASS(BlueprintType)
class UPlayerWrapper : public UObject
{
    GENERATED_BODY()
public:
    const VS::Schema::Player* Buffer = nullptr;
    void Init(const VS::Schema::Player* InBuffer) { Buffer = InBuffer; }
    UFUNCTION(BlueprintPure, Category = "Odin|Player")
    FVector2D GetPosition() const {
        if (!Buffer) return {};
        return FVector2D(Buffer->position()->x(), Buffer->position()->y());
    }
    UFUNCTION(BlueprintPure, Category = "Odin|Player")
    float GetRotation() const {
        if (!Buffer) return {};
        return Buffer->rotation();
    }
    UFUNCTION(BlueprintPure, Category = "Odin|Player")
    bool GetSlash_Active() const {
        if (!Buffer) return {};
        return Buffer->slash_active();
    }
    UFUNCTION(BlueprintPure, Category = "Odin|Player")
    float GetSlash_Angle() const {
        if (!Buffer) return {};
        return Buffer->slash_angle();
    }
    UFUNCTION(BlueprintPure, Category = "Odin|Player")
    int32 GetHealth() const {
        if (!Buffer) return {};
        return Buffer->health();
    }
};

UCLASS(BlueprintType)
class UEnemyWrapper : public UObject
{
    GENERATED_BODY()
public:
    const VS::Schema::Enemy* Buffer = nullptr;
    void Init(const VS::Schema::Enemy* InBuffer) { Buffer = InBuffer; }
    UFUNCTION(BlueprintPure, Category = "Odin|Enemy")
    FVector2D GetPosition() const {
        if (!Buffer) return {};
        return FVector2D(Buffer->position()->x(), Buffer->position()->y());
    }
    UFUNCTION(BlueprintPure, Category = "Odin|Enemy")
    bool GetIs_Alive() const {
        if (!Buffer) return {};
        return Buffer->is_alive();
    }
};

UCLASS(BlueprintType)
class UGameStateWrapper : public UObject
{
    GENERATED_BODY()
public:
    const VS::Schema::GameState* Buffer = nullptr;
    void Init(const VS::Schema::GameState* InBuffer) { Buffer = InBuffer; }
    UFUNCTION(BlueprintPure, Category = "Odin|GameState")
    UPlayerWrapper* GetPlayer() const {
        if (!Buffer) return {};
        UPlayerWrapper* Wrapper = NewObject<UPlayerWrapper>(const_cast<UObject*>(reinterpret_cast<const UObject*>(this)));
        Wrapper->Init(Buffer->player());
        return Wrapper;
    }
    UFUNCTION(BlueprintPure, Category = "Odin|GameState")
    int32 GetScore() const {
        if (!Buffer) return {};
        return Buffer->score();
    }
    UFUNCTION(BlueprintPure, Category = "Odin|GameState")
    int32 GetEnemy_Count() const {
        if (!Buffer) return {};
        return Buffer->enemy_count();
    }
    UFUNCTION(BlueprintPure, Category = "Odin|GameState")
    bool GetIs_Active() const {
        if (!Buffer) return {};
        return Buffer->is_active();
    }
};

