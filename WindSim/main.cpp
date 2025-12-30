#include "raylib.h"
#include "raymath.h"
#include "rlgl.h"
#include "windsim.hpp"
#include <iostream>
#include <memory>
#include <string>
#include <vector>

struct VisualVolume {
  WindSim::WindVolume volume;
  bool selected = false;
  Color color;
};

// Global for easy re-init
int currentRes = 32;
float cellSize = 1.0f;
std::unique_ptr<WindSim::WindGrid> windSim;

void InitSim(int res) {
  currentRes = res;
  windSim = std::make_unique<WindSim::WindGrid>(res, res, res, cellSize);
  std::cout << "Simulation initialized at resolution: " << res << "^3"
            << std::endl;
}

int main() {
  InitSim(currentRes);
  std::vector<VisualVolume> visualVolumes; // Start empty at startup

  const int screenWidth = 1280;
  const int screenHeight = 720;
  InitWindow(screenWidth, screenHeight, "WindSim Visualizer - Nguyen Phi Hung");

  Camera3D camera = {0};
  camera.position = (Vector3){60.0f, 60.0f, 60.0f};
  camera.target =
      (Vector3){currentRes / 2.0f, currentRes / 2.0f, currentRes / 2.0f};
  camera.up = (Vector3){0.0f, 1.0f, 0.0f};
  camera.fovy = 45.0f;
  camera.projection = CAMERA_PERSPECTIVE;

  SetTargetFPS(60);

  float dt = 0.1f;
  int selectedIdx = -1;
  float vectorScale = 2.0f;
  float simTimeMs = 0;

  while (!WindowShouldClose()) {
    float frameDt = GetFrameTime();

    // --- Grid Size Adjustment ---
    if (IsKeyPressed(KEY_LEFT_BRACKET)) {
      if (currentRes > 16)
        InitSim(currentRes - 16);
      camera.target =
          (Vector3){currentRes / 2.0f, currentRes / 2.0f, currentRes / 2.0f};
    }
    if (IsKeyPressed(KEY_RIGHT_BRACKET)) {
      if (currentRes < 128)
        InitSim(currentRes + 16);
      camera.target =
          (Vector3){currentRes / 2.0f, currentRes / 2.0f, currentRes / 2.0f};
    }

    // --- Vector Scaling ---
    if (IsKeyDown(KEY_O))
      vectorScale = std::max(0.1f, vectorScale - 2.0f * frameDt);
    if (IsKeyDown(KEY_P))
      vectorScale += 2.0f * frameDt;

    // --- Volume Management ---
    if (IsKeyPressed(KEY_TAB)) {
      if (!visualVolumes.empty()) {
        if (selectedIdx >= 0)
          visualVolumes[selectedIdx].selected = false;
        selectedIdx = (selectedIdx + 1) % visualVolumes.size();
        visualVolumes[selectedIdx].selected = true;
      }
    }

    if (IsKeyPressed(KEY_N)) { // New Radial
      visualVolumes.push_back(
          {WindSim::WindVolume::CreateRadial(
               {currentRes / 2.0f, currentRes / 2.0f, currentRes / 2.0f}, 10.0f,
               120.0f),
           false, DARKBLUE});
      if (selectedIdx >= 0)
        visualVolumes[selectedIdx].selected = false;
      selectedIdx = visualVolumes.size() - 1;
      visualVolumes[selectedIdx].selected = true;
    }

    if (IsKeyPressed(KEY_B)) { // New Box (Directional)
      visualVolumes.push_back(
          {WindSim::WindVolume::CreateDirectional(
               {currentRes / 2.0f, currentRes / 2.0f, currentRes / 2.0f},
               {8.0f, 8.0f, 8.0f}, {1.0f, 0.0f, 0.0f}, 150.0f),
           false, MAROON});
      if (selectedIdx >= 0)
        visualVolumes[selectedIdx].selected = false;
      selectedIdx = visualVolumes.size() - 1;
      visualVolumes[selectedIdx].selected = true;
    }

    if (IsKeyPressed(KEY_DELETE) && selectedIdx >= 0) {
      visualVolumes.erase(visualVolumes.begin() + selectedIdx);
      selectedIdx = -1;
    }

    // --- Transformation & Rotation ---
    if (selectedIdx >= 0) {
      VisualVolume &v = visualVolumes[selectedIdx];
      float moveSpeed = 40.0f * frameDt;
      float rotSpeed = 3.0f * frameDt;

      if (IsKeyDown(KEY_UP))
        v.volume.position.z -= moveSpeed;
      if (IsKeyDown(KEY_DOWN))
        v.volume.position.z += moveSpeed;
      if (IsKeyDown(KEY_LEFT))
        v.volume.position.x -= moveSpeed;
      if (IsKeyDown(KEY_RIGHT))
        v.volume.position.x += moveSpeed;
      if (IsKeyDown(KEY_PAGE_UP))
        v.volume.position.y += moveSpeed;
      if (IsKeyDown(KEY_PAGE_DOWN))
        v.volume.position.y -= moveSpeed;

      // Rotate Wind Direction (Euler Axis)
      if (IsKeyDown(KEY_R))
        v.volume.rotation.x += rotSpeed;
      if (IsKeyDown(KEY_F))
        v.volume.rotation.x -= rotSpeed;
      if (IsKeyDown(KEY_T))
        v.volume.rotation.y += rotSpeed;
      if (IsKeyDown(KEY_G))
        v.volume.rotation.y -= rotSpeed;
      if (IsKeyDown(KEY_Y))
        v.volume.rotation.z += rotSpeed;
      if (IsKeyDown(KEY_H))
        v.volume.rotation.z -= rotSpeed;

      // Resize
      if (IsKeyDown(KEY_KP_ADD) || IsKeyDown(KEY_EQUAL)) {
        v.volume.sizeParams.x += moveSpeed * 0.5f;
        if (v.volume.type == WindSim::VolumeType::Directional) {
          v.volume.sizeParams.y += moveSpeed * 0.5f;
          v.volume.sizeParams.z += moveSpeed * 0.5f;
        }
      }
      if (IsKeyDown(KEY_KP_SUBTRACT) || IsKeyDown(KEY_MINUS)) {
        v.volume.sizeParams.x =
            std::max(0.5f, v.volume.sizeParams.x - moveSpeed * 0.5f);
        if (v.volume.type == WindSim::VolumeType::Directional) {
          v.volume.sizeParams.y =
              std::max(0.5f, v.volume.sizeParams.y - moveSpeed * 0.5f);
          v.volume.sizeParams.z =
              std::max(0.5f, v.volume.sizeParams.z - moveSpeed * 0.5f);
        }
      }
    }

    // --- Simulation ---
    std::vector<WindSim::WindVolume> simVolumes;
    for (const auto &vv : visualVolumes)
      simVolumes.push_back(vv.volume);
    double simStartTime = GetTime();
    windSim->applyForces(dt, simVolumes);
    windSim->step(dt);
    simTimeMs = (float)((GetTime() - simStartTime) * 1000.0);

    // --- Rendering ---
    BeginDrawing();
    ClearBackground(RAYWHITE);
    BeginMode3D(camera);
    DrawGrid(currentRes, cellSize);

    const WindSim::Vec4 *vData =
        (const WindSim::Vec4 *)windSim->getVelocityData();
    int renderStep = (currentRes > 48) ? 4 : 2;
    for (int z = 0; z < currentRes; z += renderStep) {
      for (int y = 0; y < currentRes; y += renderStep) {
        for (int x = 0; x < currentRes; x += renderStep) {
          int idx = x + currentRes * (y + currentRes * z);
          WindSim::Vec4 v = vData[idx];
          float len = v.length3();
          if (len > 0.1f) {
            Vector3 start = {(float)x, (float)y, (float)z};
            Vector3 end = {x + v.x * vectorScale, y + v.y * vectorScale,
                           z + v.z * vectorScale};
            DrawLine3D(start, end, Fade(BLUE, std::min(1.0f, len * 0.1f)));
          }
        }
      }
    }

    for (const auto &vv : visualVolumes) {
      Vector3 pos = {vv.volume.position.x, vv.volume.position.y,
                     vv.volume.position.z};
      Color color = vv.selected ? YELLOW : vv.color;
      if (vv.volume.type == WindSim::VolumeType::Radial) {
        DrawSphereWires(pos, vv.volume.sizeParams.x, 8, 8, color);
      } else {
        // AABB Box
        DrawCubeWires(pos, vv.volume.sizeParams.x * 2.0f,
                      vv.volume.sizeParams.y * 2.0f,
                      vv.volume.sizeParams.z * 2.0f, color);
        // Direction Vector
        WindSim::Vec4 rotDir = WindSim::WindGrid::rotateDirection(
            vv.volume.direction, vv.volume.rotation);
        Vector3 arrowEnd = {pos.x + rotDir.x * 10, pos.y + rotDir.y * 10,
                            pos.z + rotDir.z * 10};
        DrawLine3D(pos, arrowEnd, MAGENTA);
        DrawSphere(arrowEnd, 0.4f, MAGENTA);
      }
    }
    EndMode3D();

    DrawText(TextFormat("Total: %.2f ms | Sim: %.2f ms",
                        GetFrameTime() * 1000.0f, simTimeMs),
             screenWidth - 250, 10, 20, DARKGRAY);
    DrawText(TextFormat("Res: %d^3 | Volumes: %d | Scale: %.1f", currentRes,
                        (int)visualVolumes.size(), vectorScale),
             10, 10, 20, DARKGRAY);
    DrawText("Grid Size: [ ] | Vector Scale: O P | TAB Selection | N/B Add | "
             "DEL Remove",
             10, 40, 18, GRAY);
    DrawText("Transform: Arrows/PgUp/PgDn Move | R/F, T/G, Y/H Rotate Wind | "
             "+/- Resize",
             10, 65, 18, GRAY);
    if (selectedIdx >= 0) {
      const auto &v = visualVolumes[selectedIdx].volume;
      DrawText(
          TextFormat(
              "SELECTED [%d]: pos(%.1f, %.1f, %.1f) wind_rot(%.1f, %.1f, %.1f)",
              selectedIdx, v.position.x, v.position.y, v.position.z,
              v.rotation.x * RAD2DEG, v.rotation.y * RAD2DEG,
              v.rotation.z * RAD2DEG),
          10, 95, 18, MAROON);
    }
    EndDrawing();
  }
  CloseWindow();
  return 0;
}