# Capability: Shared Memory Validation

## ADDED Requirements

### Requirement: Shared Memory Initialization
The system must correctly create and map a named shared memory block.

#### Scenario: Create and Open
- When `create_or_open_shared_memory` is called.
- Then a valid handle and pointer are returned.
- And the memory is zero-initialized or accessible.

### Requirement: Command Ring Buffer
The Command Ring Buffer must support FIFO operations without data corruption.

#### Scenario: Push and Pop Command
- Given an empty Input Ring.
- When a command is pushed.
- Then `has_input_command` returns true.
- And `pop_input_command` returns the exact same command.

#### Scenario: Ring Buffer Wrap-around
- Given a full Ring Buffer.
- When commands are popped and new ones pushed.
- Then the indices wrap around correctly and data is preserved.

### Requirement: Frame Data Integrity
Frame data written to the buffer must be readable and structurally correct.

#### Scenario: Write Frame
- When `write_frame` is called with a GameState.
- Then the `latest_frame_index` is updated.
- And the data in the slot matches the serialized FlatBuffer content.
