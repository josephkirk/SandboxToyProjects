Implementing **Composition Layers** in Vulkan is typically achieved using the **`VK_KHR_display`** extension or platform-specific "Multiplane Overlay" (MPO) support.

---

### 1. The Core Architecture: "Planes"

Vulkan doesn't call them "layers"; it calls them **Planes**.
A modern GPU display engine has multiple "Hardware Overlay Planes." Think of them like physical slots in a projector.

* **Plane 0:** Usually the "Primary" plane (your 3D game).
* **Plane 1:** An "Overlay" plane (your 2D UI).
* **The Hardware:** The GPU merges these planes at the very last microsecond before the signal hits the HDMI cable.

### 2. Implementation Steps (The Low-Level Flow)

#### Step A: Discovery

First, you must query the physical device to see how many planes it supports and which ones are currently "free."

* Use `vkGetPhysicalDeviceDisplayPlanePropertiesKHR` to get a list of planes.
* Use `vkGetDisplayPlaneSupportedDisplaysKHR` to ensure the plane can actually "talk" to the monitor you are using.

#### Step B: Plane Binding

When you create your **Swapchain** for the UI, you don't just target a surface; you target a specific **Plane** and **Display Mode**.

* In your `VkSwapchainCreateInfoKHR`, you typically use platform-specific extensions (like `VK_KHR_display`) to bind the swapchain to a plane index.
* You must specify the **Z-order** (which plane is on top) and the **Alpha Blending** mode (usually `VK_DISPLAY_PLANE_ALPHA_GLOBAL_BIT_KHR` or `PER_PIXEL`).

#### Step C: The "Two Swapchain" Loop

You will now have **two separate swapchains** running in parallel in your code:

1. **Game Swapchain:** Rendered at 1080p, uses your heavy shaders.
2. **UI Swapchain:** Rendered at 4K (Native), uses a simple shader for icons/text.

```cpp
// Simplified Pseudocode for Presenting Both
VkPresentInfoKHR presentInfo = {};
presentInfo.swapchainCount = 2;
presentInfo.pSwapchains = { gameSwapchain, uiSwapchain };
presentInfo.pImageIndices = { gameIndex, uiIndex };

vkQueuePresentKHR(presentQueue, &presentInfo);

```

### 3. Key Extensions to Look For

Since Vulkan is cross-platform, the exact "how-to" changes depending on the OS:

| Extension | Platform | Purpose |
| --- | --- | --- |
| **`VK_KHR_display`** | Linux / Embedded | The "Standard" way to access raw hardware planes without a Window Manager. |
| **`VK_EXT_display_control`** | Cross-platform | Adds more control over power states and "V-Sync" events for specific planes. |
| **`VK_KHR_incremental_present`** | All | Allows you to tell the compositor only *part* of the UI changed (saves massive bandwidth). |
| **`VK_ANDROID_external_memory_android_hardware_buffer`** | Android | Used for "Hardware Composer" (HWC) integration on phones. |

---

### 4. The "Alpha" Problem

When implementing this, your UI needs a **transparent background**.

* **The Pitfall:** If you use a standard `B8G8R8A8_UNORM` format, the "empty" parts of your UI might show up as black or white, blocking the game.
* **The Fix:** You must ensure the plane is set to **`VK_DISPLAY_PLANE_ALPHA_PER_PIXEL_BIT_KHR`**. This tells the hardware display engine to look at the Alpha channel of every single UI pixel to decide how much of the game "underneath" to show.

### 5. Why do this in Vulkan?

If you are building a custom engine, this is the **gold standard** for performance:

1. **Latency:** The UI has zero "input lag" because it doesn't wait for the game's post-processing to finish.
2. **Power:** The mobile GPU saves energy because it doesn't have to "read back" pixels to blend them.
3. **Visuals:** Your text will be perfectly sharp even if the game is running at  resolution.

When you implement **Composition Layers** (Multiple Swapchains) in Vulkan, you aren't just managing two images; you are managing two different "input contexts."

Handling "Focus" becomes a logic game where your application must decide which layer "owns" the mouse or keyboard at any given millisecond.

---

### 1. The "Invisible" Hit-Test

Since the hardware blends the UI and Game planes together at the display level, the OS doesn't inherently know which one is "on top" for mouse clicks.

* **The Strategy:** Your UI layer should maintain a **Hit-Map** (usually a low-res bitmask or an SDF).
* **The Logic:**
1. When a mouse event occurs, check the coordinates against the UI Hit-Map.
2. If the mouse is over a UI button (Alpha > 0), the UI "Consumes" the event.
3. If the mouse is over an empty area (Alpha = 0), "Forward" the event to the Game logic.



---

### 2. Implementation: Windowing vs. Direct Display

The way you capture these events depends on your Vulkan setup:

#### A. Windowed Mode (Standard PC)

If you are using **GLFW** or **SDL2**, you usually only have **one** OS-level window, even if you have two swapchains.

* **Input Routing:** You receive all events from the single window.
* **Focus State:** You must manually toggle a boolean like `bIsUIFocused`. When `true`, you stop sending "WASD" or "Camera Look" commands to your game engine and only send mouse-click events to your UI library (like ImGui).

#### B. Direct Display / VR (Embedded)

If you are using `VK_KHR_display` (bypassing a window manager), the hardware itself might not provide a "Mouse Pointer."

* **Custom Cursor:** You must render your own cursor as a separate small composition layer (Plane 2).
* **Ray Casting:** Instead of window events, you calculate the "Virtual Mouse" position and perform a 2D intersection check against your UI plane's geometry.

---

### 3. Handling "Focus Lost" (The Edge Cases)

In a multi-layer system, you can run into a "Locked" state. You need to implement **Focus Fallbacks**:

| Event | Action for UI Layer | Action for Game Layer |
| --- | --- | --- |
| **Open Menu (Esc)** | Enable Cursor; Start capturing clicks. | **Pause** logic; Ignore input. |
| **Click Background** | Keep Menu open (usually). | Stay paused. |
| **Close Menu** | Disable Cursor; Hide UI. | **Resume** and "Lock" mouse to center. |

---

### 4. Code Snippet: The Input Wrapper

In your main loop, your event handler should look something like this:

```cpp
void OnMouseMove(int x, int y) {
    // 1. Check if the UI needs the mouse
    if (UIController.IsOverInteractable(x, y)) {
        UIController.UpdateHoverState(x, y);
        // Do NOT send to game
    } else {
        // 2. Otherwise, let the game handle it (e.g., look around)
        GameCamera.UpdateRotation(x, y);
    }
}

```

---

### Summary

Handling focus in Vulkan composition is about **Software Routing**. The hardware is excellent at *showing* the layers, but it is "dumb" when it comes to *interacting* with them. You must build a bridge that checks the Alpha channel of your UI plane to decide who gets to "feel" the user's touch.
