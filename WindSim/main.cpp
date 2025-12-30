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
  camera.target = (Vector3){0.0f, 0.0f, 0.0f};
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
      camera.target = (Vector3){0.0f, 0.0f, 0.0f};
    }
    if (IsKeyPressed(KEY_RIGHT_BRACKET)) {
      if (currentRes < 128)
        InitSim(currentRes + 16);
      camera.target = (Vector3){0.0f, 0.0f, 0.0f};
    }

    // --- Camera Controls (Maya Style) ---
    if (IsKeyDown(KEY_LEFT_ALT) || IsKeyDown(KEY_RIGHT_ALT)) {
      Vector2 delta = GetMouseDelta();
      float mouseWheel = GetMouseWheelMove();

      // Alt + Right Mouse OR Mouse Wheel: Zoom
      if (IsMouseButtonDown(MOUSE_BUTTON_RIGHT) || mouseWheel != 0.0f) {
        float zoomFactor = 0.0f;
        if (mouseWheel != 0.0f) {
          zoomFactor = mouseWheel * 2.0f;
        } else {
          zoomFactor = -delta.x * 0.1f + delta.y * 0.1f;
        }

        Vector3 forward = Vector3Subtract(camera.target, camera.position);
        float dist = Vector3Length(forward);

        // Prevent getting too close or flipping
        if (dist > 1.0f || zoomFactor < 0.0f) {
          Vector3 move = Vector3Scale(Vector3Normalize(forward), zoomFactor);
          camera.position = Vector3Add(camera.position, move);
        }
      }
      // Alt + Middle Mouse: Pan
      else if (IsMouseButtonDown(MOUSE_BUTTON_MIDDLE)) {
        Vector3 forward =
            Vector3Normalize(Vector3Subtract(camera.target, camera.position));
        Vector3 right = Vector3CrossProduct(forward, camera.up);
        Vector3 up = camera.up; // Or re-calculate local up if needed

        float panSpeed =
            0.05f * Vector3Distance(camera.position, camera.target) * 0.05f;

        Vector3 moveX = Vector3Scale(right, -delta.x * panSpeed);
        Vector3 moveY = Vector3Scale(up, delta.y * panSpeed);

        Vector3 move = Vector3Add(moveX, moveY);
        camera.position = Vector3Add(camera.position, move);
        camera.target = Vector3Add(camera.target, move);
      }
      // Alt + Left Mouse: Orbit
      else if (IsMouseButtonDown(MOUSE_BUTTON_LEFT)) {
        Vector3 sub = Vector3Subtract(camera.position, camera.target);

        // Rotate Yaw (around global Y)
        Matrix rotYaw = MatrixRotate((Vector3){0, 1, 0}, -delta.x * 0.005f);
        sub = Vector3Transform(sub, rotYaw);

        // Rotate Pitch (around local Right)
        Vector3 right = Vector3CrossProduct(Vector3Normalize(sub), camera.up);
        right.y = 0;
        right = Vector3Normalize(right);
        Matrix rotPitch = MatrixRotate(right, -delta.y * 0.005f);
        sub = Vector3Transform(sub, rotPitch);

        camera.position = Vector3Add(camera.target, sub);
      }
    } else {
      // Scroll Zoom
      float mouseWheel = GetMouseWheelMove();
      if (mouseWheel != 0.0f) {
        Vector3 forward = Vector3Subtract(camera.target, camera.position);
        Vector3 move =
            Vector3Scale(Vector3Normalize(forward), mouseWheel * 2.0f);
        camera.position = Vector3Add(camera.position, move);
      }
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
          {WindSim::WindVolume::CreateRadial({0.0f, 0.0f, 0.0f}, 10.0f, 120.0f),
           false, DARKBLUE});
      if (selectedIdx >= 0)
        visualVolumes[selectedIdx].selected = false;
      selectedIdx = visualVolumes.size() - 1;
      visualVolumes[selectedIdx].selected = true;
    }

    if (IsKeyPressed(KEY_B)) { // New Box (Directional)
      visualVolumes.push_back({WindSim::WindVolume::CreateDirectional(
                                   {0.0f, 0.0f, 0.0f}, {8.0f, 8.0f, 8.0f},
                                   {1.0f, 0.0f, 0.0f}, 150.0f),
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
    // (Existing transform logic assumes 'v.volume' is modified directly, which
    // is World Space now. Correct.)
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
    // Transform World Space volumes to Sim Space (0..res)
    std::vector<WindSim::WindVolume> simVolumes;
    float halfRes = currentRes * 0.5f;
    for (const auto &vv : visualVolumes) {
      WindSim::WindVolume sv = vv.volume;
      sv.position.x += halfRes;
      sv.position.y += halfRes;
      sv.position.z += halfRes;
      simVolumes.push_back(sv);
    }

    double simStartTime = GetTime();
    windSim->applyForces(dt, simVolumes);
    windSim->step(dt);
    simTimeMs = (float)((GetTime() - simStartTime) * 1000.0);

    // --- Rendering ---
    BeginDrawing();
    ClearBackground(RAYWHITE);
    BeginMode3D(camera);
    // Grid matches Sim Resolution but centered
    DrawGrid(currentRes, cellSize);

    const WindSim::Vec4 *vData =
        (const WindSim::Vec4 *)windSim->getVelocityData();
    int renderStep = (currentRes > 48) ? 4 : 2;
    float offset = currentRes * 0.5f;
    for (int z = 0; z < currentRes; z += renderStep) {
      for (int y = 0; y < currentRes; y += renderStep) {
        for (int x = 0; x < currentRes; x += renderStep) {
          int idx = x + currentRes * (y + currentRes * z);
          WindSim::Vec4 v = vData[idx];
          float len = v.length3();
          if (len > 0.1f) {
            Vector3 start = {(float)x - offset, (float)y - offset,
                             (float)z - offset};
            Vector3 end = {start.x + v.x * vectorScale,
                           start.y + v.y * vectorScale,
                           start.z + v.z * vectorScale};
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
    DrawText(TextFormat("Res: %d^3 | SIMD: %s | Volumes: %d | Scale: %.1f",
                        currentRes, windSim->getSIMDName(),
                        (int)visualVolumes.size(), vectorScale),
             10, 10, 20, DARKGRAY);
    DrawText(TextFormat("Blocks: %d / %d Active",
                        windSim->getActiveBlockCount(),
                        windSim->getTotalBlockCount()),
             10, 35, 20, DARKGRAY);
    DrawText("Grid Size: [ ] | Vector Scale: O P | TAB Selection | N/B Add | "
             "DEL Remove",
             10, screenHeight - 60, 18, GRAY);
    DrawText("Transform: Arrows/PgUp/PgDn Move | R/F, T/G, Y/H Rotate Wind | "
             "+/- Resize",
             10, screenHeight - 35, 18, GRAY);
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