#pragma once
#include "CoreMinimal.h"
#include "GameState_flatbuffer.h"
#include "GameStateStructs.generated.h"

USTRUCT(BlueprintType)
struct ODINRENDER_API FPlayerData {
    GENERATED_BODY()

    UPROPERTY(BlueprintReadWrite, Category = "Odin")
    float Forward;

    UPROPERTY(BlueprintReadWrite, Category = "Odin")
    float Side;

    UPROPERTY(BlueprintReadWrite, Category = "Odin")
    float Up;

    UPROPERTY(BlueprintReadWrite, Category = "Odin")
    float Rotation;

    UPROPERTY(BlueprintReadWrite, Category = "Odin")
    bool SlashActive;

    UPROPERTY(BlueprintReadWrite, Category = "Odin")
    float SlashAngle;

    UPROPERTY(BlueprintReadWrite, Category = "Odin")
    int32 Health;

    UPROPERTY(BlueprintReadWrite, Category = "Odin")
    int32 Id;

    UPROPERTY(BlueprintReadWrite, Category = "Odin")
    int32 FrameNumber;

    static FPlayerData Unpack(const VS::Schema::PlayerData* InObj);
};

USTRUCT(BlueprintType)
struct ODINRENDER_API FEnemy {
    GENERATED_BODY()

    UPROPERTY(BlueprintReadWrite, Category = "Odin")
    float Forward;

    UPROPERTY(BlueprintReadWrite, Category = "Odin")
    float Side;

    UPROPERTY(BlueprintReadWrite, Category = "Odin")
    float Up;

    UPROPERTY(BlueprintReadWrite, Category = "Odin")
    bool IsAlive;

    UPROPERTY(BlueprintReadWrite, Category = "Odin")
    int32 Id;

    UPROPERTY(BlueprintReadWrite, Category = "Odin")
    int32 FrameNumber;

    static FEnemy Unpack(const VS::Schema::Enemy* InObj);
};

USTRUCT(BlueprintType)
struct ODINRENDER_API FVSGameState {
    GENERATED_BODY()

    UPROPERTY(BlueprintReadWrite, Category = "Odin")
    int32 Score;

    UPROPERTY(BlueprintReadWrite, Category = "Odin")
    int32 EnemyCount;

    UPROPERTY(BlueprintReadWrite, Category = "Odin")
    bool IsActive;

    UPROPERTY(BlueprintReadWrite, Category = "Odin")
    int32 FrameNumber;

    static FVSGameState Unpack(const VS::Schema::GameState* InObj);
};

