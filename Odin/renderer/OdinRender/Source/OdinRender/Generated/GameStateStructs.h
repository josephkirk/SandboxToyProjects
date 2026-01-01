#pragma once
#include "CoreMinimal.h"
#include "GameState_flatbuffer.h"
#include "GameStateStructs.generated.h"

USTRUCT(BlueprintType)
struct ODINRENDER_API FVec3 {
    GENERATED_BODY()

    UPROPERTY(BlueprintReadWrite, Category = "Odin")
    float X;

    UPROPERTY(BlueprintReadWrite, Category = "Odin")
    float Y;

    UPROPERTY(BlueprintReadWrite, Category = "Odin")
    float Z;

};

