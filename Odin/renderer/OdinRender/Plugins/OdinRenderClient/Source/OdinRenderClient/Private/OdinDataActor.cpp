// OdinDataActor.cpp
// Copyright Nguyen Phi Hung. All Rights Reserved.

#include "OdinDataActor.h"
#include "OdinDataObject.h"
#include "Components/PrimitiveComponent.h"

AOdinDataActor::AOdinDataActor() {
    PrimaryActorTick.bCanEverTick = false;
    PrimaryActorTick.bStartWithTickEnabled = false;
}

void AOdinDataActor::UpdateFromOdinData(const uint8* Buffer, int32 Size) {
    if (DataObject) {
        DataObject->UpdateFromOdinData(Buffer, Size);
    }
}

void AOdinDataActor::OnAcquiredFromPool() {
    SetPooledActive(true);
    if (DataObject) {
        DataObject->OnAcquiredFromPool();
    }
}

void AOdinDataActor::OnReleasedToPool() {
    SetPooledActive(false);
    if (DataObject) {
        DataObject->OnReleasedToPool();
    }
}

void AOdinDataActor::SetPooledActive(bool bActive) {
    SetActorHiddenInGame(!bActive);
    SetActorEnableCollision(bActive);
    SetActorTickEnabled(bActive);
    
    // Disable/enable component ticks
    TArray<UActorComponent*> Components;
    GetComponents(Components);
    for (UActorComponent* Comp : Components) {
        Comp->SetComponentTickEnabled(bActive);
    }
}
