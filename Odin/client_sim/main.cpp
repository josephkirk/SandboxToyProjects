#include <windows.h>
#include <iostream>
#include <vector>
#include <string>
#include <thread>
#include <chrono>
#include <cmath>
#include <atomic>

#include "GameState_generated.h"

// Constants
const int MAX_ENEMIES = 100;
const int RING_BUFFER_SIZE = 64;
const int COMMAND_DATA_SIZE = 128;
const int MAX_FRAME_SIZE = 16 * 1024;
const wchar_t* SHARED_MEMORY_NAME = L"OdinVampireSurvival";
const int INPUT_RING_SIZE = 16;
const int ENTITY_RING_SIZE = 64;

// Packed Structs
#pragma pack(push, 1)

enum class CommandCategory : uint16_t {
    None     = 0,
    System   = 1,
    Input    = 2,
    State    = 3,
    Action   = 4,
    Movement = 5,
    Event    = 6,
};

struct OdinCommand {
    uint32_t         sequence;
    uint64_t         tick;
    uint32_t         player_id;
    CommandCategory  category;
    uint16_t         type;
    uint16_t         flags;
    uint32_t         target_entity;
    float            target_pos[3];
    uint16_t         data_length;
    uint8_t          data[COMMAND_DATA_SIZE];
};

template <int Size>
struct CommandRing {
    int32_t head;
    int32_t tail;
    OdinCommand commands[Size];
};

struct FrameSlot {
    uint64_t frame_number;
    double timestamp;
    uint32_t data_size;
    uint8_t data[MAX_FRAME_SIZE];
};

struct SharedMemoryBlock {
    uint32_t magic;
    uint32_t version;
    FrameSlot frames[RING_BUFFER_SIZE];
    int32_t latest_frame_index;
    CommandRing<INPUT_RING_SIZE> input_ring;
    CommandRing<ENTITY_RING_SIZE> entity_ring;
};

#pragma pack(pop)

// Command Types (Categorized)
const uint16_t CMD_GAME_START = 0x81;
const uint16_t CMD_INPUT_MOVE = 0x01;
const uint16_t CMD_STATE_PLAYER_UPDATE = 0x01;

void push_input_command(SharedMemoryBlock* smh, OdinCommand cmd) {
    int32_t tail = std::atomic_load((std::atomic<int32_t>*)&smh->input_ring.tail);
    int32_t head = std::atomic_load((std::atomic<int32_t>*)&smh->input_ring.head);
    
    int32_t next_head = (head + 1) % INPUT_RING_SIZE;
    
    if (next_head == tail) {
        // Full
        return;
    }
    
    smh->input_ring.commands[head] = cmd;
    std::atomic_store((std::atomic<int32_t>*)&smh->input_ring.head, next_head);
    // std::cout << "Push CMD: Type=" << (int)cmd.type << " Head=" << next_head << std::endl;
}

OdinCommand make_command(CommandCategory cat, uint16_t type, float x, float y, float z, const std::string& data_str = "") {
    OdinCommand cmd = {};
    cmd.category = cat;
    cmd.type = type;
    cmd.target_pos[0] = x;
    cmd.target_pos[1] = y;
    cmd.target_pos[2] = z;
    
    size_t len = std::min(data_str.length(), (size_t)COMMAND_DATA_SIZE);
    memcpy(cmd.data, data_str.c_str(), len);
    cmd.data_length = (uint16_t)len;
    
    return cmd;
}

