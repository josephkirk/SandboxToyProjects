#pragma once

#include "CoreMinimal.h"
#include "OdinClientGameMode.h"
#include "VampireSurvivalGameMode.generated.h"

UCLASS()
class ODINRENDER_API AVampireSurvivalGameMode : public AOdinClientGameMode {
  GENERATED_BODY()

public:
  AVampireSurvivalGameMode();

  virtual void Tick(float DeltaTime) override;
  
protected:
  virtual void BeginPlay() override;

  UPROPERTY(EditDefaultsOnly, Category = "Odin")
  TSubclassOf<class AEnemyActor> EnemyActorClass;
};
