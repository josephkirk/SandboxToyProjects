# Vampire Survival: Odin-Unreal Hybrid Game

A high-performance hybrid game architecture demonstrating zero-copy shared memory synchronization between an **Odin** game server and an **Unreal Engine 5** rendering client, using **FlatBuffers** for schema-evolvable serialization.

## Overview

The project splits the game responsibilities:
-   **Odin (Producer)**: Runs the core game logic (simulation, physics, AI) and writes the game state to a shared memory ring buffer.
-   **Unreal Engine 5 (Consumer)**: Reads the game state from shared memory and renders the scene using high-fidelity assets and lighting.
-   **Shared Memory**: A lock-free(ish) circular buffer conveying FlatBuffer-encoded frames.

## Architecture

1.  **Schema Source of Truth**: `Odin/schemas/GameState.fbs` defines the data structure.
2.  **Code Generation**: A build script (`Odin/tools/build_schemas.py`) generates:
    -   **Odin**: `Odin/game/generated/game_state.odin` (Serialization logic).
    -   **C++**: `OdinRenderClient/Source/OdinRenderClient/Public/Generated/` (Headers & UObject Wrappers).
3.  **Communication**:
    -   Odin writes a `FrameSlot` (seq number, timestamp, FlatBuffer bytes) to shared memory.
    -   Unreal's `UVampireSurvivalSubsystem` reads the latest frame, verifies the FlatBuffer, and wraps it in a `UGameStateWrapper`.
    -   Unreal Blueprints access the game state via the Wrapper's API.

## User Guide

### Prerequisites
-   **Odin Compiler**: Ensure `odin` is in your PATH or utilize the provided vendor version.
-   **Unreal Engine 5**: Version 5.3 or later recommended.
-   **Python 3**: For running build scripts.
-   **FlatBuffers Compiler (`flatc`)**: Located in `thirdparties/Windows.flatc.binary/`.

### 1. Running the Odin Server
The Odin server drives the game state.

**Visualizer Mode (Debug)**
Runs with a Raylib window to visualize the state locally for debugging.
```bash
odin run Odin/game/main.odin -file
```

**Headless Mode (Production/Unreal)**
Runs without a window, optimized for serving the Unreal client.
```bash
odin run Odin/game/main.odin -file -- -headless
```
*Note: The server must be running BEFORE the Unreal client connects.*

### 2. Running the Unreal Client
1.  Open `Odin/renderer/OdinRender/OdinRender.uproject` in Unreal Engine 5.
2.  Press **Play** in the Editor.
3.  The GameMode will automatically connect to the shared memory and start replicating the Odin state.

## Developer Guide

### Project Structure
```
Odin/
├── game/
│   ├── main.odin           # Game loop & Shared Memory writer
│   ├── flatbuffers/        # Custom Odin FlatBuffer builder
│   └── generated/          # Generated Odin packing code
├── renderer/
│   └── OdinRender/         # Unreal Engine 5 Project
│       └── Plugins/OdinRenderClient/
│           ├── Public/Generated/   # Generated C++ Wrappers
│           └── Private/            # Subsystem implementation
├── schemas/
│   └── GameState.fbs       # FlatBuffers Schema (Source of Truth)
└── tools/
    └── build_schemas.py    # Code generation orchestration script
```

### Workflow: Modifying Game State
1.  **Edit Schema**: Modify `Odin/schemas/GameState.fbs`.
    ```flatbuffers
    table Player {
        position: Vec2;
        new_field: int; // <--- Added field
    }
    ```
2.  **Run Build Script**:
    ```bash
    uv run Odin/tools/build_schemas.py
    ```
    This updates C++ headers, Unreal Wrappers, and Odin bindings.
3.  **Update Odin Logic**:
    -   Update `Odin/game/main.odin`'s `write_frame` procedure to populate the new field in the builder.
4.  **Update Unreal Logic**:
    -   Recompile the Unreal Project (Live Coding or IDE).
    -   The new field is now available in Blueprint via `UPlayerWrapper::GetNewField()`.

### Implementation Details

**Shared Memory Layout**
The shared memory block contains a Ring Buffer of `FrameSlot`s.
```odin
FrameSlot :: struct {
    frame_number: u64,
    timestamp:    f64,
    data_size:    u32,
    data:         [MAX_FRAME_SIZE]u8, // Raw FlatBuffer bytes
}
```

**FlatBuffers Integration**
-   We use a custom minimal FlatBuffers builder in Odin (`Odin/game/flatbuffers/builder.odin`) to avoid full library dependencies.
-   Unreal uses the official `flatbuffers` library (header-only) to verify and read data.
-   **Wrappers**: We generate `UObject` wrappers because standard C++ FlatBuffer accessors are not Blueprint-compatible. These wrappers hold a pointer to the shared memory and provide `UFUNCTION` getters.