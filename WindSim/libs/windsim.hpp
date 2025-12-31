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

#include "aabbtree.hpp"

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
  Vec4 position;
  Vec4 direction;
  Vec4 sizeParams;
  Vec4 rotation;
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

  // Sparse Blocked Grid
  static constexpr int BLOCK_SIZE = 16;
  int blocksX, blocksY, blocksZ;
  std::vector<uint8_t> activeBlocks; // 1 if active, 0 if inactive

  // SoA Layout for maximized SIMD throughput
  std::vector<float> vx, vy, vz;
  std::vector<float> vxPrev, vyPrev, vzPrev;
  std::vector<float> pressure;
  std::vector<float> divergence;

  // For visualizer compatibility (AoS output)
  mutable std::vector<Vec4> aosCache;

public:
  WindGrid(int w, int h, int d, float cell_size)
      : width(w), height(h), depth(d), cellSize(cell_size) {
    totalCells = width * height * depth;

    // Initialize Blocks
    blocksX = (width + BLOCK_SIZE - 1) / BLOCK_SIZE;
    blocksY = (height + BLOCK_SIZE - 1) / BLOCK_SIZE;
    blocksZ = (depth + BLOCK_SIZE - 1) / BLOCK_SIZE;
    activeBlocks.resize(blocksX * blocksY * blocksZ, 0);

    vx.assign(totalCells, 0.0f);
    vy.assign(totalCells, 0.0f);
    vz.assign(totalCells, 0.0f);
    vxPrev.assign(totalCells, 0.0f);
    vyPrev.assign(totalCells, 0.0f);
    vzPrev.assign(totalCells, 0.0f);
    pressure.assign(totalCells, 0.0f);
    divergence.assign(totalCells, 0.0f);
    aosCache.resize(totalCells);
  }

  const void *getVelocityData() const {
    // Convert SoA to AoS for the visualizer
#pragma omp parallel for collapse(2)
    for (int z = 0; z < depth; ++z) {
      for (int y = 0; y < height; ++y) {
        int base = width * (y + height * z);
        for (int x = 0; x < width; ++x) {
          int idx = base + x;
          aosCache[idx] = Vec4(vx[idx], vy[idx], vz[idx], 0.0f);
        }
      }
    }
    return aosCache.data();
  }

  size_t getVelocityDataSize() const { return totalCells * sizeof(Vec4); }
  IVec3 getDimensions() const { return {width, height, depth}; }

  const char *getSIMDName() const {
#if defined(WINDSIM_USE_AVX2)
    return "AVX2";
#elif defined(WINDSIM_USE_SSE)
    return "SSE";
#else
    return "Scalar";
#endif
  }

  int getActiveBlockCount() const {
    int count = 0;
    for (uint8_t active : activeBlocks) {
      if (active)
        count++;
    }
    return count;
  }

  int getTotalBlockCount() const { return (int)activeBlocks.size(); }

  static Vec4 rotateDirection(const Vec4 &v, const Vec4 &euler) {
    float sx = std::sin(euler.x), cx = std::cos(euler.x);
    float sy = std::sin(euler.y), cy = std::cos(euler.y);
    float sz = std::sin(euler.z), cz = std::cos(euler.z);
    Vec4 res = v;
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

  void updateActiveBlocks(const std::vector<WindVolume> &volumes) {
    std::vector<aabb::AABB> volumeBoxes;
    if (!volumes.empty()) {
      volumeBoxes.reserve(volumes.size());
      for (const auto &v : volumes) {
        aabb::AABB b;
        if (v.type == VolumeType::Directional) {
          aabb::Vec3 c = {v.position.x, v.position.y, v.position.z};
          aabb::Vec3 e = {v.sizeParams.x, v.sizeParams.y, v.sizeParams.z};
          b.min = c - e;
          b.max = c + e;
        } else {
          float r = v.sizeParams.x;
          aabb::Vec3 c = {v.position.x, v.position.y, v.position.z};
          aabb::Vec3 e = {r, r, r};
          b.min = c - e;
          b.max = c + e;
        }
        volumeBoxes.push_back(b);
      }
    }

    aabb::Tree tree;
    tree.build(volumeBoxes);

    // Step 1: Identify "Seed" Blocks (Content-based)
    // These are blocks that clearly contain wind or sources.
    std::vector<uint8_t> seedBlocks(activeBlocks.size(), 0);

#pragma omp parallel for collapse(3)
    for (int bz = 0; bz < blocksZ; ++bz) {
      for (int by = 0; by < blocksY; ++by) {
        for (int bx = 0; bx < blocksX; ++bx) {
          int idx = bx + blocksX * (by + blocksY * bz);

          // Pass 1: Volume Overlap
          if (!volumeBoxes.empty()) {
            float minX = bx * BLOCK_SIZE * cellSize;
            float minY = by * BLOCK_SIZE * cellSize;
            float minZ = bz * BLOCK_SIZE * cellSize;
            float maxX = minX + BLOCK_SIZE * cellSize;
            float maxY = minY + BLOCK_SIZE * cellSize;
            float maxZ = minZ + BLOCK_SIZE * cellSize;

            aabb::AABB blockBox;
            blockBox.min = {minX, minY, minZ};
            blockBox.max = {maxX, maxY, maxZ};

            if (tree.query_overlap(blockBox)) {
              seedBlocks[idx] = 1;
              continue;
            }
          }

          // Pass 2: Velocity Persistence
          // If not overlapped, check if we have lingering velocity
          bool hasVelocity = false;
          int startX = bx * BLOCK_SIZE;
          int endX = std::min(startX + BLOCK_SIZE, width);
          int startY = by * BLOCK_SIZE;
          int endY = std::min(startY + BLOCK_SIZE, height);
          int startZ = bz * BLOCK_SIZE;
          int endZ = std::min(startZ + BLOCK_SIZE, depth);

          // Increased threshold to 0.05 to aggressively cull "invisible" wind
          float thresholdSq = 0.05f * 0.05f;

#if defined(WINDSIM_USE_AVX2)
          __m256 vThreshold = _mm256_set1_ps(thresholdSq);
#endif

          for (int z = startZ; z < endZ; ++z) {
            for (int y = startY; y < endY; ++y) {
              int baseIdx = width * (y + height * z);
              int x = startX;

#if defined(WINDSIM_USE_AVX2)
              for (; x <= endX - 8; x += 8) {
                int cellIdx = baseIdx + x;
                __m256 vvx = _mm256_loadu_ps(&vx[cellIdx]);
                __m256 vvy = _mm256_loadu_ps(&vy[cellIdx]);
                __m256 vvz = _mm256_loadu_ps(&vz[cellIdx]);

                __m256 vMagSq =
                    _mm256_add_ps(_mm256_add_ps(_mm256_mul_ps(vvx, vvx),
                                                _mm256_mul_ps(vvy, vvy)),
                                  _mm256_mul_ps(vvz, vvz));

                __m256 vCmp = _mm256_cmp_ps(vMagSq, vThreshold, _CMP_GT_OQ);
                if (_mm256_movemask_ps(vCmp) != 0) {
                  hasVelocity = true;
                  goto block_active;
                }
              }
#endif
              // Scalar tail
              for (; x < endX; ++x) {
                int cellIdx = baseIdx + x;
                float vSq = vx[cellIdx] * vx[cellIdx] +
                            vy[cellIdx] * vy[cellIdx] +
                            vz[cellIdx] * vz[cellIdx];
                if (vSq > thresholdSq) {
                  hasVelocity = true;
                  goto block_active;
                }
              }
            }
          }

        block_active:
          seedBlocks[idx] = hasVelocity ? 1 : 0;
        }
      }
    }

    // Step 2: Dilation (Topology-based)
    // Activate any block that has an active "Seed" neighbor.
    // This allows wind to propagate into empty space.
#pragma omp parallel for collapse(3)
    for (int bz = 0; bz < blocksZ; ++bz) {
      for (int by = 0; by < blocksY; ++by) {
        for (int bx = 0; bx < blocksX; ++bx) {
          int idx = bx + blocksX * (by + blocksY * bz);
          if (seedBlocks[idx]) {
            activeBlocks[idx] = 1;
            continue;
          }

          // Check neighbors
          bool neighborActive = false;
          for (int dz = -1; dz <= 1; ++dz) {
            for (int dy = -1; dy <= 1; ++dy) {
              for (int dx = -1; dx <= 1; ++dx) {
                if (dx == 0 && dy == 0 && dz == 0)
                  continue;
                int nbx = bx + dx;
                int nby = by + dy;
                int nbz = bz + dz;

                if (nbx >= 0 && nbx < blocksX && nby >= 0 && nby < blocksY &&
                    nbz >= 0 && nbz < blocksZ) {
                  int nidx = nbx + blocksX * (nby + blocksY * nbz);
                  if (seedBlocks[nidx]) {
                    neighborActive = true;
                    goto drift_check_done;
                  }
                }
              }
            }
          }
        drift_check_done:
          activeBlocks[idx] = neighborActive ? 1 : 0;
        }
      }
    }
  }

  void applyForces(float dt, const std::vector<WindVolume> &volumes) {
    updateActiveBlocks(volumes);
    if (volumes.empty())
      return;

#pragma omp parallel for collapse(3)
    for (int bz = 0; bz < blocksZ; ++bz) {
      for (int by = 0; by < blocksY; ++by) {
        for (int bx = 0; bx < blocksX; ++bx) {
          int blockIdx = bx + blocksX * (by + blocksY * bz);
          if (!activeBlocks[blockIdx])
            continue;

          int startX = bx * BLOCK_SIZE;
          int endX = std::min(startX + BLOCK_SIZE, width);
          int startY = by * BLOCK_SIZE;
          int endY = std::min(startY + BLOCK_SIZE, height);
          int startZ = bz * BLOCK_SIZE;
          int endZ = std::min(startZ + BLOCK_SIZE, depth);

          for (int z = startZ; z < endZ; ++z) {
            for (int y = startY; y < endY; ++y) {
              int baseIdx = width * (y + height * z);
              float worldY = y * cellSize;
              float worldZ = z * cellSize;

              for (int x = startX; x < endX; ++x) {
                int idx = baseIdx + x;
                float worldX = x * cellSize;
                float fx = 0, fy = 0, fz = 0;

                for (const auto &vol : volumes) {
                  if (vol.type == VolumeType::Directional) {
                    float dx = std::abs(worldX - vol.position.x);
                    float dy = std::abs(worldY - vol.position.y);
                    float dz = std::abs(worldZ - vol.position.z);
                    if (dx <= vol.sizeParams.x && dy <= vol.sizeParams.y &&
                        dz <= vol.sizeParams.z) {
                      Vec4 rDir = rotateDirection(vol.direction, vol.rotation);
                      fx += rDir.x * vol.strength;
                      fy += rDir.y * vol.strength;
                      fz += rDir.z * vol.strength;
                    }
                  } else if (vol.type == VolumeType::Radial) {
                    float rx = worldX - vol.position.x;
                    float ry = worldY - vol.position.y;
                    float rz = worldZ - vol.position.z;
                    float d2 = rx * rx + ry * ry + rz * rz;
                    float R2 = vol.sizeParams.x * vol.sizeParams.x;
                    if (d2 < R2) {
                      float dist = std::sqrt(d2);
                      float invDist = (dist > 1e-5f) ? (1.0f / dist) : 0.0f;
                      float falloff = 1.0f - (dist / vol.sizeParams.x);
                      float s = vol.strength * falloff * invDist;
                      fx += rx * s;
                      fy += ry * s;
                      fz += rz * s;
                    }
                  }
                }
                vx[idx] += fx * dt;
                vy[idx] += fy * dt;
                vz[idx] += fz * dt;
              }
            }
          }
        }
      }
    }
  }

  void step(float dt, int iterations = 8) {
    std::copy(vx.begin(), vx.end(), vxPrev.begin());
    std::copy(vy.begin(), vy.end(), vyPrev.begin());
    std::copy(vz.begin(), vz.end(), vzPrev.begin());
    advect(dt);
    project(iterations);
  }

private:
  inline int index(int x, int y, int z) const {
    return x + width * (y + height * z);
  }

  void sampleVelocity(float x, float y, float z, float &outX, float &outY,
                      float &outZ) const {
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

    auto bilerp = [&](const float *d) {
      return ((d[i0 + row0 + slice0] * s0 + d[i1 + row0 + slice0] * s1) * t0 +
              (d[i0 + row1 + slice0] * s0 + d[i1 + row1 + slice0] * s1) * t1) *
                 u0 +
             ((d[i0 + row0 + slice1] * s0 + d[i1 + row0 + slice1] * s1) * t0 +
              (d[i0 + row1 + slice1] * s0 + d[i1 + row1 + slice1] * s1) * t1) *
                 u1;
    };

    outX = bilerp(vxPrev.data());
    outY = bilerp(vyPrev.data());
    outZ = bilerp(vzPrev.data());
  }

  void advect(float dt) {
    const float damping = 0.99f;
#pragma omp parallel for collapse(3)
    for (int bz = 0; bz < blocksZ; ++bz) {
      for (int by = 0; by < blocksY; ++by) {
        for (int bx = 0; bx < blocksX; ++bx) {
          int blockIdx = bx + blocksX * (by + blocksY * bz);
          if (!activeBlocks[blockIdx])
            continue;

          int startX = bx * BLOCK_SIZE;
          int endX = std::min(startX + BLOCK_SIZE, width);
          int startY = by * BLOCK_SIZE;
          int endY = std::min(startY + BLOCK_SIZE, height);
          int startZ = bz * BLOCK_SIZE;
          int endZ = std::min(startZ + BLOCK_SIZE, depth);

          // Intersect with simulation bounds [1, dim - 1]
          int loopSZ = std::max(1, startZ);
          int loopEZ = std::min(endZ, depth - 1);
          int loopSY = std::max(1, startY);
          int loopEY = std::min(endY, height - 1);
          int loopSX = std::max(1, startX);
          int loopEX = std::min(endX, width - 1);

#if defined(WINDSIM_USE_AVX2)
          __m256 vDamping = _mm256_set1_ps(damping);
#endif

          for (int z = loopSZ; z < loopEZ; ++z) {
            for (int y = loopSY; y < loopEY; ++y) {
              int baseIdx = width * (y + height * z);
              int x = loopSX;
#if defined(WINDSIM_USE_AVX2)
              // Ensure we don't go out of bounds of the current BLOCK loop
              // and the safe AVX buffer width (width-9)
              int avxLimit = std::min(loopEX, width - 9);
              for (; x <= avxLimit; x += 8) {
                int idx = baseIdx + x;
                float svx[8], svy[8], svz[8];
                for (int i = 0; i < 8; ++i) {
                  int ii = idx + i;
                  sampleVelocity((x + i) - dt * vxPrev[ii], y - dt * vyPrev[ii],
                                 z - dt * vzPrev[ii], svx[i], svy[i], svz[i]);
                }
                __m256 v_svx = _mm256_loadu_ps(svx);
                __m256 v_svy = _mm256_loadu_ps(svy);
                __m256 v_svz = _mm256_loadu_ps(svz);

                v_svx = _mm256_mul_ps(v_svx, vDamping);
                v_svy = _mm256_mul_ps(v_svy, vDamping);
                v_svz = _mm256_mul_ps(v_svz, vDamping);

                _mm256_storeu_ps(&vx[idx], v_svx);
                _mm256_storeu_ps(&vy[idx], v_svy);
                _mm256_storeu_ps(&vz[idx], v_svz);
              }
#endif
              for (; x < loopEX; ++x) {
                int idx = baseIdx + x;
                float svx, svy, svz;
                sampleVelocity(x - dt * vxPrev[idx], y - dt * vyPrev[idx],
                               z - dt * vzPrev[idx], svx, svy, svz);
                vx[idx] = svx * damping;
                vy[idx] = svy * damping;
                vz[idx] = svz * damping;
              }
            }
          }
        }
      }
    }
    setBounds(vx, vy, vz);
  }

  void project(int iter) {
#pragma omp parallel for collapse(3)
    for (int bz = 0; bz < blocksZ; ++bz) {
      for (int by = 0; by < blocksY; ++by) {
        for (int bx = 0; bx < blocksX; ++bx) {
          int blockIdx = bx + blocksX * (by + blocksY * bz);
          if (!activeBlocks[blockIdx])
            continue;

          int startX = bx * BLOCK_SIZE;
          int endX = std::min(startX + BLOCK_SIZE, width);
          int startY = by * BLOCK_SIZE;
          int endY = std::min(startY + BLOCK_SIZE, height);
          int startZ = bz * BLOCK_SIZE;
          int endZ = std::min(startZ + BLOCK_SIZE, depth);

          int loopSZ = std::max(1, startZ);
          int loopEZ = std::min(endZ, depth - 1);
          int loopSY = std::max(1, startY);
          int loopEY = std::min(endY, height - 1);
          int loopSX = std::max(1, startX);
          int loopEX = std::min(endX, width - 1);

          for (int z = loopSZ; z < loopEZ; ++z) {
            for (int y = loopSY; y < loopEY; ++y) {
              int baseIdx = width * (y + height * z);
              int sy = width, sz = width * height;
              int x = loopSX;
#if defined(WINDSIM_USE_AVX2)
              __m256 vHalf = _mm256_set1_ps(-0.5f);
              __m256 vZero = _mm256_setzero_ps();
              int avxLimit = std::min(loopEX, width - 9);
              for (; x <= avxLimit; x += 8) {
                int idx = baseIdx + x;
                __m256 vx1 = _mm256_loadu_ps(&vx[idx + 1]);
                __m256 vx0 = _mm256_loadu_ps(&vx[idx - 1]);
                __m256 vy1 = _mm256_loadu_ps(&vy[idx + sy]);
                __m256 vy0 = _mm256_loadu_ps(&vy[idx - sy]);
                __m256 vz1 = _mm256_loadu_ps(&vz[idx + sz]);
                __m256 vz0 = _mm256_loadu_ps(&vz[idx - sz]);
                __m256 d =
                    _mm256_add_ps(_mm256_sub_ps(vx1, vx0),
                                  _mm256_add_ps(_mm256_sub_ps(vy1, vy0),
                                                _mm256_sub_ps(vz1, vz0)));
                _mm256_storeu_ps(&divergence[idx], _mm256_mul_ps(d, vHalf));
                _mm256_storeu_ps(&pressure[idx], vZero);
              }
#endif
              for (; x < loopEX; ++x) {
                int idx = baseIdx + x;
                divergence[idx] =
                    -0.5f * (vx[idx + 1] - vx[idx - 1] + vy[idx + sy] -
                             vy[idx - sy] + vz[idx + sz] - vz[idx - sz]);
                pressure[idx] = 0.0f;
              }
            }
          }
        }
      }
    }

    setBoundsScalar(divergence);
    setBoundsScalar(pressure);

    float invSix = 1.0f / 6.0f;
    for (int k = 0; k < iter; ++k) {
      for (int rb = 0; rb < 2; ++rb) {
#pragma omp parallel for collapse(3)
        for (int bz = 0; bz < blocksZ; ++bz) {
          for (int by = 0; by < blocksY; ++by) {
            for (int bx = 0; bx < blocksX; ++bx) {
              int blockIdx = bx + blocksX * (by + blocksY * bz);
              if (!activeBlocks[blockIdx])
                continue;

              int startX = bx * BLOCK_SIZE;
              int endX = std::min(startX + BLOCK_SIZE, width);
              int startY = by * BLOCK_SIZE;
              int endY = std::min(startY + BLOCK_SIZE, height);
              int startZ = bz * BLOCK_SIZE;
              int endZ = std::min(startZ + BLOCK_SIZE, depth);

              int loopSZ = std::max(1, startZ);
              int loopEZ = std::min(endZ, depth - 1);
              int loopSY = std::max(1, startY);
              int loopEY = std::min(endY, height - 1);
              int loopSX = std::max(1, startX);
              int loopEX = std::min(endX, width - 1);

              for (int z = loopSZ; z < loopEZ; ++z) {
                for (int y = loopSY; y < loopEY; ++y) {
                  int sy = width, sz = width * height;
                  int rowStartX = 1 + ((y + z + rb) % 2);
                  // Adjust rowStartX to be within this block loop
                  int x = std::max(loopSX, rowStartX);
                  if ((x % 2) != (rowStartX % 2))
                    x++;

                  for (; x < loopEX; x += 2) {
                    int idx = index(x, y, z);
                    pressure[idx] = (divergence[idx] + pressure[idx - 1] +
                                     pressure[idx + 1] + pressure[idx - sy] +
                                     pressure[idx + sy] + pressure[idx - sz] +
                                     pressure[idx + sz]) *
                                    invSix;
                  }
                }
              }
            }
          }
        }
      }
      setBoundsScalar(pressure);
    }

#pragma omp parallel for collapse(3)
    for (int bz = 0; bz < blocksZ; ++bz) {
      for (int by = 0; by < blocksY; ++by) {
        for (int bx = 0; bx < blocksX; ++bx) {
          int blockIdx = bx + blocksX * (by + blocksY * bz);
          if (!activeBlocks[blockIdx])
            continue;

          int startX = bx * BLOCK_SIZE;
          int endX = std::min(startX + BLOCK_SIZE, width);
          int startY = by * BLOCK_SIZE;
          int endY = std::min(startY + BLOCK_SIZE, height);
          int startZ = bz * BLOCK_SIZE;
          int endZ = std::min(startZ + BLOCK_SIZE, depth);

          int loopSZ = std::max(1, startZ);
          int loopEZ = std::min(endZ, depth - 1);
          int loopSY = std::max(1, startY);
          int loopEY = std::min(endY, height - 1);
          int loopSX = std::max(1, startX);
          int loopEX = std::min(endX, width - 1);

          for (int z = loopSZ; z < loopEZ; ++z) {
            for (int y = loopSY; y < loopEY; ++y) {
              int baseIdx = width * (y + height * z);
              int sy = width, sz = width * height;
              int x = loopSX;
#if defined(WINDSIM_USE_AVX2)
              __m256 vHalfSub = _mm256_set1_ps(0.5f);
              int avxLimit = std::min(loopEX, width - 9);
              for (; x <= avxLimit; x += 8) {
                int idx = baseIdx + x;
                __m256 p1x = _mm256_loadu_ps(&pressure[idx + 1]);
                __m256 p0x = _mm256_loadu_ps(&pressure[idx - 1]);
                __m256 p1y = _mm256_loadu_ps(&pressure[idx + sy]);
                __m256 p0y = _mm256_loadu_ps(&pressure[idx - sy]);
                __m256 p1z = _mm256_loadu_ps(&pressure[idx + sz]);
                __m256 p0z = _mm256_loadu_ps(&pressure[idx - sz]);

                _mm256_storeu_ps(
                    &vx[idx],
                    _mm256_sub_ps(
                        _mm256_loadu_ps(&vx[idx]),
                        _mm256_mul_ps(_mm256_sub_ps(p1x, p0x), vHalfSub)));

                _mm256_storeu_ps(
                    &vy[idx],
                    _mm256_sub_ps(
                        _mm256_loadu_ps(&vy[idx]),
                        _mm256_mul_ps(_mm256_sub_ps(p1y, p0y), vHalfSub)));

                _mm256_storeu_ps(
                    &vz[idx],
                    _mm256_sub_ps(
                        _mm256_loadu_ps(&vz[idx]),
                        _mm256_mul_ps(_mm256_sub_ps(p1z, p0z), vHalfSub)));
              }
#endif
              for (; x < loopEX; ++x) {
                int idx = baseIdx + x;
                vx[idx] -= 0.5f * (pressure[idx + 1] - pressure[idx - 1]);
                vy[idx] -= 0.5f * (pressure[idx + sy] - pressure[idx - sy]);
                vz[idx] -= 0.5f * (pressure[idx + sz] - pressure[idx - sz]);
              }
            }
          }
        }
      }
    }
    setBounds(vx, vy, vz);
  }

  void project_LEGACY(int iter) {
#pragma omp parallel for collapse(2)
    for (int z = 1; z < depth - 1; ++z) {
      for (int y = 1; y < height - 1; ++y) {
        int idx = index(1, y, z);
        int sy = width, sz = width * height;
        int x = 1;
#if defined(WINDSIM_USE_AVX2)
        __m256 vHalf = _mm256_set1_ps(-0.5f);
        __m256 vZero = _mm256_setzero_ps();
        for (; x <= width - 9; x += 8, idx += 8) {
          __m256 vx1 = _mm256_loadu_ps(&vx[idx + 1]);
          __m256 vx0 = _mm256_loadu_ps(&vx[idx - 1]);
          __m256 vy1 = _mm256_loadu_ps(&vy[idx + sy]);
          __m256 vy0 = _mm256_loadu_ps(&vy[idx - sy]);
          __m256 vz1 = _mm256_loadu_ps(&vz[idx + sz]);
          __m256 vz0 = _mm256_loadu_ps(&vz[idx - sz]);
          __m256 d = _mm256_add_ps(
              _mm256_sub_ps(vx1, vx0),
              _mm256_add_ps(_mm256_sub_ps(vy1, vy0), _mm256_sub_ps(vz1, vz0)));
          _mm256_storeu_ps(&divergence[idx], _mm256_mul_ps(d, vHalf));
          _mm256_storeu_ps(&pressure[idx], vZero);
        }
#endif
        for (; x < width - 1; ++x, ++idx) {
          divergence[idx] =
              -0.5f * (vx[idx + 1] - vx[idx - 1] + vy[idx + sy] - vy[idx - sy] +
                       vz[idx + sz] - vz[idx - sz]);
          pressure[idx] = 0.0f;
        }
      }
    }
    setBoundsScalar(divergence);
    setBoundsScalar(pressure);

    float invSix = 1.0f / 6.0f;
    for (int k = 0; k < iter; ++k) {
      for (int rb = 0; rb < 2; ++rb) {
#pragma omp parallel for collapse(2)
        for (int z = 1; z < depth - 1; ++z) {
          for (int y = 1; y < height - 1; ++y) {
            int sy = width, sz = width * height;
            int startX = 1 + ((y + z + rb) % 2);
            for (int x = startX; x < width - 1; x += 2) {
              int idx = index(x, y, z);
              pressure[idx] =
                  (divergence[idx] + pressure[idx - 1] + pressure[idx + 1] +
                   pressure[idx - sy] + pressure[idx + sy] +
                   pressure[idx - sz] + pressure[idx + sz]) *
                  invSix;
            }
          }
        }
      }
      setBoundsScalar(pressure);
    }

#pragma omp parallel for collapse(2)
    for (int z = 1; z < depth - 1; ++z) {
      for (int y = 1; y < height - 1; ++y) {
        int idx = index(1, y, z);
        int sy = width, sz = width * height;
        int x = 1;
#if defined(WINDSIM_USE_AVX2)
        __m256 vHalfSub = _mm256_set1_ps(0.5f);
        for (; x <= width - 9; x += 8, idx += 8) {
          __m256 p1x = _mm256_loadu_ps(&pressure[idx + 1]);
          __m256 p0x = _mm256_loadu_ps(&pressure[idx - 1]);
          _mm256_storeu_ps(
              &vx[idx],
              _mm256_sub_ps(_mm256_loadu_ps(&vx[idx]),
                            _mm256_mul_ps(_mm256_sub_ps(p1x, p0x), vHalfSub)));

          __m256 p1y = _mm256_loadu_ps(&pressure[idx + sy]);
          __m256 p0y = _mm256_loadu_ps(&pressure[idx - sy]);
          _mm256_storeu_ps(
              &vy[idx],
              _mm256_sub_ps(_mm256_loadu_ps(&vy[idx]),
                            _mm256_mul_ps(_mm256_sub_ps(p1y, p0y), vHalfSub)));

          __m256 p1z = _mm256_loadu_ps(&pressure[idx + sz]);
          __m256 p0z = _mm256_loadu_ps(&pressure[idx - sz]);
          _mm256_storeu_ps(
              &vz[idx],
              _mm256_sub_ps(_mm256_loadu_ps(&vz[idx]),
                            _mm256_mul_ps(_mm256_sub_ps(p1z, p0z), vHalfSub)));
        }
#endif
        for (; x < width - 1; ++x, ++idx) {
          vx[idx] -= 0.5f * (pressure[idx + 1] - pressure[idx - 1]);
          vy[idx] -= 0.5f * (pressure[idx + sy] - pressure[idx - sy]);
          vz[idx] -= 0.5f * (pressure[idx + sz] - pressure[idx - sz]);
        }
      }
    }
    setBounds(vx, vy, vz);
  }

  void setBounds(std::vector<float> &v_x, std::vector<float> &v_y,
                 std::vector<float> &v_z) {
    int sz = width * height;
#pragma omp parallel for
    for (int y = 0; y < height; ++y) {
      for (int x = 0; x < width; ++x) {
        v_x[x + width * y] = v_y[x + width * y] = v_z[x + width * y] = 0;
        v_x[x + width * y + sz * (depth - 1)] =
            v_y[x + width * y + sz * (depth - 1)] =
                v_z[x + width * y + sz * (depth - 1)] = 0;
      }
    }
#pragma omp parallel for
    for (int z = 0; z < depth; ++z) {
      for (int x = 0; x < width; ++x) {
        v_x[x + sz * z] = v_y[x + sz * z] = v_z[x + sz * z] = 0;
        v_x[x + width * (height - 1) + sz * z] =
            v_y[x + width * (height - 1) + sz * z] =
                v_z[x + width * (height - 1) + sz * z] = 0;
      }
    }
#pragma omp parallel for
    for (int z = 0; z < depth; ++z) {
      for (int y = 0; y < height; ++y) {
        v_x[width * y + sz * z] = v_y[width * y + sz * z] =
            v_z[width * y + sz * z] = 0;
        v_x[(width - 1) + width * y + sz * z] =
            v_y[(width - 1) + width * y + sz * z] =
                v_z[(width - 1) + width * y + sz * z] = 0;
      }
    }
  }

  void setBoundsScalar(std::vector<float> &f) {
    int sz = width * height;
#pragma omp parallel for
    for (int y = 0; y < height; ++y) {
      for (int x = 0; x < width; ++x) {
        f[x + width * y] = f[x + width * y + sz];
        f[x + width * y + sz * (depth - 1)] =
            f[x + width * y + sz * (depth - 2)];
      }
    }
#pragma omp parallel for
    for (int z = 0; z < depth; ++z) {
      for (int x = 0; x < width; ++x) {
        f[x + sz * z] = f[x + width + sz * z];
        f[x + width * (height - 1) + sz * z] =
            f[x + width * (height - 2) + sz * z];
      }
    }
#pragma omp parallel for
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