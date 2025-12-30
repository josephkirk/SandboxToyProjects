#include "windsim_shim.h"
#include "windsim.hpp"

extern "C" {

struct WindSim_Handle {
  std::unique_ptr<WindSim::WindGrid> grid;
};

WindSim_Handle *WindSim_Create(int w, int h, int d, float cellSize) {
  auto handle = new WindSim_Handle();
  handle->grid = std::make_unique<WindSim::WindGrid>(w, h, d, cellSize);
  return handle;
}

void WindSim_Destroy(WindSim_Handle *handle) {
  if (handle)
    delete handle;
}

void WindSim_Step(WindSim_Handle *handle, float dt) { handle->grid->step(dt); }

void WindSim_ApplyForces(WindSim_Handle *handle, float dt,
                         const WindVolume_C *volumes, int count) {
  std::vector<WindSim::WindVolume> cppVolumes;
  cppVolumes.reserve(count);
  for (int i = 0; i < count; ++i) {
    WindSim::WindVolume v;
    v.type = (WindSim::VolumeType)volumes[i].type;
    v.position = {volumes[i].position.x, volumes[i].position.y,
                  volumes[i].position.z, volumes[i].position.w};
    v.direction = {volumes[i].direction.x, volumes[i].direction.y,
                   volumes[i].direction.z, volumes[i].direction.w};
    v.rotation = {volumes[i].rotation.x, volumes[i].rotation.y,
                  volumes[i].rotation.z, volumes[i].rotation.w};
    v.sizeParams = {volumes[i].sizeParams.x, volumes[i].sizeParams.y,
                    volumes[i].sizeParams.z, volumes[i].sizeParams.w};
    v.strength = volumes[i].strength;
    cppVolumes.push_back(v);
  }
  handle->grid->applyForces(dt, cppVolumes);
}

const Vec4_C *WindSim_GetVelocityData(WindSim_Handle *handle) {
  return (const Vec4_C *)handle->grid->getVelocityData();
}

const char *WindSim_GetSIMDName(WindSim_Handle *handle) {
  return handle->grid->getSIMDName();
}

int WindSim_GetActiveBlockCount(WindSim_Handle *handle) {
  return handle->grid->getActiveBlockCount();
}

int WindSim_GetTotalBlockCount(WindSim_Handle *handle) {
  return handle->grid->getTotalBlockCount();
}

Vec4_C WindSim_RotateDirection(Vec4_C v, Vec4_C euler) {
  WindSim::Vec4 res = WindSim::WindGrid::rotateDirection(
      {v.x, v.y, v.z, v.w}, {euler.x, euler.y, euler.z, euler.w});
  return {res.x, res.y, res.z, res.w};
}
}
