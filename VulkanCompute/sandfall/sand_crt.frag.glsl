#version 450

// CRT Green Terminal Effect with Text Rendering for Sand Simulation
// Renders sand/walls as actual ASCII characters (inspired by https://www.shadertoy.com/view/XdtfzX)

layout(location = 0) in vec2 fragUV;
layout(location = 0) out vec4 outColor;

// Simulation data as storage image
layout(set = 0, binding = 0, r32f) uniform readonly image2D SimMap;

// Font configuration - VT220-style bitmap font
const vec2 FONT_SIZE = vec2(8.0, 12.0);  // Character cell size in pixels
const vec2 TERM_COLS_ROWS = vec2(64.0, 64.0);  // Terminal grid size

// CRT phosphor green
const vec3 PHOSPHOR_GREEN = vec3(0.2, 1.0, 0.3);
const vec3 PHOSPHOR_AMBER = vec3(1.0, 0.6, 0.1);  // For walls

// Hash for pseudo-random character selection
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// Line segment drawing for font (from reference shader)
float roundLine(vec2 p, vec2 a, vec2 b) {
    b -= a;
    p -= a;
    float h = clamp(dot(p, b) / dot(b, b), 0.0, 1.0);
    return smoothstep(1.2, 0.4, length(p - b * h));
}

// Macro for horizontal line segments
#define HL(y, x1, x2) roundLine(p, vec2(float(x1), float(y)), vec2(float(x2), float(y)))
#define VL(x, y1, y2) roundLine(p, vec2(float(x), float(y1)), vec2(float(x), float(y2)))

// Simplified ASCII font renderer - renders common characters
// p is in 0-8 x 0-12 space
float renderChar(vec2 p, int charCode) {
    if (charCode < 32) return 0.0;
    
    // '#' - Hash/number sign (for sand)
    if (charCode == 35) {
        return HL(3, 1, 7) + HL(8, 1, 7) + VL(2, 1, 11) + VL(6, 1, 11);
    }
    // '@' - At sign (dense, for walls)
    if (charCode == 64) {
        return HL(2, 2, 6) + HL(10, 2, 6) + VL(1, 3, 9) + VL(7, 3, 9) +
               HL(5, 4, 6) + HL(7, 4, 6) + VL(5, 5, 7) + VL(3, 5, 8);
    }
    // '*' - Asterisk (for falling sand)
    if (charCode == 42) {
        return HL(6, 2, 6) + VL(4, 3, 9) + 
               roundLine(p, vec2(2, 4), vec2(6, 8)) + 
               roundLine(p, vec2(6, 4), vec2(2, 8));
    }
    // '.' - Period (for background)
    if (charCode == 46) {
        float d = length(p - vec2(4, 2));
        return smoothstep(1.5, 0.5, d);
    }
    // 'O' - Letter O (for walls)
    if (charCode == 79) {
        return HL(1, 2, 6) + HL(11, 2, 6) + VL(1, 2, 10) + VL(7, 2, 10);
    }
    // 'X' - Letter X (for walls)
    if (charCode == 88) {
        return roundLine(p, vec2(1, 1), vec2(7, 11)) + 
               roundLine(p, vec2(7, 1), vec2(1, 11));
    }
    // '%' - Percent (for sand variation)
    if (charCode == 37) {
        float d1 = length(p - vec2(2, 9));
        float d2 = length(p - vec2(6, 3));
        return smoothstep(2.0, 1.0, d1) + smoothstep(2.0, 1.0, d2) +
               roundLine(p, vec2(6, 10), vec2(2, 2));
    }
    // '=' - Equals (for horizontal lines)
    if (charCode == 61) {
        return HL(4, 1, 7) + HL(8, 1, 7);
    }
    // '+' - Plus
    if (charCode == 43) {
        return HL(6, 1, 7) + VL(4, 2, 10);
    }
    // ':' - Colon (for sparse areas)
    if (charCode == 58) {
        float d1 = length(p - vec2(4, 3));
        float d2 = length(p - vec2(4, 9));
        return smoothstep(1.5, 0.5, d1) + smoothstep(1.5, 0.5, d2);
    }
    // Block character (solid)
    if (charCode == 219) {
        if (p.x > 0.5 && p.x < 7.5 && p.y > 0.5 && p.y < 11.5) {
            return 1.0;
        }
        return 0.0;
    }
    
    return 0.0;
}

// Select character based on simulation value and position
int selectChar(float simVal, vec2 cellID) {
    float r = hash(cellID);
    
    if (simVal > 0.9) {
        // SAND - use sand-like characters
        int sandChars[4] = int[4](35, 42, 37, 43);  // #, *, %, +
        int idx = int(r * 4.0) % 4;
        return sandChars[idx];
    }
    else if (simVal > 0.4) {
        // WALL - use solid/block characters
        int wallChars[4] = int[4](64, 79, 88, 219);  // @, O, X, block
        int idx = int(r * 4.0) % 4;
        return wallChars[idx];
    }
    else {
        // BACKGROUND - occasional dots
        if (r > 0.95) {
            return 46;  // .
        }
        return 32;  // space
    }
}

// CRT curvature
vec2 crtCurvature(vec2 uv) {
    vec2 curved = uv * 2.0 - 1.0;
    float curvature = 0.02;
    curved *= 1.0 + curvature * (curved.x * curved.x + curved.y * curved.y);
    return curved * 0.5 + 0.5;
}

// Scanlines
float scanlines(float y, float height) {
    return 0.9 + 0.1 * sin(y * height * 3.14159);
}

// Vignette
float vignette(vec2 uv) {
    vec2 center = uv - 0.5;
    return 1.0 - dot(center, center) * 0.5;
}

void main() {
    // Apply CRT curvature
    vec2 uv = crtCurvature(fragUV);
    
    // Outside screen bounds
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        outColor = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }
    
    // Get simulation dimensions
    ivec2 simSize = imageSize(SimMap);
    
    // Calculate terminal grid position
    vec2 termUV = uv * TERM_COLS_ROWS;
    vec2 cellID = floor(termUV);
    vec2 cellUV = fract(termUV) * FONT_SIZE;
    
    // Map terminal cell back to simulation coordinate
    ivec2 simCoord = ivec2((cellID / TERM_COLS_ROWS) * vec2(simSize));
    simCoord = clamp(simCoord, ivec2(0), simSize - 1);
    float simVal = imageLoad(SimMap, simCoord).r;
    
    // Select and render character
    int charCode = selectChar(simVal, cellID);
    float charIntensity = renderChar(cellUV, charCode);
    
    // Choose color based on element type
    vec3 charColor;
    if (simVal > 0.9) {
        charColor = PHOSPHOR_GREEN;
    } else if (simVal > 0.4) {
        charColor = PHOSPHOR_AMBER;
    } else {
        charColor = PHOSPHOR_GREEN * 0.5;
    }
    
    // Apply effects
    float scan = scanlines(uv.y, float(simSize.y));
    float vig = vignette(uv);
    
    vec3 color = charColor * charIntensity * scan * vig;
    
    // Add slight background glow
    color += vec3(0.01, 0.03, 0.01);
    
    // Add phosphor bloom for bright characters
    if (charIntensity > 0.5) {
        color += charColor * 0.1;
    }
    
    outColor = vec4(color, 1.0);
}
