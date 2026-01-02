# Proposal: Verify Shared Memory Communication

## Context
The project uses a custom Shared Memory Ring Buffer implementation for low-latency communication between the Odin server and Unreal Engine client. Currently, verification relies on running the full game and visually inspecting behavior. We need a more automated way to verify the low-level communication mechanics on the Odin side.

## Objective
Add an Odin test suite to verify:
1.  Shared Memory creation and mapping.
2.  Command Ring Buffer operations (Push/Pop).
3.  Frame Data writing and reading.

## Capabilities
- **Shared Memory Test Suite**: A set of tests using `core:testing` to validate memory layout and logic.

## Design
- Create `game/shared_memory_test.odin` (or `game/tests/`) with `@(test)` procedures.
- The test will act as both "Server" (writing frames) and "Client" (writing inputs) within the same process or mocked context to verify data integrity.
