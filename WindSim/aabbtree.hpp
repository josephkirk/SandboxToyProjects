#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <limits>
#include <vector>


namespace aabb {

struct Vec3 {
  float x, y, z;
  Vec3 operator+(const Vec3 &o) const { return {x + o.x, y + o.y, z + o.z}; }
  Vec3 operator-(const Vec3 &o) const { return {x - o.x, y - o.y, z - o.z}; }
  Vec3 operator*(float s) const { return {x * s, y * s, z * s}; }
  float operator[](int i) const { return (&x)[i]; }
};

struct Ray {
  Vec3 origin;
  Vec3 dir;
  Vec3 inv_dir;
  Ray(Vec3 o, Vec3 d) : origin(o), dir(d) {
    const float inf = std::numeric_limits<float>::max();
    inv_dir.x = (std::abs(d.x) > 1e-6f) ? 1.0f / d.x : ((d.x < 0) ? -inf : inf);
    inv_dir.y = (std::abs(d.y) > 1e-6f) ? 1.0f / d.y : ((d.y < 0) ? -inf : inf);
    inv_dir.z = (std::abs(d.z) > 1e-6f) ? 1.0f / d.z : ((d.z < 0) ? -inf : inf);
  }
};

struct AABB {
  Vec3 min{std::numeric_limits<float>::max(), std::numeric_limits<float>::max(),
           std::numeric_limits<float>::max()};
  Vec3 max{std::numeric_limits<float>::lowest(),
           std::numeric_limits<float>::lowest(),
           std::numeric_limits<float>::lowest()};

  void expand(const Vec3 &p) {
    min.x = std::min(min.x, p.x);
    min.y = std::min(min.y, p.y);
    min.z = std::min(min.z, p.z);
    max.x = std::max(max.x, p.x);
    max.y = std::max(max.y, p.y);
    max.z = std::max(max.z, p.z);
  }

  void expand(const AABB &b) {
    min.x = std::min(min.x, b.min.x);
    min.y = std::min(min.y, b.min.y);
    min.z = std::min(min.z, b.min.z);
    max.x = std::max(max.x, b.max.x);
    max.y = std::max(max.y, b.max.y);
    max.z = std::max(max.z, b.max.z);
  }

  [[nodiscard]] Vec3 center() const {
    return {(min.x + max.x) * 0.5f, (min.y + max.y) * 0.5f,
            (min.z + max.z) * 0.5f};
  }

  [[nodiscard]] bool contains(const Vec3 &p) const {
    return p.x >= min.x && p.x <= max.x && p.y >= min.y && p.y <= max.y &&
           p.z >= min.z && p.z <= max.z;
  }

  [[nodiscard]] bool overlaps(const AABB &o) const {
    return max.x >= o.min.x && min.x <= o.max.x && max.y >= o.min.y &&
           min.y <= o.max.y && max.z >= o.min.z && min.z <= o.max.z;
  }

  [[nodiscard]] bool intersect(const Ray &r, float &t_min_out) const {
    float tx1 = (min.x - r.origin.x) * r.inv_dir.x;
    float tx2 = (max.x - r.origin.x) * r.inv_dir.x;
    float tmin = std::min(tx1, tx2), tmax = std::max(tx1, tx2);
    float ty1 = (min.y - r.origin.y) * r.inv_dir.y;
    float ty2 = (max.y - r.origin.y) * r.inv_dir.y;
    tmin = std::max(tmin, std::min(ty1, ty2));
    tmax = std::min(tmax, std::max(ty1, ty2));
    float tz1 = (min.z - r.origin.z) * r.inv_dir.z;
    float tz2 = (max.z - r.origin.z) * r.inv_dir.z;
    tmin = std::max(tmin, std::min(tz1, tz2));
    tmax = std::min(tmax, std::max(tz1, tz2));
    t_min_out = tmin;
    return tmax >= tmin && tmax >= 0.0f;
  }
};

class Tree {
public:
  struct alignas(32) Node {
    float min_x, min_y, min_z;
    union {
      uint32_t left_child;
      uint32_t first_prim;
    };
    float max_x, max_y, max_z;
    union {
      uint32_t count;
      uint32_t pad;
    };

