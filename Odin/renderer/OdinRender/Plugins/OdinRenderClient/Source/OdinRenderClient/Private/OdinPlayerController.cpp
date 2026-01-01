// OdinPlayerController.cpp
// Copyright Nguyen Phi Hung. All Rights Reserved.

#include "OdinPlayerController.h"
#include "EnhancedInputComponent.h"
#include "EnhancedInputSubsystems.h"
#include "InputMappingContext.h"
#include "OdinClientSubsystem.h"

AOdinPlayerController::AOdinPlayerController() {
    PrimaryActorTick.bCanEverTick = true;
    TimeSinceLastSend = 0.0f;
}

void AOdinPlayerController::BeginPlay() {
    Super::BeginPlay();

    // Get Odin client subsystem
    if (UGameInstance* GI = GetGameInstance()) {
        OdinClient = GI->GetSubsystem<UOdinClientSubsystem>();
    }

    // Add input mapping context
    if (UEnhancedInputLocalPlayerSubsystem* Subsystem = ULocalPlayer::GetSubsystem<UEnhancedInputLocalPlayerSubsystem>(GetLocalPlayer())) {
        if (DefaultMappingContext) {
            Subsystem->AddMappingContext(DefaultMappingContext, 0);
        }
    }

    // Initialize input values
    for (const FOdinInputBinding& Binding : InputBindings) {
        CurrentInputValues.Add(Binding.InputName, FVector4::Zero());
    }
}

void AOdinPlayerController::SetupInputComponent() {
    Super::SetupInputComponent();

    UEnhancedInputComponent* EnhancedInput = Cast<UEnhancedInputComponent>(InputComponent);
    if (!EnhancedInput) return;

    for (const FOdinInputBinding& Binding : InputBindings) {
        if (!Binding.Action) continue;

        FName InputName = Binding.InputName;

        EnhancedInput->BindAction(
            Binding.Action,
            ETriggerEvent::Triggered,
            this,
            &AOdinPlayerController::OnInputTriggered,
            InputName
        );

        EnhancedInput->BindAction(
            Binding.Action,
            ETriggerEvent::Completed,
            this,
            &AOdinPlayerController::OnInputCompleted,
            InputName
        );
    }
}

void AOdinPlayerController::Tick(float DeltaTime) {
    Super::Tick(DeltaTime);

    TimeSinceLastSend += DeltaTime;
    float SendInterval = 1.0f / InputSendRate;

    if (TimeSinceLastSend >= SendInterval) {
        SendInputToOdin();
        TimeSinceLastSend = 0.0f;
    }
}

void AOdinPlayerController::OnInputTriggered(const FInputActionValue& Value, FName InputName) {
    FVector4& Stored = CurrentInputValues.FindOrAdd(InputName);

    switch (Value.GetValueType()) {
    case EInputActionValueType::Boolean:
        Stored = FVector4(Value.Get<bool>() ? 1.0f : 0.0f, 0.0f, 0.0f, 0.0f);
        break;
    case EInputActionValueType::Axis1D:
        Stored = FVector4(Value.Get<float>(), 0.0f, 0.0f, 0.0f);
        break;
    case EInputActionValueType::Axis2D:
        {
            FVector2D V2 = Value.Get<FVector2D>();
            Stored = FVector4(V2.X, V2.Y, 0.0f, 0.0f);
        }
        break;
    case EInputActionValueType::Axis3D:
        {
            FVector V3 = Value.Get<FVector>();
            Stored = FVector4(V3.X, V3.Y, V3.Z, 0.0f);
        }
        break;
    }
}

void AOdinPlayerController::OnInputCompleted(const FInputActionValue& Value, FName InputName) {
    if (FVector4* Stored = CurrentInputValues.Find(InputName)) {
        *Stored = FVector4::Zero();
    }
}

void AOdinPlayerController::SendInputToOdin() {
    if (!OdinClient) return;

    for (const auto& Pair : CurrentInputValues) {
        const FName& InputName = Pair.Key;
        const FVector4& Values = Pair.Value;

        // Only send if there is non-zero input
        if (!Values.IsNearlyZero3()) {
            OdinClient->PushInputCommand(
                InputName,
                Values.X,
                Values.Y,
                Values.Z
            );
        }
    }
}
