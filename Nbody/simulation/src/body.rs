use ultraviolet::Vec2;

/// Represents a celestial body in the simulation.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Body {
    /// Position vector.
    pub pos: Vec2,
    /// Velocity vector.
    pub vel: Vec2,
    /// Acceleration vector (reset each step).
    pub acc: Vec2,
    /// Mass of the body.
    pub mass: f32,
    /// Visual radius of the body.
    pub radius: f32,
}

impl Default for Body {
    fn default() -> Self {
        Self::new(Vec2::zero(), Vec2::zero(), 1.0, 1.0)
    }
}

impl Body {
    /// Creates a new Body with the given properties.
    /// Initial acceleration is zero.
    pub fn new(pos: Vec2, vel: Vec2, mass: f32, radius: f32) -> Self {
        Self {
            pos,
            vel,
            acc: Vec2::zero(),
            mass,
            radius,
        }
    }

    /// Updates the body's position and velocity based on its current acceleration and time step `dt`.
    /// Uses semi-implicit Euler integration (velocity update first, then position).
    pub fn update(&mut self, dt: f32) {
        self.vel += self.acc * dt;
        self.pos += self.vel * dt;
    }
}
