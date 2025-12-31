use crate::{
    body::Body,
    quadtree::Node,
    simulation::Simulation,
};
use rustfiber::JobSystem;
use ultraviolet::Vec2;

#[unsafe(no_mangle)]
pub unsafe extern "C" fn Simulation_Create() -> *mut Simulation {
    Box::into_raw(Box::new(Simulation::new()))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn Simulation_Destroy(handle: *mut Simulation) {
    if !handle.is_null() {
        unsafe { drop(Box::from_raw(handle)) };
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn Simulation_Step(handle: *mut Simulation) {
    if let Some(sim) = unsafe { handle.as_mut() } {
        sim.step();
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn Simulation_Reset(handle: *mut Simulation, n: usize) {
    if let Some(sim) = unsafe { handle.as_mut() } {
        sim.reset(n);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn Simulation_SetUseRayon(handle: *mut Simulation, use_rayon: bool) {
    if let Some(sim) = unsafe { handle.as_mut() } {
        sim.set_use_rayon(use_rayon);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn Simulation_GetUseRayon(handle: *const Simulation) -> bool {
    unsafe { handle.as_ref() }.map_or(false, |sim| sim.use_rayon)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn Simulation_GetBodyCount(handle: *const Simulation) -> usize {
    unsafe { handle.as_ref() }.map_or(0, |sim| sim.bodies.len())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn Simulation_GetBodies(handle: *const Simulation) -> *const Body {
    unsafe { handle.as_ref() }.map_or(std::ptr::null(), |sim| sim.bodies.as_ptr())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn Simulation_GetNodeCount(handle: *const Simulation) -> usize {
    unsafe { handle.as_ref() }.map_or(0, |sim| sim.quadtree.nodes.len())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn Simulation_GetNodes(handle: *const Simulation) -> *const Node {
    unsafe { handle.as_ref() }.map_or(std::ptr::null(), |sim| sim.quadtree.nodes.as_ptr())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn Simulation_AddBody(
    handle: *mut Simulation,
    x: f32,
    y: f32,
    vx: f32,
    vy: f32,
    mass: f32,
    radius: f32,
) {
    if let Some(sim) = unsafe { handle.as_mut() } {
        sim.bodies.push(Body::new(
            Vec2::new(x, y),
            Vec2::new(vx, vy),
            mass,
            radius,
        ));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn Simulation_ApplyForce(
    handle: *mut Simulation,
    x: f32,
    y: f32,
    fx: f32,
    fy: f32,
    radius: f32,
) {
    if let Some(sim) = unsafe { handle.as_mut() } {
        let pos = Vec2::new(x, y);
        let force = Vec2::new(fx, fy);
        let r_sq = radius * radius;

        for body in &mut sim.bodies {
            let d = body.pos - pos;
            if d.mag_sq() < r_sq {
                body.vel += force;
            }
        }
    }
}
// --- Extended Simulation API ---

#[unsafe(no_mangle)]
pub unsafe extern "C" fn Simulation_CreateWithJobSystem(job_system_handle: *mut JobSystem, n: usize, dt: f32) -> *mut Simulation {
    // Reconstruct Arc from handle provided by rustfiber::c_api
    let job_system = match unsafe { rustfiber::c_api::job_system_from_handle(job_system_handle) } {
        Some(js) => js,
        None => return std::ptr::null_mut(),
    };
    
    // Defaults matching Simulation::new()
    let theta = Simulation::DEFAULT_THETA;
    let epsilon = Simulation::DEFAULT_EPSILON;
    
    let bodies = crate::utils::uniform_disc(n);
    let sim = Simulation::with_bodies_and_job_system(bodies, dt, theta, epsilon, job_system);
    
    Box::into_raw(Box::new(sim))
}
