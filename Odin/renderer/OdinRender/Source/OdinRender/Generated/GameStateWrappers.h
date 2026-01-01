#pragma once
#include "CoreMinimal.h"
#include "UObject/NoExportTypes.h"
#include "GameState_flatbuffer.h"
#include "GameStateWrappers.generated.h"

USTRUCT(BlueprintType)
struct FPlayerWrapper
{
    GENERATED_BODY()

    UPROPERTY(BlueprintReadWrite, Category = "Odin|Player")
    FVector2D Position;

    UPROPERTY(BlueprintReadWrite, Category = "Odin|Player")
    float Rotation;

    UPROPERTY(BlueprintReadWrite, Category = "Odin|Player")
    bool Slash_Active;

    UPROPERTY(BlueprintReadWrite, Category = "Odin|Player")
    float Slash_Angle;

    UPROPERTY(BlueprintReadWrite, Category = "Odin|Player")
    int32 Health;

    void UpdateFrom(const VS::Schema::Player* InBuffer);
};

USTRUCT(BlueprintType)
struct FEnemyWrapper
{
    GENERATED_BODY()

    UPROPERTY(BlueprintReadWrite, Category = "Odin|Enemy")
    FVector2D Position;

    UPROPERTY(BlueprintReadWrite, Category = "Odin|Enemy")
    bool Is_Alive;

    void UpdateFrom(const VS::Schema::Enemy* InBuffer);
};

USTRUCT(BlueprintType)
struct FGameStateWrapper
{
    GENERATED_BODY()

    UPROPERTY(BlueprintReadWrite, Category = "Odin|GameState")
    FPlayerWrapper Player;

    UPROPERTY(BlueprintReadWrite, Category = "Odin|GameState")
    TArray<FEnemyWrapper> Enemies;

    UPROPERTY(BlueprintReadWrite, Category = "Odin|GameState")
    int32 Score;

    UPROPERTY(BlueprintReadWrite, Category = "Odin|GameState")
    int32 Enemy_Count;

    UPROPERTY(BlueprintReadWrite, Category = "Odin|GameState")
    bool Is_Active;

    void UpdateFrom(const VS::Schema::GameState* InBuffer);
};

