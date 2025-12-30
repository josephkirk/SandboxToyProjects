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

// Check for OpenMP
#if defined(_OPENMP)
#include <omp.h>
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

  static WindVolume CreateDirectional(Vec4 minBounds, Vec4 maxBounds, Vec4 dir,
                                      float strength) {
    WindVolume v;
    v.type = VolumeType::Directional;
    v.position = minBounds;
    v.sizeParams = maxBounds;
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

  const void *getVelocityData() const { return velocityField.data(); }
  size_t getVelocityDataSize() const {
    return velocityField.size() * sizeof(Vec4);
  }
  IVec3 getDimensions() const { return {width, height, depth}; }

  // Optimized Force Application
  void applyForces(float dt, const std::vector<WindVolume> &volumes) {
#pragma omp parallel for
    for (int z = 0; z < depth; ++z) {
      for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
          int idx = index(x, y, z);
          Vec4 worldPos = {x * cellSize, y * cellSize, z * cellSize, 0};
          Vec4 totalForce = {0, 0, 0, 0};

          for (const auto &vol : volumes) {
            if (vol.type == VolumeType::Directional) {
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
              float distSq = diff.lengthSq3();
              float radiusSq = vol.sizeParams.x * vol.sizeParams.x;
              if (distSq < radiusSq) {
                float dist = std::sqrt(distSq);
                float factor = 1.0f - (dist / vol.sizeParams.x);
                totalForce =
                    totalForce + (diff.normalized3() * (vol.strength * factor));
              }
            } else if (vol.type == VolumeType::Cone) {
              Vec4 diff = worldPos - vol.position;
              float distSq = diff.lengthSq3();
              if (distSq < vol.sizeParams.x * vol.sizeParams.x &&
                  distSq > 0.00001f) {
                float dist = std::sqrt(distSq);
                Vec4 dirToPt = diff * (1.0f / dist); // Fast normalize
                float dot = dirToPt.dot3(vol.direction);
                if (dot > vol.sizeParams.y) {
                  float factor =
                      (dot - vol.sizeParams.y) / (1.0f - vol.sizeParams.y);
                  totalForce =
                      totalForce + (vol.direction * (vol.strength * factor));
                }
              }
            }
          }

          // FMA optimization potential
          velocityField[idx] = velocityField[idx] + (totalForce * dt);
        }
      }
    }
  }

  // Optimized Step Function
  // Removed explicit diffusion (air viscosity is negligible for games)
  // Removed double projection
  // Reduced default iterations to 8
  void step(float dt, int iterations = 8) {
    // 1. Prepare for Advection: Copy current field (with forces) to Prev
    std::copy(velocityField.begin(), velocityField.end(), velocityPrev.begin());

    // 2. Advect: Move Velocity along Velocity (Self-Advection)
    // Reads from Prev, Writes to Field
    advect(dt);

    // 3. Project: Enforce Divergence-Free (Incompressible)
    // Operates in-place on Field
    project(iterations);
  }