    [[nodiscard]] bool is_leaf() const { return count > 0; }
    [[nodiscard]] AABB get_aabb() const {
      return AABB{{min_x, min_y, min_z}, {max_x, max_y, max_z}};
    }
  };

private:
  std::vector<Node> nodes;
  std::vector<uint32_t> indices;
  std::vector<AABB> original_boxes;

public:
  Tree() = default;

  void build(const std::vector<AABB> &boxes) {
    if (boxes.empty())
      return;
    original_boxes = boxes;
    indices.resize(boxes.size());
    for (size_t i = 0; i < indices.size(); ++i)
      indices[i] = static_cast<uint32_t>(i);
    nodes.clear();
    nodes.reserve(boxes.size() * 2);
    nodes.emplace_back();
    build_recursive(0, 0, static_cast<uint32_t>(indices.size()));
  }

  [[nodiscard]] int query_ray(const Ray &r, float &t_out) const {
    if (nodes.empty())
      return -1;
    int closest_prim_idx = -1;
    float closest_t = std::numeric_limits<float>::max();
    struct StackEntry {
      uint32_t node_idx;
      float dist;
    };
    StackEntry stack[64];
    int stack_ptr = 0;
    float t_box;
    if (intersect_node_fast(nodes[0], r, t_box))
      stack[stack_ptr++] = {0, t_box};

    while (stack_ptr > 0) {
      StackEntry current = stack[--stack_ptr];
      if (current.dist >= closest_t)
        continue;
      const Node &node = nodes[current.node_idx];
      if (node.is_leaf()) {
        for (uint32_t i = 0; i < node.count; ++i) {
          uint32_t prim_idx = indices[node.first_prim + i];
          const AABB &prim = original_boxes[prim_idx];
          float t;
          if (prim.intersect(r, t)) {
            if (t < closest_t && t >= 0.0f) {
              closest_t = t;
              closest_prim_idx = static_cast<int>(prim_idx);
            }
          }
        }
      } else {
        uint32_t left_idx = node.left_child;
        uint32_t right_idx = left_idx + 1;
        float t_left, t_right;
        bool hit_left = intersect_node_fast(nodes[left_idx], r, t_left);
        bool hit_right = intersect_node_fast(nodes[right_idx], r, t_right);
        if (hit_left && hit_right) {
          if (t_left < t_right) {
            stack[stack_ptr++] = {right_idx, t_right};
            stack[stack_ptr++] = {left_idx, t_left};
          } else {
            stack[stack_ptr++] = {left_idx, t_left};
            stack[stack_ptr++] = {right_idx, t_right};
          }
        } else if (hit_left)
          stack[stack_ptr++] = {left_idx, t_left};
        else if (hit_right)
          stack[stack_ptr++] = {right_idx, t_right};
      }
    }
    t_out = closest_t;
    return closest_prim_idx;
  }

  [[nodiscard]] bool query_point(const Vec3 &p) const {
    if (nodes.empty())
      return false;
    if (!nodes[0].get_aabb().contains(p))
      return false;
    uint32_t stack[64];
    int stack_ptr = 0;
    stack[stack_ptr++] = 0;
    while (stack_ptr > 0) {
      uint32_t idx = stack[--stack_ptr];
      const Node &node = nodes[idx];
      if (node.is_leaf()) {
        for (uint32_t i = 0; i < node.count; ++i) {
          if (original_boxes[indices[node.first_prim + i]].contains(p))
            return true;
        }
      } else {
        uint32_t left = node.left_child;
        if (nodes[left].get_aabb().contains(p))
          stack[stack_ptr++] = left;
        if (nodes[left + 1].get_aabb().contains(p))
          stack[stack_ptr++] = left + 1;
      }
    }
    return false;
  }

