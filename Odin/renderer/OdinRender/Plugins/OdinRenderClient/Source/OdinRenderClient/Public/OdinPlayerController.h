// OdinPlayerController.h
// Generic Player Controller with flexible Enhanced Input for Odin
// Copyright Nguyen Phi Hung. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "GameFramework/PlayerController.h"
#include "InputActionValue.h"
#include "OdinPlayerController.generated.h"

class UInputMappingContext;
class UInputAction;
class UOdinClientSubsystem;

// Binding entry for an input action
USTRUCT(BlueprintType)
struct ODINRENDERCLIENT_API FOdinInputBinding {
    GENERATED_BODY()

    // Name sent to Odin (e.g., "Move", "Look", "Jump")
    UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Input")
    FName InputName;

    // The Enhanced Input Action to bind
    UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Input")
    TObjectPtr<UInputAction> Action;
};

UCLASS()
class ODINRENDERCLIENT_API AOdinPlayerController : public APlayerController {
    GENERATED_BODY()

public:
    AOdinPlayerController();

protected:
    virtual void BeginPlay() override;
    virtual void SetupInputComponent() override;
    virtual void Tick(float DeltaTime) override;

    // Input mapping context to add on BeginPlay
    UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, Category = "Odin|Input")
    TObjectPtr<UInputMappingContext> DefaultMappingContext;

    // List of input bindings - each action is sent to Odin by name
    UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, Category = "Odin|Input")
    TArray<FOdinInputBinding> InputBindings;

    // Rate at which input is sent to Odin (Hz)
    UPROPERTY(EditDefaultsOnly, Category = "Odin|Input", meta = (ClampMin = "1", ClampMax = "120"))
    float InputSendRate = 60.0f;

private:
    UPROPERTY()
    TObjectPtr<UOdinClientSubsystem> OdinClient;

    // Cached input values by name
    TMap<FName, FVector4> CurrentInputValues;
    float TimeSinceLastSend;

    void OnInputTriggered(const FInputActionValue& Value, FName InputName);
    void OnInputCompleted(const FInputActionValue& Value, FName InputName);
    void SendInputToOdin();
};
