use criterion::{criterion_group, criterion_main, Criterion, Throughput};
use nbody_simulation::Simulation;
use nbody_simulation::rustfiber::JobSystem;
use std::sync::Arc;

fn bench_sim_job_systems(c: &mut Criterion) {
    let mut group = c.benchmark_group("nbody_simulation_presets");
    group.sample_size(10); // Reduce sample size for faster sweep
    
    // We only create bodies once to be fair, but technically we consume them.
    // So we generate them for each bench or clone them.
    // Bodies is Vec<Body>. Body is simple struct.
    
    // Helper to setup and bench
    let setup_sim = |job_system: Arc<JobSystem>| {
        // Reuse default generation logic by creating a temp default sim
        // Note: Simulation::new() creates 1M bodies which is heavy. 
        // We might want to cache the initial state if generation is slow, 
        // but utils::uniform_disc is fairly fast compared to simulation step.
        let default_sim = Simulation::new(); 
        Simulation::with_bodies_and_job_system(
            default_sim.bodies, 
            default_sim.dt, 
            1.5, // theta (default in new() is 1.5)
            0.1, // epsilon (default in new() is 0.1)
            job_system
        )
    };

    // 1. Default
    {
        let job_system = Arc::new(JobSystem::default());
        let mut sim = setup_sim(job_system.clone());
        // Warmup
        sim.step();
        
        group.throughput(Throughput::Elements(sim.bodies.len() as u64));
        group.bench_function("default", |b| {
            b.iter(|| sim.step());
        });
    }

    // 2. Gaming
    {
        let job_system = Arc::new(JobSystem::for_gaming());
        let mut sim = setup_sim(job_system.clone());
        sim.step();
        group.bench_function("gaming", |b| {
            b.iter(|| sim.step());
        });
    }

    // 3. Throughput
    {
        let job_system = Arc::new(JobSystem::for_throughput());
        let mut sim = setup_sim(job_system.clone());
        sim.step();
        group.bench_function("throughput", |b| {
            b.iter(|| sim.step());
        });
    }
    
    // 4. Low Latency
    {
        let job_system = Arc::new(JobSystem::for_low_latency());
        let mut sim = setup_sim(job_system.clone());
        sim.step();
        group.bench_function("low_latency", |b| {
            b.iter(|| sim.step());
        });
    }

    group.finish();
}

criterion_group!(benches, bench_sim_job_systems);
criterion_main!(benches);
