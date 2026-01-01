// OdinDataReceiver.h
// Interface for objects that receive data updates from Odin
// Copyright Nguyen Phi Hung. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "UObject/Interface.h"
#include "OdinDataReceiver.generated.h"

UINTERFACE(MinimalAPI, BlueprintType)
class UOdinDataReceiver : public UInterface {
    GENERATED_BODY()
};

class ODINRENDERCLIENT_API IOdinDataReceiver {
    GENERATED_BODY()
public:
    // Update object state from raw FlatBuffer data
    virtual void UpdateFromOdinData(const uint8* Buffer, int32 Size) = 0;
    
    // Called when object is acquired from pool
    virtual void OnAcquiredFromPool() {}
    
    // Called when object is released to pool
    virtual void OnReleasedToPool() {}
};
