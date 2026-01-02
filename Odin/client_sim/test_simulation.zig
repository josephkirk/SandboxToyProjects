const std = @import("std");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    std.debug.print("=== Integration Test: Position/Input Flow ===\n", .{});

    // 0.1. Generate Schemas (Server & Renderer)
    std.debug.print("0.1. Generating Schemas (Server/Renderer)...\n", .{});
    const schema_gen_cmd = [_][]const u8{ "uv", "run", "tools/build_schemas.py" };
    var schema_proc = std.process.Child.init(&schema_gen_cmd, allocator);
    // schema_proc.stdout_behavior = .Inherit;
    // schema_proc.stderr_behavior = .Inherit;
    _ = schema_proc.spawnAndWait() catch |err| {
        std.debug.print("WARNING: Schema generation failed: {any}\n", .{err});
    };

    // 0.2. Generate Schemas (Client Sim)
    std.debug.print("0.2. Generating Schemas (Client Sim)...\n", .{});
    const flatc_path = "..\\thirdparties\\Windows.flatc.binary\\flatc.exe";
    const client_schema_cmd = [_][]const u8{ flatc_path, "--cpp", "--cpp-std", "c++17", "-o", "client_sim/generated", "schemas/GameState.fbs" };
    var client_schema_proc = std.process.Child.init(&client_schema_cmd, allocator);
    _ = client_schema_proc.spawnAndWait() catch |err| {
        std.debug.print("WARNING: Client Schema generation failed: {any}\n", .{err});
    };

    // 0.3. Cleanup: Kill existing processes
    std.debug.print("0. Cleaning up old processes...\n", .{});
    {
        var kill_server = std.process.Child.init(&[_][]const u8{ "taskkill", "/F", "/IM", "game_release.exe" }, allocator);
        _ = kill_server.spawnAndWait() catch {};
    }
    {
        var kill_client = std.process.Child.init(&[_][]const u8{ "taskkill", "/F", "/IM", "main.exe" }, allocator);
        _ = kill_client.spawnAndWait() catch {};
    }

    Sleep(1000);

    // 1. Build Odin Server
    std.debug.print("1. Building Odin Server...\n", .{});
    const odin_path = "..\\thirdparties\\odin-windows-amd64-dev-2025-12a\\dist\\odin.exe";
    var build_server_proc = std.process.Child.init(&[_][]const u8{ odin_path, "build", "game", "-out:game_release.exe", "-o:speed" }, allocator);
    const server_term = try build_server_proc.spawnAndWait();
    switch (server_term) {
        .Exited => |code| if (code != 0) {
            std.debug.print("FAILED to build Odin Server (Exit Code: {d})\n", .{code});
            return error.BuildFailed;
        },
        else => return error.BuildFailed,
    }

    // 2. Build C++ Client
    std.debug.print("2. Building Client Simulator...\n", .{});
    var build_client_proc = std.process.Child.init(&[_][]const u8{ "zig", "c++", "client_sim/main.cpp", "-o", "client_sim/main.exe", "-I", "client_sim", "-I", "client_sim/generated", "-std=c++17" }, allocator);
    const client_term = try build_client_proc.spawnAndWait();
    switch (client_term) {
        .Exited => |code| if (code != 0) {
            std.debug.print("FAILED to build Client Simulator (Exit Code: {d})\n", .{code});
            return error.BuildFailed;
        },
        else => return error.BuildFailed,
    }

    // 3. Start Odin Server (Headless)
    std.debug.print("3. Starting Odin Server...\n", .{});
    const server_cmd = [_][]const u8{ "game_release.exe", "--headless", "--verbose", "--debug" };
    var server_proc = std.process.Child.init(&server_cmd, allocator);
    server_proc.stdout_behavior = .Inherit;
    server_proc.stderr_behavior = .Inherit;

    try server_proc.spawn();
    Sleep(2000); // Wait 2s for shared memory init

    // 4. Start Zig Client Sim
    std.debug.print("4. Starting Client Sim...\n", .{});
    const client_cmd = [_][]const u8{"client_sim/main.exe"};
    var client_proc = std.process.Child.init(&client_cmd, allocator);
    client_proc.stdout_behavior = .Pipe; // client prints to stderr via std.debug.print or std::cerr
    client_proc.stderr_behavior = .Pipe; // We watch stderr because we used std::cerr

    try client_proc.spawn();

    // 5. Monitor Output for specific patterns
    std.debug.print("5. Monitoring for Position Updates...\n", .{});

    const MAX_DURATION_NS = 15 * 1_000_000_000; // 15 seconds
    const start_time = std.time.nanoTimestamp();
    var success = false;

    var pos_changes: u32 = 0;
    var has_hitch: bool = false;
    var has_recv: bool = false;

    // We'll read in chunks
    var chunk_buf: [4096]u8 = undefined;

    // We loop reading output from STDERR (where std::cerr goes)
    // Note: If client uses stdout, we change to .stdout below.
    // In main.cpp we matched std::cerr.

    while (std.time.nanoTimestamp() - start_time < MAX_DURATION_NS) {
        const n = try client_proc.stderr.?.read(&chunk_buf);
        if (n == 0) break; // EOF

        const chunk = chunk_buf[0..n];
        // std.debug.print("CLIENT: {s}\n", .{chunk}); // Commented out to avoid double printing

        var it = std.mem.splitSequence(u8, chunk, "\n");
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r\t"); // Trim whitespace including carriage return

            if (std.mem.indexOf(u8, trimmed, "RECV POS: x=") != null) {
                std.debug.print("{s}\n", .{trimmed});
                pos_changes += 1;
                has_recv = true;
            }

            if (std.mem.indexOf(u8, trimmed, "CLIENT PLAYER: Pos=") != null) {
                std.debug.print("{s}\n", .{trimmed});
                pos_changes += 1;
                has_recv = true;
            }

            if (std.mem.indexOf(u8, trimmed, "[HITCH]") != null) {
                has_hitch = true;
            }
        }

        if (pos_changes > 10 and has_hitch) {
            success = true;
            break;
        }
    }

    std.debug.print("\nStopping processes...\n", .{});
    _ = server_proc.kill() catch {};
    _ = client_proc.kill() catch {};

    if (pos_changes > 10 and has_hitch) {
        std.debug.print("\n[PASS] Verified Input->Server->Client Position Flow (with Hitching).\n", .{});
        std.debug.print("Received {} position updates.\n", .{pos_changes});
    } else {
        std.debug.print("\n[FAIL] Test Failed.\n", .{});
        std.debug.print("  Position Updates: {} (Expected > 10)\n", .{pos_changes});
        std.debug.print("  Hitch Detected: {} (Expected true)\n", .{has_hitch});
        return error.TestFailed;
    }
}

extern "kernel32" fn Sleep(dwMilliseconds: u32) void;
