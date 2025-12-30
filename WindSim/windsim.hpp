#pragma once

#include <algorithm>
#include <cmath>
#include <cstring>
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

static constexpr float WINDSIM_PI = 3.14159265359f;

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

enum class VolumeType { Directional, Radial };

struct WindVolume {
  VolumeType type;
  Vec4 position;   // Center of the volume
  Vec4 direction;  // Force direction (normalized)
  Vec4 sizeParams; // Box: XYZ half-extents. Radial: X=Radius, W=Falloff.
  Vec4 rotation;   // Euler angles in radians (X, Y, Z)
  float strength;

  static WindVolume CreateDirectional(Vec4 center, Vec4 halfExtents, Vec4 dir,
                                      float strength) {
    WindVolume v;
    v.type = VolumeType::Directional;
    v.position = center;
    v.sizeParams = halfExtents;
    v.direction = dir.normalized3();
    v.rotation = {0, 0, 0, 0};
    v.strength = strength;
    return v;
  }

  static WindVolume CreateRadial(Vec4 center, float radius, float strength,
                                 float falloff = 1.0f) {
    WindVolume v;
    v.type = VolumeType::Radial;
    v.position = center;
    v.sizeParams = {radius, 0, 0, falloff};
    v.direction = {1, 0, 0, 0};
    v.rotation = {0, 0, 0, 0};
    v.strength = strength;
    return v;
  }
};

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

  // Helper for rotating a direction vector (Forward rotation)
  static Vec4 rotateDirection(const Vec4 &v, const Vec4 &euler) {
    float sx = std::sin(euler.x), cx = std::cos(euler.x);
    float sy = std::sin(euler.y), cy = std::cos(euler.y);
    float sz = std::sin(euler.z), cz = std::cos(euler.z);

    Vec4 res = v;
    // Rotate X -> Y -> Z
    float y1 = res.y * cx - res.z * sx;
    float z1 = res.y * sx + res.z * cx;
    res.y = y1;
    res.z = z1;
    float x2 = res.x * cy + res.z * sy;
    float z2 = -res.x * sy + res.z * cy;
    res.x = x2;
    res.z = z2;
    float x3 = res.x * cz - res.y * sz;
    float y3 = res.x * sz + res.y * cz;
    res.x = x3;
    res.y = y3;
    return res;
  }

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
              // Simple AABB check
              Vec4 localPos = worldPos - vol.position;
              if (std::abs(localPos.x) <= vol.sizeParams.x &&
                  std::abs(localPos.y) <= vol.sizeParams.y &&
                  std::abs(localPos.z) <= vol.sizeParams.z) {
                // Apply rotated direction
                Vec4 rotatedDir = rotateDirection(vol.direction, vol.rotation);
                totalForce = totalForce + (rotatedDir * vol.strength);
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
            }
          }
          velocityField[idx] = velocityField[idx] + (totalForce * dt);
        }
      }
    }
  }

  void step(float dt, int iterations = 8) {
    std::copy(velocityField.begin(), velocityField.end(), velocityPrev.begin());
    advect(dt);
    project(iterations);
  }

