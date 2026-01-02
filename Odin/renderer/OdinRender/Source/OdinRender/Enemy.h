// Enemy.h
// Copyright Nguyen Phi Hung. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "GameFramework/Actor.h"
#include "Generated/GameStateStructs.h"
#include "Enemy.generated.h"

UCLASS()
class ODINRENDER_API AEnemyActor : public AActor
{
	GENERATED_BODY()
	
public:	
	AEnemyActor();

protected:
	virtual void BeginPlay() override;

public:	
	virtual void Tick(float DeltaTime) override;
    
    // Holds the raw data state from Odin
	UPROPERTY(VisibleAnywhere, BlueprintReadOnly, Category = "Odin")
    FEnemy EnemyData;

};
