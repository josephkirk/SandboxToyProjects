// VampireSurvivalTypes.h
// Shared Memory structures matching Odin layout
// Copyright Nguyen Phi Hung. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"

// Must match Odin struct packing
#pragma pack(push, 1)

constexpr int32 MAX_ENEMIES = 100;
constexpr int32 RING_BUFFER_SIZE = 64;
constexpr int32 EVENT_QUEUE_SIZE = 16;

struct FVSVector2 {
  float X;
  float Y;
};

struct FVSPlayer {
  FVSVector2 Position;
  float Rotation;
  bool bSlashActive;
  float SlashAngle;
  int32 Health;
  uint8 Padding[3];
};

struct FVSEnemy {
  FVSVector2 Position;
  bool bIsAlive;
  uint8 Padding[3];
};

struct FVSGameState {
  FVSPlayer Player;
  FVSEnemy Enemies[MAX_ENEMIES];
  int32 EnemyCount;
  int32 Score;
  bool bIsActive;
  uint8 Padding[3];
};

struct FVSFrameSlot {
  uint64 FrameNumber;
  double Timestamp;
  FVSGameState State;
};

enum class EVSGameEventType : int32 {
  None = 0,
  StartGame = 1,
  EndGame = 2,
  PlayerInput = 3
};

struct FVSGameEvent {
  EVSGameEventType EventType;
  float MoveX;
  float MoveY;
};

struct FVSSharedMemoryBlock {
  // Ring Buffer for Game State (Odin -> Unreal)
  FVSFrameSlot Frames[RING_BUFFER_SIZE];
  int32 LatestFrameIndex; // Atomic read by Unreal

  // Event Queue (Unreal -> Odin)
  FVSGameEvent Events[EVENT_QUEUE_SIZE];
  int32 EventHead; // Atomic: next write position (Unreal)
  int32 EventTail; // Atomic: next read position (Odin)
};

#pragma pack(pop)

// Shared Memory Name (must match Odin)
#define VS_SHARED_MEMORY_NAME TEXT("OdinVampireSurvival")
