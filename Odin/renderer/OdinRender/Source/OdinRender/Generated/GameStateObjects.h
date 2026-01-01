#pragma once
#include "CoreMinimal.h"
#include "OdinDataObject.h"
#include "OdinDataActor.h"
#include "GameState_flatbuffer.h"
#include "GameStateStructs.h"
#include "GameStateObjects.generated.h"

UCLASS(BlueprintType)
class ODINRENDER_API UOdinPlayerData : public UOdinDataObject {
    GENERATED_BODY()
public:
    UPROPERTY(BlueprintReadWrite, Category = "Odin|PlayerData")
    FVec3 Position;

    UPROPERTY(BlueprintReadWrite, Category = "Odin|PlayerData")
    float Rotation;

    UPROPERTY(BlueprintReadWrite, Category = "Odin|PlayerData")
    bool SlashActive;

    UPROPERTY(BlueprintReadWrite, Category = "Odin|PlayerData")
    float SlashAngle;

    UPROPERTY(BlueprintReadWrite, Category = "Odin|PlayerData")
    int32 Health;

    UPROPERTY(BlueprintReadWrite, Category = "Odin|PlayerData")
    bool IsVisible;

    UPROPERTY(BlueprintReadWrite, Category = "Odin|PlayerData")
    int32 Id;

    void UpdateFromFlatBuffer(const VS::Schema::PlayerData* InTable);
    virtual void UpdateFromOdinData(const uint8* Buffer, int32 Size) override { /* Non-root: use UpdateFromFlatBuffer */ }
};

UCLASS()
class ODINRENDER_API AOdinPlayerDataActor : public AOdinDataActor {
    GENERATED_BODY()
public:
    AOdinPlayerDataActor();
    
    UFUNCTION(BlueprintPure, Category = "Odin|PlayerData")
    UOdinPlayerData* GetPlayerDataData() const { return Cast<UOdinPlayerData>(DataObject); }
};

UCLASS(BlueprintType)
class ODINRENDER_API UOdinEnemy : public UOdinDataObject {
    GENERATED_BODY()
public:
    UPROPERTY(BlueprintReadWrite, Category = "Odin|Enemy")
    FVec3 Position;

    UPROPERTY(BlueprintReadWrite, Category = "Odin|Enemy")
    bool IsAlive;

    UPROPERTY(BlueprintReadWrite, Category = "Odin|Enemy")
    bool IsVisible;

    UPROPERTY(BlueprintReadWrite, Category = "Odin|Enemy")
    int32 Id;

    void UpdateFromFlatBuffer(const VS::Schema::Enemy* InTable);
    virtual void UpdateFromOdinData(const uint8* Buffer, int32 Size) override { /* Non-root: use UpdateFromFlatBuffer */ }
};

UCLASS()
class ODINRENDER_API AOdinEnemyActor : public AOdinDataActor {
    GENERATED_BODY()
public:
    AOdinEnemyActor();
    
    UFUNCTION(BlueprintPure, Category = "Odin|Enemy")
    UOdinEnemy* GetEnemyData() const { return Cast<UOdinEnemy>(DataObject); }
};

UCLASS(BlueprintType)
class ODINRENDER_API UOdinGameState : public UOdinDataObject {
    GENERATED_BODY()
public:
    UPROPERTY(BlueprintReadWrite, Category = "Odin|GameState")
    int32 Score;

    UPROPERTY(BlueprintReadWrite, Category = "Odin|GameState")
    int32 EnemyCount;

    UPROPERTY(BlueprintReadWrite, Category = "Odin|GameState")
    bool IsActive;

    UPROPERTY(BlueprintReadWrite, Category = "Odin|GameState")
    int32 FrameNumber;

    virtual void UpdateFromOdinData(const uint8* Buffer, int32 Size) override;
};

UCLASS()
class ODINRENDER_API AOdinGameStateActor : public AOdinDataActor {
    GENERATED_BODY()
public:
    AOdinGameStateActor();
    
    UFUNCTION(BlueprintPure, Category = "Odin|GameState")
    UOdinGameState* GetGameStateData() const { return Cast<UOdinGameState>(DataObject); }
};