private:
  inline int index(int x, int y, int z) const {
    return x + width * (y + height * z);
  }

  Vec4 sampleVelocity(float x, float y, float z) const {
    float fx = std::max(0.0f, std::min(x, (float)width - 1.001f));
    float fy = std::max(0.0f, std::min(y, (float)height - 1.001f));
    float fz = std::max(0.0f, std::min(z, (float)depth - 1.001f));

    int i0 = (int)fx, i1 = i0 + 1;
    int j0 = (int)fy, j1 = j0 + 1;
    int k0 = (int)fz, k1 = k0 + 1;

    float s1 = fx - i0, s0 = 1.0f - s1;
    float t1 = fy - j0, t0 = 1.0f - t1;
    float u1 = fz - k0, u0 = 1.0f - u1;

    int slice0 = width * (height * k0), slice1 = width * (height * k1);
    int row0 = width * j0, row1 = width * j1;

    const Vec4 *v = velocityPrev.data();
    return ((v[i0 + row0 + slice0] * s0 + v[i1 + row0 + slice0] * s1) * t0 +
            (v[i0 + row1 + slice0] * s0 + v[i1 + row1 + slice0] * s1) * t1) *
               u0 +
           ((v[i0 + row0 + slice1] * s0 + v[i1 + row0 + slice1] * s1) * t0 +
            (v[i0 + row1 + slice1] * s0 + v[i1 + row1 + slice1] * s1) * t1) *
               u1;
  }

  void advect(float dt) {
#pragma omp parallel for
    for (int z = 1; z < depth - 1; ++z) {
      for (int y = 1; y < height - 1; ++y) {
        for (int x = 1; x < width - 1; ++x) {
          int idx = index(x, y, z);
          const Vec4 &v = velocityPrev[idx];
          velocityField[idx] =
              sampleVelocity(x - dt * v.x, y - dt * v.y, z - dt * v.z);
        }
      }
    }
    setBounds();
  }

  void project(int iter) {
    float h = cellSize;
#pragma omp parallel for
    for (int z = 1; z < depth - 1; ++z) {
      for (int y = 1; y < height - 1; ++y) {
        float *divRow = &divergenceField[index(0, y, z)];
        float *pRow = &pressureField[index(0, y, z)];
        const Vec4 *vRow = &velocityField[index(0, y, z)];
        int sy = width, sz = width * height;
        for (int x = 1; x < width - 1; ++x) {
          divRow[x] =
              -0.5f * (vRow[x + 1].x - vRow[x - 1].x + vRow[x + sy].y -
                       vRow[x - sy].y + vRow[x + sz].z - vRow[x - sz].z);
          pRow[x] = 0.0f;
        }
      }
    }
    setBoundsScalar(divergenceField);
    setBoundsScalar(pressureField);

    for (int k = 0; k < iter; ++k) {
#pragma omp parallel for
      for (int z = 1; z < depth - 1; ++z) {
        for (int y = 1; y < height - 1; ++y) {
          float *p = pressureField.data();
          const float *d = divergenceField.data();
#if defined(WINDSIM_USE_AVX2)
          int x = 1, endX = width - 1;
          __m256 rcpSix = _mm256_set1_ps(1.0f / 6.0f);
          for (; x <= endX - 8; x += 8) {
            int idx = index(x, y, z), oy = width, oz = width * height;
            __m256 sum =
                _mm256_add_ps(_mm256_add_ps(_mm256_loadu_ps(&p[idx - 1]),
                                            _mm256_loadu_ps(&p[idx + 1])),
                              _mm256_add_ps(_mm256_loadu_ps(&p[idx - oy]),
                                            _mm256_loadu_ps(&p[idx + oy])));
            sum = _mm256_add_ps(sum,
                                _mm256_add_ps(_mm256_loadu_ps(&p[idx - oz]),
                                              _mm256_loadu_ps(&p[idx + oz])));
            _mm256_storeu_ps(
                &p[idx],
                _mm256_mul_ps(_mm256_add_ps(sum, _mm256_loadu_ps(&d[idx])),
                              rcpSix));
          }
          for (; x < endX; ++x) {
            int idx = index(x, y, z);
            p[idx] = (d[idx] + p[idx - 1] + p[idx + 1] + p[idx - width] +
                      p[idx + width] + p[idx - width * height] +
                      p[idx + width * height]) /
                     6.0f;
          }
#else
          for (int x = 1; x < width - 1; ++x) {
            int idx = index(x, y, z);
            p[idx] = (d[idx] + p[idx - 1] + p[idx + 1] + p[idx - width] +
                      p[idx + width] + p[idx - width * height] +
                      p[idx + width * height]) /
                     6.0f;
          }
#endif
        }
      }
      setBoundsScalar(pressureField);
    }

#pragma omp parallel for
    for (int z = 1; z < depth - 1; ++z) {
      for (int y = 1; y < height - 1; ++y) {
        const float *pRow = &pressureField[index(0, y, z)];
        Vec4 *vRow = &velocityField[index(0, y, z)];
        int sy = width, sz = width * height;
        for (int x = 1; x < width - 1; ++x) {
          vRow[x].x -= 0.5f * (pRow[x + 1] - pRow[x - 1]);
          vRow[x].y -= 0.5f * (pRow[x + sy] - pRow[x - sy]);
          vRow[x].z -= 0.5f * (pRow[x + sz] - pRow[x - sz]);
        }
      }
    }
    setBounds();
  }

  void setBounds() {
    int sz = width * height;
    for (int y = 0; y < height; ++y) {
      for (int x = 0; x < width; ++x) {
        velocityField[x + width * y] = {0, 0, 0, 0};
        velocityField[x + width * y + sz * (depth - 1)] = {0, 0, 0, 0};
      }
    }
    for (int z = 0; z < depth; ++z) {
      for (int x = 0; x < width; ++x) {
        velocityField[x + sz * z] = {0, 0, 0, 0};
        velocityField[x + width * (height - 1) + sz * z] = {0, 0, 0, 0};
      }
    }
    for (int z = 0; z < depth; ++z) {
      for (int y = 0; y < height; ++y) {
        velocityField[width * y + sz * z] = {0, 0, 0, 0};
        velocityField[(width - 1) + width * y + sz * z] = {0, 0, 0, 0};
      }
    }
  }

  void setBoundsScalar(std::vector<float> &f) {
    int sz = width * height;
    for (int y = 0; y < height; ++y) {
      for (int x = 0; x < width; ++x) {
        f[x + width * y] = f[x + width * y + sz];
        f[x + width * y + sz * (depth - 1)] =
            f[x + width * y + sz * (depth - 2)];
      }
    }
    for (int z = 0; z < depth; ++z) {
      for (int x = 0; x < width; ++x) {
        f[x + sz * z] = f[x + width + sz * z];
        f[x + width * (height - 1) + sz * z] =
            f[x + width * (height - 2) + sz * z];
      }
    }
    for (int z = 0; z < depth; ++z) {
      for (int y = 0; y < height; ++y) {
        f[width * y + sz * z] = f[1 + width * y + sz * z];
        f[(width - 1) + width * y + sz * z] =
            f[(width - 2) + width * y + sz * z];
      }
    }
  }
};
} // namespace WindSim