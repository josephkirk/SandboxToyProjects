// OdinActorPoolComponent.cpp
// Copyright Nguyen Phi Hung. All Rights Reserved.

#include "OdinActorPoolComponent.h"
#include "OdinDataActor.h"

UOdinActorPoolComponent::UOdinActorPoolComponent() {
    PrimaryComponentTick.bCanEverTick = false;
}

void UOdinActorPoolComponent::BeginPlay() {
    Super::BeginPlay();
}

void UOdinActorPoolComponent::EndPlay(const EEndPlayReason::Type EndPlayReason) {
    DestroyAllPooledActors();
    Super::EndPlay(EndPlayReason);
}

FOdinActorPool& UOdinActorPoolComponent::GetOrCreatePool(TSubclassOf<AOdinDataActor> ActorClass) {
    UClass* Key = ActorClass.Get();
    if (!ActorPools.Contains(Key)) {
        FOdinActorPool NewPool;
        NewPool.ActorClass = ActorClass;
        ActorPools.Add(Key, NewPool);
    }
    return ActorPools[Key];
}

AOdinDataActor* UOdinActorPoolComponent::AcquireActor(TSubclassOf<AOdinDataActor> ActorClass, FTransform SpawnTransform) {
    if (!ActorClass) return nullptr;
    
    FOdinActorPool& Pool = GetOrCreatePool(ActorClass);
    AOdinDataActor* Actor = nullptr;
    
    // Try to get from available pool
    if (Pool.AvailableActors.Num() > 0) {
        Actor = Pool.AvailableActors.Pop();
        if (Actor) {
            Actor->SetActorTransform(SpawnTransform);
        }
    } else {
        // Spawn new actor
        UWorld* World = GetWorld();
        if (!World) return nullptr;
        
        FActorSpawnParameters SpawnParams;
        SpawnParams.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AlwaysSpawn;
        Actor = World->SpawnActor<AOdinDataActor>(ActorClass, SpawnTransform, SpawnParams);
    }
    
    if (Actor) {
        Pool.ActiveActors.Add(Actor);
        Actor->OnAcquiredFromPool();
    }
    
    return Actor;
}

void UOdinActorPoolComponent::ReleaseActor(AOdinDataActor* Actor) {
    if (!Actor) return;
    
    UClass* ActorClassKey = Actor->GetClass();
    if (!ActorPools.Contains(ActorClassKey)) return;
    
    FOdinActorPool& Pool = ActorPools[ActorClassKey];
    
    // Remove from active list
    Pool.ActiveActors.Remove(Actor);
    
    // Notify actor of release
    Actor->OnReleasedToPool();
    
    // Add to available pool if not at capacity
    if (Pool.AvailableActors.Num() < Pool.MaxPoolSize) {
        Pool.AvailableActors.Add(Actor);
    } else {
        // Pool is full, destroy the actor
        Actor->Destroy();
    }
}

void UOdinActorPoolComponent::ReleaseAllActorsOfClass(TSubclassOf<AOdinDataActor> ActorClass) {
    if (!ActorClass) return;
    
    UClass* Key = ActorClass.Get();
    if (!ActorPools.Contains(Key)) return;
    
    FOdinActorPool& Pool = ActorPools[Key];
    
    // Release all active actors
    TArray<AOdinDataActor*> ActorsToRelease = Pool.ActiveActors;
    for (AOdinDataActor* Actor : ActorsToRelease) {
        ReleaseActor(Actor);
    }
}

void UOdinActorPoolComponent::ReleaseAllActors() {
    for (auto& Pair : ActorPools) {
        TArray<AOdinDataActor*> ActorsToRelease = Pair.Value.ActiveActors;
        for (AOdinDataActor* Actor : ActorsToRelease) {
            ReleaseActor(Actor);
        }
    }
}

int32 UOdinActorPoolComponent::GetPooledCount(TSubclassOf<AOdinDataActor> ActorClass) const {
    if (!ActorClass) return 0;
    
    UClass* Key = ActorClass.Get();
    if (!ActorPools.Contains(Key)) return 0;
    
    return ActorPools[Key].AvailableActors.Num();
}

int32 UOdinActorPoolComponent::GetActiveCount(TSubclassOf<AOdinDataActor> ActorClass) const {
    if (!ActorClass) return 0;
    
    UClass* Key = ActorClass.Get();
    if (!ActorPools.Contains(Key)) return 0;
    
    return ActorPools[Key].ActiveActors.Num();
}

void UOdinActorPoolComponent::PrewarmPool(TSubclassOf<AOdinDataActor> ActorClass, int32 Count) {
    if (!ActorClass || Count <= 0) return;
    
    UWorld* World = GetWorld();
    if (!World) return;
    
    FOdinActorPool& Pool = GetOrCreatePool(ActorClass);
    
    for (int32 i = 0; i < Count; ++i) {
        FActorSpawnParameters SpawnParams;
        SpawnParams.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AlwaysSpawn;
        AOdinDataActor* Actor = World->SpawnActor<AOdinDataActor>(ActorClass, FTransform::Identity, SpawnParams);
        if (Actor) {
            Actor->OnReleasedToPool(); // Start inactive
            Pool.AvailableActors.Add(Actor);
        }
    }
}

void UOdinActorPoolComponent::DestroyAllPooledActors() {
    for (auto& Pair : ActorPools) {
        // Destroy active actors
        for (AOdinDataActor* Actor : Pair.Value.ActiveActors) {
            if (Actor) Actor->Destroy();
        }
        Pair.Value.ActiveActors.Empty();
        
        // Destroy pooled actors
        for (AOdinDataActor* Actor : Pair.Value.AvailableActors) {
            if (Actor) Actor->Destroy();
        }
        Pair.Value.AvailableActors.Empty();
    }
    ActorPools.Empty();
}
