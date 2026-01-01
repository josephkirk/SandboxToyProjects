// OdinActorPoolComponent.h
// Component for managing pooled Odin actors
// Copyright Nguyen Phi Hung. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "Components/ActorComponent.h"
#include "OdinActorPoolComponent.generated.h"

class AOdinDataActor;

// Pool for a single actor type
USTRUCT(BlueprintType)
struct FOdinActorPool {
    GENERATED_BODY()

    UPROPERTY()
    TSubclassOf<AOdinDataActor> ActorClass;
    
    UPROPERTY()
    TArray<AOdinDataActor*> AvailableActors;
    
    UPROPERTY()
    TArray<AOdinDataActor*> ActiveActors;
    
    UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Pool")
    int32 MaxPoolSize = 100;
    
    UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Pool")
    int32 PrewarmCount = 0;
};

UCLASS(ClassGroup=(Odin), meta=(BlueprintSpawnableComponent))
class ODINRENDERCLIENT_API UOdinActorPoolComponent : public UActorComponent {
    GENERATED_BODY()

public:
    UOdinActorPoolComponent();

    virtual void BeginPlay() override;
    virtual void EndPlay(const EEndPlayReason::Type EndPlayReason) override;

    // Acquire an actor from pool, or spawn a new one if pool is empty
    UFUNCTION(BlueprintCallable, Category = "OdinPool")
    AOdinDataActor* AcquireActor(TSubclassOf<AOdinDataActor> ActorClass, FTransform SpawnTransform);
    
    // Release an actor back to the pool (hides and disables it)
    UFUNCTION(BlueprintCallable, Category = "OdinPool")
    void ReleaseActor(AOdinDataActor* Actor);
    
    // Release all active actors of a given class back to pool
    UFUNCTION(BlueprintCallable, Category = "OdinPool")
    void ReleaseAllActorsOfClass(TSubclassOf<AOdinDataActor> ActorClass);
    
    // Release all active actors
    UFUNCTION(BlueprintCallable, Category = "OdinPool")
    void ReleaseAllActors();
    
    // Get pool statistics
    UFUNCTION(BlueprintPure, Category = "OdinPool")
    int32 GetPooledCount(TSubclassOf<AOdinDataActor> ActorClass) const;
    
    UFUNCTION(BlueprintPure, Category = "OdinPool")
    int32 GetActiveCount(TSubclassOf<AOdinDataActor> ActorClass) const;
    
    // Pre-warm a pool with inactive actors
    UFUNCTION(BlueprintCallable, Category = "OdinPool")
    void PrewarmPool(TSubclassOf<AOdinDataActor> ActorClass, int32 Count);

protected:
    // Actor pools keyed by class
    UPROPERTY()
    TMap<UClass*, FOdinActorPool> ActorPools;
    
    // Helper to get or create pool for a class
    FOdinActorPool& GetOrCreatePool(TSubclassOf<AOdinDataActor> ActorClass);
    
    // Destroy all pooled actors
    void DestroyAllPooledActors();
};
