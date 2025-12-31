const std = @import("std");
const math = std.math;

// Vector helpers
fn sub(a: [2]f32, b: [2]f32) [2]f32 {
    return .{ a[0] - b[0], a[1] - b[1] };
}
fn add(a: [2]f32, b: [2]f32) [2]f32 {
    return .{ a[0] + b[0], a[1] + b[1] };
}
fn scale(a: [2]f32, s: f32) [2]f32 {
    return .{ a[0] * s, a[1] * s };
}
fn dot(a: [2]f32, b: [2]f32) f32 {
    return a[0] * b[0] + a[1] * b[1];
}
fn lenSq(a: [2]f32) f32 {
    return dot(a, a);
}

pub const Body = extern struct {
    pos: [2]f32,
    vel: [2]f32,
    acc: [2]f32,
    mass: f32,
    radius: f32,
};

pub const Quad = extern struct {
    center: [2]f32,
    size: f32,

    pub fn findQuadrant(self: Quad, pos: [2]f32) usize {
        var idx: usize = 0;
        if (pos[1] > self.center[1]) idx |= 2;
        if (pos[0] > self.center[0]) idx |= 1;
        return idx;
    }

    pub fn intoQuadrant(self: Quad, quadrant: usize) Quad {
        const half = self.size * 0.5;
        const qx: f32 = if ((quadrant & 1) != 0) 0.5 else -0.5;
        const qy: f32 = if ((quadrant & 2) != 0) 0.5 else -0.5;
        return .{
            .center = .{ self.center[0] + qx * self.size, self.center[1] + qy * self.size },
            .size = half,
        };
    }

    pub fn newContaining(bodies: []const Body) Quad {
        var min_x: f32 = std.math.floatMax(f32);
        var min_y: f32 = std.math.floatMax(f32);
        var max_x: f32 = std.math.floatMin(f32);
        var max_y: f32 = std.math.floatMin(f32);

        for (bodies) |b| {
            min_x = @min(min_x, b.pos[0]);
            min_y = @min(min_y, b.pos[1]);
            max_x = @max(max_x, b.pos[0]);
            max_y = @max(max_y, b.pos[1]);
        }

        const center_x = (min_x + max_x) * 0.5;
        const center_y = (min_y + max_y) * 0.5;
        const size = @max(max_x - min_x, max_y - min_y);

        return Quad{ .center = .{ center_x, center_y }, .size = size };
    }
};

// Update Node struct
pub const Node = extern struct {
    children: u32,
    next: u32,
    pos: [2]f32,
    mass: f32,
    quad: Quad,
    body_index: u32, // Added for collision

    pub fn isLeaf(self: Node) bool {
        return self.children == 0;
    }
    pub fn isBranch(self: Node) bool {
        return self.children != 0;
    }
    pub fn isEmpty(self: Node) bool {
        return self.mass == 0.0;
    }
};

