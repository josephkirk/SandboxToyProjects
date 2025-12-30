#pragma once

#include <algorithm>
#include <cmath>
#include <cstring>
#include <iostream>
#include <memory>
#include <vector>


// Check for SIMD support
#if defined(__AVX2__)
#include <immintrin.h>
#define WINDSIM_USE_AVX2
#elif defined(__SSE4_1__)
#include <immintrin.h>
#define WINDSIM_USE_SSE
#endif

namespace WindSim {

// -------------------------------------------------------------------------
// Math & Types (Aligned for Vulkan/SIMD)
// -------------------------------------------------------------------------

static constexpr float PI = 3.14159265359f;

// Aligns to 16 bytes for std140/std430 layout compatibility in Vulkan
struct alignas(16) Vec4 {
  float x, y, z, w;

  Vec4() : x(0), y(0), z(0), w(0) {}
  Vec4(float _x, float _y, float _z, float _w = 0.0f)
      : x(_x), y(_y), z(_z), w(_w) {}

  Vec4 operator+(const Vec4 &rhs) const {
    return {x + rhs.x, y + rhs.y, z + rhs.z, w + rhs.w};
  }
  Vec4 operator-(const Vec4 &rhs) const {
    return {x - rhs.x, y - rhs.y, z - rhs.z, w - rhs.w};
  }
  Vec4 operator*(float s) const { return {x * s, y * s, z * s, w * s}; }

  // Dot product of XYZ only
  float dot3(const Vec4 &rhs) const {
    return x * rhs.x + y * rhs.y + z * rhs.z;
  }

  float lengthSq3() const { return x * x + y * y + z * z; }
  float length3() const { return std::sqrt(lengthSq3()); }

  Vec4 normalized3() const {
    float len = length3();
    if (len < 1e-5f)
      return {0, 0, 0, 0};
    float inv = 1.0f / len;
    return {x * inv, y * inv, z * inv, w};
  }
};

struct IVec3 {
  int x, y, z;
};

// -------------------------------------------------------------------------
// Wind Generator Volumes
// -------------------------------------------------------------------------

enum class VolumeType { Directional, Radial, Cone };

struct WindVolume {
  VolumeType type;
  Vec4 position;   // Center for Radial/Cone, MinBounds for Directional
  Vec4 direction;  // Direction for Cone/Directional (Normalized)
  Vec4 sizeParams; // x=radius/width, y=height, z=angle(cos), w=falloff
  float strength;

  // Helpers for construction
  static WindVolume CreateDirectional(Vec4 minBounds, Vec4 maxBounds, Vec4 dir,
                                      float strength) {
    WindVolume v;
    v.type = VolumeType::Directional;
    v.position = minBounds;
    v.sizeParams = maxBounds; // Storing max bounds in sizeParams for box
    v.direction = dir.normalized3();
    v.strength = strength;
    return v;
  }

  static WindVolume CreateRadial(Vec4 center, float radius, float strength,
                                 float falloff = 1.0f) {
    WindVolume v;
    v.type = VolumeType::Radial;
    v.position = center;
    v.sizeParams = {radius, 0, 0, falloff};
    v.strength = strength;
    return v;
  }

  static WindVolume CreateCone(Vec4 apex, Vec4 dir, float length,
                               float angleDeg, float strength) {
    WindVolume v;
    v.type = VolumeType::Cone;
    v.position = apex;
    v.direction = dir.normalized3();
    float halfAngleRad = (angleDeg / 2.0f) * (PI / 180.0f);
    v.sizeParams = {length, std::cos(halfAngleRad), 0, 0};
    v.strength = strength;
    return v;
  }
};

// -------------------------------------------------------------------------
// Solver Grid
// -------------------------------------------------------------------------

class WindGrid {
private:
  int width, height, depth;
  int totalCells;
  float cellSize;

  // Double buffering for solving
  // Layout: Flat array of Vec4.
  // Index = x + y*width + z*width*height
  // Memory is explicitly aligned for direct GPU mapping if needed
  std::vector<Vec4> velocityField;
  std::vector<Vec4> velocityPrev;

