use crate::body::Body;
use ultraviolet::Vec2;

/// Represents a square region in the quadtree.
/// Used to define the bounds of nodes.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Quad {
    pub center: Vec2,
    pub size: f32,
}

impl Quad {
    /// Creates a new Quad that encompasses all the given bodies.
    /// It calculates the bounding box of the bodies and centers the Quad on it.
    pub fn new_containing(bodies: &[Body]) -> Self {
        let mut min_x = f32::MAX;
        let mut min_y = f32::MAX;
        let mut max_x = f32::MIN;
        let mut max_y = f32::MIN;

        for body in bodies {
            min_x = min_x.min(body.pos.x);
            min_y = min_y.min(body.pos.y);
            max_x = max_x.max(body.pos.x);
            max_y = max_y.max(body.pos.y);
        }

        let center = Vec2::new(min_x + max_x, min_y + max_y) * 0.5;
        let size = (max_x - min_x).max(max_y - min_y);

        Self { center, size }
    }

    /// Determines which quadrant a position falls into relative to the quad's center.
    /// Returns an index from 0 to 3:
    /// 0: Top-Left, 1: Top-Right, 2: Bottom-Left, 3: Bottom-Right
    pub fn find_quadrant(&self, pos: Vec2) -> usize {
        ((pos.y > self.center.y) as usize) << 1 | (pos.x > self.center.x) as usize
    }

    /// Transforms the current Quad into one of its sub-quadrants.
    /// Updates center and size to represent the specified quadrant.
    pub fn into_quadrant(mut self, quadrant: usize) -> Self {
        self.size *= 0.5;
        self.center.x += ((quadrant & 1) as f32 - 0.5) * self.size;
        self.center.y += ((quadrant >> 1) as f32 - 0.5) * self.size;
        self
    }

    /// Divides the quad into 4 equal sub-quadrants.
    pub fn subdivide(&self) -> [Quad; 4] {
        [0, 1, 2, 3].map(|i| self.into_quadrant(i))
    }
}

#[repr(C)]
#[derive(Clone, Debug)]
pub struct Node {
    /// Index of the first child in the nodes array (0 if leaf).
    pub children: u32,
    /// Index of the next sibling (or 0 if last child/root).
    pub next: u32,
    /// Center of mass of the node.
    pub pos: Vec2,
    /// Total mass of the node.
    pub mass: f32,
    /// Spatial bounds of the node.
    pub quad: Quad,
    /// External body index (only valid if is_leaf() and mass > 0).
    pub body_index: u32,
}

impl Node {
    pub fn new(next: u32, quad: Quad) -> Self {
        Self {
            children: 0,
            next,
            pos: Vec2::zero(),
            mass: 0.0,
            quad,
            body_index: u32::MAX,
        }
    }

    pub fn is_leaf(&self) -> bool {
        self.children == 0
    }

    pub fn is_branch(&self) -> bool {
        self.children != 0
    }

    pub fn is_empty(&self) -> bool {
        self.mass == 0.0
    }
}

/// The Quadtree data structure for the Barnes-Hut simulation.
/// Uses a flat vector `nodes` for better cache locality.
#[derive(Debug)]
pub struct Quadtree {
    /// Theta squared (opening angle threshold for approximation).
    pub t_sq: f32,
    /// Epsilon squared (softening parameter to avoid singularities).
    pub e_sq: f32,
    /// Linearized tree nodes.
    pub nodes: Vec<Node>,
    /// Indices of parent nodes, used for bottom-up center of mass propagation.
    pub parents: Vec<usize>,
}

impl Default for Quadtree {
    fn default() -> Self {
        Self::new(1.0, 1.0)
    }
}

impl Quadtree {
    pub const ROOT: usize = 0;

    pub fn new(theta: f32, epsilon: f32) -> Self {
        Self {
            t_sq: theta * theta,
            e_sq: epsilon * epsilon,
            nodes: Vec::new(),
            parents: Vec::new(),
        }
    }

    /// Resets the tree and initializes the root node with the given bounds.
    pub fn clear(&mut self, quad: Quad) {
        self.nodes.clear();
        self.parents.clear();
        self.nodes.push(Node::new(0, quad));
    }

    /// Subdivides a leaf node into 4 children.
    /// Returns the index of the first child.
    fn subdivide(&mut self, node: usize) -> usize {
        self.parents.push(node);
        let children = self.nodes.len() as u32;
        self.nodes[node].children = children;

        // Set up 'next' pointers for the children to link them together
        // and link the last child to the parent's 'next' to support linear traversal.
        let nexts = [
            children + 1,
            children + 2,
            children + 3,
            self.nodes[node].next,
        ];
        let quads = self.nodes[node].quad.subdivide();
        for i in 0..4 {
            self.nodes.push(Node::new(nexts[i], quads[i]));
        }

        return children as usize;
    }

