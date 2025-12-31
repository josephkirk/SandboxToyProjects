const std = @import("std");

const c = @cImport({
    @cInclude("raylib.h");
    @cInclude("raymath.h");
    @cInclude("rlgl.h");
});

const Body = extern struct {
    pos: [2]f32,
    vel: [2]f32,
    acc: [2]f32,
    mass: f32,
    radius: f32,
};

const Quad = extern struct {
    center: [2]f32,
    size: f32,
};

const Node = extern struct {
    children: usize,
    next: usize,
    pos: [2]f32,
    mass: f32,
    quad: Quad,
};

extern fn Simulation_Create() ?*anyopaque;
extern fn Simulation_Destroy(handle: ?*anyopaque) void;
extern fn Simulation_Step(handle: ?*anyopaque) void;
extern fn Simulation_GetBodyCount(handle: ?*const anyopaque) usize;
extern fn Simulation_GetBodies(handle: ?*const anyopaque) [*]const Body;
extern fn Simulation_GetNodeCount(handle: ?*const anyopaque) usize;
extern fn Simulation_GetNodes(handle: ?*const anyopaque) [*]const Node;
extern fn Simulation_AddBody(handle: ?*anyopaque, x: f32, y: f32, vx: f32, vy: f32, mass: f32, radius: f32) void;
extern fn Simulation_ApplyForce(handle: ?*anyopaque, x: f32, y: f32, fx: f32, fy: f32, radius: f32) void;
extern fn Simulation_Reset(handle: ?*anyopaque, n: usize) void;

const SimState = struct {
    handle: ?*anyopaque,
    mutex: std.Thread.Mutex = .{},
    running: bool = true,

    // Buffers for rendering
    render_bodies: []Body,
    render_nodes: []Node,

    body_count: usize = 0,
    node_count: usize = 0,
    sim_time_ms: f32 = 0,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !*SimState {
        const self = try allocator.create(SimState);
        self.* = .{
            .handle = Simulation_Create(),
            .render_bodies = try allocator.alloc(Body, 1_100_000), // Max support
            .render_nodes = try allocator.alloc(Node, 3_000_000), // Max support
            .allocator = allocator,
        };
        return self;
    }

    fn deinit(self: *SimState) void {
        self.running = false;
        Simulation_Destroy(self.handle);
        self.allocator.free(self.render_bodies);
        self.allocator.free(self.render_nodes);
        self.allocator.destroy(self);
    }

    fn loop(self: *SimState) void {
        while (self.running) {
            const start = c.GetTime();
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                Simulation_Step(self.handle);

                self.body_count = Simulation_GetBodyCount(self.handle);
                const bodies = Simulation_GetBodies(self.handle);
                if (self.body_count > self.render_bodies.len) {
                    self.allocator.free(self.render_bodies);
                    // alloc or panic
                    self.render_bodies = self.allocator.alloc(Body, self.body_count + 100_000) catch @panic("OOM");
                }
                @memcpy(self.render_bodies[0..self.body_count], bodies[0..self.body_count]);

                self.node_count = Simulation_GetNodeCount(self.handle);
                const nodes = Simulation_GetNodes(self.handle);
                if (self.node_count > self.render_nodes.len) {
                    self.allocator.free(self.render_nodes);
                    self.render_nodes = self.allocator.alloc(Node, self.node_count + 100_000) catch @panic("OOM");
                }
                @memcpy(self.render_nodes[0..self.node_count], nodes[0..self.node_count]);
            }
            const end = c.GetTime();
            self.sim_time_ms = @floatCast((end - start) * 1000.0);

            // Cap simulation speed if it's too fast, or just let it rip
            if (self.sim_time_ms < 1.0) {}
        }
    }
};

