// OdinDataActor.h
// Base Actor class for pooled actors that receive Odin data
// Copyright Nguyen Phi Hung. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "GameFramework/Actor.h"
#include "OdinDataReceiver.h"
#include "OdinDataActor.generated.h"

class UOdinDataObject;

UCLASS(Abstract)
class ODINRENDERCLIENT_API AOdinDataActor : public AActor, public IOdinDataReceiver {
    GENERATED_BODY()

public:
    AOdinDataActor();

protected:
    UPROPERTY(BlueprintReadOnly, Category = "OdinData")
    UOdinDataObject* DataObject;

public:
    // IOdinDataReceiver implementation - delegates to DataObject
    virtual void UpdateFromOdinData(const uint8* Buffer, int32 Size) override;
    virtual void OnAcquiredFromPool() override;
    virtual void OnReleasedToPool() override;
    
    // Pooling helpers
    UFUNCTION(BlueprintCallable, Category = "OdinData")
    void SetPooledActive(bool bActive);
    
    // Access to data object
    UFUNCTION(BlueprintPure, Category = "OdinData")
    UOdinDataObject* GetDataObject() const { return DataObject; }
    
    // Template accessor for subclasses
    template<typename T>
    T* GetTypedData() const { return Cast<T>(DataObject); }
};
