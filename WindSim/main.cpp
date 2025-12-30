#include "windsim.hpp"
#include <chrono>
#include <iomanip>
#include <iostream>
#include <thread>

// Utility to visualize a 2D slice of the 3D grid
void printAsciiSlice(const WindSim::WindGrid &grid, int zSlice) {
  auto dims = grid.getDimensions();
  const WindSim::Vec4 *data = (const WindSim::Vec4 *)grid.getVelocityData();

  std::cout << "Slice Z=" << zSlice << "\n";
  for (int y = 0; y < dims.y; ++y) {
    for (int x = 0; x < dims.x; ++x) {
      int idx = x + dims.x * (y + dims.y * zSlice);
      WindSim::Vec4 v = data[idx];
      float len = v.length3();

      char c = '.';
      if (len > 0.1f)
        c = '~';
      if (len > 0.5f)
        c = 'v';
      if (len > 1.0f)
        c = 'V';
      if (len > 2.0f)
        c = '#';

      // Simple direction arrow approximation
      if (len > 0.2f) {
        if (std::abs(v.x) > std::abs(v.y))
          c = (v.x > 0) ? '>' : '<';
        else
          c = (v.y > 0) ? 'v' : '^';
      }

      std::cout << c << " ";
    }
    std::cout << "\n";
  }
  std::cout << "--------------------------------\n";
}

int main() {
  // 1. Initialize Grid (32x32x32)
  int res = 32;
  WindSim::WindGrid windSim(res, res, res, 1.0f);

  std::cout << "Initializing Wind Simulation (" << res << "^3 cells)...\n";
  std::cout << "Memory usage: " << (windSim.getVelocityDataSize() / 1024)
            << " KB\n";

  // 2. Define Wind Generators
  std::vector<WindSim::WindVolume> volumes;

  // A directional wind blowing Right
  //   volumes.push_back(WindSim::WindVolume::CreateDirectional(
  //       {0, 0, 0}, {6, 6, 6}, // Bounds
  //       {1.0f, 0.2f, 0.0f},   // Direction (Slightly Up-Right)
  //       5.0f                  // Strength
  //       ));

  // A generic "explosion" or radial gust in the middle
  volumes.push_back(WindSim::WindVolume::CreateRadial({16, 16, 16}, // Center
                                                      8.0f,         // Radius
                                                      20.0f         // Strength
                                                      ));

  // 3. Simulation Loop
  float dt = 0.1f;
  for (int i = 0; i < 20; ++i) {
    // Apply wind sources
    windSim.applyForces(dt, volumes);

    // Solve Fluid Dynamics
    auto start = std::chrono::high_resolution_clock::now();
    windSim.step(dt);
    auto end = std::chrono::high_resolution_clock::now();

    std::chrono::duration<double, std::milli> ms = end - start;

    // Visualize center slice
    if (i % 2 == 0) { // Print every other frame
      std::cout << "Frame " << i << " (" << ms.count() << "ms compute)\n";
      printAsciiSlice(windSim, 16);
    }

    // --- Vulkan Interop Note ---
    // At this point, you would map your Vulkan Storage Buffer:
    // void* mappedData;
    // vkMapMemory(device, bufferMemory, 0, size, 0, &mappedData);
    // memcpy(mappedData, windSim.getVelocityData(),
    // windSim.getVelocityDataSize()); vkUnmapMemory(device, bufferMemory);
  }

  std::cout << "Simulation complete.\n";
  return 0;
}