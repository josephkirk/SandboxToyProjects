use crate::{
    body::Body,
    quadtree::{Quad, Quadtree},
    utils,
};

use broccoli::aabb::Rect;
use ultraviolet::Vec2;
use rustfiber::{JobSystem, ParallelSliceMut};
use rayon::prelude::*;

use std::sync::Arc;


/// Manages the Barnes-Hut N-body simulation state and logic.
// #[derive(Debug)] // JobSystem doesn't implement Debug

pub struct Simulation {
    /// Time step per frame.
    pub dt: f32,
    /// Current frame count.
    pub frame: usize,
    /// Collection of all bodies in the simulation.
    pub bodies: Vec<Body>,
    /// The Quadtree used for spatial acceleration of gravitational calculations.
    pub quadtree: Quadtree,
    /// The JobSystem for parallel execution.
    pub job_system: Arc<JobSystem>,
    /// Whether to use Rayon instead of RustFiber.
    pub use_rayon: bool,
}

impl std::fmt::Debug for Simulation {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Simulation")
            .field("dt", &self.dt)
            .field("frame", &self.frame)
            .field("bodies", &self.bodies)
            .field("quadtree", &self.quadtree)
            .field("job_system", &"JobSystem")
            .field("use_rayon", &self.use_rayon)
            .finish()
    }
}




impl Default for Simulation {
    fn default() -> Self {
        Self::new()
    }
}

impl Simulation {
    /// Default constants.
    pub const DEFAULT_DT: f32 = 0.05;
    pub const DEFAULT_N: usize = 1_000_000;
    pub const DEFAULT_THETA: f32 = 1.0;
    pub const DEFAULT_EPSILON: f32 = 1.0;

    /// Initializes a new simulation with default parameters and a uniform disc distribution of bodies.
    pub fn new() -> Self {
        Self::with_params(
            Self::DEFAULT_N,
            Self::DEFAULT_DT,
            Self::DEFAULT_THETA,
            Self::DEFAULT_EPSILON,
        )
    }

    /// Initializes a new simulation with custom parameters and a uniform disc of bodies.
    pub fn with_params(n: usize, dt: f32, theta: f32, epsilon: f32) -> Self {
        let bodies = utils::uniform_disc(n);
        Self::with_bodies(bodies, dt, theta, epsilon)
    }

    /// Initializes a new simulation with the given bodies and parameters.
    pub fn with_bodies(bodies: Vec<Body>, dt: f32, theta: f32, epsilon: f32) -> Self {
        // Use a robust configuration for the job system
        let job_system = JobSystem::builder()
            .stack_size(2 * 1024 * 1024) // 2MB stack to match OS threads and prevent overflow
            .initial_pool_size(64)       // Larger initial pool
            .target_pool_size(512)       // Allow more growth
            .pinning_strategy(rustfiber::PinningStrategy::AvoidSMT)
            .build();
            
        Self::with_bodies_and_job_system(bodies, dt, theta, epsilon, Arc::new(job_system))
    }

    pub fn with_bodies_and_job_system(
        bodies: Vec<Body>, 
        dt: f32, 
        theta: f32, 
        epsilon: f32, 
        job_system: Arc<JobSystem>
    ) -> Self {
        let quadtree = Quadtree::new(theta, epsilon);

        Self {
            dt,
            frame: 0,
            bodies,
            quadtree,
            job_system,
            use_rayon: false,
        }
    }

    /// Resets the simulation with a new number of bodies.
    pub fn reset(&mut self, n: usize) {
        self.bodies = crate::utils::uniform_disc(n);
        self.frame = 0;
    }

    /// Sets whether to use Rayon for parallelism.
    pub fn set_use_rayon(&mut self, use_rayon: bool) {
        self.use_rayon = use_rayon;
    }

    /// Advances the simulation by one step.
    /// This includes updating positions (iterate), handling collisions, and calculating gravitational forces (attract).
    pub fn step(&mut self) {
        // Signal start of frame to reset per-frame allocators (prevents memory leaks)
        self.job_system.start_new_frame();

        self.iterate();
        self.collide();
        self.attract();
        self.frame += 1;
    }

