// OdinClientActorManagerComponent.h
// Copyright Nguyen Phi Hung. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "Components/ActorComponent.h"
#include "OdinClientTypes.h"
#include "OdinClientActorManagerComponent.generated.h"


USTRUCT()
struct FOdinActorPool {
    GENERATED_BODY()
    
    UPROPERTY()
    TArray<AActor*> Actors;
};

UCLASS( ClassGroup=(Custom), meta=(BlueprintSpawnableComponent) )
class ODINRENDERCLIENT_API UOdinClientActorManagerComponent : public UActorComponent
{
	GENERATED_BODY()

    // ... (rest of the file until private section)

public:	
	UOdinClientActorManagerComponent();

protected:
	virtual void BeginPlay() override;
	virtual void EndPlay(const EEndPlayReason::Type EndPlayReason) override;

public:	
	// Default class to spawn if none specified (for simple testing)
	UPROPERTY(EditDefaultsOnly, Category = "Odin|Pooling")
	TSubclassOf<AActor> DefaultActorClass;

	// Event Handlers
	UFUNCTION()
	void HandleEntitySpawn(const FBPOdinCommand& Cmd);

	UFUNCTION()
	void HandleEntityDestroy(const FBPOdinCommand& Cmd);

	UFUNCTION()
	void HandleEntityUpdate(const FBPOdinCommand& Cmd);

    // Configuration
    UFUNCTION(BlueprintCallable, Category = "Odin|Pooling")
    void RegisterEntityMapping(const FString& EntityName, TSubclassOf<AActor> ActorClass);

	// Pooling API
	AActor* AcquireActor(UClass* ActorClass);
	void ReleaseActor(AActor* Actor);

private:
	// Map of Class -> Struct containing Array of Inactive Actors
	UPROPERTY()
	TMap<UClass*, FOdinActorPool> ActorPool; 
    
    // Map of Entity Name (from Odin) -> Actor Class
    UPROPERTY()
    TMap<FString, TSubclassOf<AActor>> EntityClassMap;
 
    
    // Non-UPROPERTY helper access to same data if needed, but UPROPERTY Map is fine with struct


	// Map of Entity ID (from Odin) -> Active Actor
	UPROPERTY()
	TMap<int32, AActor*> ActiveEntityActors;
};
