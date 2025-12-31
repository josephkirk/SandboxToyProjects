use criterion::{criterion_group, criterion_main, Criterion};
use nbody_simulation::Simulation;

fn bench_sim_step(c: &mut Criterion) {
    let mut sim = Simulation::new();
    
    // Warmup
    for _ in 0..10 {
        sim.step();
    }

    c.bench_function("sim_step_1m", |b| {
        b.iter(|| {
            sim.step();
        });
    });
}

criterion_group!(benches, bench_sim_step);
criterion_main!(benches);
