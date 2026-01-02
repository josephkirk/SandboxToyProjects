const std = @import("std");
const protocol = @import("protocol.zig");
const rl = @cImport({
    @cInclude("raylib.h");
});

// Credits: Nguyen Phi Hung

const Windows = std.os.windows;
const kernel32 = std.os.windows.kernel32;

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
) callconv(.winapi) ?*anyopaque;

extern "kernel32" fn UnmapViewOfFile(lpBaseAddress: ?*const anyopaque) callconv(.winapi) Windows.BOOL;
extern "kernel32" fn CloseHandle(hObject: Windows.HANDLE) callconv(.winapi) Windows.BOOL;
extern "kernel32" fn Sleep(dwMilliseconds: Windows.DWORD) callconv(.winapi) void;

const FILE_MAP_ALL_ACCESS: Windows.DWORD = 0x000F001F;
const SHARED_MEMORY_NAME = "OdinVampireSurvival";

const ConnectionState = enum {
    Disconnected,
    Connected,
};

pub fn main() void {
    mainImpl() catch |err| {
        std.debug.print("CRITICAL ERROR: {any}\n", .{err});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
    };
}

fn mainImpl() !void {
    std.debug.print("Starting Zig Client...\n", .{});

    // 1. Initialize Raylib First
    rl.InitWindow(800, 600, "Zig Visual Client - Vampire Survival");
    rl.SetTargetFPS(60);
    defer rl.CloseWindow();

    var state = ConnectionState.Disconnected;
    var hMapFile: ?Windows.HANDLE = null;
    var pBuf: ?*anyopaque = null;
    var block: ?*volatile protocol.SharedMemoryBlock = null;

    var current_game_state: protocol.GameState = std.mem.zeroes(protocol.GameState);
    var last_move_vec = rl.Vector2{ .x = 0, .y = 0 };

    var last_frame_idx: i32 = -1;
    var time_since_last_frame: f32 = 0.0;
    const CONNECTION_TIMEOUT = 2.0;

    const name_w = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, SHARED_MEMORY_NAME);
    defer std.heap.page_allocator.free(name_w);

    while (!rl.WindowShouldClose()) {
        const dt = rl.GetFrameTime();

        switch (state) {
            .Disconnected => {
                // Try to connect
                hMapFile = OpenFileMappingW(FILE_MAP_ALL_ACCESS, Windows.FALSE, name_w);
                if (hMapFile) |handle| {
                    pBuf = MapViewOfFile(handle, FILE_MAP_ALL_ACCESS, 0, 0, @sizeOf(protocol.SharedMemoryBlock));
                    if (pBuf) |buf| {
                        block = @ptrCast(@alignCast(buf));
                        if (block.?.magic == 0x12345678) {
                            state = .Connected;
                            std.debug.print("Connected to Server! Magic: 0x{X}\n", .{block.?.magic});
                            time_since_last_frame = 0;
                            last_frame_idx = -1;
                        } else {
                            // Invalid magic, unmap immediately
                            _ = UnmapViewOfFile(buf);
                            _ = CloseHandle(handle);
                            hMapFile = null;
                            pBuf = null;
                            block = null;
                        }
                    } else {
                        _ = CloseHandle(handle);
                        hMapFile = null;
                    }
                }

                rl.BeginDrawing();
                rl.ClearBackground(rl.Color{ .r = 10, .g = 10, .b = 15, .a = 255 });
                rl.DrawText("Waiting for Server...", 280, 280, 24, rl.GRAY);
                rl.DrawText("Run 'manage.ps1 run-server' to start", 220, 320, 20, rl.DARKGRAY);
                rl.EndDrawing();

                Sleep(100);
            },
            .Connected => {
                if (block) |blk| {
                    // Check Heartbeat
                    const latest_idx = @atomicLoad(i32, &blk.latest_frame_index, .acquire);

                    if (latest_idx != last_frame_idx) {
                        time_since_last_frame = 0;
                        last_frame_idx = latest_idx;

                        if (latest_idx >= 0) {
                            const slot = &blk.frames[@intCast(latest_idx)];
                            if (slot.data_size == @sizeOf(protocol.GameState)) {
                                const state_ptr = @as(*const volatile protocol.GameState, @ptrCast(@alignCast(&slot.data[0])));
                                current_game_state = state_ptr.*;
                            }
                        }
                    } else {
                        time_since_last_frame += dt;
                    }

                    if (time_since_last_frame > CONNECTION_TIMEOUT) {
                        std.debug.print("Server Lost (Timeout). Disconnecting...\n", .{});
                        if (pBuf) |buf| _ = UnmapViewOfFile(buf);
                        if (hMapFile) |h| _ = CloseHandle(h);
                        pBuf = null;
                        hMapFile = null;
                        block = null;
                        state = .Disconnected;
                        continue;
                    }

                    // Process Input
                    var move_vec = rl.Vector2{ .x = 0, .y = 0 };
                    if (rl.IsKeyDown(rl.KEY_W) or rl.IsKeyDown(rl.KEY_UP)) move_vec.y -= 1;
                    if (rl.IsKeyDown(rl.KEY_S) or rl.IsKeyDown(rl.KEY_DOWN)) move_vec.y += 1;
                    if (rl.IsKeyDown(rl.KEY_A) or rl.IsKeyDown(rl.KEY_LEFT)) move_vec.x -= 1;
                    if (rl.IsKeyDown(rl.KEY_D) or rl.IsKeyDown(rl.KEY_RIGHT)) move_vec.x += 1;

                    if (move_vec.x != last_move_vec.x or move_vec.y != last_move_vec.y) {
                        sendMoveCommand(blk, move_vec.x, move_vec.y);
                        last_move_vec = move_vec;
                    }

                    renderGame(blk, &current_game_state);
                }
            },
        }
    }

    // Cleanup
    if (state == .Connected) {
        if (pBuf) |buf| _ = UnmapViewOfFile(buf);
        if (hMapFile) |h| _ = CloseHandle(h);
    }
}

