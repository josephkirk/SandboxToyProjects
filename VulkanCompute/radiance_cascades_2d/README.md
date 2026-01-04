# Radiance Cascades 2D (Zig + Vulkan)

Okay, so this is my attempt at implementing **Radiance Cascades** in Zig and Vulkan following https://jason.today/rc

```bash
zig build run -Doptimize=ReleaseFast
```


## Controls

*   **LMB**: Light.
*   **RMB**: Wall.
*   **MMB (Hold)**: Erase (The "I messed up" button).
*   **Keys 1-9**: Colors.
*   **+/-**: Brush size.
*   **D**: Debug views (L1x, L1y, Vectors - honestly mostly looked at Vectors to feel smart).
*   **ImGui**:
    *   *Show Intervals*: Shows red rings. Useful to see if your geometric progression is broken.
    *   *Ringing Fix*: Some hack to fix fireflies/ringing at high ray counts. Leave it on.

## The Algorithms

### 1. Brute-Force (`cascade_brute.hlsl`)
This is my brute attempt at the radiance cascade. It simply **casts more rays** for higher cascade levels.
*   **How it works**: To cover the wider angular domain required by distant cascades, it scales the ray count exponentially.
    *   Level 0: 4 rays/pixel.
    *   Level 1: 16 rays/pixel ($4 \times 4$).
    *   Level 2: 64 rays/pixel ($16 \times 4$).
*   **SDF Logic**: Implements Jump Flooding Algorithm (JFA) for fast distance field lookup (though analytic fallback is available) for learning purpose.
*   **Performance**: **O(N^2)** cost. This becomes prohibitively slow very quickly. It treats every pixel as an isolated integration problem. Also pretty noise and have a lot of artifact.

### 2. Probe-Based (`cascade.hlsl`)
This is the modern, efficient implementation. It keeps the cost constant by trading **spatial resolution** for **angular resolution**.
*   **How it works**: Instead of every pixel casting 64 rays, we space out "Probes" in a grid.
    *   **Level 0**: Probes are dense (every pixel), casting 4 directions.
    *   **Level 1**: Probes are spaced 2 pixels apart (2x2 area). We pack these 4 pixels' worth of data into a single "Probe" that can now store 16 distinct ray directions (4 per pixel × 4 pixels).
    *   **Level 2**: Probes are spaced 4 pixels apart. The 4x4 area contributes 16 pixels × 4 rays = 64 directions.
*   **SDF Logic**: Uses Analytic SDF (looping through circles) for maximum precision.
*   **Performance**: **O(1)** cost. Every pixel in the texture computes exactly 4 rays, regardless of the level. The data is stored in a "Texture Atlas" where adjacent pixels represent different ray directions for the same spatial location.

## Project Structure

*   `main.zig`: The good one. Probe-based.
*   `main_brute.zig`: The bad one. Brute-force.
*   `cascade.hlsl`: The magic. Logic for the flatland.
*   `display.hlsl`: Tone mapping so it doesn't look washed out.