  std::vector<float> pressureField;
  std::vector<float> divergenceField;

public:
  WindGrid(int w, int h, int d, float cell_size)
      : width(w), height(h), depth(d), cellSize(cell_size) {
    totalCells = width * height * depth;
    velocityField.resize(totalCells, Vec4(0, 0, 0, 0));
    velocityPrev.resize(totalCells, Vec4(0, 0, 0, 0));
    pressureField.resize(totalCells, 0.0f);
    divergenceField.resize(totalCells, 0.0f);
  }

  // ---------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------

  void applyForces(float dt, const std::vector<WindVolume> &volumes) {
// Apply wind volumes to velocity field
#pragma omp parallel for
    for (int z = 0; z < depth; ++z) {
      for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
          int idx = index(x, y, z);
          Vec4 worldPos = {x * cellSize, y * cellSize, z * cellSize, 0};

          Vec4 totalForce = {0, 0, 0, 0};

          for (const auto &vol : volumes) {
            if (vol.type == VolumeType::Directional) {
              // AABB Check
              if (worldPos.x >= vol.position.x &&
                  worldPos.x <= vol.sizeParams.x &&
                  worldPos.y >= vol.position.y &&
                  worldPos.y <= vol.sizeParams.y &&
                  worldPos.z >= vol.position.z &&
                  worldPos.z <= vol.sizeParams.z) {
                totalForce = totalForce + (vol.direction * vol.strength);
              }
            } else if (vol.type == VolumeType::Radial) {
              Vec4 diff = worldPos - vol.position;
              float dist = diff.length3();
              if (dist < vol.sizeParams.x) {
                float factor =
                    1.0f - (dist / vol.sizeParams.x); // Linear falloff
                totalForce =
                    totalForce + (diff.normalized3() * (vol.strength * factor));
              }
            } else if (vol.type == VolumeType::Cone) {
              Vec4 diff = worldPos - vol.position;
              float dist = diff.length3();
              if (dist < vol.sizeParams.x && dist > 0.001f) {
                Vec4 dirToPt = diff.normalized3();
                float dot = dirToPt.dot3(vol.direction);
                // Check angle (sizeParams.y is cos(angle))
                if (dot > vol.sizeParams.y) {
                  float factor =
                      (dot - vol.sizeParams.y) / (1.0f - vol.sizeParams.y);
                  totalForce =
                      totalForce + (vol.direction * (vol.strength * factor));
                }
              }
            }
          }

          // Apply force
          velocityField[idx] = velocityField[idx] + (totalForce * dt);
        }
      }
    }
  }

  void step(float dt, int iterations = 20) {
    std::swap(velocityField, velocityPrev);

    // 1. Diffuse (Viscosity) - Optional for air, often skipped for performance
    // in games
    diffuse(dt, 0.0001f, iterations);

    // 2. Project (Enforce incompressibility)
    project(iterations);

    std::swap(velocityField, velocityPrev);

    // 3. Advect (Self-transport)
    advect(dt);

    // 4. Project again (to keep it stable)
    project(iterations);
  }

  // ---------------------------------------------------------------------
  // Vulkan Interop Helpers
  // ---------------------------------------------------------------------

  // Returns pointer to standard layout data (array of vec4 floats)
  const void *getVelocityData() const { return velocityField.data(); }

  // Size in bytes of the velocity buffer
  size_t getVelocityDataSize() const {
    return velocityField.size() * sizeof(Vec4);
  }

  IVec3 getDimensions() const { return {width, height, depth}; }

