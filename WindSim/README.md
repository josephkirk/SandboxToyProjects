# WindSim: Sparse Blocked Grid Architecture

This directory contains the optimized implementation of a 3D wind simulation using a **Sparse Blocked Grid** architecture. This approach allows for high-resolution simulations by processing only the active regions of the domain, treating empty space as effectively zero-cost.

## Core Concepts

### 1. Unit Blocks (16x16x16)
The simulation domain is divided into "Unit Blocks" of size \`16^3\` (4096 cells).
- **Alignment**: 16 is chosen to perfectly match the SIMD width (AVX2 can process 8 floats at once, so 16 is two full vectors).
- **Block Indexing**: Blocks are indexed linearly \`(bx, by, bz)\`, minimizing cache misses during iteration.

### 2. AABB Tree Culling (`aabbtree.hpp`)
We use a custom Axis-Aligned Bounding Box (AABB) Tree to efficiently detect which blocks are "active".
- **Dynamic Updates**: Every frame, the tree is rebuilt from the current `WindVolume` positions.
- **Pass 1 (Wake)**: We check if a block's bounding box overlaps with any active Wind Volume. If so, it is marked **Active**.

### 3. Velocity Persistence
To prevent wind from "freezing" when a volume moves away, we implement a second activation pass.
- **Pass 2 (Persist)**: We scan inactive blocks for lingering velocity.
- **Threshold**: If any cell in a block has `|v| > 1e-4`, the block remains **Active** until the velocity dissipates naturally.

## Performance Architectures

### Data Layout: Structure of Arrays (SoA)
We use a virtual memory approach where the underlying arrays (`vx`, `vy`, `vz`) are contiguous and allocated for the *entire* domain.
- **Benefit**: This allows us to use `blockIdx` to jump directly into memory without pointer indirection.
- **SIMD**: The contiguous layout enables efficient AVX2 processing (`_mm256_loadu_ps`) within the inner loops.

### Culling Logic
The solvers (`advect`, `project`) iterate over blocks rather than cells:
```cpp
#pragma omp parallel for collapse(3)
for (int bz = 0; bz < blocksZ; ++bz) {
  for (int by = 0; by < blocksY; ++by) {
    for (int bx = 0; bx < blocksX; ++bx) {
       if (!activeBlocks[blockIdx]) continue; // SKIP EMPTY SPACE
       
       // Process 16x16x16 cells with AVX2...
    }
  }
}
```

## Building
Use the provided Zig build script:
```bash
zig build -Doptimize=ReleaseFast
```

## Controls
- **WASD / Arrows**: Move Camera (Maya Style: Alt + Left/Mid/Right Mouse).
- **N / B**: Add Radial / Directional Wind.
- **TAB**: Select Volume.
- **Arrows / PgUp / PgDn**: Move Selected Volume.
- **R/F, T/G, Y/H**: Rotate Wind Direction.
