// OdinClientSubsystem.h
// Generic Subsystem for managing Shared Memory connection to Odin
// Copyright Nguyen Phi Hung. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "Subsystems/GameInstanceSubsystem.h"
#include "OdinClientTypes.h"
#include "OdinClientSubsystem.generated.h"

DECLARE_DYNAMIC_MULTICAST_DELEGATE(FOdinConnectionDelegate);

UCLASS()
class ODINRENDERCLIENT_API UOdinClientSubsystem : public UGameInstanceSubsystem {
    GENERATED_BODY()

public:
    virtual void Initialize(FSubsystemCollectionBase& Collection) override;
    virtual void Deinitialize() override;

    UFUNCTION(BlueprintCallable, Category = "OdinClient")
    bool ConnectToOdin(FString SharedMemoryName);

    UFUNCTION(BlueprintCallable, Category = "OdinClient")
    void DisconnectFromOdin();

    UFUNCTION(BlueprintPure, Category = "OdinClient")
    bool IsConnected() const { return SharedMemory != nullptr; }

    // Raw Data Access
    const FOdinSharedMemoryBlock::FrameSlot* GetLatestFrameSlot() const;

    // ========================================
    // Command Buffer API (New Unified System)
    // ========================================
    
    // Push input command to game (Client -> Game)
    UFUNCTION(BlueprintCallable, Category = "OdinClient|Commands")
    bool PushInputCommand(FName InputName, float AxisX = 0.f, float AxisY = 0.f, float Button = 0.f);
    
    // Push game lifecycle command (Client -> Game)
    UFUNCTION(BlueprintCallable, Category = "OdinClient|Commands")
    bool PushGameCommand(float GameState, FName StateName = NAME_None);
    
    // Check for pending entity commands from game
    UFUNCTION(BlueprintPure, Category = "OdinClient|Commands")
    bool HasEntityCommand() const;
    
    // Pop entity command from game (Game -> Client)
    // Not Blueprint-exposed since FOdinCommand is a raw packed struct
    bool PopEntityCommand(FOdinCommand& OutCommand);
    
    // Helper to create command struct
    static FOdinCommand MakeCommand(uint8 Type, float V0 = 0.f, float V1 = 0.f, float V2 = 0.f, float V3 = 0.f, const FString& Data = TEXT(""));

    UPROPERTY(BlueprintAssignable, Category = "OdinClient")
    FOdinConnectionDelegate OnConnected;

    UPROPERTY(BlueprintAssignable, Category = "OdinClient")
    FOdinConnectionDelegate OnDisconnected;

private:
    void* SharedMemoryHandle = nullptr;
    FOdinSharedMemoryBlock* SharedMemory = nullptr;
    
    // Internal command push/pop
    bool PushCommand(TOdinCommandRing<ODIN_INPUT_RING_SIZE>& Ring, const FOdinCommand& Cmd);
    bool PopCommand(TOdinCommandRing<ODIN_ENTITY_RING_SIZE>& Ring, FOdinCommand& OutCmd);
};