// Helper to keep main clean
fn renderGame(block: *volatile protocol.SharedMemoryBlock, gs: *const protocol.GameState) void {
    rl.BeginDrawing();
    defer rl.EndDrawing();

    rl.ClearBackground(rl.Color{ .r = 20, .g = 20, .b = 30, .a = 255 });

    // Draw Grid
    var x: i32 = 0;
    while (x < 800) : (x += 50) {
        rl.DrawLine(x, 0, x, 600, rl.Color{ .r = 40, .g = 40, .b = 50, .a = 255 });
    }
    var y: i32 = 0;
    while (y < 600) : (y += 50) {
        rl.DrawLine(0, y, 800, y, rl.Color{ .r = 40, .g = 40, .b = 50, .a = 255 });
    }

    const p = &gs.player;

    // Draw Enemies
    for (gs.enemies[0..@intCast(gs.enemy_count)]) |enemy| {
        if (enemy.is_alive) {
            const ex: i32 = @intFromFloat(enemy.position.x);
            const ey: i32 = @intFromFloat(enemy.position.y);
            rl.DrawCircle(ex, ey, 10, rl.Color{ .r = 200, .g = 50, .b = 50, .a = 255 });
            rl.DrawCircleLines(ex, ey, 10, rl.Color{ .r = 255, .g = 100, .b = 100, .a = 255 });
        }
    }

    // Draw Slash Range
    if (p.slash_active) {
        const px: f32 = p.position.x;
        const py: f32 = p.position.y;
        const angle_deg = p.slash_angle * 180.0 / 3.14159;
        const start_angle = angle_deg - 45;
        const end_angle = angle_deg + 45;

        rl.DrawCircleSector(
            .{ .x = px, .y = py },
            80.0,
            start_angle,
            end_angle,
            32,
            rl.Color{ .r = 255, .g = 255, .b = 100, .a = 100 },
        );
        rl.DrawCircleSectorLines(
            .{ .x = px, .y = py },
            80.0,
            start_angle,
            end_angle,
            32,
            rl.Color{ .r = 255, .g = 255, .b = 0, .a = 255 },
        );
    }

    // Draw Player
    const px: i32 = @intFromFloat(p.position.x);
    const py: i32 = @intFromFloat(p.position.y);
    rl.DrawCircle(px, py, 15, rl.Color{ .r = 50, .g = 150, .b = 255, .a = 255 });
    rl.DrawCircleLines(px, py, 15, rl.Color{ .r = 100, .g = 200, .b = 255, .a = 255 });

    // Draw Facing Direction
    const dir_x = @cos(p.rotation) * 20;
    const dir_y = @sin(p.rotation) * 20;
    rl.DrawLine(px, py, px + @as(i32, @intFromFloat(dir_x)), py + @as(i32, @intFromFloat(dir_y)), rl.WHITE);

    // UI Bar
    rl.DrawRectangle(0, 0, 800, 40, rl.Color{ .r = 0, .g = 0, .b = 0, .a = 180 });

    // Health Bar
    rl.DrawRectangle(10, 10, 200, 20, rl.Color{ .r = 60, .g = 60, .b = 60, .a = 255 });
    const health_width: i32 = @intCast(@as(i32, @intFromFloat(@as(f32, @floatFromInt(p.health)) / 100.0 * 196.0)));
    var health_color = rl.Color{ .r = 50, .g = 200, .b = 50, .a = 255 };
    if (p.health < 30) {
        health_color = rl.Color{ .r = 200, .g = 50, .b = 50, .a = 255 };
    } else if (p.health < 60) {
        health_color = rl.Color{ .r = 200, .g = 200, .b = 50, .a = 255 };
    }
    rl.DrawRectangle(12, 12, health_width, 16, health_color);

    const score_text = rl.TextFormat("Score: %d", gs.score);
    const enemies_text = rl.TextFormat("Enemies: %d", gs.enemy_count);
    rl.DrawText(score_text, 220, 14, 18, rl.YELLOW);
    rl.DrawText(enemies_text, 400, 14, 18, rl.RED);

    // Game State Overlay
    if (!gs.is_active) {
        rl.DrawRectangle(0, 0, 800, 600, rl.Color{ .r = 0, .g = 0, .b = 0, .a = 150 });

        // Check for Restart Input
        if (rl.IsKeyPressed(rl.KEY_R) or rl.IsKeyPressed(rl.KEY_SPACE)) {
            sendGameCommand(block, CMD_GAME_START, 1.0);
        }

        if (p.health <= 0) {
            rl.DrawText("GAME OVER", 280, 250, 50, rl.Color{ .r = 255, .g = 50, .b = 50, .a = 255 });
            rl.DrawText(rl.TextFormat("Final Score: %d", gs.score), 300, 320, 30, rl.WHITE);
            rl.DrawText(rl.TextFormat("Total Kills: %d", gs.total_kills), 320, 360, 20, rl.Color{ .r = 200, .g = 200, .b = 200, .a = 255 });
        } else {
            rl.DrawText("VAMPIRE SURVIVAL", 200, 200, 40, rl.Color{ .r = 100, .g = 200, .b = 255, .a = 255 });
            rl.DrawText("Press SPACE to Start", 270, 280, 24, rl.Color{ .r = 200, .g = 200, .b = 200, .a = 255 });
        }

        rl.DrawText("WASD - Move | Auto-slash every 0.5s", 220, 420, 16, rl.Color{ .r = 150, .g = 150, .b = 150, .a = 255 });
        rl.DrawText("ESC - Quit | R - Restart", 280, 450, 16, rl.Color{ .r = 150, .g = 150, .b = 150, .a = 255 });
    }

    rl.DrawText("Zig Client [Raylib]", 650, 570, 14, rl.GRAY);
}