  // NEW: Overlap query
  [[nodiscard]] bool query_overlap(const AABB &box) const {
    if (nodes.empty())
      return false;
    if (!nodes[0].get_aabb().overlaps(box))
      return false;

    uint32_t stack[64];
    int stack_ptr = 0;
    stack[stack_ptr++] = 0;

    while (stack_ptr > 0) {
      uint32_t idx = stack[--stack_ptr];
      const Node &node = nodes[idx];

      if (node.is_leaf()) {
        for (uint32_t i = 0; i < node.count; ++i) {
          if (original_boxes[indices[node.first_prim + i]].overlaps(box))
            return true;
        }
      } else {
        uint32_t left = node.left_child;
        if (nodes[left].get_aabb().overlaps(box))
          stack[stack_ptr++] = left;
        if (nodes[left + 1].get_aabb().overlaps(box))
          stack[stack_ptr++] = left + 1;
      }
    }
    return false;
  }

  [[nodiscard]] const std::vector<Node> &get_nodes() const { return nodes; }

private:
  bool intersect_node_fast(const Node &n, const Ray &r, float &t) const {
    float tx1 = (n.min_x - r.origin.x) * r.inv_dir.x;
    float tx2 = (n.max_x - r.origin.x) * r.inv_dir.x;
    float tmin = std::min(tx1, tx2), tmax = std::max(tx1, tx2);
    float ty1 = (n.min_y - r.origin.y) * r.inv_dir.y;
    float ty2 = (n.max_y - r.origin.y) * r.inv_dir.y;
    tmin = std::max(tmin, std::min(ty1, ty2));
    tmax = std::min(tmax, std::max(ty1, ty2));
    float tz1 = (n.min_z - r.origin.z) * r.inv_dir.z;
    float tz2 = (n.max_z - r.origin.z) * r.inv_dir.z;
    tmin = std::max(tmin, std::min(tz1, tz2));
    tmax = std::min(tmax, std::max(tz1, tz2));
    t = tmin;
    return tmax >= tmin && tmax >= 0.0f;
  }

  void build_recursive(uint32_t node_idx, uint32_t start_idx, uint32_t count) {
    Node &node = nodes[node_idx];
    AABB bounds, centroids;
    for (uint32_t i = 0; i < count; ++i) {
      const AABB &b = original_boxes[indices[start_idx + i]];
      bounds.expand(b);
      centroids.expand(b.center());
    }
    node.min_x = bounds.min.x;
    node.min_y = bounds.min.y;
    node.min_z = bounds.min.z;
    node.max_x = bounds.max.x;
    node.max_y = bounds.max.y;
    node.max_z = bounds.max.z;

    if (count <= 2) {
      node.first_prim = start_idx;
      node.count = count;
      return;
    }

    Vec3 extent = centroids.max - centroids.min;
    int axis = 0;
    if (extent.y > extent.x)
      axis = 1;
    if (extent.z > extent[extent.y > extent.x ? 1 : 0])
      axis = 2; // Rough axis check fix

    float split_pos = centroids.min[axis] + extent[axis] * 0.5f;
    auto it =
        std::partition(indices.begin() + start_idx,
                       indices.begin() + start_idx + count, [&](uint32_t idx) {
                         return original_boxes[idx].center()[axis] < split_pos;
                       });

    uint32_t left_count =
        static_cast<uint32_t>(std::distance(indices.begin() + start_idx, it));
    if (left_count == 0 || left_count == count) {
      left_count = count / 2;
      std::nth_element(
          indices.begin() + start_idx, indices.begin() + start_idx + left_count,
          indices.begin() + start_idx + count, [&](uint32_t a, uint32_t b) {
            return original_boxes[a].center()[axis] <
                   original_boxes[b].center()[axis];
          });
    }

    uint32_t left_child_idx = static_cast<uint32_t>(nodes.size());
    nodes.emplace_back();
    nodes.emplace_back();
    nodes[node_idx].left_child = left_child_idx;
    nodes[node_idx].count = 0;
    build_recursive(left_child_idx, start_idx, left_count);
    build_recursive(left_child_idx + 1, start_idx + left_count,
                    count - left_count);
  }
};
} // namespace aabb