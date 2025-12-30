#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WindSim_Handle WindSim_Handle;

typedef struct {
  float x, y, z, w;
} Vec4_C;

typedef enum { VolumeType_Directional, VolumeType_Radial } VolumeType_C;

typedef struct {
  VolumeType_C type;
  Vec4_C position;
  Vec4_C direction;
  Vec4_C sizeParams;
  Vec4_C rotation;
  float strength;
} WindVolume_C;

WindSim_Handle *WindSim_Create(int w, int h, int d, float cellSize);
void WindSim_Destroy(WindSim_Handle *handle);
void WindSim_Step(WindSim_Handle *handle, float dt);
void WindSim_ApplyForces(WindSim_Handle *handle, float dt,
                         const WindVolume_C *volumes, int count);
const Vec4_C *WindSim_GetVelocityData(WindSim_Handle *handle);
const char *WindSim_GetSIMDName(WindSim_Handle *handle);
int WindSim_GetActiveBlockCount(WindSim_Handle *handle);
int WindSim_GetTotalBlockCount(WindSim_Handle *handle);

Vec4_C WindSim_RotateDirection(Vec4_C v, Vec4_C euler);

#ifdef __cplusplus
}
#endif