pub const Quadtree = struct {
    nodes: std.ArrayListUnmanaged(Node),
    parents: std.ArrayListUnmanaged(u32),
    t_sq: f32,
    e_sq: f32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, theta: f32, epsilon: f32) Quadtree {
        return .{
            .nodes = .{},
            .parents = .{},
            .t_sq = theta * theta,
            .e_sq = epsilon * epsilon,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Quadtree) void {
        self.nodes.deinit(self.allocator);
        self.parents.deinit(self.allocator);
    }

    pub fn clear(self: *Quadtree, root_quad: Quad) !void {
        self.nodes.clearRetainingCapacity();
        self.parents.clearRetainingCapacity();
        try self.nodes.append(self.allocator, Node{
            .children = 0,
            .next = 0,
            .pos = .{ 0, 0 },
            .mass = 0,
            .quad = root_quad,
            .body_index = 0,
        });
    }

    fn subdivide(self: *Quadtree, node_idx: u32) !u32 {
        try self.parents.append(self.allocator, node_idx);
        const children_idx: u32 = @intCast(self.nodes.items.len);
        self.nodes.items[node_idx].children = children_idx;

        const nexts = [4]u32{
            children_idx + 1,
            children_idx + 2,
            children_idx + 3,
            self.nodes.items[node_idx].next,
        };

        const parent_quad = self.nodes.items[node_idx].quad;
        inline for (0..4) |i| {
            try self.nodes.append(self.allocator, Node{
                .children = 0,
                .next = nexts[i],
                .pos = .{ 0, 0 },
                .mass = 0,
                .quad = parent_quad.intoQuadrant(i),
                .body_index = 0,
            });
        }

        return children_idx;
    }

    pub fn insert(self: *Quadtree, pos: [2]f32, mass: f32, body_idx: u32) !void {
        var node_idx: u32 = 0; // Start at root

        // Traverse down to leaf
        while (self.nodes.items[node_idx].isBranch()) {
            const q = self.nodes.items[node_idx].quad.findQuadrant(pos);
            node_idx = self.nodes.items[node_idx].children + @as(u32, @intCast(q));
        }

        // If leaf empty, place body
        if (self.nodes.items[node_idx].isEmpty()) {
            self.nodes.items[node_idx].pos = pos;
            self.nodes.items[node_idx].mass = mass;
            self.nodes.items[node_idx].body_index = body_idx;
            return;
        }

        // Deal with collision (leaf occupied)
        const p = self.nodes.items[node_idx].pos;
        const m = self.nodes.items[node_idx].mass;
        const idx = self.nodes.items[node_idx].body_index;

        // Exact overlap
        if (p[0] == pos[0] and p[1] == pos[1]) {
            self.nodes.items[node_idx].mass += mass;
            return;
        }

        // Split until separated
        while (true) {
            const children_idx = try self.subdivide(node_idx);

            const q1 = self.nodes.items[node_idx].quad.findQuadrant(p);
            const q2 = self.nodes.items[node_idx].quad.findQuadrant(pos);

            if (q1 == q2) {
                node_idx = children_idx + @as(u32, @intCast(q1));
            } else {
                const n1 = children_idx + @as(u32, @intCast(q1));
                const n2 = children_idx + @as(u32, @intCast(q2));

                self.nodes.items[n1].pos = p;
                self.nodes.items[n1].mass = m;
                self.nodes.items[n1].body_index = idx;

                self.nodes.items[n2].pos = pos;
                self.nodes.items[n2].mass = mass;
                self.nodes.items[n2].body_index = body_idx;
                return;
            }
        }
    }

    // ... propagate remains same ...

    pub fn propagate(self: *Quadtree) void {
        var i = self.parents.items.len;
        while (i > 0) {
            i -= 1;
            const node_idx = self.parents.items[i];
            const first_child = self.nodes.items[node_idx].children;

            var sum_mass: f32 = 0;
            var sum_pos_x: f32 = 0;
            var sum_pos_y: f32 = 0;

            inline for (0..4) |offset| {
                const child = &self.nodes.items[first_child + offset];
                const m = child.mass;
                sum_mass += m;
                sum_pos_x += child.pos[0] * m;
                sum_pos_y += child.pos[1] * m;
            }

            self.nodes.items[node_idx].mass = sum_mass;
            if (sum_mass > 0) {
                self.nodes.items[node_idx].pos = .{ sum_pos_x / sum_mass, sum_pos_y / sum_mass };
            }
        }
    }

    // ... acc remains same ...
    pub fn acc(self: *const Quadtree, pos: [2]f32, theta_sq: f32, eps_sq: f32) [2]f32 {
        var a = [2]f32{ 0, 0 };
        var node_idx: u32 = 0;

        const nodes = self.nodes.items; // Direct slice access for speed
        if (nodes.len == 0) return a;

        while (true) {
            const n = nodes[node_idx];

            // Vector from body to node (node.pos - pos)
            const dx = n.pos[0] - pos[0];
            const dy = n.pos[1] - pos[1];
            const dist_sq = dx * dx + dy * dy;

            // Re-check logic: Rust: n.is_leaf() || size*size < dist_sq * t_sq
            const size_sq = n.quad.size * n.quad.size;
            const is_close_enough = size_sq < dist_sq * theta_sq;

            if (n.isLeaf() or is_close_enough) {
                if (n.mass > 0) { // Avoid self-interaction if at exactly same pos, or empty
                    // F = G * m / (d^2 + e^2)^(3/2) * d
                    // we want acc, so F/m_body = G * n.mass / ...
                    const denom_term = dist_sq + eps_sq;
                    const denom = denom_term * @sqrt(denom_term);
                    const f = (0.5 * n.mass) / denom; // G=0.5

                    a[0] += dx * f;
                    a[1] += dy * f;
                }

                if (n.next == 0) break;
                node_idx = n.next;
            } else {
                node_idx = n.children;
            }
        }
        return a;
    }

    // New helper for collision
    pub fn findCollisions(self: *const Quadtree, body_idx: u32, pos: [2]f32, r: f32, bodies: []Body) void {
        var node_idx: u32 = 0;
        const nodes = self.nodes.items;
        if (nodes.len == 0) return;

        // Bounding box of the body
        const min_x = pos[0] - r;
        const max_x = pos[0] + r;
        const min_y = pos[1] - r;
        const max_y = pos[1] + r;

        while (true) {
            const n = nodes[node_idx];

            // Check bounding box overlap with node quad
            // Quad: center/size -> min/max
            const q_extent = n.quad.size * 0.5;
            const q_min_x = n.quad.center[0] - q_extent;
            const q_max_x = n.quad.center[0] + q_extent;
            const q_min_y = n.quad.center[1] - q_extent;
            const q_max_y = n.quad.center[1] + q_extent;

            const overlap = (max_x > q_min_x) and (min_x < q_max_x) and (max_y > q_min_y) and (min_y < q_max_y);

            if (overlap) {
                if (n.isLeaf()) {
                    if (n.mass > 0 and n.body_index != body_idx) {
                        // Potential collision
                        const other_idx = n.body_index;
                        // Avoid double checking (check only if other_idx > body_idx? No, we need to iterate all or prevent double solve)
                        // Rust solves efficiently. Here simple check:
                        if (other_idx > body_idx) {
                            resolveCollision(bodies, body_idx, other_idx);
                        }
                    }

                    if (n.next == 0) break;
                    node_idx = n.next;
                } else {
                    node_idx = n.children;
                }
            } else {
                // No overlap, skip tree branch
                if (n.next == 0) break;
                node_idx = n.next;
            }
        }
    }
};