    /// Calculates gravitational forces (acceleration) for all bodies using the Barnes-Hut algorithm.
    /// 1. Rebuilds the Quadtree from current body positions.
    /// 2. Propagates center of mass information up the tree.
    /// 3. Approximates forces for each body using the tree.
    pub fn attract(&mut self) {
        let quad = Quad::new_containing(&self.bodies);
        self.quadtree.clear(quad);

        for body in &self.bodies {
            self.quadtree.insert(body.pos, body.mass);
        }

        self.quadtree.propagate();

        if self.use_rayon {
             let quadtree = &self.quadtree;
             self.bodies.par_iter_mut().for_each(|body| {
                  body.acc = quadtree.acc(body.pos);
             });
        } else {
             // Optimized RustFiber path with manual chunking to match Zig's performance
             let len = self.bodies.len();
             if len == 0 { return; }

             let bodies_ptr = self.bodies.as_mut_ptr() as usize;
             let quadtree_ptr = &self.quadtree as *const Quadtree as usize;

             // SAFETY:
             // 1. We access non-overlapping ranges of `bodies` (guaranteed by job system partitioner)
             // 2. `quadtree` is read-only
             let counter = self.job_system.parallel_for_chunked_with_hint(
                 0..len,
                 rustfiber::GranularityHint::Light, // Target ~4 jobs per worker
                 move |range| {
                     unsafe {
                         let bodies = std::slice::from_raw_parts_mut(bodies_ptr as *mut Body, len);
                         let qt = &*(quadtree_ptr as *const Quadtree);
                         
                         for i in range {
                             // Use get_unchecked for the bodies array inside the known valid range
                             // (Though iterator elision should handle this, specific indices help)
                             bodies.get_unchecked_mut(i).acc = qt.acc(bodies.get_unchecked(i).pos);
                         }
                     }
                 }
             );
             self.job_system.wait_for_counter(&counter);
        }
    }

    /// Updates the position and velocity of all bodies based on their current acceleration and time step.
    pub fn iterate(&mut self) {
        let dt = self.dt;
        // self.bodies.iter_mut().for_each(|body| body.update(dt)); // sequential fallback for comparison? no.
        
        if self.use_rayon {
             self.bodies.par_iter_mut().for_each(|body| {
                 body.update(dt);
             });
        } else {
             self.bodies.fiber_iter_mut(&self.job_system).for_each(move |body| {
                 body.update(dt);
             });
        }
    }

    /// Detects and resolves collisions between bodies.
    /// Uses the `broccoli` crate (a broad-phase collision detection library) to find potentially colliding pairs efficiently.
    pub fn collide(&mut self) {
        let mut rects = self
            .bodies
            .iter()
            .enumerate()
            .map(|(index, body)| {
                let pos = body.pos;
                let radius = body.radius;
                let min = pos - Vec2::one() * radius;
                let max = pos + Vec2::one() * radius;
                (Rect::new(min.x, max.x, min.y, max.y), index)
            })
            .collect::<Vec<_>>();

        let mut broccoli = broccoli::Tree::new(&mut rects);

        broccoli.find_colliding_pairs(|i, j| {
            let i = *i.unpack_inner();
            let j = *j.unpack_inner();

            self.resolve(i, j);
        });
    }

    /// Resolves a collision between two bodies identified by indices `i` and `j`.
    /// Handles elastic collision response.
    fn resolve(&mut self, i: usize, j: usize) {
        let b1 = &self.bodies[i];
        let b2 = &self.bodies[j];

        let p1 = b1.pos;
        let p2 = b2.pos;

        let r1 = b1.radius;
        let r2 = b2.radius;

        let d = p2 - p1;
        let r = r1 + r2;

        if d.mag_sq() > r * r {
            return;
        }

        let v1 = b1.vel;
        let v2 = b2.vel;

        let v = v2 - v1;

        let d_dot_v = d.dot(v);

        let m1 = b1.mass;
        let m2 = b2.mass;

        let weight1 = m2 / (m1 + m2);
        let weight2 = m1 / (m1 + m2);

        // If bodies are moving apart or static, just separate them slightly without impulse
        if d_dot_v >= 0.0 && d != Vec2::zero() {
            let tmp = d * (r / d.mag() - 1.0);
            self.bodies[i].pos -= weight1 * tmp;
            self.bodies[j].pos += weight2 * tmp;
            return;
        }

        // Calculate collision time 't' to rewind simulation to the exact moment of impact
        let v_sq = v.mag_sq();
        let d_sq = d.mag_sq();
        let r_sq = r * r;

        let t = (d_dot_v + (d_dot_v * d_dot_v - v_sq * (d_sq - r_sq)).max(0.0).sqrt()) / v_sq;

        // Rewind positions
        self.bodies[i].pos -= v1 * t;
        self.bodies[j].pos -= v2 * t;

        let p1 = self.bodies[i].pos;
        let p2 = self.bodies[j].pos;
        let d = p2 - p1;
        let d_dot_v = d.dot(v);
        let d_sq = d.mag_sq();

        // Calculate impulse and update velocities
        let tmp = d * (1.5 * d_dot_v / d_sq);
        let v1 = v1 + tmp * weight1;
        let v2 = v2 - tmp * weight2;

        self.bodies[i].vel = v1;
        self.bodies[j].vel = v2;
        // Fast-forward positions after collision response
        self.bodies[i].pos += v1 * t;
        self.bodies[j].pos += v2 * t;
    }
}