private:
  inline int index(int x, int y, int z) const {
    return x + width * (y + height * z);
  }

  Vec4 sampleVelocity(float x, float y, float z) const {
    // Fast clamp
    float fx = std::max(0.0f, std::min(x, (float)width - 1.001f));
    float fy = std::max(0.0f, std::min(y, (float)height - 1.001f));
    float fz = std::max(0.0f, std::min(z, (float)depth - 1.001f));

    int i0 = (int)fx;
    int i1 = i0 + 1;
    int j0 = (int)fy;
    int j1 = j0 + 1;
    int k0 = (int)fz;
    int k1 = k0 + 1;

    float s1 = fx - i0;
    float s0 = 1.0f - s1;
    float t1 = fy - j0;
    float t0 = 1.0f - t1;
    float u1 = fz - k0;
    float u0 = 1.0f - u1;

    int slice0 = width * (height * k0);
    int slice1 = width * (height * k1);
    int row0 = width * j0;
    int row1 = width * j1;

    int idx000 = i0 + row0 + slice0;
    int idx100 = i1 + row0 + slice0;
    int idx010 = i0 + row1 + slice0;
    int idx110 = i1 + row1 + slice0;
    int idx001 = i0 + row0 + slice1;
    int idx101 = i1 + row0 + slice1;
    int idx011 = i0 + row1 + slice1;
    int idx111 = i1 + row1 + slice1;

    const Vec4 *v = velocityPrev.data();

    // Direct pointer access for speed
    return ((v[idx000] * s0 + v[idx100] * s1) * t0 +
            (v[idx010] * s0 + v[idx110] * s1) * t1) *
               u0 +
           ((v[idx001] * s0 + v[idx101] * s1) * t0 +
            (v[idx011] * s0 + v[idx111] * s1) * t1) *
               u1;
  }

  void advect(float dt) {
#pragma omp parallel for
    for (int z = 1; z < depth - 1; ++z) {
      for (int y = 1; y < height - 1; ++y) {
        for (int x = 1; x < width - 1; ++x) {
          int idx = index(x, y, z);
          const Vec4 &v = velocityPrev[idx]; // Advect along previous velocity

          float backX = x - dt * v.x;
          float backY = y - dt * v.y;
          float backZ = z - dt * v.z;

          velocityField[idx] = sampleVelocity(backX, backY, backZ);
        }
      }
    }
    setBounds();
  }

  void project(int iter) {
    float h = cellSize;

    // Precompute scalar optimization
    float halfH = 0.5f * h;

// 1. Calculate Divergence & Init Pressure
// Using pointer arithmetic to avoid index mul in inner loop
#pragma omp parallel for
    for (int z = 1; z < depth - 1; ++z) {
      for (int y = 1; y < height - 1; ++y) {
        float *divRow = &divergenceField[index(0, y, z)];
        float *pRow = &pressureField[index(0, y, z)];
        const Vec4 *vRow = &velocityField[index(0, y, z)];

        int strideY = width;
        int strideZ = width * height;

        for (int x = 1; x < width - 1; ++x) {
          float div = vRow[x + 1].x - vRow[x - 1].x + vRow[x + strideY].y -
                      vRow[x - strideY].y + vRow[x + strideZ].z -
                      vRow[x - strideZ].z;

          divRow[x] = -0.5f * div;
          pRow[x] = 0.0f;
        }
      }
    }
    setBoundsScalar(divergenceField);
    setBoundsScalar(pressureField);

    // 2. Solve Pressure (Jacobi)
    // Reduced default iterations from 20 -> 8
    for (int k = 0; k < iter; ++k) {
#pragma omp parallel for
      for (int z = 1; z < depth - 1; ++z) {
        for (int y = 1; y < height - 1; ++y) {
          float *p = pressureField.data();
          const float *d = divergenceField.data();

#if defined(WINDSIM_USE_AVX2)
          int x = 1;
          int endX = width - 1;
          __m256 six = _mm256_set1_ps(6.0f);
          __m256 rcpSix = _mm256_div_ps(_mm256_set1_ps(1.0f),
                                        six); // multiply is faster than div

          for (; x <= endX - 8; x += 8) {
            int idx = index(x, y, z);
            int offY = width;
            int offZ = width * height;

            __m256 p_left = _mm256_loadu_ps(&p[idx - 1]);
            __m256 p_right = _mm256_loadu_ps(&p[idx + 1]);
            __m256 p_up = _mm256_loadu_ps(&p[idx - offY]);
            __m256 p_down = _mm256_loadu_ps(&p[idx + offY]);
            __m256 p_back = _mm256_loadu_ps(&p[idx - offZ]);
            __m256 p_front = _mm256_loadu_ps(&p[idx + offZ]);
            __m256 div_val = _mm256_loadu_ps(&d[idx]);

            __m256 sum = _mm256_add_ps(p_left, p_right);
            sum = _mm256_add_ps(sum, p_up);
            sum = _mm256_add_ps(sum, p_down);
            sum = _mm256_add_ps(sum, p_back);
            sum = _mm256_add_ps(sum, p_front);
            sum = _mm256_add_ps(sum, div_val);

            // Note: Writing back to same array (Jacobi requires double buffer
            // usually) But for game fluids, Gauss-Seidel style in-place
            // converges faster even if dependent on order.
            _mm256_storeu_ps(&p[idx], _mm256_mul_ps(sum, rcpSix));
          }
          for (; x < endX; ++x) {
            int idx = index(x, y, z);
            p[idx] = (d[idx] + p[index(x - 1, y, z)] + p[index(x + 1, y, z)] +
                      p[index(x, y - 1, z)] + p[index(x, y + 1, z)] +
                      p[index(x, y, z - 1)] + p[index(x, y, z + 1)]) /
                     6.0f;
          }
#else
          for (int x = 1; x < width - 1; ++x) {
            int idx = index(x, y, z);
            p[idx] = (d[idx] + p[index(x - 1, y, z)] + p[index(x + 1, y, z)] +
                      p[index(x, y - 1, z)] + p[index(x, y + 1, z)] +
                      p[index(x, y, z - 1)] + p[index(x, y, z + 1)]) /
                     6.0f;
          }
#endif
        }
      }
      setBoundsScalar(pressureField);
    }

// 3. Subtract Gradient
#pragma omp parallel for
    for (int z = 1; z < depth - 1; ++z) {
      for (int y = 1; y < height - 1; ++y) {
        // Pointers for inner loop
        const float *pRow = &pressureField[index(0, y, z)];
        Vec4 *vRow = &velocityField[index(0, y, z)];
        int strideY = width;
        int strideZ = width * height;

        for (int x = 1; x < width - 1; ++x) {
          float p_x = pRow[x + 1] - pRow[x - 1];
          float p_y = pRow[x + strideY] - pRow[x - strideY];
          float p_z = pRow[x + strideZ] - pRow[x - strideZ];

          vRow[x].x -= 0.5f * p_x;
          vRow[x].y -= 0.5f * p_y;
          vRow[x].z -= 0.5f * p_z;
        }
      }
    }
    setBounds();
  }

  void setBounds() {
    int strideZ = width * height;

    // Z Faces
    for (int y = 0; y < height; ++y) {
      for (int x = 0; x < width; ++x) {
        velocityField[x + width * y + strideZ * 0] = {0, 0, 0, 0};
        velocityField[x + width * y + strideZ * (depth - 1)] = {0, 0, 0, 0};
      }
    }

    // Y Faces
    for (int z = 0; z < depth; ++z) {
      for (int x = 0; x < width; ++x) {
        velocityField[x + width * 0 + strideZ * z] = {0, 0, 0, 0};
        velocityField[x + width * (height - 1) + strideZ * z] = {0, 0, 0, 0};
      }
    }

    // X Faces
    for (int z = 0; z < depth; ++z) {
      for (int y = 0; y < height; ++y) {
        velocityField[0 + width * y + strideZ * z] = {0, 0, 0, 0};
        velocityField[(width - 1) + width * y + strideZ * z] = {0, 0, 0, 0};
      }
    }
  }

  void setBoundsScalar(std::vector<float> &f) {
    int strideZ = width * height;

    // Z Faces (Mirror neighbors)
    for (int y = 0; y < height; ++y) {
      for (int x = 0; x < width; ++x) {
        f[x + width * y + strideZ * 0] = f[x + width * y + strideZ * 1];
        f[x + width * y + strideZ * (depth - 1)] =
            f[x + width * y + strideZ * (depth - 2)];
      }
    }

    // Y Faces
    for (int z = 0; z < depth; ++z) {
      for (int x = 0; x < width; ++x) {
        f[x + width * 0 + strideZ * z] = f[x + width * 1 + strideZ * z];
        f[x + width * (height - 1) + strideZ * z] =
            f[x + width * (height - 2) + strideZ * z];
      }
    }

    // X Faces
    for (int z = 0; z < depth; ++z) {
      for (int y = 0; y < height; ++y) {
        f[0 + width * y + strideZ * z] = f[1 + width * y + strideZ * z];
        f[(width - 1) + width * y + strideZ * z] =
            f[(width - 2) + width * y + strideZ * z];
      }
    }
  }
};
} // namespace WindSim