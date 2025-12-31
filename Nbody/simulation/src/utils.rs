use crate::body::Body;
use ultraviolet::Vec2;

/// Generates `n` bodies distributed in a uniform disc, suitable for a galaxy simulation.
/// - Creates a massive central body.
/// - Places other bodies in random circular orbits around the center.
/// - Assigns velocities to ensure stable orbits based on accumulated mass.
pub fn uniform_disc(n: usize) -> Vec<Body> {
    fastrand::seed(0);
    let inner_radius = 25.0;
    let outer_radius = (n as f32).sqrt() * 5.0;

    let mut bodies: Vec<Body> = Vec::with_capacity(n);

    // Create a massive central black hole / star
    let m = 1e6;
    let center = Body::new(Vec2::zero(), Vec2::zero(), m as f32, inner_radius);
    bodies.push(center);

    while bodies.len() < n {
        // Random angle
        let a = fastrand::f32() * std::f32::consts::TAU;
        let (sin, cos) = a.sin_cos();
        
        // Random radius with uniform area distribution
        let t = inner_radius / outer_radius;
        let r = fastrand::f32() * (1.0 - t * t) + t * t;
        let pos = Vec2::new(cos, sin) * outer_radius * r.sqrt();
        
        // Initial perpendicular velocity direction
        let vel = Vec2::new(sin, -cos);
        let mass = 1.0f32;
        let radius = mass.cbrt();

        bodies.push(Body::new(pos, vel, mass, radius));
    }

    // Sort bodies by distance from center (closest first)
    bodies.sort_by(|a, b| a.pos.mag_sq().total_cmp(&b.pos.mag_sq()));
    
    // Calculate orbital velocities
    let mut mass = 0.0;
    for i in 0..n {
        mass += bodies[i].mass;
        if bodies[i].pos == Vec2::zero() {
            continue;
        }

        // Velocity for circular orbit: v = sqrt(GM / r)
        // Here G is implicitly 1
        let v = (mass / bodies[i].pos.mag()).sqrt();
        bodies[i].vel *= v;
    }

    bodies
}