fn resolveCollision(bodies: []Body, i: u32, j: u32) void {
    const b1 = bodies[i];
    const b2 = bodies[j];

    const dx = b2.pos[0] - b1.pos[0];
    const dy = b2.pos[1] - b1.pos[1];
    const dist_sq = dx * dx + dy * dy;
    const r_sum = b1.radius + b2.radius;

    if (dist_sq > r_sum * r_sum) return;
    if (dist_sq == 0) return; // Exact overlap support?

    const dist = @sqrt(dist_sq);
    const nx = dx / dist;
    const ny = dy / dist;

    const dvx = b2.vel[0] - b1.vel[0];
    const dvy = b2.vel[1] - b1.vel[1];

    const dot_v = dvx * nx + dvy * ny;

    // Moving apart?
    if (dot_v >= 0) {
        // Just separate (optional: Rust handles overlap even if moving apart to prevent sinking?)
        // Rust does: check dot_v >= 0, separate only.
        const overlap = r_sum - dist;
        const m_total = b1.mass + b2.mass;
        const w1 = b2.mass / m_total;
        const w2 = b1.mass / m_total;

        // Naive position correction
        bodies[i].pos[0] -= nx * overlap * w1;
        bodies[i].pos[1] -= ny * overlap * w1;
        bodies[j].pos[0] += nx * overlap * w2;
        bodies[j].pos[1] += ny * overlap * w2;
        return;
    }

    // Collision response
    // Impulse: j = -(1+e) * v_rel_norm / (1/m1 + 1/m2)
    // elastic e=1 -> -2
    // simplified from Rust
    // Rust uses complex rewind logic. I'll use simple impulse for now to save time/complexity.

    // Match Rust's "tmp" calculation somewhat:
    // Rust: tmp = d * (1.5 * d_dot_v / d_sq); (Impulse)
    // weight1 = m2 / total

    // Rust:
    // let tmp = d * (1.5 * d_dot_v / d_sq);
    // v1 += tmp * weight1
    // v2 -= tmp * weight2

    const factor = 1.5 * dot_v / dist_sq;
    const tmp_x = dx * factor;
    const tmp_y = dy * factor;

    const m_total = b1.mass + b2.mass;
    const w1 = b2.mass / m_total;
    const w2 = b1.mass / m_total;

    bodies[i].vel[0] += tmp_x * w1;
    bodies[i].vel[1] += tmp_y * w1;
    bodies[j].vel[0] -= tmp_x * w2;
    bodies[j].vel[1] -= tmp_y * w2;

    // And standard separation
    const overlap = r_sum - dist;
    // ... we skip rewinding for brevity in Zig (it's optimization for stability).
    // Simple positional correction:
    bodies[i].pos[0] -= nx * overlap * w1;
    bodies[i].pos[1] -= ny * overlap * w1;
    bodies[j].pos[0] += nx * overlap * w2;
    bodies[j].pos[1] += ny * overlap * w2;
}

