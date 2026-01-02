const std = @import("std");
const protocol = @import("protocol.zig");
const rl = @cImport({
    @cInclude("raylib.h");
});

// Credits: Nguyen Phi Hung

const Windows = std.os.windows;

extern "kernel32" fn OpenFileMappingW(
    dwDesiredAccess: Windows.DWORD,
    bInheritHandle: Windows.BOOL,
    lpName: Windows.LPCWSTR,
) callconv(.winapi) ?Windows.HANDLE;

extern "kernel32" fn MapViewOfFile(
    hFileMappingObject: Windows.HANDLE,
    dwDesiredAccess: Windows.DWORD,
    dwFileOffsetHigh: Windows.DWORD,
    dwFileOffsetLow: Windows.DWORD,
    dwNumberOfBytesToMap: Windows.SIZE_T,
) callconv(.winapi) ?Windows.LPVOID;

extern "kernel32" fn CloseHandle(hObject: Windows.HANDLE) callconv(.winapi) Windows.BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) Windows.DWORD;

const FILE_MAP_ALL_ACCESS: Windows.DWORD = 0x000F001F;
const SHARED_MEMORY_NAME = "OdinVampireSurvival";

pub fn main() !void {
    std.debug.print("Starting Zig Client...\n", .{});

    // 1. Map Shared Memory
    const name_w = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, SHARED_MEMORY_NAME);
    defer std.heap.page_allocator.free(name_w);

    const hMapFile = OpenFileMappingW(FILE_MAP_ALL_ACCESS, Windows.FALSE, name_w) orelse {
        std.debug.print("Could not open file mapping object ({d}).\n", .{GetLastError()});
        return;
    };
    defer _ = CloseHandle(hMapFile);

    const pBuf = MapViewOfFile(hMapFile, FILE_MAP_ALL_ACCESS, 0, 0, @sizeOf(protocol.SharedMemoryBlock)) orelse {
        std.debug.print("Could not map view of file ({d}).\n", .{GetLastError()});
        return;
    };
    const block: *volatile protocol.SharedMemoryBlock = @ptrCast(@alignCast(pBuf));

    // 2. Initialize Raylib
    rl.InitWindow(800, 600, "Zig Visual Client - Vampire Survival");
    rl.SetTargetFPS(60);
    defer rl.CloseWindow();

    var player_pos = rl.Vector2{ .x = 400, .y = 300 };
    var score: i32 = 0;
    var enemy_count: i32 = 0;

    while (!rl.WindowShouldClose()) {
        // 3. Process Input -> Send to Server
        var move_vec = rl.Vector2{ .x = 0, .y = 0 };
        if (rl.IsKeyDown(rl.KEY_W)) move_vec.y -= 1;
        if (rl.IsKeyDown(rl.KEY_S)) move_vec.y += 1;
        if (rl.IsKeyDown(rl.KEY_A)) move_vec.x -= 1;
        if (rl.IsKeyDown(rl.KEY_D)) move_vec.x += 1;

        if (move_vec.x != 0 or move_vec.y != 0) {
            sendMoveCommand(block, move_vec.x, move_vec.y);
        }

        // 4. Update from Shared Memory (Entities/State)
        const latest_idx = block.latest_frame_index;
        if (latest_idx >= 0) {
            // We could parse the FlatBuffer frame here if needed
            // For now, let's just listen to the entity_ring for position updates
        }

        // Listen to entity_ring for State updates
        consumeEntityUpdates(block, &player_pos, &score, &enemy_count);

        // 5. Render
        rl.BeginDrawing();
        rl.ClearBackground(rl.Color{ .r = 25, .g = 25, .b = 35, .a = 255 });

        // Draw Player
        rl.DrawCircleV(player_pos, 15, rl.SKYBLUE);
        rl.DrawCircleLines(@intFromFloat(player_pos.x), @intFromFloat(player_pos.y), 15, rl.BLUE);

        // UI
        const score_text = rl.TextFormat("Score: %d", score);
        const enemies_text = rl.TextFormat("Enemies: %d", enemy_count);
        rl.DrawText(score_text, 10, 10, 20, rl.RAYWHITE);
        rl.DrawText(enemies_text, 10, 40, 20, rl.RAYWHITE);
        rl.DrawText("Zig Client [Raylib]", 650, 570, 14, rl.GRAY);

        rl.EndDrawing();
    }
}

fn sendMoveCommand(block: *volatile protocol.SharedMemoryBlock, x: f32, y: f32) void {
    const head = @atomicLoad(i32, &block.input_ring.head, .seq_cst);
    const tail = @atomicLoad(i32, &block.input_ring.tail, .seq_cst);
    const next_head = @mod(head + 1, protocol.INPUT_RING_SIZE);

    if (next_head == tail) return; // Full

    const cmd = protocol.Command{
        .sequence = 0,
        .tick = 0,
        .player_id = 0,
        .category = .Input,
        .command_type = protocol.CMD_INPUT_MOVE,
        .flags = 0,
        .target_entity = 0,
        .target_pos = .{ x, y, 0 },
        .data_length = 0,
        .data = [_]u8{0} ** protocol.MAX_COMMAND_DATA,
    };

    block.input_ring.commands[@intCast(head)] = cmd;
    @atomicStore(i32, &block.input_ring.head, next_head, .seq_cst);
}

fn consumeEntityUpdates(block: *volatile protocol.SharedMemoryBlock, p_pos: *rl.Vector2, p_score: *i32, p_enemies: *i32) void {
    _ = p_score;
    _ = p_enemies;
    while (true) {
        const head = @atomicLoad(i32, &block.entity_ring.head, .seq_cst);
        const tail = @atomicLoad(i32, &block.entity_ring.tail, .seq_cst);
        if (head == tail) break;

        const cmd = block.entity_ring.commands[@intCast(tail)];
        if (cmd.category == .State) {
            if (cmd.command_type == protocol.CMD_STATE_PLAYER_UPDATE) {
                p_pos.x = cmd.target_pos[0];
                p_pos.y = cmd.target_pos[1];
            } else if (cmd.command_type == protocol.CMD_STATE_GAME_UPDATE) {
                // Parse metadata if sent
            }
        }

        @atomicStore(i32, &block.entity_ring.tail, @mod(tail + 1, protocol.ENTITY_RING_SIZE), .seq_cst);
    }
}
