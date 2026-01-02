# Project Context

## Purpose
Vampire Survival Game using Odin as a dedicated server/backend and Unreal Engine 5 as the rendering client, communicating via Shared Memory.

## Tech Stack
- **Server**: Odin Programming Language
- **Client**: Unreal Engine 5 (C++)
- **Communication**: Windows Shared Memory, FlatBuffers
- **Build System**: Batch scripts, `odin build`, UnrealBuildTool

## Project Conventions

### Code Style
- **Odin**: Standard Odin formatting (`odin fmt`), snake_case.
- **C++**: Unreal Engine coding standard, PascalCase.

### Architecture Patterns
- **Shared Memory Ring Buffer**: Used for high-performance IPC.
- **Command Pattern**: Unified `OdinCommand` struct for Input and Game Events.
- **FlatBuffers**: Used for serializing complex game state.

### Testing Strategy
- **Odin**: Built-in testing (`odin test`).
- **Integration**: Manual verification via Headless Server + UE Client.

## Important Constraints
- Shared Memory layout must match exactly between Odin (packed structs) and C++.
- FlatBuffers schemas must be generated for both languages.
