// OdinClientActorManagerComponent.cpp
// Copyright Nguyen Phi Hung. All Rights Reserved.

#include "OdinClientActorManagerComponent.h"
#include "OdinClientSubsystem.h"
#include "GameFramework/Actor.h"

UOdinClientActorManagerComponent::UOdinClientActorManagerComponent()
{
	PrimaryComponentTick.bCanEverTick = false;
}

void UOdinClientActorManagerComponent::BeginPlay()
{
	Super::BeginPlay();

	if (UOdinClientSubsystem* Subsystem = UOdinClientSubsystem::Get(this))
	{
		Subsystem->OnEntitySpawn.AddDynamic(this, &UOdinClientActorManagerComponent::HandleEntitySpawn);
		Subsystem->OnEntityDestroy.AddDynamic(this, &UOdinClientActorManagerComponent::HandleEntityDestroy);
		Subsystem->OnEntityUpdate.AddDynamic(this, &UOdinClientActorManagerComponent::HandleEntityUpdate);
	}
}

void UOdinClientActorManagerComponent::EndPlay(const EEndPlayReason::Type EndPlayReason)
{
	if (UOdinClientSubsystem* Subsystem = UOdinClientSubsystem::Get(this))
	{
		Subsystem->OnEntitySpawn.RemoveDynamic(this, &UOdinClientActorManagerComponent::HandleEntitySpawn);
		Subsystem->OnEntityDestroy.RemoveDynamic(this, &UOdinClientActorManagerComponent::HandleEntityDestroy);
		Subsystem->OnEntityUpdate.RemoveDynamic(this, &UOdinClientActorManagerComponent::HandleEntityUpdate);
	}

    // Clean up pool? 
    // Actors are owned by Level, so they will be destroyed when Level ends.
    ActorPool.Empty();
    ActiveEntityActors.Empty();

	Super::EndPlay(EndPlayReason);
}


void UOdinClientActorManagerComponent::RegisterEntityMapping(const FString& EntityName, TSubclassOf<AActor> ActorClass)
{
    if (ActorClass) {
        EntityClassMap.Add(EntityName, ActorClass);
    }
}

void UOdinClientActorManagerComponent::HandleEntitySpawn(const FBPOdinCommand& Cmd)
{
    // Values[0] = Entity ID
    int32 EntityID = static_cast<int32>(Cmd.Values[0]);
    
    // If already exists, just update? Or error?
    if (ActiveEntityActors.Contains(EntityID)) {
        HandleEntityUpdate(Cmd);
        return;
    }

    // Determine class from Cmd.Data (Name)
    UClass* ClassToSpawn = DefaultActorClass;
    if (TSubclassOf<AActor>* FoundClass = EntityClassMap.Find(Cmd.DataString)) {
        ClassToSpawn = *FoundClass;
    }

    if (!ClassToSpawn) {
        ClassToSpawn = AActor::StaticClass(); 
    }

    AActor* Actor = AcquireActor(ClassToSpawn);
    if (Actor) {
        // Map ID to Actor
        ActiveEntityActors.Add(EntityID, Actor);
        
        // Initial setup from Cmd
        FVector Location(Cmd.Values[1], Cmd.Values[2], 0.0f); // Arbitrary mapping: X, Y
        Actor->SetActorLocation(Location);
    }
}

void UOdinClientActorManagerComponent::HandleEntityDestroy(const FBPOdinCommand& Cmd)
{
    int32 EntityID = static_cast<int32>(Cmd.Values[0]);
    if (AActor** ActorPtr = ActiveEntityActors.Find(EntityID)) {
        ReleaseActor(*ActorPtr);
        ActiveEntityActors.Remove(EntityID);
    }
}

void UOdinClientActorManagerComponent::HandleEntityUpdate(const FBPOdinCommand& Cmd)
{
    int32 EntityID = static_cast<int32>(Cmd.Values[0]);
    if (AActor** ActorPtr = ActiveEntityActors.Find(EntityID)) {
        AActor* Actor = *ActorPtr;
        // Update Transform
        FVector Location(Cmd.Values[1], Cmd.Values[2], 0.0f);
        Actor->SetActorLocation(Location);
        
        // Use Data or other values for Rotation/Scale/State
    }
}

AActor* UOdinClientActorManagerComponent::AcquireActor(UClass* ActorClass)
{
    if (!ActorClass) return nullptr;

    FOdinActorPool& Pool = ActorPool.FindOrAdd(ActorClass);
    AActor* Actor = nullptr;

    // Try to find valid pooled actor
    while (Pool.Actors.Num() > 0) {
        Actor = Pool.Actors.Pop();
        if (IsValid(Actor)) {
            break;
        }
        Actor = nullptr;
    }

    if (!Actor) {
        // Spawn new
        FActorSpawnParameters Params;
        Params.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AlwaysSpawn;
        Actor = GetWorld()->SpawnActor<AActor>(ActorClass, FVector::ZeroVector, FRotator::ZeroRotator, Params);
    }

    if (Actor) {
        // Activate
        Actor->SetActorHiddenInGame(false);
        Actor->SetActorEnableCollision(true);
        Actor->SetActorTickEnabled(true);
        // Reset state if needed
    }

    return Actor;
}

void UOdinClientActorManagerComponent::ReleaseActor(AActor* Actor)
{
    if (!IsValid(Actor)) return;

    // Deactivate
    Actor->SetActorHiddenInGame(true);
    Actor->SetActorEnableCollision(false);
    Actor->SetActorTickEnabled(false);
    
    // Add to pool
    FOdinActorPool& Pool = ActorPool.FindOrAdd(Actor->GetClass());
    Pool.Actors.Add(Actor);
}
