use crate::{
    body::Body,
    quadtree::Node,
    simulation::Simulation,
};
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
    if let Some(sim) = handle.as_mut() {
        sim.step();
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn Simulation_Reset(handle: *mut Simulation, n: usize) {
    if let Some(sim) = handle.as_mut() {
        sim.reset(n);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn Simulation_GetBodyCount(handle: *const Simulation) -> usize {
    handle.as_ref().map_or(0, |sim| sim.bodies.len())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn Simulation_GetBodies(handle: *const Simulation) -> *const Body {
    handle.as_ref().map_or(std::ptr::null(), |sim| sim.bodies.as_ptr())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn Simulation_GetNodeCount(handle: *const Simulation) -> usize {
    handle.as_ref().map_or(0, |sim| sim.quadtree.nodes.len())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn Simulation_GetNodes(handle: *const Simulation) -> *const Node {
    handle.as_ref().map_or(std::ptr::null(), |sim| sim.quadtree.nodes.as_ptr())
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
    if let Some(sim) = handle.as_mut() {
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
    if let Some(sim) = handle.as_mut() {
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
