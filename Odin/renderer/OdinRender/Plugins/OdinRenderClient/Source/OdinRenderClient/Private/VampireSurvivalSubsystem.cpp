// VampireSurvivalSubsystem.cpp
// Copyright Nguyen Phi Hung. All Rights Reserved.

#include "VampireSurvivalSubsystem.h"
#if PLATFORM_WINDOWS
#include "Windows/AllowWindowsPlatformTypes.h"
#include "Windows/HideWindowsPlatformTypes.h"
#include <windows.h>

#endif

void UVampireSurvivalSubsystem::Initialize(
    FSubsystemCollectionBase &Collection) {
  Super::Initialize(Collection);
  UE_LOG(LogTemp, Log, TEXT("VampireSurvivalSubsystem initialized"));
}

void UVampireSurvivalSubsystem::Deinitialize() {
  DisconnectFromOdin();
  Super::Deinitialize();
}

bool UVampireSurvivalSubsystem::ConnectToOdin() {
  if (SharedMemory != nullptr) {
    UE_LOG(LogTemp, Warning, TEXT("Already connected to Odin"));
    return true;
  }

  // Open existing shared memory created by Odin
  SharedMemoryHandle =
      OpenFileMappingW(FILE_MAP_ALL_ACCESS, false, VS_SHARED_MEMORY_NAME);

  if (SharedMemoryHandle == nullptr) {
    UE_LOG(LogTemp, Error,
           TEXT("Failed to open shared memory. Is Odin running?"));
    return false;
  }

  SharedMemory = static_cast<FVSSharedMemoryBlock *>(
      MapViewOfFile(SharedMemoryHandle, FILE_MAP_ALL_ACCESS, 0, 0,
                    sizeof(FVSSharedMemoryBlock)));

  if (SharedMemory == nullptr) {
    CloseHandle(SharedMemoryHandle);
    SharedMemoryHandle = nullptr;
    UE_LOG(LogTemp, Error, TEXT("Failed to map shared memory view"));
    return false;
  }

  UE_LOG(LogTemp, Log, TEXT("Connected to Odin shared memory"));
  OnConnected.Broadcast();
  return true;
}

void UVampireSurvivalSubsystem::DisconnectFromOdin() {
  if (SharedMemory != nullptr) {
    UnmapViewOfFile(SharedMemory);
    SharedMemory = nullptr;
  }

  if (SharedMemoryHandle != nullptr) {
    CloseHandle(SharedMemoryHandle);
    SharedMemoryHandle = nullptr;
  }

  LastReadFrameNumber = -1;
  UE_LOG(LogTemp, Log, TEXT("Disconnected from Odin"));
  OnDisconnected.Broadcast();
}

bool UVampireSurvivalSubsystem::SendEvent(const FVSGameEvent &Event) {
  if (SharedMemory == nullptr) {
    UE_LOG(LogTemp, Warning, TEXT("Cannot send event: not connected"));
    return false;
  }

  // Atomic read of current head
  int32 Head = FPlatformAtomics::AtomicRead(&SharedMemory->EventHead);
  int32 Tail = FPlatformAtomics::AtomicRead(&SharedMemory->EventTail);

  // Check if queue is full
  int32 NextHead = (Head + 1) % EVENT_QUEUE_SIZE;
  if (NextHead == Tail) {
    UE_LOG(LogTemp, Warning, TEXT("Event queue full, dropping event"));
    return false;
  }

  // Write event
  SharedMemory->Events[Head] = Event;

  // Update head atomically
  FPlatformAtomics::InterlockedExchange(&SharedMemory->EventHead, NextHead);

  return true;
}

void UVampireSurvivalSubsystem::SendStartGame() {
  FVSGameEvent Event;
  Event.EventType = EVSGameEventType::StartGame;
  Event.MoveX = 0.0f;
  Event.MoveY = 0.0f;

  if (SendEvent(Event)) {
    UE_LOG(LogTemp, Log, TEXT("Sent StartGame event"));
  }
}

void UVampireSurvivalSubsystem::SendEndGame() {
  FVSGameEvent Event;
  Event.EventType = EVSGameEventType::EndGame;
  Event.MoveX = 0.0f;
  Event.MoveY = 0.0f;

  if (SendEvent(Event)) {
    UE_LOG(LogTemp, Log, TEXT("Sent EndGame event"));
  }
}

void UVampireSurvivalSubsystem::SendPlayerInput(float MoveX, float MoveY) {
  FVSGameEvent Event;
  Event.EventType = EVSGameEventType::PlayerInput;
  Event.MoveX = MoveX;
  Event.MoveY = MoveY;

  SendEvent(Event);
}

bool UVampireSurvivalSubsystem::ReadLatestGameState(FVSGameState &OutState) {
  if (SharedMemory == nullptr) {
    return false;
  }

  // Read latest frame index atomically
  int32 LatestIndex =
      FPlatformAtomics::AtomicRead(&SharedMemory->LatestFrameIndex);

  if (LatestIndex < 0 || LatestIndex >= RING_BUFFER_SIZE) {
    return false;
  }

  const FVSFrameSlot &Slot = SharedMemory->Frames[LatestIndex];

  // Check if this is a new frame
  if (static_cast<int32>(Slot.FrameNumber) == LastReadFrameNumber) {
    return false; // No new data
  }

  OutState = Slot.State;
  LastReadFrameNumber = static_cast<int32>(Slot.FrameNumber);

  return true;
}