pub fn main() !void {
    const screenWidth = 1280;
    const screenHeight = 720;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    c.InitWindow(screenWidth, screenHeight, "NBody Visualizer - Nguyen Phi Hung");
    c.SetTargetFPS(144);
    defer c.CloseWindow();

    var camera = std.mem.zeroes(c.Camera3D);
    camera.position = .{ .x = 0.0, .y = 0.0, .z = 1000.0 };
    camera.target = .{ .x = 0.0, .y = 0.0, .z = 0.0 };
    camera.up = .{ .x = 0.0, .y = 1.0, .z = 0.0 };
    camera.fovy = 45.0;
    camera.projection = c.CAMERA_PERSPECTIVE;

    const state = try SimState.init(allocator);
    defer state.deinit();

    const thread = try std.Thread.spawn(.{}, SimState.loop, .{state});
    thread.detach();

    var show_quadtree = false;
    var is_spawning = false;
    var spawn_pos = c.Vector2{ .x = 0, .y = 0 };
    var spawn_mass: f32 = 1.0;

    while (!c.WindowShouldClose()) {
        // --- Input Handling ---

        if (c.IsKeyPressed(c.KEY_Q)) show_quadtree = !show_quadtree;

        if (c.IsKeyDown(c.KEY_LEFT_ALT) or c.IsKeyDown(c.KEY_RIGHT_ALT)) {
            const delta = c.GetMouseDelta();
            const mouseWheel = c.GetMouseWheelMove();

            if (c.IsMouseButtonDown(c.MOUSE_BUTTON_RIGHT) or mouseWheel != 0.0) {
                var zoomFactor: f32 = 0.0;
                if (mouseWheel != 0.0) {
                    zoomFactor = mouseWheel * 10.0;
                } else {
                    zoomFactor = -delta.x * 1.0 + delta.y * 1.0;
                }

                const forward = c.Vector3Subtract(camera.target, camera.position);
                const dist = c.Vector3Length(forward);

                if (dist > 10.0 or zoomFactor < 0.0) {
                    const move = c.Vector3Scale(c.Vector3Normalize(forward), zoomFactor);
                    camera.position = c.Vector3Add(camera.position, move);
                }
            } else if (c.IsMouseButtonDown(c.MOUSE_BUTTON_MIDDLE)) {
                const forward = c.Vector3Normalize(c.Vector3Subtract(camera.target, camera.position));
                const right = c.Vector3CrossProduct(forward, camera.up);
                const up = camera.up;

                const panSpeed = 0.001 * c.Vector3Distance(camera.position, camera.target);

                const moveX = c.Vector3Scale(right, -delta.x * panSpeed);
                const moveY = c.Vector3Scale(up, delta.y * panSpeed);
                const move = c.Vector3Add(moveX, moveY);

                camera.position = c.Vector3Add(camera.position, move);
                camera.target = c.Vector3Add(camera.target, move);
            } else if (c.IsMouseButtonDown(c.MOUSE_BUTTON_LEFT)) {
                var sub = c.Vector3Subtract(camera.position, camera.target);

                const rotYaw = c.MatrixRotate(.{ .x = 0, .y = 1, .z = 0 }, -delta.x * 0.005);
                sub = c.Vector3Transform(sub, rotYaw);

                var right = c.Vector3CrossProduct(c.Vector3Normalize(sub), camera.up);
                right.y = 0;
                right = c.Vector3Normalize(right);
                const rotPitch = c.MatrixRotate(right, -delta.y * 0.005);
                sub = c.Vector3Transform(sub, rotPitch);

                camera.position = c.Vector3Add(camera.target, sub);
            }
        } else {
            const mouseWheel = c.GetMouseWheelMove();
            if (mouseWheel != 0.0) {
                const forward = c.Vector3Subtract(camera.target, camera.position);
                const move = c.Vector3Scale(c.Vector3Normalize(forward), mouseWheel * 10.0);
                camera.position = c.Vector3Add(camera.position, move);
            }
        }

        // --- Interaction ---
        if (c.IsKeyPressed(c.KEY_ONE)) {
            state.mutex.lock();
            Simulation_Reset(state.handle, 100_000);
            state.mutex.unlock();
        }
        if (c.IsKeyPressed(c.KEY_TWO)) {
            state.mutex.lock();
            Simulation_Reset(state.handle, 1_000_000);
            state.mutex.unlock();
        }
        const ray = c.GetMouseRay(c.GetMousePosition(), camera);
        const t = -ray.position.z / ray.direction.z;
        const world_mouse = c.Vector3Add(ray.position, c.Vector3Scale(ray.direction, t));
        const mouse_2d = c.Vector2{ .x = world_mouse.x, .y = world_mouse.y };

        if (c.IsMouseButtonDown(c.MOUSE_BUTTON_LEFT) and !c.IsKeyDown(c.KEY_LEFT_ALT)) {
            const delta = c.GetMouseDelta();
            if (c.Vector2Length(delta) > 0.1) {
                const force = c.Vector2Scale(delta, 10.0);
                state.mutex.lock();
                Simulation_ApplyForce(state.handle, mouse_2d.x, mouse_2d.y, force.x, -force.y, 50.0);
                state.mutex.unlock();
            }
        }

        if (c.IsMouseButtonPressed(c.MOUSE_BUTTON_RIGHT) and !c.IsKeyDown(c.KEY_LEFT_ALT)) {
            is_spawning = true;
            spawn_pos = mouse_2d;
            spawn_mass = 1.0;
        } else if (c.IsMouseButtonDown(c.MOUSE_BUTTON_RIGHT) and is_spawning) {
            const dist = c.Vector2Distance(mouse_2d, spawn_pos);
            spawn_mass = 1.0 + dist * 10.0;
        } else if (c.IsMouseButtonReleased(c.MOUSE_BUTTON_RIGHT) and is_spawning) {
            const vel = c.Vector2Subtract(mouse_2d, spawn_pos);
            const radius = std.math.pow(f32, spawn_mass, 1.0 / 3.0);
            state.mutex.lock();
            Simulation_AddBody(state.handle, spawn_pos.x, spawn_pos.y, vel.x * 0.1, vel.y * 0.1, spawn_mass, radius);
            state.mutex.unlock();
            is_spawning = false;
        }

        // --- Rendering ---
        c.BeginDrawing();

        c.ClearBackground(c.BLACK);

        c.rlSetClipPlanes(0.1, 50000.0);
        c.BeginMode3D(camera);

        c.rlPushMatrix();
        c.rlRotatef(90, 1, 0, 0);
        c.DrawGrid(100, 100);
        c.rlPopMatrix();

        // Local snapshot for rendering
        const body_count = state.body_count;
        const bodies = state.render_bodies[0..body_count];

        c.rlBegin(c.RL_LINES);
        for (bodies) |b| {
            if (b.mass < 1000.0) {
                const color = if (b.mass > 100.0) c.ORANGE else c.WHITE;
                c.rlColor4ub(color.r, color.g, color.b, color.a);
                const size = 0.5; // Small cross size
                c.rlVertex3f(b.pos[0] - size, b.pos[1], 0.0);
                c.rlVertex3f(b.pos[0] + size, b.pos[1], 0.0);
                c.rlVertex3f(b.pos[0], b.pos[1] - size, 0.0);
                c.rlVertex3f(b.pos[0], b.pos[1] + size, 0.0);
            }
        }
        c.rlEnd();

        // Draw large bodies as spheres
        for (bodies) |b| {
            if (b.mass >= 1000.0) {
                c.DrawSphere(.{ .x = b.pos[0], .y = b.pos[1], .z = 0.0 }, b.radius, c.YELLOW);
            }
        }

        if (show_quadtree) {
            const node_count = state.node_count;
            const nodes = state.render_nodes[0..node_count];
            c.rlBegin(c.RL_LINES);
            c.rlColor4ub(0, 255, 0, 70); // Faded green
            for (nodes) |n| {
                if (n.mass > 0) {
                    const x = n.quad.center[0];
                    const y = n.quad.center[1];
                    const s = n.quad.size * 0.5;

                    c.rlVertex3f(x - s, y - s, 0);
                    c.rlVertex3f(x + s, y - s, 0);

                    c.rlVertex3f(x + s, y - s, 0);
                    c.rlVertex3f(x + s, y + s, 0);

                    c.rlVertex3f(x + s, y + s, 0);
                    c.rlVertex3f(x - s, y + s, 0);

                    c.rlVertex3f(x - s, y + s, 0);
                    c.rlVertex3f(x - s, y - s, 0);
                }
            }
            c.rlEnd();
        }

        if (is_spawning) {
            const radius = std.math.pow(f32, spawn_mass, 1.0 / 3.0);
            c.DrawSphereWires(.{ .x = spawn_pos.x, .y = spawn_pos.y, .z = 0.0 }, radius, 8, 8, c.RED);
            c.DrawLine3D(.{ .x = spawn_pos.x, .y = spawn_pos.y, .z = 0.0 }, .{ .x = mouse_2d.x, .y = mouse_2d.y, .z = 0.0 }, c.RED);
        }

        c.EndMode3D();

        c.DrawText(c.TextFormat("Bodies: %d", @as(c_int, @intCast(body_count))), 10, 10, 20, c.RAYWHITE);
        c.DrawText(c.TextFormat("Sim Time: %.2f ms", state.sim_time_ms), 10, 35, 20, c.RAYWHITE);
        c.DrawText(c.TextFormat("FPS: %d", c.GetFPS()), 10, 60, 20, c.RAYWHITE);
        c.DrawText("Alt+Mouse: Cam | LMB: Force | RMB: Spawn | Q: Quadtree | 1: 100k | 2: 1M", 10, screenHeight - 30, 20, c.GRAY);

        c.EndDrawing();
    }
}
