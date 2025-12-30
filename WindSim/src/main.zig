const std = @import("std");

const c = @cImport({
    @cInclude("raylib.h");
    @cInclude("raymath.h");
    @cInclude("rlgl.h");
    @cInclude("windsim_shim.h");
});

const VisualVolume = struct {
    volume: c.WindVolume_C,
    selected: bool,
    color: c.Color,
};

var currentRes: i32 = 32;
const cellSize: f32 = 1.0;
var windSim: ?*c.WindSim_Handle = null;

fn initSim(res: i32) void {
    currentRes = res;
    if (windSim) |handle| {
        c.WindSim_Destroy(handle);
    }
    windSim = c.WindSim_Create(res, res, res, cellSize);
    std.debug.print("Simulation initialized at resolution: {d}^3\n", .{res});
}

pub fn main() !void {
    initSim(currentRes);
    const allocator = std.heap.page_allocator;
    var visualVolumes = std.ArrayListUnmanaged(VisualVolume){};
    defer visualVolumes.deinit(allocator);

    const screenWidth = 1280;
    const screenHeight = 720;
    c.InitWindow(screenWidth, screenHeight, "WindSim Visualizer - Nguyen Phi Hung");
    defer c.CloseWindow();

    var camera = std.mem.zeroes(c.Camera3D);
    camera.position = .{ .x = 60.0, .y = 60.0, .z = 60.0 };
    camera.target = .{ .x = 0.0, .y = 0.0, .z = 0.0 };
    camera.up = .{ .x = 0.0, .y = 1.0, .z = 0.0 };
    camera.fovy = 45.0;
    camera.projection = c.CAMERA_PERSPECTIVE;

    c.SetTargetFPS(60);

    const dt: f32 = 0.1;
    var selectedIdx: isize = -1;
    var vectorScale: f32 = 2.0;
    var simTimeMs: f32 = 0;

    while (!c.WindowShouldClose()) {
        const frameDt = c.GetFrameTime();

        // --- Grid Size Adjustment ---
        if (c.IsKeyPressed(c.KEY_LEFT_BRACKET)) {
            if (currentRes > 16) {
                initSim(currentRes - 16);
                camera.target = .{ .x = 0.0, .y = 0.0, .z = 0.0 };
            }
        }
        if (c.IsKeyPressed(c.KEY_RIGHT_BRACKET)) {
            if (currentRes < 128) {
                initSim(currentRes + 16);
                camera.target = .{ .x = 0.0, .y = 0.0, .z = 0.0 };
            }
        }

        // --- Vector Scaling ---
        if (c.IsKeyDown(c.KEY_O)) vectorScale = @max(0.1, vectorScale - 2.0 * frameDt);
        if (c.IsKeyDown(c.KEY_P)) vectorScale += 2.0 * frameDt;

        // --- Camera Controls (Maya Style) ---
        if (c.IsKeyDown(c.KEY_LEFT_ALT) or c.IsKeyDown(c.KEY_RIGHT_ALT)) {
            const delta = c.GetMouseDelta();
            const mouseWheel = c.GetMouseWheelMove();

            // Alt + Right Mouse OR Mouse Wheel: Zoom
            if (c.IsMouseButtonDown(c.MOUSE_BUTTON_RIGHT) or mouseWheel != 0.0) {
                var zoomFactor: f32 = 0.0;
                if (mouseWheel != 0.0) {
                    zoomFactor = mouseWheel * 2.0;
                } else {
                    zoomFactor = -delta.x * 0.1 + delta.y * 0.1;
                }

                const forward = c.Vector3Subtract(camera.target, camera.position);
                const dist = c.Vector3Length(forward);

                if (dist > 1.0 or zoomFactor < 0.0) {
                    const move = c.Vector3Scale(c.Vector3Normalize(forward), zoomFactor);
                    camera.position = c.Vector3Add(camera.position, move);
                }
            }
            // Alt + Middle Mouse: Pan
            else if (c.IsMouseButtonDown(c.MOUSE_BUTTON_MIDDLE)) {
                const forward = c.Vector3Normalize(c.Vector3Subtract(camera.target, camera.position));
                const right = c.Vector3CrossProduct(forward, camera.up);
                const up = camera.up;

                const panSpeed = 0.05 * c.Vector3Distance(camera.position, camera.target) * 0.05;

                const moveX = c.Vector3Scale(right, -delta.x * panSpeed);
                const moveY = c.Vector3Scale(up, delta.y * panSpeed);
                const move = c.Vector3Add(moveX, moveY);

                camera.position = c.Vector3Add(camera.position, move);
                camera.target = c.Vector3Add(camera.target, move);
            }
            // Alt + Left Mouse: Orbit
            else if (c.IsMouseButtonDown(c.MOUSE_BUTTON_LEFT)) {
                var sub = c.Vector3Subtract(camera.position, camera.target);

                // Yaw
                const rotYaw = c.MatrixRotate(.{ .x = 0, .y = 1, .z = 0 }, -delta.x * 0.005);
                sub = c.Vector3Transform(sub, rotYaw);

                // Pitch
                var right = c.Vector3CrossProduct(c.Vector3Normalize(sub), camera.up);
                right.y = 0;
                right = c.Vector3Normalize(right);
                const rotPitch = c.MatrixRotate(right, -delta.y * 0.005);
                sub = c.Vector3Transform(sub, rotPitch);

                camera.position = c.Vector3Add(camera.target, sub);
            }
        } else {
            // Scroll Zoom without Alt
            const mouseWheel = c.GetMouseWheelMove();
            if (mouseWheel != 0.0) {
                const forward = c.Vector3Subtract(camera.target, camera.position);
                const move = c.Vector3Scale(c.Vector3Normalize(forward), mouseWheel * 2.0);
                camera.position = c.Vector3Add(camera.position, move);
            }
        }

        // --- Volume Management ---
        if (c.IsKeyPressed(c.KEY_TAB)) {
            if (visualVolumes.items.len > 0) {
                if (selectedIdx >= 0) visualVolumes.items[@intCast(selectedIdx)].selected = false;
                selectedIdx = @mod(selectedIdx + 1, @as(isize, @intCast(visualVolumes.items.len)));
                visualVolumes.items[@intCast(selectedIdx)].selected = true;
            }
        }

        if (c.IsKeyPressed(c.KEY_N)) { // New Radial
            var v = VisualVolume{
                .volume = undefined,
                .selected = false,
                .color = c.DARKBLUE,
            };
            // Manually recreate "CreateRadial" logic since C structs don't have static methods
            v.volume.type = c.VolumeType_Radial;
            v.volume.position = .{ .x = 0.0, .y = 0.0, .z = 0.0, .w = 0.0 };
            v.volume.sizeParams = .{ .x = 10.0, .y = 0.0, .z = 0.0, .w = 120.0 }; // x=radius, w=falloff
            v.volume.direction = .{ .x = 1.0, .y = 0.0, .z = 0.0, .w = 0.0 };
            v.volume.rotation = .{ .x = 0.0, .y = 0.0, .z = 0.0, .w = 0.0 };
            v.volume.strength = 10.0; // strength

            try visualVolumes.append(allocator, v);

            if (selectedIdx >= 0) visualVolumes.items[@intCast(selectedIdx)].selected = false;
            selectedIdx = @as(isize, @intCast(visualVolumes.items.len)) - 1;
            visualVolumes.items[@intCast(selectedIdx)].selected = true;
        }

        if (c.IsKeyPressed(c.KEY_B)) { // New Box (Directional)
            var v = VisualVolume{
                .volume = undefined,
                .selected = false,
                .color = c.MAROON,
            };
            v.volume.type = c.VolumeType_Directional;
            v.volume.position = .{ .x = 0.0, .y = 0.0, .z = 0.0, .w = 0.0 };
            v.volume.sizeParams = .{ .x = 8.0, .y = 8.0, .z = 8.0, .w = 0.0 };
            v.volume.direction = .{ .x = 1.0, .y = 0.0, .z = 0.0, .w = 0.0 };
            v.volume.rotation = .{ .x = 0.0, .y = 0.0, .z = 0.0, .w = 0.0 };
            v.volume.strength = 150.0;

            try visualVolumes.append(allocator, v);

            if (selectedIdx >= 0) visualVolumes.items[@intCast(selectedIdx)].selected = false;
            selectedIdx = @as(isize, @intCast(visualVolumes.items.len)) - 1;
            visualVolumes.items[@intCast(selectedIdx)].selected = true;
        }

        if (c.IsKeyPressed(c.KEY_DELETE) and selectedIdx >= 0) {
            _ = visualVolumes.orderedRemove(@intCast(selectedIdx));
            selectedIdx = -1;
        }

        // --- Transformation ---
        if (selectedIdx >= 0) {
            var v = &visualVolumes.items[@intCast(selectedIdx)];
            const moveSpeed = 40.0 * frameDt;
            const rotSpeed = 3.0 * frameDt;

            if (c.IsKeyDown(c.KEY_UP)) v.volume.position.z -= moveSpeed;
            if (c.IsKeyDown(c.KEY_DOWN)) v.volume.position.z += moveSpeed;
            if (c.IsKeyDown(c.KEY_LEFT)) v.volume.position.x -= moveSpeed;
            if (c.IsKeyDown(c.KEY_RIGHT)) v.volume.position.x += moveSpeed;
            if (c.IsKeyDown(c.KEY_PAGE_UP)) v.volume.position.y += moveSpeed;
            if (c.IsKeyDown(c.KEY_PAGE_DOWN)) v.volume.position.y -= moveSpeed;

            if (c.IsKeyDown(c.KEY_R)) v.volume.rotation.x += rotSpeed;
            if (c.IsKeyDown(c.KEY_F)) v.volume.rotation.x -= rotSpeed;
            if (c.IsKeyDown(c.KEY_T)) v.volume.rotation.y += rotSpeed;
            if (c.IsKeyDown(c.KEY_G)) v.volume.rotation.y -= rotSpeed;
            if (c.IsKeyDown(c.KEY_Y)) v.volume.rotation.z += rotSpeed;
            if (c.IsKeyDown(c.KEY_H)) v.volume.rotation.z -= rotSpeed;

            // Resize
            if (c.IsKeyDown(c.KEY_KP_ADD) or c.IsKeyDown(c.KEY_EQUAL)) {
                v.volume.sizeParams.x += moveSpeed * 0.5;
                if (v.volume.type == c.VolumeType_Directional) {
                    v.volume.sizeParams.y += moveSpeed * 0.5;
                    v.volume.sizeParams.z += moveSpeed * 0.5;
                }
            }
            if (c.IsKeyDown(c.KEY_KP_SUBTRACT) or c.IsKeyDown(c.KEY_MINUS)) {
                v.volume.sizeParams.x = @max(0.5, v.volume.sizeParams.x - moveSpeed * 0.5);
                if (v.volume.type == c.VolumeType_Directional) {
                    v.volume.sizeParams.y = @max(0.5, v.volume.sizeParams.y - moveSpeed * 0.5);
                    v.volume.sizeParams.z = @max(0.5, v.volume.sizeParams.z - moveSpeed * 0.5);
                }
            }
        }

        // --- Simulation ---
        var simVolumes = std.ArrayListUnmanaged(c.WindVolume_C){};
        defer simVolumes.deinit(allocator);

        const halfRes = @as(f32, @floatFromInt(currentRes)) * 0.5;
        for (visualVolumes.items) |vv| {
            var sv = vv.volume;
            // Center Offset Logic
            sv.position.x += halfRes;
            sv.position.y += halfRes;
            sv.position.z += halfRes;
            try simVolumes.append(allocator, sv);
        }

        const simStartTime = c.GetTime();
        c.WindSim_ApplyForces(windSim, dt, simVolumes.items.ptr, @intCast(simVolumes.items.len));
        c.WindSim_Step(windSim, dt);
        simTimeMs = @floatCast((c.GetTime() - simStartTime) * 1000.0);

        // --- Rendering ---
        c.BeginDrawing();
        c.ClearBackground(c.RAYWHITE);
        c.BeginMode3D(camera);
        c.DrawGrid(currentRes, cellSize);

        const vData = c.WindSim_GetVelocityData(windSim);
        const renderStep: i32 = if (currentRes > 48) 4 else 2;
        const offset = halfRes;

        var z: i32 = 0;
        while (z < currentRes) : (z += renderStep) {
            var y: i32 = 0;
            while (y < currentRes) : (y += renderStep) {
                var x: i32 = 0;
                while (x < currentRes) : (x += renderStep) {
                    const idx = x + currentRes * (y + currentRes * z);
                    const v = vData[@intCast(idx)];
                    // Manually calculate length since C struct doesn't have methods
                    const len = std.math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z);

                    if (len > 0.05) {
                        const start = c.Vector3{ .x = @as(f32, @floatFromInt(x)) - offset, .y = @as(f32, @floatFromInt(y)) - offset, .z = @as(f32, @floatFromInt(z)) - offset };
                        const end = c.Vector3{ .x = start.x + v.x * vectorScale, .y = start.y + v.y * vectorScale, .z = start.z + v.z * vectorScale };
                        c.DrawLine3D(start, end, c.Fade(c.BLUE, @min(1.0, len * 0.1)));
                    }
                }
            }
        }

        for (visualVolumes.items) |vv| {
            const pos = c.Vector3{ .x = vv.volume.position.x, .y = vv.volume.position.y, .z = vv.volume.position.z };
            const color = if (vv.selected) c.YELLOW else vv.color;

            if (vv.volume.type == c.VolumeType_Radial) {
                c.DrawSphereWires(pos, vv.volume.sizeParams.x, 8, 8, color);
            } else {
                c.DrawCubeWires(pos, vv.volume.sizeParams.x * 2.0, vv.volume.sizeParams.y * 2.0, vv.volume.sizeParams.z * 2.0, color);

                const rotDirC = c.WindSim_RotateDirection(vv.volume.direction, vv.volume.rotation);

                const arrowEnd = c.Vector3{ .x = pos.x + rotDirC.x * 10, .y = pos.y + rotDirC.y * 10, .z = pos.z + rotDirC.z * 10 };
                c.DrawLine3D(pos, arrowEnd, c.MAGENTA);
                c.DrawSphere(arrowEnd, 0.4, c.MAGENTA);
            }
        }
        c.EndMode3D();

        c.DrawText(c.TextFormat("Total: %.2f ms | Sim: %.2f ms", frameDt * 1000.0, simTimeMs), screenWidth - 250, 10, 20, c.DARKGRAY);
        c.DrawText(c.TextFormat("Res: %d^3 | SIMD: %s | Volumes: %d | Scale: %.1f", currentRes, c.WindSim_GetSIMDName(windSim), @as(c_int, @intCast(visualVolumes.items.len)), vectorScale), 10, 10, 20, c.DARKGRAY);

        c.DrawText(c.TextFormat("Blocks: %d / %d Active", c.WindSim_GetActiveBlockCount(windSim), c.WindSim_GetTotalBlockCount(windSim)), 10, 35, 20, c.DARKGRAY);

        c.DrawText("Grid Size: [ ] | Vector Scale: O P | TAB Selection | N/B Add | DEL Remove", 10, screenHeight - 60, 18, c.GRAY);
        c.DrawText("Transform: Arrows/PgUp/PgDn Move | R/F, T/G, Y/H Rotate Wind | +/- Resize", 10, screenHeight - 35, 18, c.GRAY);

        if (selectedIdx >= 0) {
            const v = visualVolumes.items[@intCast(selectedIdx)].volume;
            c.DrawText(c.TextFormat("SELECTED [%d]: pos(%.1f, %.1f, %.1f)", @as(c_int, @intCast(selectedIdx)), v.position.x, v.position.y, v.position.z), 10, 95, 18, c.MAROON);
        }

        c.EndDrawing();
    }
}