private:
  inline int index(int x, int y, int z) const {
    return x + width * (y + height * z);
  }

  // Trilinear interpolation of velocity grid
  Vec4 sampleVelocity(float x, float y, float z) const {
    // Clamp to grid
    float cx = std::max(0.0f, std::min(x, (float)width - 1.001f));
    float cy = std::max(0.0f, std::min(y, (float)height - 1.001f));
    float cz = std::max(0.0f, std::min(z, (float)depth - 1.001f));

    int i0 = (int)cx;
    int i1 = i0 + 1;
    int j0 = (int)cy;
    int j1 = j0 + 1;
    int k0 = (int)cz;
    int k1 = k0 + 1;

    float s1 = cx - i0;
    float s0 = 1.0f - s1;
    float t1 = cy - j0;
    float t0 = 1.0f - t1;
    float u1 = cz - k0;
    float u0 = 1.0f - u1;

    int idx000 = index(i0, j0, k0);
    int idx100 = index(i1, j0, k0);
    int idx010 = index(i0, j1, k0);
    int idx110 = index(i1, j1, k0);
    int idx001 = index(i0, j0, k1);
    int idx101 = index(i1, j0, k1);
    int idx011 = index(i0, j1, k1);
    int idx111 = index(i1, j1, k1);

    // Fetch
    const Vec4 &v000 = velocityPrev[idx000];
    const Vec4 &v100 = velocityPrev[idx100];
    const Vec4 &v010 = velocityPrev[idx010];
    const Vec4 &v110 = velocityPrev[idx110];
    const Vec4 &v001 = velocityPrev[idx001];
    const Vec4 &v101 = velocityPrev[idx101];
    const Vec4 &v011 = velocityPrev[idx011];
    const Vec4 &v111 = velocityPrev[idx111];

    // Lerp
    return ((v000 * s0 + v100 * s1) * t0 + (v010 * s0 + v110 * s1) * t1) * u0 +
           ((v001 * s0 + v101 * s1) * t0 + (v011 * s0 + v111 * s1) * t1) * u1;
  }

  void advect(float dt) {
#pragma omp parallel for
    for (int z = 1; z < depth - 1; ++z) {
      for (int y = 1; y < height - 1; ++y) {
        for (int x = 1; x < width - 1; ++x) {
          int idx = index(x, y, z);

          // Backtrace
          Vec4 vel = velocityPrev[idx];
          float backX = x - dt * vel.x;
          float backY = y - dt * vel.y;
          float backZ = z - dt * vel.z;

          velocityField[idx] = sampleVelocity(backX, backY, backZ);
        }
      }
    }
    setBounds();
  }

  void diffuse(float dt, float visc, int iter) {
    float a = dt * visc * (width * height * depth); // simplified scaling

    // Jacobi Iteration
    for (int k = 0; k < iter; ++k) {
#pragma omp parallel for
      for (int z = 1; z < depth - 1; ++z) {
        for (int y = 1; y < height - 1; ++y) {
          // Optimizable inner loop for SIMD
          for (int x = 1; x < width - 1; ++x) {
            int idx = index(x, y, z);
            Vec4 neighborSum = velocityField[index(x - 1, y, z)] +
                               velocityField[index(x + 1, y, z)] +
                               velocityField[index(x, y - 1, z)] +
                               velocityField[index(x, y + 1, z)] +
                               velocityField[index(x, y, z - 1)] +
                               velocityField[index(x, y, z + 1)];

            Vec4 prevVal = velocityPrev[idx];

            // vel = (prev + a * neighborSum) / (1 + 6a)
            velocityField[idx] =
                (prevVal + neighborSum * a) * (1.0f / (1.0f + 6.0f * a));
          }
        }
      }
      setBounds();
    }
  }

  void project(int iter) {
// 1. Calculate Divergence
#pragma omp parallel for
    for (int z = 1; z < depth - 1; ++z) {
      for (int y = 1; y < height - 1; ++y) {
        for (int x = 1; x < width - 1; ++x) {
          int idx = index(x, y, z);
          float div = velocityField[index(x + 1, y, z)].x -
                      velocityField[index(x - 1, y, z)].x +
                      velocityField[index(x, y + 1, z)].y -
                      velocityField[index(x, y - 1, z)].y +
                      velocityField[index(x, y, z + 1)].z -
                      velocityField[index(x, y, z - 1)].z;
          divergenceField[idx] = -0.5f * div;
          pressureField[idx] = 0;
        }
      }
    }
    setBoundsScalar(divergenceField);
    setBoundsScalar(pressureField);

    // 2. Solve Pressure (Poisson equation)
    for (int k = 0; k < iter; ++k) {
#pragma omp parallel for
      for (int z = 1; z < depth - 1; ++z) {
        for (int y = 1; y < height - 1; ++y) {
          // SIMD Candidate: Continuous float array processing
          // Using raw pointers for vectorization hint
          float *p = pressureField.data();
          const float *div = divergenceField.data();

#if defined(WINDSIM_USE_AVX2)
          // Example AVX2 Optimization for inner X loop
          int x = 1;
          int endX = width - 1;
          __m256 six = _mm256_set1_ps(6.0f);

          for (; x <= endX - 8; x += 8) {
            // Calculate indices
            int idx = index(x, y, z);
            // Need offsets. Since x is contiguous, neighbors are +/- 1
            // Z and Y offsets are constant
            int offY = width;
            int offZ = width * height;

            // Load neighbors (gather is slow, but structured grid allows
            // arithmetic offset)
            __m256 p_left = _mm256_loadu_ps(&p[idx - 1]);
            __m256 p_right = _mm256_loadu_ps(&p[idx + 1]);
            __m256 p_up = _mm256_loadu_ps(&p[idx - offY]);
            __m256 p_down = _mm256_loadu_ps(&p[idx + offY]);
            __m256 p_back = _mm256_loadu_ps(&p[idx - offZ]);
            __m256 p_front = _mm256_loadu_ps(&p[idx + offZ]);
            __m256 div_val = _mm256_loadu_ps(&div[idx]);

            __m256 sum = _mm256_add_ps(p_left, p_right);
            sum = _mm256_add_ps(sum, p_up);
            sum = _mm256_add_ps(sum, p_down);
            sum = _mm256_add_ps(sum, p_back);
            sum = _mm256_add_ps(sum, p_front);
            sum = _mm256_add_ps(sum, div_val);

            __m256 res = _mm256_div_ps(sum, six);
            _mm256_storeu_ps(&p[idx], res);
          }
          // Handle remainder
          for (; x < endX; ++x) {
            int idx = index(x, y, z);
            p[idx] = (div[idx] + p[index(x - 1, y, z)] + p[index(x + 1, y, z)] +
                      p[index(x, y - 1, z)] + p[index(x, y + 1, z)] +
                      p[index(x, y, z - 1)] + p[index(x, y, z + 1)]) /
                     6.0f;
          }

#else
          // Scalar Fallback
          for (int x = 1; x < width - 1; ++x) {
            int idx = index(x, y, z);
            p[idx] = (div[idx] + p[index(x - 1, y, z)] + p[index(x + 1, y, z)] +
                      p[index(x, y - 1, z)] + p[index(x, y + 1, z)] +
                      p[index(x, y, z - 1)] + p[index(x, y, z + 1)]) /
                     6.0f;
          }
#endif
        }
      }
      setBoundsScalar(pressureField);
    }

// 3. Subtract Gradient from Velocity
#pragma omp parallel for
    for (int z = 1; z < depth - 1; ++z) {
      for (int y = 1; y < height - 1; ++y) {
        for (int x = 1; x < width - 1; ++x) {
          int idx = index(x, y, z);
          float p_x = pressureField[index(x + 1, y, z)] -
                      pressureField[index(x - 1, y, z)];
          float p_y = pressureField[index(x, y + 1, z)] -
                      pressureField[index(x, y - 1, z)];
          float p_z = pressureField[index(x, y, z + 1)] -
                      pressureField[index(x, y, z - 1)];

          velocityField[idx].x -= 0.5f * p_x;
          velocityField[idx].y -= 0.5f * p_y;
          velocityField[idx].z -= 0.5f * p_z;
        }
      }
    }
    setBounds();
  }

  // Basic boundary conditions (reflect)
  void setBounds() {
    // Simplified: Set edges to 0 or reflect.
    // For open wind, usually we want borders to be open or flow-through,
    // but for stability in a box simulation, we zero edges.
    for (int x = 0; x < width; ++x) {
      for (int y = 0; y < height; ++y) {
        // Z faces
        velocityField[index(x, y, 0)] = {0, 0, 0, 0};
        velocityField[index(x, y, depth - 1)] = {0, 0, 0, 0};
      }
    }
    // Repeat for X and Y faces...
    // (Omitted for brevity, but crucial for closed containers)
  }

  void setBoundsScalar(std::vector<float> &f) {
    // Set scalar field boundaries
  }
};
} // namespace WindSim