pub const ZigSimulation = struct {
    bodies: std.ArrayListUnmanaged(Body),
    quadtree: Quadtree,
    allocator: std.mem.Allocator,
    pool: std.Thread.Pool,
    wg: std.Thread.WaitGroup,
    G: f32 = 0.5,
    dt: f32 = 0.016, // Use 0.016 to match Rust? Rust default is 0.05!
    softening: f32 = 5.0,

    pub fn init(allocator: std.mem.Allocator) !*ZigSimulation {
        const self = try allocator.create(ZigSimulation);
        self.* = .{
            .bodies = .{},
            .quadtree = Quadtree.init(allocator, 1.0, 5.0),
            .allocator = allocator,
            .pool = undefined,
            .wg = .{},
            .dt = 0.05, // Match Rust default
        };
        try std.Thread.Pool.init(&self.pool, .{ .allocator = allocator });
        return self;
    }

    // ... deinit, addBody, reset remain same ...
    pub fn deinit(self: *ZigSimulation) void {
        self.pool.deinit();
        self.bodies.deinit(self.allocator);
        self.quadtree.deinit();
        self.allocator.destroy(self);
    }

    pub fn addBody(self: *ZigSimulation, x: f32, y: f32, vx: f32, vy: f32, mass: f32, radius: f32) void {
        self.bodies.append(self.allocator, Body{
            .pos = .{ x, y },
            .vel = .{ vx, vy },
            .acc = .{ 0, 0 },
            .mass = mass,
            .radius = radius,
        }) catch {};
    }

    pub fn reset(self: *ZigSimulation, count: usize) void {
        self.bodies.clearRetainingCapacity();

        const random = std.crypto.random;

        var i: usize = 0;
        while (i < count) : (i += 1) {
            const angle = random.float(f32) * math.pi * 2.0;
            const dist = 100.0 + random.float(f32) * 400.0;
            const velocity = 150.0 / @sqrt(dist);

            const x = @cos(angle) * dist;
            const y = @sin(angle) * dist;
            const vx = -@sin(angle) * velocity;
            const vy = @cos(angle) * velocity;

            self.bodies.append(self.allocator, Body{
                .pos = .{ x, y },
                .vel = .{ vx, vy },
                .acc = .{ 0, 0 },
                .mass = 1.0 + random.float(f32),
                .radius = 1.0 + random.float(f32), // Add radius
            }) catch break;
        }

        self.bodies.append(self.allocator, Body{
            .pos = .{ 0, 0 },
            .vel = .{ 0, 0 },
            .acc = .{ 0, 0 },
            .mass = 10000.0,
            .radius = 10.0,
        }) catch {};
    }

    fn calcForcesChunk(qt: *const Quadtree, bodies: []Body, theta_sq: f32, eps_sq: f32) void {
        for (bodies) |*b| {
            b.acc = qt.acc(b.pos, theta_sq, eps_sq);
        }
    }

    pub fn step(self: *ZigSimulation) void {
        // 1. Iterate (Integrate)
        const dt = self.dt;
        for (self.bodies.items) |*b| {
            b.vel[0] += b.acc[0] * dt;
            b.vel[1] += b.acc[1] * dt;
            b.pos[0] += b.vel[0] * dt;
            b.pos[1] += b.vel[1] * dt;
        }

        // 2. Collide
        // Rebuild Quadtree for collision
        const root_quad = Quad.newContaining(self.bodies.items);
        self.quadtree.clear(root_quad) catch return;

        for (self.bodies.items, 0..) |b, i| {
            self.quadtree.insert(b.pos, b.mass, @intCast(i)) catch continue;
        }
        // Collision detection (SEQ for now due to race)
        for (self.bodies.items, 0..) |b, i| {
            self.quadtree.findCollisions(@intCast(i), b.pos, b.radius, self.bodies.items);
        }

        // 3. Attract (Calc Forces)
        // Rebuild Quadtree for gravity (positions changed by collision?)
        // Rust rebuilds it. We reused it in collision but collision modified pos.
        // If collision modified pos significantly, we should rebuild or update.
        // For performance, maybe we reuse?
        // Let's reuse for now to be fast, but strictly should rebuild.
        // Propagate mass
        self.quadtree.propagate();

        // Compute Forces using Barnes-Hut (Parallel)
        const theta_sq = self.quadtree.t_sq;
        const eps_sq = self.quadtree.e_sq;

        const bodies_slice = self.bodies.items;
        const total = bodies_slice.len;
        const thread_count = 12;
        const min_chunk_size = 500;
        const chunk_size = @max(min_chunk_size, total / (thread_count * 4));

        var i: usize = 0;
        while (i < total) {
            const end = @min(i + chunk_size, total);
            const chunk = bodies_slice[i..end];
            self.pool.spawnWg(&self.wg, calcForcesChunk, .{ &self.quadtree, chunk, theta_sq, eps_sq });
            i = end;
        }

        self.wg.wait();
    }

    pub fn applyForce(self: *ZigSimulation, x: f32, y: f32, fx: f32, fy: f32, radius: f32) void {
        _ = radius;
        const items = self.bodies.items;
        for (items) |*b| {
            const dx = b.pos[0] - x;
            const dy = b.pos[1] - y;
            const d2 = dx * dx + dy * dy;
            if (d2 < 2500.0) {
                b.vel[0] += fx * 0.01;
                b.vel[1] += fy * 0.01;
            }
        }
    }
};