    /// Inserts a body (position and mass) into the tree.
    pub fn insert(&mut self, pos: Vec2, mass: f32, body_index: usize) {
        let mut node = Self::ROOT;

        // Traverse down to a leaf
        while self.nodes[node].is_branch() {
            let quadrant = self.nodes[node].quad.find_quadrant(pos);
            node = (self.nodes[node].children as usize) + quadrant;
        }

        // If leaf is empty, just place the body there
        if self.nodes[node].is_empty() {
            self.nodes[node].pos = pos;
            self.nodes[node].mass = mass;
            self.nodes[node].body_index = body_index as u32;
            return;
        }

        // Handle collision (leaf already occupied)
        let (p, m) = (self.nodes[node].pos, self.nodes[node].mass);
        let idx = self.nodes[node].body_index;
        
        // If positions are identical, just add mass (merge bodies/star collision)
        if pos == p {
            self.nodes[node].mass += mass;
            return;
        }

        // Otherwise, split the node until the bodies are in different quadrants
        loop {
            let children = self.subdivide(node);

            let q1 = self.nodes[node].quad.find_quadrant(p);
            let q2 = self.nodes[node].quad.find_quadrant(pos);

            if q1 == q2 {
                // Both bodies fell into the same child, keep subdividing this child
                node = children + q1;
            } else {
                // Bodies separated, place them in their respective children
                let n1 = children + q1;
                let n2 = children + q2;

                self.nodes[n1].pos = p;
                self.nodes[n1].mass = m;
                self.nodes[n1].body_index = idx;
                
                self.nodes[n2].pos = pos;
                self.nodes[n2].mass = mass;
                self.nodes[n2].body_index = body_index as u32;
                return;
            }
        }
    }

    /// Calculates center of mass and total mass for all nodes (bottom-up).
    /// Should be called after all insertions are done.
    pub fn propagate(&mut self) {
        // Iterate parents in reverse insertion order (deepest first)
        for &node in self.parents.iter().rev() {
            let i = self.nodes[node].children as usize;

            // Compute center of mass: (Sum(pos * mass) / TotalMass)
            self.nodes[node].pos = self.nodes[i].pos * self.nodes[i].mass
                + self.nodes[i + 1].pos * self.nodes[i + 1].mass
                + self.nodes[i + 2].pos * self.nodes[i + 2].mass
                + self.nodes[i + 3].pos * self.nodes[i + 3].mass;
            
            self.nodes[node].mass = self.nodes[i].mass
                + self.nodes[i + 1].mass
                + self.nodes[i + 2].mass
                + self.nodes[i + 3].mass;

            let mass = self.nodes[node].mass;
            if mass > 0.0 {
                self.nodes[node].pos /= mass;
            }
        }
    }

    /// Calculates the gravitational acceleration at a given position.
    /// Uses the Barnes-Hut approximation criteria.
    #[inline(always)]
    pub fn acc(&self, pos: Vec2) -> Vec2 {
        let mut acc = Vec2::zero();

        let mut node_idx = Self::ROOT;
        if self.nodes.is_empty() {
             return acc;
        }

        loop {
            // SAFETY: The tree construction ensures valid indices. Next/Children indices are always valid or 0.
            // Removing bounds checks is critical for performance here.
            let n = unsafe { self.nodes.get_unchecked(node_idx) };

            let d = n.pos - pos;
            let d_sq = d.mag_sq();

            // Check Barnes-Hut criterion: s/d < theta
            // Equivalent to: s^2 < d^2 * theta^2
            if n.is_leaf() || n.quad.size * n.quad.size < d_sq * self.t_sq {
                // Treat node as a single body
                if n.mass > 1e-10 {
                    let denom_term = d_sq + self.e_sq;
                    let denom = denom_term * denom_term.sqrt();
                    acc += d * (n.mass / denom);
                }

                // Skip children, go to next sibling/node
                if n.next == 0 {
                    break;
                }
                node_idx = n.next as usize;
            } else {
                // Node is too close/large, recurse into children
                node_idx = n.children as usize;
            }
        }

        acc
    }

    /// Finds potential collisions for a body using the quadtree.
    /// Calls `callback` for each potential collision candidate (index).
    #[inline(always)]
    pub fn find_collisions(&self, body_idx: u32, pos: Vec2, radius: f32, mut callback: impl FnMut(u32)) {
        if self.nodes.is_empty() { return; }
        
        // AABB of the query body
        let min = pos - Vec2::broadcast(radius);
        let max = pos + Vec2::broadcast(radius);

        let mut node_idx = Self::ROOT;
        
        loop {
            let n = unsafe { self.nodes.get_unchecked(node_idx) };

            // Check AABB overlap with node quad
            let q_half = n.quad.size * 0.5;
            let q_min = n.quad.center - Vec2::broadcast(q_half);
            let q_max = n.quad.center + Vec2::broadcast(q_half);

            // Simple AABB overlap check
            if max.x > q_min.x && min.x < q_max.x && max.y > q_min.y && min.y < q_max.y {
                if n.is_leaf() {
                    let n_idx = n.body_index;
                     if n.mass > 0.0 && n_idx != u32::MAX && n_idx != body_idx {
                        callback(n_idx);
                     }
                    
                    if n.next == 0 { break; }
                    node_idx = n.next as usize;
                } else {
                    node_idx = n.children as usize;
                }
            } else {
                // No overlap, skip children
                if n.next == 0 { break; }
                node_idx = n.next as usize;
            }
        }
    }
}