pub const CMD_GAME_START = 0x81;

fn sendGameCommand(block: *volatile protocol.SharedMemoryBlock, cmd_type: u16, val: f32) void {
    const head = @atomicLoad(i32, &block.input_ring.head, .seq_cst);
    const tail = @atomicLoad(i32, &block.input_ring.tail, .seq_cst);
    const next_head = @mod(head + 1, protocol.INPUT_RING_SIZE);

    if (next_head == tail) return; // Full

    const cmd = protocol.Command{
        .sequence = 0,
        .tick = 0,
        .player_id = 0,
        .category = .System, // Use System for Game commands as per main.odin logic (mapped to CMD_GAME)
        .type = cmd_type,
        .flags = 0,
        .target_entity = 0,
        .target_pos = .{ val, 0, 0 }, // 1.0 for Start
        .data_length = 0,
        .data = [_]u8{0} ** protocol.MAX_COMMAND_DATA,
    };

    block.input_ring.commands[@intCast(head)] = cmd;
    @atomicStore(i32, &block.input_ring.head, next_head, .seq_cst);
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
        .type = protocol.CMD_INPUT_MOVE,
        .flags = 0,
        .target_entity = 0,
        .target_pos = .{ x, y, 0 },
        .data_length = 0,
        .data = [_]u8{0} ** protocol.MAX_COMMAND_DATA,
    };

    block.input_ring.commands[@intCast(head)] = cmd;
    @atomicStore(i32, &block.input_ring.head, next_head, .seq_cst);
}