int main() {
    std::cout << "=== C++ Client Simulator ===" << std::endl;
    
    // Open Shared Memory
    HANDLE handle = OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE, SHARED_MEMORY_NAME);
    
    if (handle == NULL) {
        std::cerr << "ERROR: Could not open file mapping. Error: " << GetLastError() << std::endl;
        return 1;
    }
    
    void* ptr = MapViewOfFile(handle, FILE_MAP_ALL_ACCESS, 0, 0, 0);
    if (ptr == NULL) {
        std::cerr << "ERROR: Could not map view of file." << std::endl;
        CloseHandle(handle);
        return 1;
    }
    
    SharedMemoryBlock* smh = (SharedMemoryBlock*)ptr;
    
    std::cout << "Connected to Shared Memory!" << std::endl;
    std::cout << "Magic: 0x" << std::hex << smh->magic << std::dec << " | Version: " << smh->version << std::endl;
    
    std::cout << "Struct Sizes:" << std::endl;
    std::cout << "  FrameSlot: " << sizeof(FrameSlot) << std::endl;
    std::cout << "  SharedMemoryBlock: " << sizeof(SharedMemoryBlock) << std::endl;
    std::cout << "  OdinCommand: " << sizeof(OdinCommand) << std::endl;
    
    std::cout << "Offsets:" << std::endl;
    std::cout << "  frames: " << offsetof(SharedMemoryBlock, frames) << std::endl;
    std::cout << "  latest_frame_index: " << offsetof(SharedMemoryBlock, latest_frame_index) << std::endl;
    std::cout << "  input_ring: " << offsetof(SharedMemoryBlock, input_ring) << std::endl;
    std::cout << "  entity_ring: " << offsetof(SharedMemoryBlock, entity_ring) << std::endl;

    
    if (smh->magic != 0x12345678) {
        std::cerr << "ERROR: Invalid Magic Number!" << std::endl;
        // Proceed anyway for debugging
    }
    
    // 1. Send START GAME Command
    std::cout << "Sending START GAME..." << std::endl;
    push_input_command(smh, make_command(CommandCategory::System, CMD_GAME_START, 1.0f, 0, 0));
    
    int32_t last_frame_idx = -1;
    int frames_received = 0;
    
    // Loop for 5 seconds (simulated) or N frames
    auto start_time = std::chrono::steady_clock::now();
    
    while (true) {
        auto now = std::chrono::steady_clock::now();
        if (std::chrono::duration_cast<std::chrono::seconds>(now - start_time).count() > 10) {
            break;
        }
        
        // Check for new frames
        int32_t latest_idx = std::atomic_load((std::atomic<int32_t>*)&smh->latest_frame_index);
        if (latest_idx != last_frame_idx) {
            // New frame!
            FrameSlot* slot = &smh->frames[latest_idx];
            
            // Verify Frame Number
            // std::cout << "Frame: " << slot->frame_number << " Size: " << slot->data_size << std::endl;
            
            // Parse FlatBuffer
            if (slot->data_size > 0) {
                auto game_state = VS::Schema::GetGameState(slot->data);
                
                // GameState no longer contains player data; player updates are via entity ring.
            }
            
            last_frame_idx = latest_idx;
            frames_received++;
        }
        
        // Check for Entity Updates (Player Pos)
        int32_t tail = std::atomic_load((std::atomic<int32_t>*)&smh->entity_ring.tail);
        int32_t head = std::atomic_load((std::atomic<int32_t>*)&smh->entity_ring.head);
        
        while (tail != head) {
            OdinCommand* cmd = &smh->entity_ring.commands[tail];
            
            // std::cout << "Entity CMD: 0x" << std::hex << (int)cmd->type << std::dec << std::endl;
            
            if (cmd->category == CommandCategory::State && cmd->type == CMD_STATE_PLAYER_UPDATE) {
                // Use target_pos: x, y, z
                float x = cmd->target_pos[0];
                float y = cmd->target_pos[1];
                std::cerr << "CLIENT PLAYER: Pos=" << x << "," << y << std::endl;
            }
            
            tail = (tail + 1) % ENTITY_RING_SIZE;
            std::atomic_store((std::atomic<int32_t>*)&smh->entity_ring.tail, tail);
        }
        
        // Send Move Command (Circle)
        float t = (float)frames_received * 0.1f;
        float x = cos(t);
        float y = sin(t);
        push_input_command(smh, make_command(CommandCategory::Input, CMD_INPUT_MOVE, x, y, 0, "Move"));
        
        // Sim Hitching
        if (frames_received > 0 && frames_received % 100 == 0) {
            std::cerr << "[HITCH] Simulated Lag Spike" << std::endl;
            Sleep(500); 
        }

        Sleep(16);
    }
    
    // Send END GAME Command
    std::cout << "Sending END GAME..." << std::endl;
    push_input_command(smh, make_command(CommandCategory::System, CMD_GAME_START, -1.0f, 0, 0));
    
    UnmapViewOfFile(ptr);
    CloseHandle(handle);
    
    std::cout << "Client Finished." << std::endl;
    return 0;
}
