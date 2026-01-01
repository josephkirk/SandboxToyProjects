// OdinDataObject.h
// Base UObject class for objects that receive Odin data
// Copyright Nguyen Phi Hung. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "UObject/NoExportTypes.h"
#include "OdinDataReceiver.h"
#include "OdinDataObject.generated.h"

UCLASS(Abstract, BlueprintType)
class ODINRENDERCLIENT_API UOdinDataObject : public UObject, public IOdinDataReceiver {
    GENERATED_BODY()

public:
    // Subclasses implement schema-specific parsing
    virtual void UpdateFromOdinData(const uint8* Buffer, int32 Size) override 
        PURE_VIRTUAL(UOdinDataObject::UpdateFromOdinData, );
    
    virtual void OnAcquiredFromPool() override {}
    virtual void OnReleasedToPool() override {}
};
