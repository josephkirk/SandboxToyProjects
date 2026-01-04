---
title: "Building Real-Time Global Illumination: Radiance Cascades"
scripts:
  - https://cdnjs.cloudflare.com/ajax/libs/three.js/r134/three.min.js
#  - https://cdn.jsdelivr.net/npm/spectorjs@0.9.30/dist/spector.bundle.js
head: '
  <link rel="stylesheet" href="../css/mdxish.css">
  <link rel="stylesheet" href="../css/prism.css">
  <meta charset="UTF-8">
  <meta name="description" content="An interactive walkthrough of implementing radiance cascades, a technique for real-time noiseless global illumination.">
  <meta name="og:description" content="An interactive walkthrough of implementing radiance cascades, a technique for real-time noiseless global illumination.">
  <meta name="twitter:card" content="summary_large_image">
  <meta property="og:title" content="Building Real-Time Global Illumination: Radiance Cascades">
  <meta property="og:type" content="website">
  <meta property="og:url" content="https://jason.today/rc">
  <meta property="og:image" content="https://jason.today/img/rc-preview-social.png">
  <script src="../js/three.js"></script>
  <script src="../js/prism.js"></script>
  <style>
  button { border: none; cursor: pointer; }
  .color { max-width: 20px; width: 20px; height: 20px; position: relative; }
  canvas { image-rendering: pixelated; }
  .iconButton {
    margin-left: -1px;
    padding: 0;
    width: 24px;
    height: 24px;
    padding-top: 4px;
  }
  .erase { position: absolute;  top: 2px; left: 1px; }
  .arrow { border: none; position: absolute;  top: 0; left: -17px; cursor: auto; color: var(--article-text-color); }
  .hidden { display: none; }
  </style>
'
---

[//]: # (Note to markdown source readers - I tend to put a bunch of code up front - Just scroll down to the first `#` for the title / start of the post.)

```javascript
// @run
// var spector = new SPECTOR.Spector();
// spector.displayUI();

class GPUTimer {
  constructor(renderer, disabled = false) {
    this.gl = renderer.getContext();
    this.ext = !disabled && this.gl.getExtension('EXT_disjoint_timer_query_webgl2');
    if (!this.ext) {
      console.warn('EXT_disjoint_timer_query_webgl2 not available');
    }
    this.queries = new Map();
    this.results = new Map();
    this.lastPrintTime = Date.now();
    this.printInterval = 1000; // 10 seconds

  }

  start(id) {
    if (!this.ext) return;
    const query = this.gl.createQuery();
    this.gl.beginQuery(this.ext.TIME_ELAPSED_EXT, query);
    if (!this.queries.has(id)) {
      this.queries.set(id, []);
    }
    this.queries.get(id).push(query);
  }

  end(id) {
    if (!this.ext) return;
    this.gl.endQuery(this.ext.TIME_ELAPSED_EXT);
  }

  update() {
    if (!this.ext) return;
    for (const [id, queryList] of this.queries) {
      const completedQueries = [];
      for (let i = queryList.length - 1; i >= 0; i--) {
        const query = queryList[i];
        const available = this.gl.getQueryParameter(query, this.gl.QUERY_RESULT_AVAILABLE);
        const disjoint = this.gl.getParameter(this.ext.GPU_DISJOINT_EXT);

        if (available && !disjoint) {
          const timeElapsed = this.gl.getQueryParameter(query, this.gl.QUERY_RESULT);
          const timeMs = timeElapsed / 1000000; // Convert nanoseconds to milliseconds

          if (!this.results.has(id)) {
            this.results.set(id, []);
          }
          this.results.get(id).push(timeMs);

          completedQueries.push(query);
          queryList.splice(i, 1);
        }
      }

      // Clean up completed queries
      completedQueries.forEach(query => this.gl.deleteQuery(query));
    }

    // Check if it's time to print results
    const now = Date.now();
    if (now - this.lastPrintTime > this.printInterval) {
      this.printAverages();
      this.lastPrintTime = now;
    }
  }

  printAverages() {
    if (!this.ext) return;
    console.log('--- GPU Timing Averages ---');
    for (const [id, times] of this.results) {
      if (times.length > 0) {
        const avg = times.reduce((a, b) => a + b, 0) / times.length;
        console.log(`${id}: ${avg.toFixed(2)}ms (${times.length} samples)`);
      }
    }
    console.log('---------------------------');
  }
}

const isMobile = (() => {
  return /Android|webOS|iPhone|iPad|iPod|BlackBerry|IEMobile|Opera Mini/i.test(navigator.userAgent)
    || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
})();

const vertexShader = `
varying vec2 vUv;
void main() {
    vUv = uv;
    gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
}`;

const resetSvg = `<svg  xmlns="http://www.w3.org/2000/svg"  width="16"  height="16"  viewBox="0 0 24 24"  fill="none"  stroke="currentColor"  stroke-width="1"  stroke-linecap="round"  stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M20 11a8.1 8.1 0 0 0 -15.5 -2m-.5 -4v4h4" /><path d="M4 13a8.1 8.1 0 0 0 15.5 2m.5 4v-4h-4" /></svg>`;

const eraseSvg = `<svg  xmlns="http://www.w3.org/2000/svg"  width="16"  height="16"  viewBox="0 0 24 24"  fill="none"  stroke="currentColor"  stroke-width="1"  stroke-linecap="round"  stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M19 20h-10.5l-4.21 -4.3a1 1 0 0 1 0 -1.41l10 -10a1 1 0 0 1 1.41 0l5 5a1 1 0 0 1 0 1.41l-9.2 9.3" /><path d="M18 13.3l-6.3 -6.3" /></svg>`;

const clearSvg = `<svg  xmlns="http://www.w3.org/2000/svg"  width="16"  height="16"  viewBox="0 0 24 24"  fill="none"  stroke="currentColor"  stroke-width="1"  stroke-linecap="round"  stroke-linejoin="round"  class="icon icon-tabler icons-tabler-outline icon-tabler-trash"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M4 7l16 0" /><path d="M10 11l0 6" /><path d="M14 11l0 6" /><path d="M5 7l1 12a2 2 0 0 0 2 2h8a2 2 0 0 0 2 -2l1 -12" /><path d="M9 7v-3a1 1 0 0 1 1 -1h4a1 1 0 0 1 1 1v3" /></svg>`;

const sunMoonSvg = `<svg  xmlns="http://www.w3.org/2000/svg"  width="16"  height="16"  viewBox="0 0 24 24"  fill="none"  stroke="currentColor"  stroke-width="1"  stroke-linecap="round"  stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M9.173 14.83a4 4 0 1 1 5.657 -5.657" /><path d="M11.294 12.707l.174 .247a7.5 7.5 0 0 0 8.845 2.492a9 9 0 0 1 -14.671 2.914" /><path d="M3 12h1" /><path d="M12 3v1" /><path d="M5.6 5.6l.7 .7" /><path d="M3 21l18 -18" /></svg>`

function hexToRgb(hex) {
  const result = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})?$/i.exec(hex);
  return result ? {
    r: parseInt(result[1], 16),
    g: parseInt(result[2], 16),
    b: parseInt(result[3], 16),
    a: result[4] ? parseInt(result[4], 16) : 255,
  } : null;
}

function rgbToHex(r, g, b, a) {
  if (a !== undefined) {
    return "#" + ((1 << 24) + (r << 16) + (g << 8) + b).toString(16).slice(1) +
      Math.round(a * 255).toString(16).padStart(2, '0');
  }
  return "#" + ((1 << 24) + (r << 16) + (g << 8) + b).toString(16).slice(1);
}

// This is the html plumbing / structure / controls for little canvases
function intializeCanvas({
 id, canvas, onSetColor, startDrawing, onMouseMove, stopDrawing, clear, reset, toggleSun, colors = [
    "#fff6d3", "#f9a875", "#eb6b6f", "#7c3f58", "#03C4A1", "#3d9efc", "#000000", "#00000000"
  ]
}) {
  const clearDom = clear ? `<button id="${id}-clear" class="iconButton">${clearSvg}</button>` : "";
  const resetDom = reset ? `<button id="${id}-reset" class="iconButton">${resetSvg}</button>` : "";
  const sunMoonDom = toggleSun ? `<button id="${id}-sun" class="iconButton">${sunMoonSvg}</button>` : "";
  const thisId = document.querySelector(`#${id}`);
  thisId.innerHTML = `
  <div style="display: flex; gap: 20px;">
    <div id="${id}-canvas-container"></div>

    <div style="display: flex; flex-direction: column; justify-content: space-between;">
        <div id="${id}-color-picker" style="display: flex; flex-direction: column;  border: solid 1px white; margin: 1px;">
          <input type="color" id="${id}-color-input" value="#eb6b6f" style="display: none; width: 0px" >
      </div>
      <div style="display: flex; flex-direction: column; gap: 2px">
      ${sunMoonDom}
      ${clearDom}
      ${resetDom}
      </div>
    </div>
</div>`;
  const colorInput = document.getElementById(`${id}-color-input`);

  function setColor(r, g, b, a) {
    colorInput.value = rgbToHex(r, g, b, a);
    onSetColor({r, g, b, a});
  }

  function setHex(hex) {
    const rgb = hexToRgb(hex);
    setColor(rgb.r, rgb.g, rgb.b, rgb.a);
    const stringifiedColor = `rgb(${rgb.r}, ${rgb.g}, ${rgb.b})`;
    thisId.querySelectorAll(".arrow").forEach((node) => {
      if (rgb.a === 0) {
        if (node.parentNode.style.backgroundColor === "var(--pre-background)") {
          node.className = "arrow";
        } else {
          node.className = "arrow hidden";
        }
      } else if (node.parentNode.style.backgroundColor === stringifiedColor) {
        node.className = "arrow";
      } else {
        node.className = "arrow hidden";
      }
    });
  }

  function updateColor(event) {
    const hex = event.target.value;
    setHex(hex);
  }

  colorInput.addEventListener('input', updateColor);

  const colorPicker = document.querySelector(`#${id}-color-picker`);

  colors.forEach((color, i) => {
    const colorButton = document.createElement("button");
    colorButton.className = "color";
    colorButton.style.backgroundColor = color;
    colorButton.innerHTML = `<span class="arrow hidden">&#9654;</span>`;
    if (color === "#00000000") {
      colorButton.innerHTML += `<span class="erase">${eraseSvg}</span>`;
      colorButton.style.backgroundColor = "var(--pre-background)";
    }
    colorPicker.appendChild(colorButton);
    colorButton.addEventListener('click', () => setHex(color));
  });
  const container = document.querySelector(`#${id}-canvas-container`);
  container.appendChild(canvas);

  canvas.addEventListener('touchstart', startDrawing);
  canvas.addEventListener('mousedown', startDrawing);
  canvas.addEventListener('mouseenter', (e) => {
    if (e.buttons === 1) {
      startDrawing(e);
    }
  });
  canvas.addEventListener('mousemove', onMouseMove);
  canvas.addEventListener('touchmove', onMouseMove);
  canvas.addEventListener('mouseup', (e) => stopDrawing(e, false));
  canvas.addEventListener('touchend', (e) => stopDrawing(e, false));
  canvas.addEventListener('touchcancel', (e) => stopDrawing(e, true));
  canvas.addEventListener('mouseleave', (e) => stopDrawing(e, true));

  if (clear) {
    document.querySelector(`#${id}-clear`).addEventListener("click", () => {
      clear();
    });
  }

  if (reset) {
    document.querySelector(`#${id}-reset`).addEventListener("click", () => {
      reset();
    });
  }

  if (toggleSun) {
    document.querySelector(`#${id}-sun`).addEventListener("click", (e) => {
      toggleSun(e);
    });
  }

  return {container, setHex};
}

// This is the JS side that connects our canvas to three.js, and adds drawing on mobile
// Also deals with interaction (mouse / touch) logic
class PaintableCanvas {
  constructor({width, height, initialColor = 'transparent', radius = 6, friction = 0.1}) {

    this.isDrawing = false;
    this.currentMousePosition = { x: 0, y: 0 };
    this.lastPoint = { x: 0, y: 0 };
    this.currentPoint = { x: 0, y: 0 };

    this.mouseMoved = false;
    this.currentColor = {r: 255, g: 255, b: 255, a: 255};
    this.RADIUS = radius;
    this.FRICTION = friction;
    this.width = width;
    this.height = height;

    this.initialColor = initialColor;

    if (this.useFallbackCanvas()) {
      [this.canvas, this.context] = this.createCanvas(width, height, initialColor);
      this.texture = new THREE.CanvasTexture(this.canvas);
      this.setupTexture(this.texture);
      this.currentImageData = new ImageData(this.canvas.width, this.canvas.height);
    }
    this.onUpdateTextures = () => {
    };

    this.drawSmoothLine = (from, to) => {
      throw new Error("Missing implementation");
    }
  }

  useFallbackCanvas() {
    return false;
  }

  // Mobile breaks in all kinds of ways
  // Drawing on cpu fixes most of the issues
  drawSmoothLineFallback(from, to) {
    this.drawLine(from, to, this.currentColor, this.context);
    this.updateTexture();
  }

  drawLine(from, to, color, context) {
    const radius = this.RADIUS;

    // Ensure we're within canvas boundaries
    const left = 0;
    const top = 0;
    const right = context.canvas.width - 1;
    const bottom = context.canvas.height - 1;

    let width = right - left + 1;
    let height = bottom - top + 1;

    let imageData = this.currentImageData;
    let data = imageData.data;

    // Bresenham's line algorithm
    let x0 = Math.round(from.x - left);
    let y0 = Math.round(from.y - top);
    let x1 = Math.round(to.x - left);
    let y1 = Math.round(to.y - top);

    let dx = Math.abs(x1 - x0);
    let dy = Math.abs(y1 - y0);
    let sx = (x0 < x1) ? 1 : -1;
    let sy = (y0 < y1) ? 1 : -1;
    let err = dx - dy;

    while (true) {
      // Draw the pixel and its surrounding pixels
      this.drawCircle(x0, y0, color, radius);

      if (x0 === x1 && y0 === y1) break;
      let e2 = 2 * err;
      if (e2 > -dy) {
        err -= dy;
        x0 += sx;
      }
      if (e2 < dx) {
        err += dx;
        y0 += sy;
      }
    }

    // Put the modified image data back to the canvas
    context.putImageData(imageData, left, top);
  }

  drawCircle(x0, y0, color, radius) {
    for (let ry = -radius; ry <= radius; ry++) {
      for (let rx = -radius; rx <= radius; rx++) {
        if (rx * rx + ry * ry <= radius * radius) {
          let x = x0 + rx;
          let y = y0 + ry;
          if (x >= 0 && x < this.width && y >= 0 && y < this.height) {
            this.setPixel(x, y, color);
          }
        }
      }
    }
  }

  setPixel(x, y, color) {
    let index = (y * this.width + x) * 4;
    this.currentImageData.data[index] = color.r;     // Red
    this.currentImageData.data[index + 1] = color.g; // Green
    this.currentImageData.data[index + 2] = color.b; // Blue
    this.currentImageData.data[index + 3] = color.a;   // Alpha
  }

  createCanvas(width, height, initialColor) {
    const canvas = document.createElement('canvas');
    canvas.width = width;
    canvas.height = height;
    const context = canvas.getContext('2d');
    context.fillStyle = initialColor;
    context.fillRect(0, 0, canvas.width, canvas.height);
    // canvas.style.width = `${width / 2}px`;
    // canvas.style.height = `${height / 2}px`;
    return [canvas, context];
  }

  setupTexture(texture) {
    texture.minFilter = THREE.NearestFilter;
    texture.magFilter = THREE.NearestFilter;
    texture.format = THREE.RGBAFormat;
    texture.type = true ? THREE.HalfFloatType : THREE.FloatType;
    texture.wrapS = THREE.ClampToEdgeWrapping;
    texture.wrapT = THREE.ClampToEdgeWrapping
    texture.generateMipmaps = true;
  }

  updateTexture() {
    this.texture.needsUpdate = true;
    this.onUpdateTextures();
  }

  startDrawing(e) {
    this.isDrawing = true;
    this.currentMousePosition = this.lastPoint = this.currentPoint = this.getMousePos(e);
    try {
      this.onMouseMove(e);
    } catch(e) {
      console.error(e);
    }
    this.mouseMoved = false;
  }

  stopDrawing(e, redraw) {
    const wasDrawing = this.isDrawing;
    if (!wasDrawing) {
      return false;
    }
    if (!this.mouseMoved) {
      this.drawSmoothLine(this.currentPoint, this.currentPoint);
    } else if (redraw) {
      this.drawSmoothLine(this.currentPoint, this.getMousePos(e));
    }
    this.isDrawing = false;
    this.mouseMoved = false;
    return true;
  }

  onMouseMove(event) {
    if (!this.isDrawing) {
      this.currentMousePosition = this.lastPoint = this.currentPoint = this.getMousePos(event);
      return false;
    } else {
      this.currentMousePosition = this.getMousePos(event);
    }

    this.mouseMoved = true;

    this.doDraw();

    return true;
  }

  doDraw() {
    const newPoint = this.currentMousePosition;

    // Some smoothing...
    let dist = this.distance(this.currentPoint, newPoint);

    if (dist > 0) {
      let dir = {
        x: (newPoint.x - this.currentPoint.x) / dist,
        y: (newPoint.y - this.currentPoint.y) / dist
      };
      let len = Math.max(dist - this.RADIUS, 0);
      let ease = 1 - Math.pow(this.FRICTION, 1 / 60 * 10);
      this.currentPoint = {
        x: this.currentPoint.x + dir.x * len * ease,
        y: this.currentPoint.y + dir.y * len * ease
      };
    } else {
      this.currentPoint = newPoint;
    }

    this.drawSmoothLine(this.lastPoint, this.currentPoint);
    this.lastPoint = this.currentPoint;
  }

  // I'll be honest - not sure why I can't just use `clientX` and `clientY`
  // Must have made a weird mistake somewhere.
  getMousePos(e) {
    e.preventDefault();

    const {width, height} = e.target.style;
    const [dx, dy] = [
      (width ? this.width / parseInt(width) : 1.0),
      (height ? this.height / parseInt(height) : 1.0),
    ];

    if (e.touches) {
      return {
        x: (e.touches[0].clientX - (e.touches[0].target.offsetLeft - window.scrollX)) * dx,
        y: (e.touches[0].clientY - (e.touches[0].target.offsetTop - window.scrollY)) * dy
      };
    }

    return {
      x: (e.clientX - (e.target.offsetLeft - window.scrollX)) * dx,
      y: (e.clientY - (e.target.offsetTop - window.scrollY)) * dy
    };
  }

  distance(p1, p2) {
    return Math.sqrt(Math.pow(p2.x - p1.x, 2) + Math.pow(p2.y - p1.y, 2));
  }

  setColor(r, g, b, a) {
    this.currentColor = {r, g, b, a};
  }

  clear() {
    this.context.clearRect(0, 0, this.canvas.width, this.canvas.height);
    this.currentImageData = new ImageData(this.canvas.width, this.canvas.height);
    this.updateTexture();
  }
}

function threeJSInit(width, height, materialProperties, renderer = null, renderTargetOverrides = {}, makeRenderTargets = undefined, extra = {}) {
  const scene = new THREE.Scene();
  const camera = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);
  const dpr = extra.dpr || window.devicePixelRatio || 1;

  if (!renderer) {
    renderer = new THREE.WebGLRenderer({
      antialiasing: false,
      powerPreference: "high-performance"
      // powerPreference: "low-power",
    });
    renderer.setPixelRatio(dpr);
  }
  renderer.setSize(width, height);
  const renderTargetProps = {
    minFilter: THREE.NearestFilter,
    magFilter: THREE.NearestFilter,
    type: !document.querySelector("#full-precision")?.checked ? THREE.HalfFloatType : THREE.FloatType,
    format: THREE.RGBAFormat,
    wrapS: THREE.ClampToEdgeWrapping,
    wrapT: THREE.ClampToEdgeWrapping,
    ...renderTargetOverrides,
  };

  const geometry = new THREE.PlaneGeometry(2, 2);
  const material = new THREE.ShaderMaterial({
    depthTest: false,
    depthWrite: false,
    glslVersion: THREE.GLSL3,
    ...materialProperties,
  });
  plane = new THREE.Mesh(geometry, material);
  scene.add(plane);

  return {
    plane,
    canvas: renderer.domElement,
    render: () => {
      renderer.render(scene, camera)
    },
    renderTargets: makeRenderTargets ? makeRenderTargets(
      { width, height, renderer, renderTargetProps}
    ) : (() => {
      const renderTargetA = new THREE.WebGLRenderTarget(extra?.width ?? width, extra?.height ?? height, renderTargetProps);
      const renderTargetB = renderTargetA.clone();
      return [renderTargetA, renderTargetB];
    })(),
    renderer
  }
}
```

```javascript
// @run
// Let's instrument the post with this so we can disable animations while editing.
const disableAnimation = false;
// Draw animations very fast, with a huge loss in accuracy (for testing)
const instantMode = false;
const getFrame = disableAnimation
  ? (fn) => { fn() }
  : requestAnimationFrame;
```

```javascript
// @run
class BaseSurface {
  constructor({ id, width, height, radius = 5, dpr = 1 }) {
    // Create PaintableCanvas instances
    this.createSurface(width, height, radius);
    this.dpr = dpr || window.devicePixelRatio || 1;
    this.width = width;
    this.height = height;
    this.id = id;
    this.initialized = false;
    this.initialize();
  }

  createSurface(width, height, radius) {
    this.surface = new PaintableCanvas({ width, height, radius });
  }

  initialize() {
    // Child class should fill this out
  }

  load() {
    // Child class should fill this out
  }

  clear() {
    // Child class should fill this out
  }

  renderPass() {
    // Child class should fill this out
  }

  reset() {
    this.clear();
    this.setHex("#fff6d3");
    new Promise((resolve) => {
      getFrame(() => this.draw(0.0, null, resolve));
    });
  }

  draw(t, last, resolve) {
    if (t >= 10.0) {
      resolve();
      return;
    }

    const angle = (t * 0.05) * Math.PI * 2;

    const {x, y} = {
      x: 100 + 100 * Math.sin(angle + 0.25) * Math.cos(angle * 0.15),
      y: 50 + 100 * Math.sin(angle * 0.7)
    };

    last ??= {x, y};

    this.surface.drawSmoothLine(last, {x, y});
    last = {x, y};

    const step = instantMode ? 5.0 : 0.2;
    getFrame(() => this.draw(t + step, last, resolve));
  }

  buildCanvas() {
    return intializeCanvas({
      id: this.id,
      canvas: this.canvas,
      onSetColor: ({r, g, b, a}) => {
        this.surface.currentColor = {r, g, b, a};
        this.plane.material.uniforms.color.value = new THREE.Vector4(
          this.surface.currentColor.r / 255.0,
          this.surface.currentColor.g / 255.0,
          this.surface.currentColor.b / 255.0,
          this.surface.currentColor.a != null
              ? this.surface.currentColor.a / 255.0
            : 1.0,
        );
      },
      startDrawing: (e) => this.surface.startDrawing(e),
      onMouseMove: (e) => this.surface.onMouseMove(e),
      stopDrawing: (e, redraw) => this.surface.stopDrawing(e, redraw),
      clear: () => this.clear(),
      reset: () => this.reset(),
      ...this.canvasModifications()
    });
  }

  canvasModifications() {
    return {}
  }

  observe() {
    const observer = new IntersectionObserver((entries) => {
      if (entries[0].isIntersecting === true) {
        this.load();
        observer.disconnect(this.container);
      }
    });

    observer.observe(this.container);
  }

  initThreeJS({ uniforms, fragmentShader, renderTargetOverrides, makeRenderTargets, ...rest }) {
    return threeJSInit(this.width, this.height, {
      uniforms,
      fragmentShader,
      vertexShader,
      transparent: false,
    }, this.renderer, renderTargetOverrides ?? {}, makeRenderTargets, rest)
  }
}

class Drawing extends BaseSurface {
  initializeSmoothSurface() {
    const props = this.initThreeJS({
      uniforms: {
        inputTexture: { value: this.surface.texture },
        color: {value: new THREE.Vector4(1, 1, 1, 1)},
        from: {value: new THREE.Vector2(0, 0)},
        to: {value: new THREE.Vector2(0, 0)},
        radiusSquared: {value: Math.pow(this.surface.RADIUS, 2.0)},
        resolution: {value: new THREE.Vector2(this.width, this.height)},
        drawing: { value: false },
        indicator: { value: false },
      },
      fragmentShader: `
uniform sampler2D inputTexture;
uniform vec4 color;
uniform vec2 from;
uniform vec2 to;
uniform float radiusSquared;
uniform vec2 resolution;
uniform bool drawing;
uniform bool indicator;
varying vec2 vUv;

out vec4 FragColor;

float sdfLineSquared(vec2 p, vec2 from, vec2 to) {
  vec2 toStart = p - from;
  vec2 line = to - from;
  float lineLengthSquared = dot(line, line);
  float t = clamp(dot(toStart, line) / lineLengthSquared, 0.0, 1.0);
  vec2 closestVector = toStart - line * t;
  return dot(closestVector, closestVector);
}

void main() {
vec4 current = texture(inputTexture, vUv, 0.0);
if (drawing) {
  vec2 coord = vUv * resolution;
  float distSquared = sdfLineSquared(coord, from, to);
  if (distSquared <= radiusSquared) {
    if (!indicator || color.a > 0.1) {
      current = color;
    }
  } else if (color.a < 0.1 && indicator && distSquared <= (radiusSquared * 1.5)) {
    current = vec4(1.0);
  } else if (length(current.rgb) < 0.1 && indicator && distSquared <= (radiusSquared + 6.0)) {
    // Draw a thin white outline
    current = vec4(1.0);
  }

}

FragColor = current;
}`,
    });

    if (this.surface.useFallbackCanvas()) {
      this.surface.drawSmoothLine = (from, to) => {
        this.surface.drawSmoothLineFallback(from, to);
      }
      this.surface.onUpdateTextures = () => {
        this.renderPass();
      }
    } else {
      this.surface.drawSmoothLine = (from, to) => {
        props.plane.material.uniforms.drawing.value = true;
        props.plane.material.uniforms.from.value = {
          ...from, y: this.height - from.y
        };
        props.plane.material.uniforms.to.value = {
          ...to, y: this.height - to.y
        };
        this.triggerDraw();
        props.plane.material.uniforms.drawing.value = false;
      }
    }

    return props;
  }

  triggerDraw() {
    this.renderPass();
  }

  clear() {
    if (this.surface.useFallbackCanvas()) {
      this.surface.clear();
      return;
    }
    if (this.initialized) {
      this.renderTargets.forEach((target) => {
        this.renderer.setRenderTarget(target);
        this.renderer.clearColor();
      });
    }
    this.renderer.setRenderTarget(null);
    this.renderer.clearColor();
  }

  initialize() {
    const {
      plane, canvas, render, renderer, renderTargets
    } = this.initializeSmoothSurface();
    this.canvas = canvas;
    this.plane = plane;
    this.render = render;
    this.renderer = renderer;
    this.renderTargets = renderTargets;
    const { container, setHex } = this.buildCanvas();
    this.container = container;
    this.setHex = setHex;
    this.renderIndex = 0;

    this.innerInitialize();

    this.observe();
  }

  innerInitialize() {

  }

  load() {
    this.reset();
    this.initialized = true;
  }

  drawPass() {
    if (this.surface.useFallbackCanvas()) {
      return this.surface.texture;
    } else {
        this.plane.material.uniforms.inputTexture.value = this.renderTargets[this.renderIndex].texture;
        this.renderIndex = 1 - this.renderIndex;
        this.renderer.setRenderTarget(this.renderTargets[this.renderIndex]);
        this.render();
        return this.renderTargets[this.renderIndex].texture;
    }
  }

  renderPass() {
    this.drawPass()
    this.renderer.setRenderTarget(null);
    this.render();
  }
}

```

```javascript
// @run
class JFA extends Drawing {
  innerInitialize() {
    // _should_ be ceil.
    this.passes = Math.ceil(Math.log2(Math.max(this.width, this.height)));

    const {plane: seedPlane, render: seedRender, renderTargets: seedRenderTargets} = this.initThreeJS({
      uniforms: {
        surfaceTexture: {value: null},
      },
      fragmentShader: `
        precision highp float;
        uniform sampler2D surfaceTexture;
        out vec4 FragColor;

        in vec2 vUv;

        void main() {
          float alpha = texture(surfaceTexture, vUv).a;
          FragColor = vec4(vUv * ceil(alpha), 0.0, 1.0);
        }`,
    });

    const {plane: jfaPlane, render: jfaRender, renderTargets: jfaRenderTargets} = this.initThreeJS({
      uniforms: {
        inputTexture: {value: null},
        oneOverSize: {value: new THREE.Vector2(1.0 / this.width, 1.0 / this.height)},
        uOffset: {value: Math.pow(2, this.passes - 1)},
        direction: {value: 0},
        skip: {value: true},
      },
      fragmentShader: `
precision highp float;
uniform vec2 oneOverSize;
uniform sampler2D inputTexture;
uniform float uOffset;
uniform int direction;
uniform bool skip;

in vec2 vUv;
out vec4 FragColor;

void classic() {
  if (skip) {
    FragColor = vec4(vUv, 0.0, 1.0);
  } else {
    vec4 nearestSeed = vec4(0.0);
    float nearestDist = 999999.9;

    for (float y = -1.0; y <= 1.0; y += 1.0) {
      for (float x = -1.0; x <= 1.0; x += 1.0) {
        vec2 sampleUV = vUv + vec2(x, y) * uOffset * oneOverSize;

        // Check if the sample is within bounds
        if (sampleUV.x < 0.0 || sampleUV.x > 1.0 || sampleUV.y < 0.0 || sampleUV.y > 1.0) { continue; }

          vec4 sampleValue = texture(inputTexture, sampleUV);
          vec2 sampleSeed = sampleValue.xy;

          if (sampleSeed.x != 0.0 || sampleSeed.y != 0.0) {
            vec2 diff = sampleSeed - vUv;
            float dist = dot(diff, diff);
            if (dist < nearestDist) {
              nearestDist = dist;
              nearestSeed.xy = sampleValue.xy;
            }
          }
      }
    }

    FragColor = nearestSeed;
  }
}

void main() {
  classic();
}
`
    });

    this.seedPlane = seedPlane;
    this.seedRender = seedRender;
    this.seedRenderTargets = seedRenderTargets;

    this.jfaPlane = jfaPlane;
    this.jfaRender = jfaRender;
    this.jfaRenderTargets = jfaRenderTargets;
  }

  seedPass(inputTexture) {
    this.seedPlane.material.uniforms.surfaceTexture.value = inputTexture;
    this.renderer.setRenderTarget(this.seedRenderTargets[0]);
    this.seedRender();
    return this.seedRenderTargets[0].texture;
  }

  jfaPass(inputTexture) {
    let currentInput = inputTexture;
    let [renderA, renderB] = this.jfaRenderTargets;
    let currentOutput = renderA;
    this.jfaPlane.material.uniforms.skip.value = true;
    let passes = this.passes;

    for (let i = 0; i < passes || (passes === 0 && i === 0); i++) {
      this.jfaPlane.material.uniforms.skip.value = passes === 0;
      this.jfaPlane.material.uniforms.inputTexture.value = currentInput;
      // This intentionally uses `this.passes` which is the true value
      // In order to properly show stages using the JFA slider.
      this.jfaPlane.material.uniforms.uOffset.value = Math.pow(2, this.passes - i - 1);
      this.jfaPlane.material.uniforms.direction.value = 0;

      this.renderer.setRenderTarget(currentOutput);
      this.jfaRender();

      currentInput = currentOutput.texture;
      currentOutput = (currentOutput === renderA) ? renderB : renderA;
    }

    return currentInput;
  }

  draw(last, t, isShadow, resolve) {
    if (t >= 10.0) {
      resolve();
      return;
    }

    const angle = (t * 0.05) * Math.PI * 2;

    const {x, y} = isShadow
      ? {
        x: 90 + 12 * t,
        y: 200 + 1 * t,
      }
      : {
        x: 100 + 100 * Math.sin(angle + 0.25) * Math.cos(angle * 0.15),
        y: 50 + 100 * Math.sin(angle * 0.7)
      };

    last ??= {x, y};

    this.surface.drawSmoothLine(last, {x, y});
    last = {x, y};

    const step = instantMode ? 5.0 : (isShadow ? 0.7 : 0.3);
    getFrame(() => this.draw(last, t + step, isShadow, resolve));
  }

  clear() {
    if (this.initialized) {
      this.seedRenderTargets.concat(this.jfaRenderTargets).forEach((target) => {
        this.renderer.setRenderTarget(target);
        this.renderer.clearColor();
      });
    }
    super.clear();
  }

  load() {
    super.load();
    getFrame(() => this.reset());
  }

  renderPass() {
    let out = this.drawPass();
    out = this.seedPass(out);
    out = this.jfaPass(out);
    this.renderer.setRenderTarget(null);
    this.jfaRender();
  }

  reset() {
    this.clear();
    let last = undefined;
    return new Promise((resolve) => {
      this.setHex("#f9a875");
      getFrame(() => this.draw(last, 0, false, resolve));
    }).then(() => new Promise((resolve) => {
      last = undefined;
      getFrame(() => {
        this.setHex("#000000");
        getFrame(() => this.draw(last, 0, true, resolve));
      });
    }))
      .then(() => {
        this.renderPass();
        getFrame(() => this.setHex("#fff6d3"));
      });
  }
}

```

```javascript
// @run
class DistanceField extends JFA {
  jfaPassesCount() {
    return this.passes;
  }

  innerInitialize() {
    super.innerInitialize();

    const {plane: dfPlane, render: dfRender, renderTargets: dfRenderTargets} = this.initThreeJS({
      uniforms: {
        jfaTexture: {value: null},
        surfaceTexture: {value: null},
      },
      fragmentShader: `
      precision highp float;
        uniform sampler2D jfaTexture;
        uniform sampler2D surfaceTexture;

        in vec2 vUv;
        out vec4 FragColor;

        void main() {
          vec2 nearestSeed = texture(jfaTexture, vUv).xy;

          // Clamp by the size of our texture (1.0 in uv space).
          float distance = clamp(
              distance(vUv, nearestSeed), 0.0, 1.0
          );

          // Normalize and visualize the distance
          FragColor = vec4(vec3(distance), 1.0);
        }`,
    });

    this.dfPlane = dfPlane;
    this.dfRender = dfRender;
    this.dfRenderTargets = dfRenderTargets;
  }

  load() {
    this.reset();
    this.initialized = true;
  }

  clear() {
    if (this.initialized) {
      this.dfRenderTargets.forEach((target) => {
        this.renderer.setRenderTarget(target);
        this.renderer.clearColor();
      });
    }
    super.clear();
  }

  dfPass(inputTexture) {
    this.renderer.setRenderTarget(this.dfRenderTargets[0]);
    this.dfPlane.material.uniforms.jfaTexture.value = inputTexture;
    this.dfPlane.material.uniforms.surfaceTexture.value = this.drawPassTexture
      ?? this.surface.texture;
    this.dfRender();
    return this.dfRenderTargets[0].texture;
  }

  renderPass() {
    let out = this.drawPass();
    out = this.seedPass(out);
    out = this.jfaPass(out);
    out = this.dfPass(out);
    this.renderer.setRenderTarget(null);
    this.dfRender();
  }
}

```

```javascript
// @run
class Particle {
  constructor(color, empty = false) {
    this.color = color;
    this.empty = empty;
    this.modified = true;
  }

  update () {
    this.modified = false;
  }

  getUpdateCount() {
    return 0;
  }

  resetVelocity() {
    this.velocity = 0;
  }
}

class MovingParticle extends Particle {
  constructor(color, empty = false) {
    super(color, empty);
    this.color = color;
    this.empty = empty;
    this.maxSpeed = 8;
    this.acceleration = 0.4;
    this.velocity = 0;
    this.modified = true;
  }

  update() {
    if (this.maxSpeed === 0) {
      this.modified = false;
      return;
    }
    this.updateVelocity();
    this.modified = this.velocity > 0.5;
  }

  updateVelocity() {
    let newVelocity = this.velocity + this.acceleration;
    if (Math.abs(newVelocity) > this.maxSpeed) {
      newVelocity = Math.sign(newVelocity) * this.maxSpeed;
    }
    this.velocity = newVelocity;
  }

  resetVelocity() {
    this.velocity = 0;
  }

  getUpdateCount() {
    const abs = Math.abs(this.velocity);
    const floored = Math.floor(abs);
    const mod = abs - floored;
    return floored + (Math.random() < mod ? 1 : 0);
  }
}

class Sand extends MovingParticle {
  constructor(color) {
    super(color);
  }
}

class Solid extends Particle {
  constructor(color) {
    super(color);
    this.maxSpeed = 0;
  }
}

class Empty extends Particle {
  constructor() {
    super({ r: 0, g: 0, b: 0 }, true);
    this.maxSpeed = 0;
  }
}

class FallingSandSurface extends PaintableCanvas {
  constructor(options) {
    super(options);
    this.scale = options.scale ?? 2;
    this.updateRequired = true;
    this.gridWidth = Math.floor(this.width / this.scale);
    this.gridHeight = Math.floor(this.height / this.scale);
    this.grid = new Array(this.gridWidth * this.gridHeight).fill(null).map(() => new Empty());
    this.tempGrid = new Array(this.gridWidth * this.gridHeight).fill(null).map(() => new Empty());
    this.colorGrid = new Array(this.gridWidth * this.gridHeight * 3).fill(0);
    this.modifiedIndices = new Set();
    this.cleared = false;
    this.rowCount = this.gridHeight;
    this.turnSolidsToSand = false;

    requestAnimationFrame(() => this.updateSand());
    this.mode = Sand;

    document.querySelector("#sand-mode-button").addEventListener("click", () => {
      this.mode = Sand;
    });

    document.querySelector("#solid-mode-button").addEventListener("click", () => {
      this.mode = Solid;
    });

    document.querySelector("#solid-to-sand-button").addEventListener("click", () => {
      this.turnSolidsToSand = true;
      requestAnimationFrame(() => {
        this.updateSand();
      });
    });
  }

  onMouseMove(event) {
    if (!this.isDrawing) return false;
    this.mouseMoved = true;
    this.currentMousePosition = this.getMousePos(event);
    return true;
  }

  varyColor(color) {
    const hue = color.h;
    let saturation = color.s + Math.floor(Math.random() * 20) - 20;
    saturation = Math.max(0, Math.min(100, saturation));
    let lightness = color.l + Math.floor(Math.random() * 10) - 5;
    lightness = Math.max(0, Math.min(100, lightness));
    return this.hslToRgb(hue, saturation, lightness, color.a);
  }

  hslToRgb(h, s, l, a) {
    s /= 100;
    l /= 100;
    const k = n => (n + h / 30) % 12;
    const f = n =>
      l - (
        s * Math.min(l, 1 - l)
      ) * Math.max(-1, Math.min(k(n) - 3, Math.min(9 - k(n), 1)));
    return {
      r: Math.round(255 * f(0)),
      g: Math.round(255 * f(8)),
      b: Math.round(255 * f(4)),
      a,
    };
  }

  rgbToHsl(rgb) {
    const r = rgb.r / 255;
    const g = rgb.g / 255;
    const b = rgb.b / 255;
    const a = rgb.a / 255;
    const max = Math.max(r, g, b);
    const min = Math.min(r, g, b);
    let h, s, l = (max + min) / 2;

    if (max === min) {
      h = s = 0; // achromatic
    } else {
      const d = max - min;
      s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
      switch (max) {
        case r: h = (g - b) / d + (g < b ? 6 : 0); break;
        case g: h = (b - r) / d + 2; break;
        case b: h = (r - g) / d + 4; break;
      }
      h /= 6;
    }

    return { h: h * 360, s: s * 100, l: l * 100, a };
  }

  drawSmoothLineFallback(from, to) {
    this.drawParticleLine(from, to, this.mode);
    requestAnimationFrame(() => this.updateSand());
  }

  startDrawing(e) {
    super.startDrawing(e);
    this.isDrawing = true;
    requestAnimationFrame(() => this.updateSand());
  }

  drawParticleLine(from, to, ParticleType) {
    const radius = this.RADIUS;
    const dx = to.x - from.x;
    const dy = to.y - from.y;
    const distance = Math.sqrt(dx * dx + dy * dy);
    const steps = Math.max(Math.abs(dx), Math.abs(dy));

    const scaleX = this.width / this.gridWidth;
    const scaleY = this.height / this.gridHeight;

    for (let i = 0; i <= steps; i++) {
      const t = (steps === 0) ? 0 : i / steps;
      const x = Math.floor((from.x + dx * t) / scaleX);
      const y = Math.floor((from.y + dy * t) / scaleY);

      for (let ry = -radius; ry <= radius; ry++) {
        for (let rx = -radius; rx <= radius; rx++) {
          if (rx * rx + ry * ry <= radius * radius) {
            const px = x + Math.floor(rx / scaleX);
            const py = y + Math.floor(ry / scaleY);
            if (px >= 0 && px < this.gridWidth && py >= 0 && py < this.gridHeight) {
              const index = py * this.gridWidth + px;

              if (this.currentColor.a > 0.0) {
                const variedColor = this.varyColor(this.rgbToHsl(this.currentColor));
                this.setParticle(index, new ParticleType(variedColor));
              } else {
                this.setParticle(index, new Empty());
              }

              this.modifiedIndices.add(index);
            }
          }
        }
      }
    }
  }

  updateSand() {
    if (this.updating) return;

    if (!this.needsUpdate()) {
      return;
    }

    this.updating = true;
    this.updateRequired = false;

    if (this.isDrawing) {
      this.doDraw();
    }

    this.cleared = false;
    const solidsToSand = this.turnSolidsToSand;

    for (let row = this.rowCount - 1; row >= 0; row--) {
      const rowOffset = row * this.gridWidth;
      const leftToRight = Math.random() > 0.5;
      for (let i = 0; i < this.gridWidth; i++) {
        const columnOffset = leftToRight ? i : -i - 1 + this.gridWidth;
        let index = rowOffset + columnOffset;
        let particle = this.grid[index];

        if (solidsToSand && particle instanceof Solid) {
          particle = new Sand(particle.color);
          this.setParticle(index, particle);
          this.modifiedIndices.add(index);
          this.turnSolidsToSand = false;
        }

        particle.update();

        if (!particle.modified) {
          continue;
        }

        // SHOULDN'T NEED THIS IT CAUSES CONSTANT RERENDERS
        // this.modifiedIndices.add(index);

        if (particle.getUpdateCount() === 0) {
          // this.modifiedIndices.add(index);
        }

        for (let v = 0; v < particle.getUpdateCount(); v++) {
          const newIndex = this.updatePixel(index);

          if (newIndex !== index) {
            index = newIndex;
          } else {
            particle.resetVelocity();
            break;
          }
        }
      }
    }

    this.updateCanvasFromGrid();
    this.updateTexture();

    requestAnimationFrame(() => {
      this.updating = false;
      this.updateSand()
    });
  }

  updatePixel(i) {
    const particle = this.grid[i];
    if (particle instanceof Empty) return i;

    const below = i + this.gridWidth;
    const belowLeft = below - 1;
    const belowRight = below + 1;
    const column = i % this.gridWidth;

    if (this.isEmpty(below)) {
      this.swap(i, below);
      return below;
    } else if (this.isEmpty(belowLeft) && belowLeft % this.gridWidth < column) {
      this.swap(i, belowLeft);
      return belowLeft;
    } else if (this.isEmpty(belowRight) && belowRight % this.gridWidth > column) {
      this.swap(i, belowRight);
      return belowRight;
    }

    return i;
  }

  swap(a, b) {
    if (this.grid[a] instanceof Empty && this.grid[b] instanceof Empty) {
      return;
    }
    [this.grid[a], this.grid[b]] = [this.grid[b], this.grid[a]];
    this.modifiedIndices.add(a);
    this.modifiedIndices.add(b);
  }

  setParticle(i, particle) {
    const prev = this.grid[i];
    if (prev.velocity) {
      particle.velocity = prev.velocity;
    }
    this.grid[i] = particle;
  }

  isEmpty(i) {
    return this.grid[i] instanceof Empty;
  }

  updateCanvasFromGrid() {
    const imageData = this.currentImageData;
    const scaleX = Math.ceil(this.width / this.gridWidth);
    const scaleY = Math.ceil(this.height / this.gridHeight);

    this.modifiedIndices.forEach((i) => {
      const gridX = i % this.gridWidth;
      const gridY = Math.floor(i / this.gridWidth);
      const particle = this.grid[i];

      // Calculate the starting position on the canvas for this grid cell
      const startX = gridX * scaleX;
      const startY = gridY * scaleY;

      // Fill in all pixels corresponding to this grid cell
      for (let dy = 0; dy < scaleY; dy++) {
        for (let dx = 0; dx < scaleX; dx++) {
          const canvasX = startX + dx;
          const canvasY = startY + dy;

          // Ensure we don't draw outside the canvas bounds
          if (canvasX < this.width && canvasY < this.height) {
            const canvasIndex = (canvasY * this.width + canvasX) * 4;

            if (particle instanceof Empty) {
              imageData.data[canvasIndex] = 0;
              imageData.data[canvasIndex + 1] = 0;
              imageData.data[canvasIndex + 2] = 0;
              imageData.data[canvasIndex + 3] = 0;
            } else {
              imageData.data[canvasIndex] = particle.color.r;
              imageData.data[canvasIndex + 1] = particle.color.g;
              imageData.data[canvasIndex + 2] = particle.color.b;
              imageData.data[canvasIndex + 3] = 255;
            }
          }
        }
      }
    });

    this.updateRequired = this.modifiedIndices.size > 0;
    this.modifiedIndices = new Set();

    this.context.putImageData(imageData, 0, 0);
  }

  clear() {
    super.clear();
    this.grid.fill(new Empty());
    this.tempGrid.fill(new Empty());
    this.colorGrid.fill(0);
    this.cleared = true;
  }

  load() {
    this.clear();
    this.reset();
  }

  needsUpdate() {
    return this.cleared || this.modifiedIndices.size > 0 || this.isDrawing || this.updateRequired || this.turnSolidsToSand;
  }

  useFallbackCanvas() {
    return true;
  }
}

```

```javascript
// @run
function onBuildReload(self, instance) {
  return (event) => {
    const oldShaderSet = new Set(
      Object.keys(window[instance])
      .filter((a) => a.toLowerCase().includes("plane"))
      .map((p) => window[instance][p]?.material?.fragmentShader)
    );
    document.querySelectorAll("iframe").forEach((o) => {
      o.parentNode.removeChild(o);
    });
    const iframe = document.createElement('iframe');
    iframe.style.display = "none";
    document.body.appendChild(iframe);
    const htmlContent = event.html;
    iframe.srcdoc = htmlContent;

    iframe.onload = () => {
      const win = iframe.contentWindow[instance];
      const iframeDocument = iframe.contentDocument || iframe.contentWindow.document;
      const shaders = Object.keys(win)
        .filter((a) => a.toLowerCase().includes("plane"))
        .map((p) => win?.[p]?.material?.fragmentShader);

      if (oldShaderSet.size === shaders.length) {
        const same = shaders.filter((shader) => oldShaderSet.has(shader));
        if (same.length === shaders.length) {
          window.location.reload();
          return;
        }
      }

      Object.keys(win)
        .filter((a) => a.toLowerCase().includes("plane"))
        .forEach((p) => {
          const shader = win?.[p]?.material?.fragmentShader;
          if (shader) {
            self[p].material.fragmentShader = shader;
            self[p].material.needsUpdate = true;
          }
      });

      self.renderPass();
      document.querySelectorAll("iframe").forEach((o) => {
        o.parentNode.removeChild(o);
      });
    };
    return false;
  };
}

function addSlider({
   id,
   name,
   onUpdate,
   options = {},
    hidden = false,
   showValue = true,
  initialSpanValue = undefined,
 }) {
  const div = document.createElement("div");
  div.style = `display: ${hidden ? "none": "flex"}; align-items: center; gap: 8px`;
  document.querySelector(`#${id}`).appendChild(div);
  div.append(`${name}`);
  const input = document.createElement("input");
  input.id = `${id}-${name.replace(" ", "-").toLowerCase()}-slider`;
  input.className = "slider";
  input.type = "range";
  Object.entries(options).forEach(([key, value]) => {
    input.setAttribute(key, value);
  });
  if (options.value) {
    input.value = options.value;
  }
  const span = document.createElement("span");
  input.setSpan = (value) => span.innerText = `${value}`;

  input.addEventListener("input", () => {
    input.setSpan(`${onUpdate(input.value)}`);
  });
  span.innerText = `${input.value}`;
  div.appendChild(input);
  div.appendChild(span);

  input.onUpdate = onUpdate;
  if (initialSpanValue != null) {
    input.setSpan(initialSpanValue);
  }
  return input;
}
```

<a href="https://jason.today">jason.today</a>

# Radiance Cascades

### Building Real-Time Global Illumination

_This is the second post in a series. Checkout the [first post](./gi.html), which walks through raymarching, the jump flood algorithm, distance fields, and a noise-based global illumination method. We use them all again here!_

This is what we will build in this post. It's noiseless, real-time global illumination. The real deal.

Drag around inside!

Colors on the right - try toggling the sun!

```html
// @run

<span id="radiance-cascades-enabled"></span>
<span id="falling-sand-enabled">

<div id="bigger-canvas"></div>

<details style="cursor: pointer">
  <summary>Additional Controls</summary>

<div style="display: flex; align-items: center; gap: 4px">
  <input type="checkbox" id="enable-srgb">
  <label for="enable-srgb">Correct SRGB</label>
</div>

<div style="display: flex; align-items: center; gap: 4px">
  <input type="checkbox" id="add-noise">
  <label for="add-noise">Naive GI Noise</label>
</div>

<div style="display: none; align-items: center; gap: 4px">
  <input type="checkbox" id="ringing-fix">
  <label for="ringing-fix">Ringing Fix</label>
</div>

<div id="radius-slider-container">
</div>

<div style="display: "flex"; align-items: center; gap: 8px">
Sun Angle
<input id="rc-sun-angle-slider" class="slider" type="range" min="0" max="6.2" step="0.1" value="2.0" />
</div>

<div style="display: flex; align-items: center; gap: 4px">
  <input type="checkbox" id="reduce-demand">
  <label for="reduce-demand">Reduce Demand (Calculate over 2 frames)</label>
</div>

</details>

<br />

<div id="radiance-cascades-canvas"></div>
<div id="falling-sand-rc-canvas"></div>

<div id="falling-sand-buttons" style="display: none; align-items: center; gap: 4px; margin-top: 17px">
  <button id="sand-mode-button">Sand Mode</button>
  <button id="solid-mode-button">Solid Mode</button>
  <button id="solid-to-sand-button">Solid to Sand</button>
  <br/>
</div>

```

<button id="swap-to-falling-sand">Swap to Falling Sand</button>

<br />

_Want a bigger canvas? You can set the width and height as query parameters. For example, here's [1024 x 1024](https://jason.today/rc?width=1024&height=1024) - note it likely requires a modern dedicated GPU to run smoothly!_


<br />

<h2>Why is the previous post's approach naive?</h2>

So last time we left off with a method that sent N rays in equidistant directions about a unit circle, with a bit of noise added whenever we pick a direction to cast a ray. Each ray marches until it hits something, leveraging sphere marching via a distance field to jump as far as possible with high certainty that nothing would be missed or jumped over. The stopping condition is hand-wavy, just some epsilon value - which we'll improve on.

In that post we used 32 rays - that's pretty low accuracy, which shows. We try to cover up with style and temporal accumulation. It should be noted that it could look much smoother using the same method. If we were to cast many more rays per pixel, say, 512 or 1024, use a more appropriate type of noise, and some additional smoothing... but it would no longer run in real-time in common cases - especially at large resolutions.

Take a look at the impact and look that noise has, and how smooth our GI can get at high ray counts.

```glsl
// @run id="one-pass-raymarch-fragment" type="x-shader/x-fragment"
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif
uniform vec2 resolution;
uniform sampler2D sceneTexture;
uniform sampler2D distanceTexture;
uniform bool enableSun;
uniform bool addNoise;
uniform int rayCount;

in vec2 vUv;
out vec4 FragColor;

const float PI = 3.14159265;
const float TAU = 2.0 * PI;
const float srgb = 1.0;

const vec3 skyColor = vec3(0.02, 0.08, 0.2);
const vec3 sunColor = vec3(0.95, 0.95, 0.9);
const float sunAngle = 4.2;
const int maxSteps = 32;
const float EPS = 0.001;

vec3 sunAndSky(float rayAngle) {
  // Get the sun / ray relative angle
  float angleToSun = mod(rayAngle - sunAngle, TAU);

  // Sun falloff based on the angle
  float sunIntensity = smoothstep(1.0, 0.0, angleToSun);

  // And that's our sky radiance
  return sunColor * sunIntensity + skyColor;
}

float rand(vec2 co) {
    return fract(sin(dot(co.xy ,vec2(12.9898,78.233))) * 43758.5453);
}

bool outOfBounds(vec2 uv) {
  return uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0;
}

void main() {
  vec2 uv = vUv;

  vec2 cascadeExtent = resolution;
  vec2 coord = floor(vUv * cascadeExtent);

  vec4 light = texture(sceneTexture, uv);
  light = vec4(pow(light.rgb, vec3(srgb)), light.a);

  vec4 radiance = vec4(0.0);

  float oneOverRayCount = 1.0 / float(rayCount);
  float angleStepSize = TAU * oneOverRayCount;

  float offset = addNoise ? rand(uv) : 0.0;

  float rayAngleStepSize = angleStepSize + offset * TAU;

  vec2 oneOverSize = 1.0 / resolution;
  float minStepSize = min(oneOverSize.x, oneOverSize.y) * 0.5;

  vec2 scale = min(resolution.x, resolution.y) / resolution;

  if (light.a < 0.001) {
      // Shoot rays in "rayCount" directions, equally spaced, with some randomness.
      for (int i = 0; i < rayCount; i++) {
          float index = float(i);
          float angleStep = (index + offset + 0.5);
          float angle = angleStepSize * angleStep;
          vec2 rayDirection = vec2(cos(angle), -sin(angle));

          vec2 sampleUv = vUv;
          vec4 radDelta = vec4(0.0);
          bool hitSurface = false;

          // We tested uv already (we know we aren't an object), so skip step 0.
          for (int step = 1; step < maxSteps; step++) {
              // How far away is the nearest object?
              float dist = texture(distanceTexture, sampleUv).r;

              // Go the direction we're traveling
              sampleUv += rayDirection * dist * scale;

              if (outOfBounds(sampleUv)) break;

              if (dist < minStepSize) {
                  vec4 colorSample = texture(sceneTexture, sampleUv);
                  radDelta += vec4(pow(colorSample.rgb, vec3(srgb)), 1.0);
                  break;
              }
          }

          // If we didn't find an object, add some sky + sun color
          if (enableSun) {
            radDelta += vec4(sunAndSky(angle), 1.0);
          }

          // Accumulate total radiance
          radiance += radDelta;
      }
  }

  vec3 final = max(light, radiance * oneOverRayCount).rgb;

  FragColor = vec4(pow(final, vec3(1.0 / srgb)), 1.0);
}
```


<div style="display: flex; align-items: center; gap: 4px">
  <input type="checkbox" id="one-raymarch-add-noise">
  <label for="one-raymarch-add-noise">Naive GI Noise</label>
</div>
<div id="ray-count-container"></div>
<br />

<div id="one-pass-raymarch"></div>


```javascript
// @run
class OnePassRaymarch extends DistanceField {
  getFragmentShader() {
    return document.querySelector("#one-pass-raymarch-fragment").innerHTML;
  }

  sliders() {
    this.rayCountSlider = addSlider({
      id: "ray-count-container", name: "Ray Count", onUpdate: (value) => {
        this.rcPlane.material.uniforms.rayCount.value = Math.pow(2.0, value);
        this.renderPass();
        return Math.pow(2.0, value);
      },
      options: {min: 2.0, max: 10.0, step: 1.0, value: 5.0},
      initialSpanValue: Math.pow(2.0, 5.0),
    });

    this.addNoise = document.querySelector("#one-raymarch-add-noise");

    this.addNoise.addEventListener("input", () => {
      this.rcPlane.material.uniforms.addNoise.value = this.addNoise.checked;
      this.renderPass();
    });
  }

  initializeRaymarch() {
    const fragmentShader = this.getFragmentShader();

    return this.initThreeJS({
      renderTargetOverrides: {
        minFilter: THREE.NearestFilter,
        magFilter: THREE.NearestFilter,
      },
      uniforms: {
        resolution: {value: new THREE.Vector2(this.width, this.height)},
        sceneTexture: {value: null},
        distanceTexture: {value: null},
        rayCount: { value: 32.0 },
        enableSun: { value: false },
        addNoise: { value: false },
      },
      fragmentShader,
    });
  }

  innerInitialize() {
    // Enforce 1.0 pixel ratio
    this.renderer.setPixelRatio(1.0);
    this.lastRequest = Date.now();
    this.frame = 0;
    super.innerInitialize();
    this.gpuTimer = new GPUTimer(this.renderer, true);
    this.activelyDrawing = false;

    this.animating = false;

    const fragmentShader = this.getFragmentShader();

    const {plane: rcPlane, render: rcRender, renderTargets: rcRenderTargets} = this.initializeRaymarch();

    const {plane: overlayPlane, render: overlayRender, renderTargets: overlayRenderTargets} = this.initThreeJS({
      uniforms: {
        inputTexture: {value: null},
        drawPassTexture: {value: null},
      },
      renderTargetOverrides: {
        minFilter: THREE.NearestFilter,
        magFilter: THREE.NearestFilter,
      },
      fragmentShader: `
        uniform sampler2D inputTexture;
        uniform sampler2D drawPassTexture;

        varying vec2 vUv;
        out vec4 FragColor;

        void main() {
          vec3 rc = texture(inputTexture, vUv).rgb;
          FragColor = vec4(rc, 1.0);
        }`
    });

    this.rcPlane = rcPlane;
    this.rcRender = rcRender;
    this.rcRenderTargets = rcRenderTargets;
    this.prev = 0;

    this.overlayPlane = overlayPlane;
    this.overlayRender = overlayRender;
    this.overlayRenderTargets = overlayRenderTargets;

    this.sliders();
  }

  overlayPass(inputTexture) {
    this.overlayPlane.material.uniforms.drawPassTexture.value = this.drawPassTexture;
    this.overlayPlane.material.uniforms.inputTexture.value = inputTexture;
    this.renderer.setRenderTarget(this.overlayRenderTargets[0]);
    this.overlayRender();

    if (!this.isDrawing) {
      this.overlay = true;
      const frame = this.forceFullPass ? 0 : 1 - this.frame;
      this.plane.material.uniforms.inputTexture.value = this.overlayRenderTargets[frame].texture;
      this.plane.material.uniforms.indicator.value = true;
      this.surface.drawSmoothLine(this.surface.currentPoint, this.surface.currentPoint);
      this.plane.material.uniforms.indicator.value = false;
      this.overlay = false;
    }
  }

  triggerDraw() {
    if (this.overlay) {
      this.renderer.setRenderTarget(null);
      this.render();
      return;
    }
    super.triggerDraw();
  }

  canvasModifications() {
    return {
      startDrawing: (e) => {
        this.lastRequest = Date.now();
        this.surface.startDrawing(e);
      },
      onMouseMove: (e) => {
        const needRestart = Date.now() - this.lastRequest > 1000;
        this.lastRequest = Date.now();
        this.surface.onMouseMove(e);
        if (needRestart) {
          this.renderPass();
        }
      },
      stopDrawing: (e, redraw) => {
        this.lastRequest = Date.now();
        this.surface.stopDrawing(e, redraw);
      },
      toggleSun: (e) => {
        if (e.currentTarget.getAttribute("selected") === "true") {
          e.currentTarget.removeAttribute("selected");
          this.rcPlane.material.uniforms.enableSun.value = false;
        } else {
          e.currentTarget.setAttribute("selected", "true");
          this.rcPlane.material.uniforms.enableSun.value = true;
        }
        this.renderPass();
      }
    }
  }

  rcPass(distanceFieldTexture, drawPassTexture) {
    this.rcPlane.material.uniforms.distanceTexture.value = distanceFieldTexture;
    this.rcPlane.material.uniforms.sceneTexture.value = drawPassTexture;
    this.renderer.setRenderTarget(null);
    this.rcRender();
  }

  doRenderPass() {
    this.gpuTimer.start('seedPass');
    let out = this.seedPass(this.drawPassTexture);
    this.gpuTimer.end('seedPass');

    this.gpuTimer.start('jfaPass');
    out = this.jfaPass(out);
    this.gpuTimer.end('jfaPass');

    this.gpuTimer.start('dfPass');
    this.distanceFieldTexture = this.dfPass(out);
    this.gpuTimer.end('dfPass');

    let rcTexture = this.rcPass(this.distanceFieldTexture, this.drawPassTexture);


    // this.overlayPass(rcTexture);
    // this.finishRenderPass();
  }

  finishRenderPass() {
    // Update timer and potentially print results
    this.gpuTimer.update();
  }

  renderPass() {
    this.drawPassTexture = this.drawPass();
    if (!this.animating) {
      this.animating = true;
      requestAnimationFrame(() => {
        this.animate();
      });
    }
  }

  animate() {
    this.animating = true;

    this.doRenderPass();
    this.desiredRenderPass = false;

    requestAnimationFrame(() => {
      if (Date.now() - this.lastRequest > 1000) {
        this.animating = false;
        return;
      }
      this.animate()
    });
  }

  clear() {
    this.lastFrame = null;
    if (this.initialized) {
      this.rcRenderTargets.forEach((target) => {
        this.renderer.setRenderTarget(target);
        this.renderer.clearColor();
      });
    }
    super.clear();
    this.renderPass();
  }

  //foo bar baz!!
  load() {
    window.mdxishState.onReload = onBuildReload(this, "radianceCascades");
    this.reset();
    this.initialized = true;
  }

  reset() {
    this.clear();
    let last = undefined;
    return new Promise((resolve) => {
      this.setHex("#f9a875");
      getFrame(() => this.draw(last, 0, false, resolve));
    }).then(() => new Promise((resolve) => {
      last = undefined;
      getFrame(() => {
        this.surface.mode = Solid;
        this.setHex("#000000");
        getFrame(() => this.draw(last, 0, true, resolve));
      });
    }))
      .then(() => {
        this.renderPass();
        getFrame(() => this.setHex("#fff6d3"));
        this.surface.mode = Sand;
      });
  }
}


new OnePassRaymarch({
  id: "one-pass-raymarch", width: 300, height: 400, radius: 4
});
```

<br />

An important question to ask is certainly, "do we care about noise?" If you like the aesthetic of noise or otherwise don't mind it, you can make the decision to use noise based methods. It inherently comes with inaccuracy alongside the visual artifacts. But, put the slider at 16 rays. This is roughly the cost of radiance cascades, yet the end result has no noise. Pretty crazy.

Let's take a moment to talk about how many rays we're casting to get a sense of the computation we're performing every frame. Let's say we have a 1024 x 1024 canvas - that's roughly 1M pixels. If we're casting 512 (on the low side of nice and smooth) that's ~500M rays cast every frame. Because we added some great performance savings by creating distance fields, we only need to take (on the order of) 10 steps per ray - and really the most computationally expensive operation is a texture lookup which we do once to figure out if we need to perform a raymarch and once if we hit something - so let's call that roughly 2 texture lookups per cast ray totaling around 1B texture lookups. Even if we can perform a texture lookup in a nanosecond (likely slower), we're looking at a full second per frame. To run at just 60fps, we need to get that down to ~16ms. So roughly 100x faster.

How can we simplify the amount of work we need to do without sacrificing quality?

## Penumbra hypothesis

It turns out, there's an idea called the "penumbra hypothesis" which provides critical insight that we'll leverage to dramatically reduce the amount of computational effort required.

The idea has two parts.

When a shadow is cast:

1. The necessary linear (spatial in pixel space) resolution to accurately capture some area of it is inversely proportional to that area's distance from the origin.
2. The necessary angular resolution to accurately capture some area of it is proportional to that area's distance from the origin.

Below is a scene that illustrates a penumbra.

<br />

<div id="penumbra-hypothesis-canvas"></div>

<br />

```javascript
// @run
class PenumbraHypothesis extends OnePassRaymarch {
  canvasModifications() {
    return {
      ...super.canvasModifications(),
      toggleSun: undefined,
      colors: [
        "#fff6d3", "#000000", "#00000000"
      ]
    }
  }

  sliders() {}

  initializeRaymarch() {
    const fragmentShader = this.getFragmentShader();

    return this.initThreeJS({
      renderTargetOverrides: {
        minFilter: THREE.NearestFilter,
        magFilter: THREE.NearestFilter,
      },
      uniforms: {
        resolution: {value: new THREE.Vector2(this.width, this.height)},
        sceneTexture: {value: null},
        distanceTexture: {value: null},
        rayCount: { value: 512.0 },
        enableSun: { value: false },
        addNoise: { value: true },
      },
      fragmentShader,
    });
  }

  reset() {
    this.clear();
    return new Promise((resolve) => {
      setTimeout(() => {
        getFrame(() => {
          this.setHex("#fff6d3");
          this.surface.drawSmoothLine({x: 0.0, y: 0.0}, { x: this.width, y: 0.0});
          this.setHex("#000000");
          this.surface.drawSmoothLine({x:  this.width * 0.5, y: this.height * 0.45}, { x:  this.width * 1.0, y: this.height * 0.45});
          this.setHex("#fff6d3");
          resolve();
        });
      }, 100);
    });
  }
}


new PenumbraHypothesis({
  id: "penumbra-hypothesis-canvas", width: 300, height: 400, radius: 4
});
```

Observe the shape and color of the shadow as it extends away from the left edge of the drawn black opaque line. There's kind of two parts - the dark area on the right, and the area on the left that gets softer the further left you look. That softening center area is shaped like a cone (or triangle) and called the penumbra. (wikipedia has some [nice labeled diagrams](https://en.wikipedia.org/wiki/Umbra,_penumbra_and_antumbra) too).

_Like all other canvases, if you want to get the original back, just hit the little refresh button in the bottom right._

So to put the penumbra hypothesis above into more familiar terms, given some pixel, to accurately represent its radiance (its rgba value) we need to collect light from all light sources in our scene. The further away a light source is, the more angular resolution and less linear (spatial pixel) resolution is required. In other words, the more rays we need to cast and the fewer individual pixels we need to look at.

If we observe that shadow in our illustration of the penumbra above, we can kind of see why that's the case in regard to the linear resolution. The shadow's left edge is quite sharp near the left edge of the black line and it's pretty hard to tell where exactly it becomes the same color as the background (or if it does).

As far as angular resolution, we can easily see the sense behind this condition by changing our ray count down to 4 in our [previous canvas](#one-raymarch-add-noise) and placing a black dot in a dark area that _should_ be illuminated, then increasing the ray count step by step. We can see how the dot can easily be lost or misrepresented if far enough away and the ray count isn't high enough.

So. More rays at lower resolution the further away a light source is...

Currently, our previous method casts the same number of rays from every pixel, and operates only according to the scene resolution.

So, how do we dynamically increase the number of rays cast mid raymarch? Sounds like some sort of branching operation which doesn't sound particularly gpu friendly.

Also, reducing linear resolution sounds like taking bigger steps as we get further from our origin during our raymarch, but we swapped to using a distance field, not stepping pixel by pixel like we did in our very first implementation. So how would we reduce our linear resolution as we get further away? Isn't it optimized already?

## Codifying the penumbra hypothesis

So instead of dynamically increasing rays mid cast / branching, let's break down our global illumination process into multiple passes. We'll do a high resolution pass with fewer rays, and a lower resolution pass with more rays. According to the penumbra hypothesis, that should more accurately model how lights / shadows behave.

So to start - we need our distance field texture and our scene texture (same as before). But this time we'll also need to keep around a `lastTexture` that we'll use to keep around the previous pass.

```javascript
rcPass(distanceFieldTexture, drawPassTexture) {
  uniforms.distanceTexture.value = distanceFieldTexture;
  uniforms.sceneTexture.value = drawPassTexture;
  uniforms.lastTexture.value = null;

  // ping-pong rendering
}
```

We need to be able to pass the previous raymarch pass into the next, so we'll setup a `for` loop using a ping-pong strategy and two render targets just like when we made our multi-pass JFA.

We'll start with the highest ray count, lowest resolution layer, (256 rays and 1/16th resolution). Then we'll do our low ray count, high resolution render.

```javascript
// ping-pong rendering
for (let i = 2; i >= 1; i--) {
  uniforms.rayCount.value = Math.pow(uniforms.baseRayCount.value, i);

  if (i > 1) {
    renderer.setRenderTarget(rcRenderTargets[prev]);
    rcRender();
    uniforms.lastTexture.value = rcRenderTargets[prev].texture;
    prev = 1 - prev;
  } else {
    uniforms.rayCount.value = uniforms.baseRayCount.value;
    renderer.setRenderTarget(null);
    rcRender();
  }
}
```

In the shader, we're going to make 3 modifications to our original naive gi shader.

1. Add the ability to render at a lower resolution
2. Add the ability to merge with a previous pass
3. Add the ability to start and stop at a specified distance from the origin of the raymarch.

That last modifications models the behavior in the penumbra hypothesis that describes how the required resolution drops and required ray count increases as you move further away. To model that behavior, we need to be able to tell our shader to march between a specified interval.

So starting with rendering at a lower resolution - let's just try something out.

Let's cut our resolution in half (floor each pixel to half).

```glsl
  vec2 coord = uv * resolution;

  bool isLastLayer = rayCount == baseRayCount;
  vec2 effectiveUv = isLastLayer ? uv : floor(coord / 2.0) * 2.0 / resolution;
```

Let's decide where to cast our ray from and how far it should travel. We'll arbitrarily decide on 1/8th of the UV space (screen) and the end will be the longest possible `sqrt(2.0)`. If it's our low-res pass, start at `partial` otherwise only go _until_ `partial`.

```glsl
float partial = 0.125;
float intervalStart = rayCount == baseRayCount ? 0.0 : partial;
float intervalEnd = rayCount == baseRayCount ? partial : sqrt(2.0);
```

And now our core raymarch loop (mostly reiterating) but no noise this time!
```glsl
// Shoot rays in "rayCount" directions, equally spaced, NO ADDED RANDOMNESS.
for (int i = 0; i < rayCount; i++) {
    float index = float(i);
    // Add 0.5 radians to avoid vertical angles
    float angleStep = (index + 0.5);
    float angle = angleStepSize * angleStep;
    vec2 rayDirection = vec2(cos(angle), -sin(angle));

    // Start in our decided starting location
    vec2 sampleUv = effectiveUv + rayDirection * intervalStart * scale;
    // Keep track of how far we've gone
    float traveled = intervalStart;
    vec4 radDelta = vec4(0.0);
```

And when we actually take our steps along the ray...

```glsl
    // (Existing loop, but to reiterate, we're raymarching)
    for (int step = 1; step < maxSteps; step++) {
      // How far away is the nearest object?
      float dist = texture(distanceTexture, effectiveUv).r;

      // Go the direction we're traveling
      sampleUv += rayDirection * dist * scale;

      if (outOfBounds(sampleUv)) break;

      // Read if our distance field tells us to!
      if (dist < minStepSize) {
          // Accumulate radiance or shadow!
          vec4 colorSample = texture(sceneTexture, sampleUv);
          radDelta += vec4(pow(colorSample.rgb, vec3(srgb)), 1.0);
          break;
      }

      // Stop if we've gone our interval length!
      traveled += dist;
      if (traveled >= intervalEnd) break;
    }

    // Accumulate total radiance
    radiance += radDelta;
}
```

And then same as before, we set the pixel to the final radiance... We also corrected SRGB here as well to make it easier to see all the rays (more on that in a bit)

```glsl
vec3 final = radiance.rgb * oneOverRayCount;
vec3 correctSRGB = pow(final, vec3(1.0 / 2.2));

FragColor = vec4(correctSRGB, 1.0);
```

Here's what that looks like:

<br />

<div id="base-ray-count-container"></div>
<br />

<div id="two-pass-raymarch"></div>

```glsl
// @run id="two-pass-raymarch-fragment" type="x-shader/x-fragment"
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif
uniform vec2 resolution;
uniform sampler2D sceneTexture;
uniform sampler2D distanceTexture;
uniform sampler2D lastTexture;
uniform bool enableSun;
uniform int rayCount;
uniform int baseRayCount;
uniform float sunAngle;
uniform float intervalPartial;

in vec2 vUv;
out vec4 FragColor;

const float PI = 3.14159265;
const float TAU = 2.0 * PI;
const float srgb = 2.2;

const vec3 skyColor = vec3(0.02, 0.08, 0.2);
const vec3 sunColor = vec3(0.95, 0.95, 0.9);
const int maxSteps = 32;
const float EPS = 0.001;

vec3 sunAndSky(float rayAngle) {
  // Get the sun / ray relative angle
  float angleToSun = mod(rayAngle - sunAngle, TAU);

  // Sun falloff based on the angle
  float sunIntensity = smoothstep(1.0, 0.0, angleToSun);

  // And that's our sky radiance
  return sunColor * sunIntensity + skyColor;
}

bool outOfBounds(vec2 uv) {
  return uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0;
}

void main() {
  vec2 uv = vUv;

  vec2 cascadeExtent = resolution;
  vec2 coord = floor(vUv * cascadeExtent);

  vec4 radiance = vec4(0.0);

  float oneOverRayCount = 1.0 / float(rayCount);
  float angleStepSize = TAU * oneOverRayCount;

  float intervalStart = rayCount == baseRayCount ? 0.0 : intervalPartial;
  float intervalEnd = rayCount == baseRayCount ? intervalPartial : sqrt(2.0);

  vec2 effectiveUv = rayCount == baseRayCount ? vUv : (floor(coord / 2.0) * 2.0) / resolution;

  vec2 scale = min(resolution.x, resolution.y) / resolution;
  vec2 oneOverSize = 1.0 / resolution;
  float minStepSize = min(oneOverSize.x, oneOverSize.y) * 0.5;

  // Shoot rays in "rayCount" directions, equally spaced.
  for (int i = 0; i < rayCount; i++) {
      float index = float(i);
      float angleStep = (index + 0.5);
      float angle = angleStepSize * angleStep;
      vec2 rayDirection = vec2(cos(angle), -sin(angle));

      vec2 sampleUv = effectiveUv + rayDirection * intervalStart * scale;
      vec4 radDelta = vec4(0.0);

      float traveled = intervalStart;

      // We tested uv already (we know we aren't an object), so skip step 0.
      for (int step = 1; step < maxSteps; step++) {
          // How far away is the nearest object?
          float dist = texture(distanceTexture, sampleUv).r;

          // Go the direction we're traveling
          sampleUv += rayDirection * dist * scale;

          if (outOfBounds(sampleUv)) break;

          if (dist < minStepSize) {
              vec4 colorSample = texture(sceneTexture, sampleUv);
              radDelta += vec4(pow(colorSample.rgb, vec3(srgb)), 1.0);
              break;
          }

          traveled += dist;
          if (traveled >= intervalEnd) break;
      }

      // Only merge on non-opaque areas
      if (rayCount == baseRayCount && radDelta.a == 0.0) {
        vec4 upperSample = texture(lastTexture, uv);

        radDelta += vec4(pow(upperSample.rgb, vec3(srgb)), upperSample.a);

        // If we didn't find an object, add some sky + sun color
        if (enableSun) {
          radDelta += vec4(sunAndSky(angle), 1.0);
        }
      }

      // Accumulate total radiance
      radiance += radDelta;
  }

  vec3 final = (radiance.rgb * oneOverRayCount);

  FragColor = vec4(pow(final, vec3(1.0 / srgb)), 1.0);
}
```

```javascript
// @run
class TwoPassRaymarch extends OnePassRaymarch {
  getFragmentShader() {
    return document.querySelector("#two-pass-raymarch-fragment").innerHTML;
  }

  sliders() {
    this.baseRayCountSlider = addSlider({
      id: "base-ray-count-container", name: "Base Ray Count", onUpdate: (value) => {
        this.rcPlane.material.uniforms.baseRayCount.value = Math.pow(4.0, value);
        this.renderPass();
        return Math.pow(4.0, value);
      },
      options: {min: 1.0, max: 2.0, step: 1.0, value: 2.0},
      initialSpanValue: Math.pow(4.0, 2.0),
    });
  }

  initializeRc() {
    return this.initThreeJS({
      renderTargetOverrides: {
        minFilter: THREE.LinearFilter,
        magFilter: THREE.LinearFilter,
      },
      uniforms: {
        resolution: {value: new THREE.Vector2(this.width, this.height)},
        sceneTexture: {value: null},
        distanceTexture: {value: null},
        lastTexture: {value: null},
        rayCount: { value: 16.0 },
        baseRayCount: { value: Math.pow(4.0, this.baseRayCountSlider.value) },
        enableSun: { value: false },
        srgb: { value: 2.2 },
        sunAngle: { value: 4.2 },
        lastIndex: { value: false },
        intervalPartial: { value: 0.125 },
      },
      fragmentShader: this.getFragmentShader(),
    });
  }

  innerInitialize() {
    this.lastRequest = Date.now();
    this.frame = 0;
    super.innerInitialize();

    this.gpuTimer = new GPUTimer(this.renderer, true);
    this.activelyDrawing = false;

    this.animating = false;

    const fragmentShader = this.getFragmentShader();

    const {plane: rcPlane, render: rcRender, renderTargets: rcRenderTargets} = this.initializeRc();

    const {plane: overlayPlane, render: overlayRender, renderTargets: overlayRenderTargets} = this.initThreeJS({
      uniforms: {
        inputTexture: {value: null},
        drawPassTexture: {value: null},
      },
      renderTargetOverrides: {
        minFilter: THREE.NearestFilter,
        magFilter: THREE.NearestFilter,
      },
      fragmentShader: `
        uniform sampler2D inputTexture;
        uniform sampler2D drawPassTexture;

        varying vec2 vUv;
        out vec4 FragColor;

        void main() {
          vec3 rc = texture(inputTexture, vUv).rgb;
          FragColor = vec4(rc, 1.0);
        }`
    });

    this.rcPlane = rcPlane;
    this.rcRender = rcRender;
    this.rcRenderTargets = rcRenderTargets;
    this.prev = 0;

    this.overlayPlane = overlayPlane;
    this.overlayRender = overlayRender;
    this.overlayRenderTargets = overlayRenderTargets;
    this.lastRenderPassIndex = 0;
  }

  rcPass(distanceFieldTexture, drawPassTexture) {
    this.rcPlane.material.uniforms.distanceTexture.value = distanceFieldTexture;
    this.rcPlane.material.uniforms.sceneTexture.value = drawPassTexture;
    this.rcPlane.material.uniforms.lastTexture.value = null;

    for (let i = 2; i >= this.lastRenderPassIndex + 1; i--) {
      this.gpuTimer.start(`rcPass-${i}`);
      this.rcPlane.material.uniforms.lastIndex.value = i === this.lastRenderPassIndex + 1;
      this.rcPlane.material.uniforms.rayCount.value = Math.pow(
        this.rcPlane.material.uniforms.baseRayCount.value, i
      );

      if (i == this.lastRenderPassIndex + 1) {
        this.renderer.setRenderTarget(null);
        this.rcRender();
      } else {
        this.renderer.setRenderTarget(this.rcRenderTargets[this.prev]);
        this.rcRender();
        this.rcPlane.material.uniforms.lastTexture.value = this.rcRenderTargets[this.prev].texture;
        this.prev = 1 - this.prev;
      }
      this.gpuTimer.end(`rcPass-${i}`);
    }
  }

  reset() {
    this.clear();
    return new Promise((resolve) => {
      this.setHex("#fff6d3");
      setTimeout(() => {
        getFrame(() => {
          const point = {x: this.width / 2.0, y: this.height / 2.0};
          this.surface.drawSmoothLine(point, point);
          resolve();
        });
      }, 100);
    }).then(() => {
      setTimeout(() => {
        this.renderPass();
        getFrame(() => {
          this.setHex("#fff6d3");
        });
      }, 100);
    });
  }
}


new TwoPassRaymarch({
  id: "two-pass-raymarch", width: 300, height: 400, radius: 4
});
```

<br />

We can first notice the two (radiance) cascades (or layers) we now have. One in the background and one in the foreground. The one in the background has some crazy designs and a hole in the middle. The one in the foreground has clearly visible rays extending from the light source just over the circular hole in background.

_We should be careful with language - as we know rays don't extend from the light source, but actually start from what could be perceived as the "end" of the ray "coming out" of the light source and are cast in different directions, one of which hit the light source and thus was illuminated._

Let's swap the base ray count between 4 and 16 and paint around a bit.

Note that our ray counts are 4 rays up close and 16 further away or 16 up close and 256 further away.

When we drag around light, that upper / background layer looks very reasonable- a bit pixelated, but better than the white noise from earlier.

When we draw shadows, they look offset proportional to the offset of the upper interval. But let's not worry about that for a moment...

So that's 256 rays at half resolution. And our core loop through ray angles did 256 rays for every pixel - but because we cut our resolution in half, 3 out of every 4 rays we marched were redundant. Woah!

And that's a key insight in radiance cascades. Specifically for our case - what if we split up the rays we need to cast? Instead of doing half resolution, let's do 1/4th resolution (which is every 16 total pixels) and instead of casting 256 rays per pixel, cast 16 rays for every pixel, offsetting by `TAU / 16` incrementally per pixel.

This group of pixels is called a "probe" in radiance cascades.

Let's make the changes.

Our `baseRayCount` is either `4` or `16` in our running example.

So let's define all our variables.

```glsl
// A handy term we use in other calculations
float sqrtBase = sqrt(float(baseRayCount));
// The width / space between probes
// If our `baseRayCount` is 16, this is 4 on the upper cascade or 1 on the lower.
float spacing = rayCount == baseRayCount ? 1.0 : sqrtBase;
// Calculate the number of probes per x/y dimension
vec2 size = floor(resolution / spacing);
// Calculate which probe we're processing this pass
vec2 probeRelativePosition = mod(coord, size);
// Calculate which group of rays we're processing this pass
vec2 rayPos = floor(coord / size);
// Calculate the index of the set of rays we're processing
float baseIndex = float(baseRayCount) * (rayPos.x + (spacing * rayPos.y));
// Calculate the size of our angle step
float angleStepSize = TAU / float(rayCount);
// Find the center of the probe we're processing
vec2 probeCenter = (probeRelativePosition + 0.5) * spacing;
```

It's a fair amount of new complexity, but we're just encoding our base ray count (4 or 16) rays into each pixel for a downsampled version of our texture.

Then when we actually do our raymarching step, we only need to cast rays `baseRayCount` times per pixel.

```glsl
// Shoot rays in "rayCount" directions, equally spaced
for (int i = 0; i < baseRayCount; i++) {
  float index = baseIndex + float(i);
  float angleStep = index + 0.5;
  // Same as before from here out
}
```

In our first pass (upper cascade / background layer), we'll end up casting 256 rays total from each group of 16 pixels (probe), all from the same point - specifically the center of the probe.

In our second pass (lower cascade / foreground layer), we'll cast 16 rays total from each pixel (probe again), all from the same point - again, from the center.

That is a total cost of 2 x 16 ray raymarches - the same cost as our 32 ray raymarch, and the penumbra hypothesis says it will be more accurate (and hopefully look better - we're using an angular resolution of 256 rays instead of 32).

But at what point do we swap from the low ray, high spatial resolution to high ray low spatial resolution? We'll make "Interval Split" a slider and play with it.

```glsl
// Calculate our intervals based on an input `intervalSplit`
float intervalStart = rayCount == baseRayCount ? 0.0 : intervalSplit;
// End at the split or the max possible (in uv) sqrt(2.0)
float intervalEnd = rayCount == baseRayCount ? intervalSplit : sqrt(2.0);
```

No changes needed to how we leveraged them. But we do need to "merge" them, as in, when we get to the lower cascade, we need to read from the upper cascade, which is stored differently than a normal texture.

So first things first - we only want to read the upper cascade from the lower layer (there's no layer above the upper cascade) and we only want to do it if we're in an empty area. If we already have light, there's no reason to read from the upper cascade. We already hit something (which we know will be closer).

```glsl
bool nonOpaque = radDelta.a == 0.0;

// Only merge on non-opaque areas
if (firstLevel && nonOpaque) {
```

Once we know we need to merge, we need to decode our encoded texture.

So we store 16 different directions (assuming a base of 16) in 16 different quadrants of our texture. That's a 4 x 4 grid. Once we calculate that we can find our current position by modding and dividing (and flooring) the index with `sqrtBase` (4) to find our x and y terms. Then multiply them by the size of a quadrant that we just calculated.

```glsl
// The spacing between probes
vec2 upperSpacing = sqrtBase;
// Grid of probes
vec2 upperSize = floor(resolution / upperSpacing);
// Position of _this_ probe
vec2 upperPosition = vec2(
  mod(index, sqrtBase), floor(index / upperSpacing)
) * upperSize;
```

Next we offset where we sample from by the center of the current layers probe relative to the upper probe.

```glsl
vec2 offset = (probeRelativePosition + 0.5) / sqrtBase;
vec2 upperUv = (upperPosition + offset) / resolution
```

And finally we accumulate radiance from our previous texture at the calculated `upperUv`.

```glsl
radDelta += texture(lastTexture, upperUv);
```

And here it is. Take a moment and swap between "Cascade Index" 0 and 1. When we set it to 1, we render the upper cascade texture directly. That is how it is stored. (starts from bottom left, then goes to the right and then up a row, then to the right etc.) Notice the clockwise rotation.

<br />

<div id="rc-sliders-container-2"></div>

<br />

<div id="two-pass-raymarch-v2"></div>


```glsl
// @run id="two-pass-raymarch-fragment-v2" type="x-shader/x-fragment"
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif
uniform vec2 resolution;
uniform sampler2D sceneTexture;
uniform sampler2D distanceTexture;
uniform sampler2D lastTexture;
uniform bool enableSun;
uniform int rayCount;
uniform int baseRayCount;
uniform bool lastIndex;
uniform float sunAngle;
uniform float intervalPartial;
uniform float srgb;

in vec2 vUv;
out vec4 FragColor;

const float PI = 3.14159265;
const float TAU = 2.0 * PI;

const vec3 skyColor = vec3(0.02, 0.08, 0.2);
const vec3 sunColor = vec3(0.95, 0.95, 0.9);
const int maxSteps = 32;
const float EPS = 0.001;

vec3 sunAndSky(float rayAngle) {
  // Get the sun / ray relative angle
  float angleToSun = mod(rayAngle - sunAngle, TAU);

  // Sun falloff based on the angle
  float sunIntensity = smoothstep(1.0, 0.0, angleToSun);

  // And that's our sky radiance
  return sunColor * sunIntensity + skyColor;
}

float rand(vec2 co) {
    return fract(sin(dot(co.xy ,vec2(12.9898,78.233))) * 43758.5453);
}

bool outOfBounds(vec2 uv) {
  return uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0;
}

void main() {
  vec2 uv = vUv;

  vec2 cascadeExtent = resolution;
  vec2 coord = floor(vUv * cascadeExtent);

  vec4 radiance = vec4(0.0);

  float sqrtBaseRayCount = sqrt(float(baseRayCount));

  float oneOverRayCount = 1.0 / float(rayCount);
  float angleStepSize = TAU * oneOverRayCount;

  float base = float(baseRayCount);
  float sqrtBase = sqrt(float(base));

  bool lastLevel = rayCount == 256;
  bool firstLevel = rayCount == baseRayCount;

  float spacing = firstLevel ? 1.0 : sqrtBase;

  // Calculate the number of probes per x/y dimension
  vec2 size = floor(cascadeExtent / spacing);
  // Calculate which probe we're processing this pass
  vec2 probeRelativePosition = mod(coord, size);
  // Calculate which group of rays we're processing this pass
  vec2 rayPos = floor(coord / size);

  float intervalStart = firstLevel ? 0.0 : intervalPartial;
  float intervalEnd = firstLevel ? intervalPartial : sqrt(2.0);

  // Find the center of the probe we're processing
  vec2 probeCenter = (probeRelativePosition + 0.5) * spacing;
  vec2 normalizedProbeCenter = probeCenter / resolution;

  // Calculate which set of rays we care about
  float baseIndex = float(baseRayCount) * (rayPos.x + (spacing * rayPos.y));

  vec2 oneOverSize = 1.0 / resolution;
  vec2 scale = min(resolution.x, resolution.y) * oneOverSize;

  float minStepSize = min(oneOverSize.x, oneOverSize.y) * 0.5;

  // Shoot rays in "rayCount" directions, equally spaced
  for (int i = 0; i < baseRayCount; i++) {
      float index = baseIndex + float(i);
      float angleStep = index + 0.5;
      float angle = angleStepSize * angleStep;
      vec2 rayDirection = vec2(cos(angle), -sin(angle));

      vec2 sampleUv = normalizedProbeCenter + intervalStart * rayDirection * scale;
      vec4 radDelta = vec4(0.0);
      float traveled = intervalStart;

      // We tested uv already (we know we aren't an object), so skip step 0.
      for (int step = 1; step < maxSteps; step++) {

        // How far away is the nearest object?
        float dist = texture(distanceTexture, sampleUv).r;

        // Go the direction we're traveling
        sampleUv += rayDirection * dist * scale;

        if (outOfBounds(sampleUv)) break;

        if (dist <= minStepSize) {
            vec4 colorSample = texture(sceneTexture, sampleUv);
            radDelta += vec4(
              pow(colorSample.rgb, vec3(srgb)),
              colorSample.a
            );
            break;
        }

        traveled += dist;
        if (traveled >= intervalEnd) break;
      }

      bool nonOpaque = radDelta.a == 0.0;

      // Only merge on non-opaque areas
      if (firstLevel && nonOpaque) {
        float upperSpacing = sqrtBase;
        vec2 upperSize = floor(cascadeExtent / upperSpacing);
        vec2 upperPosition = vec2(
          mod(index, sqrtBase), floor(index / upperSpacing)
        ) * upperSize;

        vec2 offset = (probeRelativePosition + 0.5) / upperSpacing;

        vec4 upperSample = texture(
          lastTexture,
          (upperPosition + offset) / cascadeExtent
        );

        radDelta += vec4(upperSample.rgb, upperSample.a);
      }

      if (lastIndex && nonOpaque) {
        // If we didn't find an object, add some sky + sun color
        if (enableSun) {
          radDelta += vec4(sunAndSky(angle), 1.0);
        }
      }

      // Accumulate total radiance
      radiance += radDelta;
  }

  vec4 totalRadiance = vec4(radiance.rgb / float(baseRayCount), 1.0);

  FragColor = vec4(
      !lastIndex
        ? totalRadiance.rgb
        : pow(totalRadiance.rgb, vec3(1.0 / srgb)),
      1.0
    );
}
```

```javascript
// @run
class TwoPassRaymarchV2 extends TwoPassRaymarch {
  getFragmentShader() {
    return document.querySelector("#two-pass-raymarch-fragment-v2").innerHTML;
  }

  sliders() {
    this.baseRayCountSlider = addSlider({
      id: "rc-sliders-container-2", name: "Base Ray Count", onUpdate: (value) => {
        this.rcPlane.material.uniforms.baseRayCount.value = Math.pow(4.0, value);
        this.renderPass();
        return Math.pow(4.0, value);
      },
      options: {min: 1.0, max: 2.0, step: 1.0, value: 2.0},
      initialSpanValue: Math.pow(4.0, 2.0),
    });

    this.lastRenderPassIndexSlider = addSlider({
      id: "rc-sliders-container-2", name: "Cascade Index", onUpdate: (value) => {
        this.lastRenderPassIndex = parseInt(value);
        this.renderPass();
        return parseInt(value);
      },
      options: {min: 0.0, max: 1.0, step: 1.0, value: 0.0},
      initialSpanValue: 0,
    });

    this.intervalSlider = addSlider({
      id: "rc-sliders-container-2", name: "Interval Split", onUpdate: (value) => {
        this.rcPlane.material.uniforms.intervalPartial.value = value;
        this.renderPass();
        return value;
      },
      options: {min: 0.0, max: 1.0, step: 0.001, value: 0.125},
    });
  }
}

new TwoPassRaymarchV2({
  id: "two-pass-raymarch-v2", width: 300, height: 400, radius: 4
});
```

<br />

It looks relatively similar to the previous canvas, but the upper cascade is clearly lower resolution. If we paint around though, it looks just as good. And if we lower the "Interval Split" a bunch, it looks even better. (shadows look reasonable now too)

The ideal split seems like, pretty close to zero, but clearly not 0 (after drawing some light and shadow lines). For what it's worth ~0.02 (or like 8 pixels) looks a bit too long, but reasonable. Which is about half (or the radius) of 16 pixels. And the probe width is 16 pixels - and we're casting it from the center. So we'll need to keep experimenting but let's say that were our "rule" to determine interval length for a moment... So far we've been talking about this all as just a split.

Let's say we used our rule (which is probably _too long_), 16 x 8 pixels is 128 pixels. Our upper cascade is 256 rays, so it should use an interval that ends at 128 pixels. We'd need another layer - which would have pixel groups of 256 x 256 pixels - so (according to our rule) 256 x 128 pixels max, which is 32K, and beyond any canvas we'd use.

Let's codify that, and we'll also make sure it works for a base ray count of 4 - which will require more layers (we could calculate that too).

We'll need new variables like `cascadeIndex` and `cascadeCount` which will pass in from the CPU...

But let's first figure out / codify our interval length, as this determines how many cascades we'll need.

Let's try basing everything off of our `baseRayCount` - we'll call it `base`.

Our lowest cascade (index of 0) starts at the center of our probe - that's easy. And for the length - let's have it just go 1 pixel - so 1 divided by shortest side of our resolution - and we'll scale steps by the ratio of the shortest side over resolution.

As we go up in cascade size, we need to scale by some amount. A mathematically simple way to scale is just to start at `pow(base, cascadeIndex - 2.0)` where `cascadeIndex`

```glsl
float shortestSide = min(resolution.x, resolution.y);
// Multiply steps by this to ensure unit circle with non-square resolution
vec2 scale = shortestSide / resolution;

float intervalStart = cascadeIndex == 0.0 ? 0.0 : (
  pow(base, cascadeIndex - 1.0)
) / shortestSide;
float intervalLength = pow(base, cascadeIndex) / shortestSide;
```

We also need to generalize a couple of other variables to be based on `cascadeIndex`.

Ray count is just `base ^ (cascadeIndex + 1)` - as the lowest layer is just base, then the next is `base * base` and so on. Similarly, the spacing for the current layer starts with `1`, then is a total of `base` pixels which is `sqrtBase` on each dimension. And then `sqrtBase * sqrtBase` and so on.

```glsl
float rayCount = pow(base, cascadeIndex + 1.0);
float spacing = pow(sqrtBase, cascadeIndex);
```

And finally we need to update our merging logic. It's actually really easy due to the effort we put in on the previous canvas - we just need to generalize when we perform it (as long as we aren't processing the upper-most cascade) and then generalize `upperSpacing`.

And, it's just the probe spacing of the upper cascade!

```glsl
if (cascadeIndex < cascadeCount - 1.0 && nonOpaque) {
  float upperSpacing = pow(sqrtBase, cascadeIndex + 1.0);
```

Alright - back to `cascadeCount` and `cascadeIndex` - we need to calculate and pass those is on the CPU side. Let's modify our logic to figure out how many cascades we need.

Well, say we have 300 x 400 - we know our longest possible ray length is 500 (it's a [pythagorean triple](https://en.wikipedia.org/wiki/Pythagorean_triple) after all - so the longest possible line is 500 pixels, which is our longest possible ray). Using a base of 4 - log base 4 of 500 is roughly 4.5, so we'll need a minimum of 5 cascades...

But when we place a light point in the very top-left and limit to 5 cascades, we see that our longest interval doesn't reach the edge. So there's clearly an issue. In the short term, we're going to solve it in the most naive way possible. Add an extra cascade.

```javascript
rcPass(distanceFieldTexture, drawPassTexture) {
  // initialize variables from before

  const diagonal = Math.sqrt(
    width * width + height * height
  );

  // Our calculation for number of cascades
  cascadeCount = Math.ceil(
    Math.log(diagonal) / Math.log(uniforms.base.value)
  ) + 1;

  uniforms.cascadeCount.value = cascadeCount;

  for (let i = cascadeCount - 1; i >= 0; i--) {
    uniforms.cascadeIndex.value = i;

    // Same as before
  }
}
```

A fix we'll also discuss here, which we used in the last demo is - whenever we read a texture from the drawn scene, we take it from SRGB space and turn it into linear space, then apply our lighting, and then turn it back into SRGB. This produces a much brighter (accurate) result. It also illuminates a clear ringing artifact of vanilla radiance cascades. We'll do this with the approximate version of `vec3(2.2)` when reading and `vec3(1.0 / 2.2)` when writing.

In our raymarching:

```glsl
vec4 colorSample = texture(sceneTexture, sampleUv);
radDelta += vec4(
  pow(colorSample.rgb, vec3(srgb)),
  colorSample.a
);
```

And our final output:

```glsl
FragColor = vec4(
  !(cascadeIndex > firstCascadeIndex)
    ? totalRadiance.rgb
    : pow(totalRadiance.rgb, vec3(1.0 / srgb)),
  1.0
);
```

And for another tweak tweak - it's possible to leak light from one side to the other during the merge step, so let's clamp appropriately to not allow this. You can see this by turning the interval split to zero and drawing along an edge in the [previous canvas](#rc-sliders-container-2).

```glsl
// (From before)
vec2 offset = (probeRelativePosition + 0.5) / sqrtBase;
// Clamp to ensure we don't go outside of any edge
vec2 clamped = clamp(offset, vec2(0.5), upperSize - 0.5);
// And add the clamped offset
vec2 upperUv = (upperPosition + clamped) / resolution
```

Let's check it out!

<br />

<div id="rc-sliders-container-3">
<div style="display: flex; align-items: center; gap: 4px">
  <input type="checkbox" id="multipass-enable-srgb" checked>
  <label for="multipass-enable-srgb">Correct SRGB</label>
</div>
</div>

<br />

<div id="multi-pass-raymarch"></div>

```glsl
// @run id="multipass-raymarch-fragment" type="x-shader/x-fragment"
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif
uniform vec2 resolution;
uniform sampler2D sceneTexture;
uniform sampler2D distanceTexture;
uniform sampler2D lastTexture;
uniform bool enableSun;
uniform float base;
uniform float cascadeIndex;
uniform float cascadeCount;
uniform bool lastIndex;
uniform float sunAngle;
uniform float srgb;

in vec2 vUv;
out vec4 FragColor;

const float PI = 3.14159265;
const float TAU = 2.0 * PI;

const vec3 skyColor = vec3(0.02, 0.08, 0.2);
const vec3 sunColor = vec3(0.95, 0.95, 0.9);
const int maxSteps = 32;
const float EPS = 0.001;

vec3 sunAndSky(float rayAngle) {
  // Get the sun / ray relative angle
  float angleToSun = mod(rayAngle - sunAngle, TAU);

  // Sun falloff based on the angle
  float sunIntensity = smoothstep(1.0, 0.0, angleToSun);

  // And that's our sky radiance
  return sunColor * sunIntensity + skyColor;
}

float rand(vec2 co) {
    return fract(sin(dot(co.xy ,vec2(12.9898,78.233))) * 43758.5453);
}

bool outOfBounds(vec2 uv) {
  return uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0;
}

void main() {
  vec2 uv = vUv;

  vec2 cascadeExtent = resolution;
  vec2 coord = floor(vUv * cascadeExtent);

  vec4 radiance = vec4(0.0);

  float rayCount = pow(base, cascadeIndex + 1.0);
  float sqrtBase = sqrt(base);

  float oneOverRayCount = 1.0 / float(rayCount);
  float angleStepSize = TAU * oneOverRayCount;

  bool firstLevel = cascadeIndex == 0.0;

  float spacing = pow(sqrtBase, cascadeIndex);

  vec2 size = floor(cascadeExtent / spacing);
  vec2 probeRelativePosition = mod(coord, size);
  vec2 rayPos = floor(coord / size);

  vec2 probeCenter = (probeRelativePosition + 0.5) * spacing;
  vec2 normalizedProbeCenter = probeCenter / resolution;

  vec2 oneOverSize = 1.0 / resolution;
  float shortestSide = min(resolution.x, resolution.y);
  vec2 scale = shortestSide * oneOverSize;

  // Hand-wavy rule that improved smoothing of other base ray counts
  float modifierHack = base < 16.0 ? 1.0 : 4.0;

  float intervalStart = firstLevel ? 0.0 : (
    modifierHack * pow(base, cascadeIndex - 1.0)
  ) / shortestSide;
  float intervalLength = (modifierHack * pow(base, cascadeIndex)) / shortestSide;

  // Calculate which set of rays we care about
  float baseIndex = float(base) * (rayPos.x + (spacing * rayPos.y));

  float minStepSize = min(oneOverSize.x, oneOverSize.y) * 0.5;

  // Shoot rays in "base" directions, equally spaced, with some randomness.
  for (int i = 0; i < int(base); i++) {
      float index = baseIndex + float(i);
      float angleStep = index + 0.5;
      float angle = angleStepSize * angleStep;
      vec2 rayDirection = vec2(cos(angle), -sin(angle));

      vec2 sampleUv = normalizedProbeCenter + intervalStart * rayDirection * scale;

      bool dontStart = outOfBounds(sampleUv);

      vec4 radDelta = vec4(0.0);
      float traveled = 0.0;

      // We tested uv already (we know we aren't an object), so skip step 0.
      for (int step = 1; step < maxSteps && !dontStart; step++) {

        // How far away is the nearest object?
        float dist = texture(distanceTexture, sampleUv).r;

        // Go the direction we're traveling
        sampleUv += rayDirection * dist * scale;

        if (outOfBounds(sampleUv)) break;

        if (dist <= minStepSize) {
            vec4 colorSample = texture(sceneTexture, sampleUv);
            radDelta += vec4(
              pow(colorSample.rgb, vec3(srgb)),
              colorSample.a
            );
            break;
        }

        traveled += dist;
        if (traveled >= intervalLength) break;
      }

      bool nonOpaque = radDelta.a == 0.0;

      // Only merge on non-opaque areas
      if (cascadeIndex < cascadeCount - 1.0 && nonOpaque) {
        float upperSpacing = pow(sqrtBase, cascadeIndex + 1.0);
        vec2 upperSize = floor(cascadeExtent / upperSpacing);
        vec2 upperPosition = vec2(
          mod(index, upperSpacing), floor(index / upperSpacing)
        ) * upperSize;

        vec2 offset = (probeRelativePosition + 0.5) / sqrtBase;
        vec2 clamped = clamp(offset, vec2(0.5), upperSize - 0.5);

        vec4 upperSample = texture(
            lastTexture,
            (upperPosition + clamped) / cascadeExtent
        );

        radDelta += vec4(upperSample.rgb, upperSample.a);
      }

      if (lastIndex && nonOpaque) {
        // If we didn't find an object, add some sky + sun color
        if (enableSun) {
          radDelta += vec4(sunAndSky(angle), 1.0);
        }
      }

      // Accumulate total radiance
      radiance += radDelta;
  }

  vec4 totalRadiance = vec4(radiance.rgb / float(base), 1.0);

  FragColor = vec4(
      !lastIndex
        ? totalRadiance.rgb
        : pow(totalRadiance.rgb, vec3(1.0 / srgb)),
      1.0
    );
}
```

```javascript
// @run
class MultipassRaymarch extends TwoPassRaymarchV2 {
  getFragmentShader() {
    return document.querySelector("#multipass-raymarch-fragment").innerHTML;
  }

  sliders() {
    const initialBaseValue = 1.0;
    const initialBase = Math.pow(4.0, initialBaseValue);
    this.baseRayCountSlider = addSlider({
      id: "rc-sliders-container-3", name: "Base Ray Count", onUpdate: (value) => {
        const base = Math.pow(4.0, value);
        this.rcPlane.material.uniforms.base.value = base
        this.renderPass();
        const cascadeCount = Math.ceil(
          Math.log(Math.min(this.width, this.height)) / Math.log(base)
        ) + 1;
        this.lastRenderPassIndexSlider.max = cascadeCount - 1;
        return Math.pow(4.0, value);
      },
      options: {min: 1.0, max: 2.0, step: 1.0, value: initialBaseValue},
      initialSpanValue: initialBase,
    });

    const diagonal = Math.sqrt(
      this.width * this.width + this.height * this.height
    );
    const base = Math.pow(4.0, this.baseRayCountSlider.value);
    const cascadeCount = Math.ceil(Math.log(diagonal) / Math.log(base)) + 1;
    this.lastRenderPassIndexSlider = addSlider({
      id: "rc-sliders-container-3", name: "Cascade Index", onUpdate: (value) => {
        this.lastRenderPassIndex = parseInt(value);
        this.renderPass();
        return parseInt(value);
      },
      options: {min: 0.0, max: cascadeCount - 1, step: 1.0, value: 0.0},
      initialSpanValue: 0,
    });

    this.enableSrgb = document.querySelector("#multipass-enable-srgb");
    this.enableSrgb.addEventListener("input", () => {
      this.rcPlane.material.uniforms.srgb.value = this.enableSrgb.checked ? 2.2 : 1.0;
      this.renderPass();
    });
  }


  initializeRc() {
    return this.initThreeJS({
      renderTargetOverrides: {
        minFilter: THREE.LinearFilter,
        magFilter: THREE.LinearFilter,
      },
      uniforms: {
        resolution: {value: new THREE.Vector2(this.width, this.height)},
        sceneTexture: {value: null},
        distanceTexture: {value: null},
        lastTexture: {value: null},
        base: { value: Math.pow(4.0, 1.0) },
        cascadeIndex: { value: 0.0 },
        cascadeCount: { value: 1.0 },
        srgb: { value: this.enableSrgb.checked ? 2.2 : 1.0 },
        enableSun: { value: false },
        sunAngle: { value: 4.2 },
        lastIndex: { value: false },
      },
      fragmentShader: this.getFragmentShader(),
    });
  }

  rcPass(distanceFieldTexture, drawPassTexture) {
    this.rcPlane.material.uniforms.distanceTexture.value = distanceFieldTexture;
    this.rcPlane.material.uniforms.sceneTexture.value = drawPassTexture;
    this.rcPlane.material.uniforms.lastTexture.value = null;
    this.prev = 0;

    const diagonal = Math.sqrt(
      this.width * this.width + this.height * this.height
    );
    this.cascadeCount = Math.ceil(
      Math.log(diagonal) / Math.log(this.rcPlane.material.uniforms.base.value)
    ) + 1;
    this.rcPlane.material.uniforms.cascadeCount.value = (
      this.cascadeCount
    );

    for (let i = this.cascadeCount; i >= this.lastRenderPassIndex; i--) {
      this.gpuTimer.start(`rcPass-${i}`);
      this.rcPlane.material.uniforms.cascadeIndex.value = i;
      this.rcPlane.material.uniforms.lastIndex.value = i === this.lastRenderPassIndex;

      if (i == this.lastRenderPassIndex) {
        this.renderer.setRenderTarget(null);
        this.rcRender();
      } else {
        this.renderer.setRenderTarget(this.rcRenderTargets[this.prev]);
        this.rcRender();
        this.rcPlane.material.uniforms.lastTexture.value = this.rcRenderTargets[this.prev].texture;
        this.prev = 1 - this.prev;
      }
      this.gpuTimer.end(`rcPass-${i}`);
    }
  }
}

window.radianceCascades = new MultipassRaymarch({
  id: "multi-pass-raymarch", width: 300, height: 400, radius: 4
});
```

<br />

And at this point, this looks genuinely reasonable - if you paint around. But if you make a single dot, like it's setup by default, _especially_ with "Correct SRGB" checked, there are some serious ringing artifacts!

And this is still an active area of research. There are a number of approaches to fixing this ringing, but many of them incur a fair amount of overhead (as in doubling the frame time) or cause other artifacts, etc.

And this isn't the only area of active research - pretty much the entire approach is still being actively worked on over in [the discord](https://discord.gg/WSW7d2wrps). People are also working on various approaches to Radiance Cascades in 3D. Pretty exciting stuff!

Now that you get it, go checkout [the final canvas at the top](#radiance-cascades) and see what all the different levers and knobs do in "Additional Controls".


### Acknowledgements / Resources

In general, the folks in the Graphics Programming Discord, Radiance Cascades thread were incredibly helpful while I was learning. The creator of Radiance Cascades, Alexander Sannikov, gave great feedback on the issues my implementations had, along with Yaazarai, fad, tmpvar, Mytino, Goobley, Sam and many others, either directly or indirectly. I _really_ liked how Yaazarai approached building Radiance Cascades and his work had the biggest direct influence on this work and post.

- [Radiance Cascades Paper](https://github.com/Raikiri/RadianceCascadesPaper)
- [Yaazarai's Blog Post](https://mini.gmshaders.com/p/radiance-cascades)
- [The official discord](https://discord.gg/WSW7d2wrps)


### Appendix: Penumbra with Radiance Cascades

Let's examine what our penumbra looks like with our new method.

It has subtly ringing artifacts in the shadow we saw above, but otherwise looks quite clean and is incredibly cheap to compute in comparison.


<br />

<div id="penumbra-hypothesis-canvas-rc"></div>

<br />

```javascript
// @run
class PenumbraHypothesisRC extends MultipassRaymarch {
  canvasModifications() {
    return {
      ...super.canvasModifications(),
      toggleSun: undefined,
      colors: [
        "#fff6d3", "#000000", "#00000000"
      ]
    }
  }

  sliders() {}

  initializeRc() {
    const fragmentShader = this.getFragmentShader();

    return this.initThreeJS({
      renderTargetOverrides: {
        minFilter: THREE.LinearFilter,
        magFilter: THREE.LinearFilter,
      },
      uniforms: {
        resolution: {value: new THREE.Vector2(this.width, this.height)},
        sceneTexture: {value: null},
        distanceTexture: {value: null},
        lastTexture: {value: null},
        base: { value: Math.pow(4.0, 1.0) },
        cascadeIndex: { value: 0.0 },
        cascadeCount: { value: 1.0 },
        srgb: { value: 1.0 },
        enableSun: { value: false },
        sunAngle: { value: 4.2 },
        lastIndex: { value: false },
      },
      fragmentShader,
    });
  }

  reset() {
    this.clear();
    return new Promise((resolve) => {
      setTimeout(() => {
        getFrame(() => {
          this.setHex("#fff6d3");
          this.surface.drawSmoothLine({x: 0.0, y: 0.0}, { x: this.width, y: 0.0});
          this.setHex("#000000");
          this.surface.drawSmoothLine({x:  this.width * 0.5, y: this.height * 0.45}, { x:  this.width * 1.0, y: this.height * 0.45});
          this.setHex("#fff6d3");
          resolve();
        });
      }, 100);
    });
  }
}


new PenumbraHypothesisRC({
  id: "penumbra-hypothesis-canvas-rc", width: 300, height: 400, radius: 4
});
```

### Appendix: Additional Hacks

I actually snuck in one more hack. I either have a bug somewhere or am missing something regarding bases other than 4. As you can see the artifacts are _much_ worse at 16. So I added this hack which helped a lot. This further enforces that some of the hand-waving we did earlier can be improved. We just multiply the interval and interval lengths by a small amount for larger bases.

```glsl
// Hand-wavy rule that improved smoothing of other base ray counts
float modifierHack = base < 16.0 ? 1.0 : sqrtBase;
```

<br />

---

<br />

_If you'd like to see the full source for the demo at the top of the page, the source code is just below here in the HTML. Just inspect here. You can also [read the whole post as markdown](https://gist.github.com/jasonjmcghee/0c72d185830685f67d3b8d9c7f330c3a) - all canvases swapped out for their underlying code._

```glsl
// @run id="rc-fragment" type="x-shader/x-fragment"
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif
uniform vec2 resolution;
uniform sampler2D sceneTexture;
uniform sampler2D distanceTexture;
uniform sampler2D lastTexture;
uniform vec2 cascadeExtent;
uniform float cascadeCount;
uniform float cascadeIndex;
uniform float basePixelsBetweenProbes;
uniform float cascadeInterval;
uniform float rayInterval;
uniform bool addNoise;
uniform bool enableSun;
uniform float sunAngle;
uniform float srgb;
uniform float firstCascadeIndex;
uniform float lastCascadeIndex;
uniform float baseRayCount;

in vec2 vUv;
out vec4 FragColor;

const float PI = 3.14159265;
const float TAU = 2.0 * PI;
const float goldenAngle = PI * 0.7639320225;
const float sunDistance = 1.0;

const vec3 skyColor = vec3(0.2, 0.24, 0.35) * 6.0;
const vec3 sunColor = vec3(0.95, 0.9, 0.8) * 4.0;

const vec3 oldSkyColor = vec3(0.02, 0.08, 0.2);
const vec3 oldSunColor = vec3(0.95, 0.95, 0.9);

vec3 oldSunAndSky(float rayAngle) {
  // Get the sun / ray relative angle
  float angleToSun = mod(rayAngle - sunAngle, TAU);

  // Sun falloff based on the angle
  float sunIntensity = smoothstep(1.0, 0.0, angleToSun);

  // And that's our sky radiance
  return oldSunColor * sunIntensity + oldSkyColor;
}

vec3 sunAndSky(float rayAngle) {
    // Get the sun / ray relative angle
    float angleToSun = mod(rayAngle - sunAngle, TAU);

    // Sun falloff
    float sunIntensity = pow(max(0.0, cos(angleToSun)), 4.0 / sunDistance);

    return mix(sunColor * sunIntensity, skyColor, 0.3);
}

float rand(vec2 co) {
    return fract(sin(dot(co.xy ,vec2(12.9898,78.233))) * 43758.5453);
}

vec4 safeTextureSample(sampler2D tex, vec2 uv, float lod) {
    vec4 color = textureLod(tex, uv, lod);
    return vec4(color.rgb, color.a);
}

vec4 colorSample(sampler2D tex, vec2 uv, float lod, bool srgbSample) {
    vec4 color = textureLod(tex, uv, lod);
    if (!srgbSample) {
      return color;
    }
    return vec4(pow(color.rgb, vec3(srgb)), color.a);
}

vec4 raymarch(
  vec2 normalizedPoint, vec2 delta, float scale, vec2 oneOverSize, vec2 interval, float intervalLength, float minStepSize
) {
    vec2 rayUv = normalizedPoint + delta * interval;
    if (floor(rayUv) != vec2(0.0)) return vec4(0);

    vec2 pre = delta * scale * oneOverSize;

    int safety = 0;

    for (float dist = 0.0; dist < intervalLength && safety < 100; safety++) {
        float df = safeTextureSample(distanceTexture, rayUv, 0.0).r;

        if (df <= minStepSize) {
          vec4 sampleColor = colorSample(sceneTexture, rayUv, 0.0, true);
          return sampleColor;
        }

        dist += df * scale;
        if (dist >= intervalLength) break;

        rayUv += pre * df;
        if (floor(rayUv) != vec2(0.0)) break;
    }

    // divide by hits?
    return vec4(0);
}

vec4 merge(vec4 currentRadiance, float index, vec2 position, float spacingBase) {
    // Occluders / Largest cascade
    if (currentRadiance.a > 0.0 || cascadeIndex >= cascadeCount - 1.0) {
      return currentRadiance;
    }

    float upperSpacing = pow(spacingBase, cascadeIndex + 1.0);
    vec2 upperSize = floor(cascadeExtent / upperSpacing);
    vec2 upperPosition = vec2(
      mod(index, upperSpacing), floor(index / upperSpacing)
    ) * upperSize;

    vec2 offset = (position + 0.5) / spacingBase;

    // Sample in-between the 4 probes for pre-averaging
    vec2 clamped = clamp(offset, vec2(0.5), upperSize - 0.5);
    vec2 samplePosition = (upperPosition + clamped);
    vec4 upperSample = colorSample(
      lastTexture,
      samplePosition / cascadeExtent,
      0.0,
      false
    );

    vec3 c = currentRadiance.rgb + upperSample.rgb;


    return vec4(
      c,
      currentRadiance.a + upperSample.a
    );
}

void main() {
    vec2 coord = floor(vUv * cascadeExtent);

    if (cascadeIndex == 0.0) {
      vec4 color = colorSample(sceneTexture, vUv, cascadeIndex, true);
      if (color.a > 0.0) {
          FragColor = vec4(
              pow(color.rgb, vec3(1.0 / srgb)),
              color.a
          );
          return;
      }
    }

    float base = baseRayCount;
    float rayCount = pow(base, cascadeIndex + 1.0);
    float sqrtBase = sqrt(baseRayCount);
    float spacing = pow(sqrtBase, cascadeIndex);

    // Hand-wavy rule that improved smoothing of other base ray counts
    float modifierHack = base < 16.0 ? 1.0 : sqrtBase;

    vec2 size = floor(cascadeExtent / spacing);
    vec2 probeRelativePosition = mod(coord, size);
    vec2 rayPos = floor(coord / size);

    float modifiedInterval = modifierHack * rayInterval * cascadeInterval;

    float start = cascadeIndex == 0.0 ? cascadeInterval : modifiedInterval;
    vec2 interval = (start * pow(base, (cascadeIndex - 1.0))) / resolution;
    float intervalLength = (modifiedInterval) * pow(base, cascadeIndex);

    vec2 probeCenter = (probeRelativePosition + 0.5) * basePixelsBetweenProbes * spacing;

    float preAvgAmt = baseRayCount;

    // Calculate which set of rays we care about
    float baseIndex = (rayPos.x + (spacing * rayPos.y)) * preAvgAmt;
    // The angle delta (how much it changes per index / ray)
    float angleStep = TAU / rayCount;

    // Can we do this instead of length?
    float scale = min(resolution.x, resolution.y);
    vec2 oneOverSize = 1.0 / resolution;
    float minStepSize = min(oneOverSize.x, oneOverSize.y) * 0.5;
    float avgRecip = 1.0 / (preAvgAmt);

    vec2 normalizedProbeCenter = probeCenter * oneOverSize;

    vec4 totalRadiance = vec4(0.0);
    float noise = addNoise
        ? rand(vUv * (cascadeIndex + 1.0)) / (rayCount * 0.5)
        : 0.0;

    for (int i = 0; i < int(preAvgAmt); i++) {
      float index = baseIndex + float(i);
      float angle = (index + 0.5) * angleStep + noise;
      vec2 rayDir = vec2(cos(angle), -sin(angle));

      // Core raymarching!
      vec4 raymarched = raymarch(
        normalizedProbeCenter, rayDir, scale, oneOverSize, interval, intervalLength, minStepSize
      );

      // Merge with the previous layer
      vec4 merged = merge(raymarched, index, probeRelativePosition, sqrtBase);

      // If enabled, apply the sky radiance
      if (enableSun && cascadeIndex == cascadeCount - 1.0) {
        merged.rgb = max(addNoise ? oldSunAndSky(angle) : sunAndSky(angle), merged.rgb);
      }

      totalRadiance += merged * avgRecip;
    }

    FragColor = vec4(
      (cascadeIndex > firstCascadeIndex)
        ? totalRadiance.rgb
        : pow(totalRadiance.rgb, vec3(1.0 / srgb)),
      1.0
    );
}
```

```javascript
// @run
class RC extends DistanceField {
  innerInitialize() {
    this.lastRequest = Date.now();
    this.frame = 0;
    this.baseRayCount = 4.0;
    this.reduceDemandCheckbox = document.querySelector("#reduce-demand");
    this.forceFullPass = !this.reduceDemandCheckbox.checked;
    super.innerInitialize();
    this.gpuTimer = new GPUTimer(this.renderer, true);
    this.activelyDrawing = false;
    this.rawBasePixelsBetweenProbes = 1.0;

    this.animating = false;

    this.enableSrgb = document.querySelector("#enable-srgb");
    this.addNoise = document.querySelector("#add-noise");
    this.ringingFix = document.querySelector("#ringing-fix");
    this.sunAngleSlider = document.querySelector("#rc-sun-angle-slider");
    this.sunAngleSlider.disabled = true;

    this.rayIntervalSlider = addSlider({
      id: "radius-slider-container", name: "Interval Length", onUpdate: (value) => {
        this.rcPlane.material.uniforms.rayInterval.value = value;
        this.renderPass();
        return value;
      },
      options: {min: 1.0, max: 512.0, step: 1.0, value: 1.0},
    });

    this.baseRayCountSlider = addSlider({
      id: "radius-slider-container", name: "Base Ray Count", onUpdate: (value) => {
        this.rcPlane.material.uniforms.baseRayCount.value = Math.pow(4.0, value);
        this.baseRayCount = Math.pow(4.0, value);
        this.renderPass();
        return Math.pow(4.0, value);
      },
      options: {min: 1.0, max: 3.0, step: 1.0, value: 1.0},
    });

    this.initializeParameters();

    const fragmentShader = document.querySelector("#rc-fragment").innerHTML;

    const {plane: rcPlane, render: rcRender, renderTargets: rcRenderTargets} = this.initThreeJS({
      renderTargetOverrides: {
        minFilter: THREE.LinearMipMapLinearFilter,
        magFilter: THREE.LinearFilter,
        generateMipmaps: true,
      },
      uniforms: {
        resolution: {value: new THREE.Vector2(this.width, this.height)},
        sceneTexture: {value: this.surface.texture},
        distanceTexture: {value: null},
        lastTexture: {value: null},
        cascadeExtent: {value: new THREE.Vector2(this.radianceWidth, this.radianceHeight)},
        cascadeCount: {value: this.radianceCascades},
        cascadeIndex: {value: 0.0},
        basePixelsBetweenProbes: {value: this.basePixelsBetweenProbes},
        cascadeInterval: {value: this.radianceInterval},
        rayInterval: {value: this.rayIntervalSlider.value},
        baseRayCount: {value: Math.pow(4.0, this.baseRayCountSlider.value)},
        sunAngle: { value: this.sunAngleSlider.value },
        time: { value: 0.1 },
        srgb: { value: this.enableSrgb.checked ? 2.2 : 1.0 },
        enableSun: { value: false },
        addNoise: { value: this.addNoise.checked },
        firstCascadeIndex: { value: 0 },
      },
      fragmentShader,
    });

    this.baseRayCountSlider.setSpan(Math.pow(4.0, this.baseRayCountSlider.value));

    this.firstLayer = this.radianceCascades - 1;
    this.lastLayer = 0;

    this.lastLayerSlider = addSlider({
      id: "radius-slider-container",
      name: "(RC) Layer to Render",
      onUpdate: (value) => {
        this.rcPlane.material.uniforms.firstCascadeIndex.value = value;
        this.lastLayer = value;
        this.renderPass();
        return value;
      },
      options: { min: 0, max: this.radianceCascades - 1, value: 0, step: 1 },
    });

    this.firstLayerSlider = addSlider({
      id: "radius-slider-container",
      name: "(RC) Layer Count",
      onUpdate: (value) => {
        this.rcPlane.material.uniforms.cascadeCount.value = value;
        this.firstLayer = value - 1;
        this.renderPass();
        return value;
      },
      options: { min: 1, max: this.radianceCascades, value: this.radianceCascades, step: 1 },
    });

    this.stage = 3;
    this.stageToRender = addSlider({
      id: "radius-slider-container",
      name: "Stage To Render",
      onUpdate: (value) => {
        this.stage = value;
        this.renderPass();
        return value;
      },
      options: { min: 0, max: 3, value: 3, step: 1 },
    });

    this.pixelsBetweenProbes = addSlider({
      id: "radius-slider-container",
      name: "Pixels Between Base Probe",
      onUpdate: (value) => {
        this.rawBasePixelsBetweenProbes = Math.pow(2, value);
        this.initializeParameters(true);
        this.renderPass();
        return Math.pow(2, value);
      },
      options: { min: 0, max: 4, value: 0, step: 1 },
    });

    const {plane: overlayPlane, render: overlayRender, renderTargets: overlayRenderTargets} = this.initThreeJS({
      uniforms: {
        inputTexture: {value: null},
        drawPassTexture: {value: null},
      },
      fragmentShader: `
        uniform sampler2D inputTexture;
        uniform sampler2D drawPassTexture;

        varying vec2 vUv;
        out vec4 FragColor;

        void main() {
          vec3 rc = texture(inputTexture, vUv).rgb;
          FragColor = vec4(rc, 1.0);
        }`
    });

    this.radiusSlider = addSlider({
      id: "radius-slider-container", name: "Brush Radius", onUpdate: (value) => {
        this.surface.RADIUS = value;
        this.plane.material.uniforms.radiusSquared.value = Math.pow(this.surface.RADIUS, 2.0);
        this.renderPass();
        return this.surface.RADIUS;
      },
      options: {min: 1.0, max: 100.0, step: 0.1, value: 6.0},
    });

    this.rcPlane = rcPlane;
    this.rcRender = rcRender;
    this.rcRenderTargets = rcRenderTargets;
    this.prev = 0;

    this.overlayPlane = overlayPlane;
    this.overlayRender = overlayRender;
    this.overlayRenderTargets = overlayRenderTargets;
  }

  // Key parameters we care about
  initializeParameters(setUniforms) {
    this.renderWidth = this.width;
    this.renderHeight = this.height;

    // Calculate radiance cascades
    const angularSize = Math.sqrt(
      this.renderWidth * this.renderWidth + this.renderHeight * this.renderHeight
    );
    this.radianceCascades = Math.ceil(
      Math.log(angularSize) / Math.log(4)
    ) + 1.0;
    this.basePixelsBetweenProbes = this.rawBasePixelsBetweenProbes;
    this.radianceInterval = 1.0;

    this.radianceWidth = Math.floor(this.renderWidth / this.basePixelsBetweenProbes);
    this.radianceHeight = Math.floor(this.renderHeight / this.basePixelsBetweenProbes);

    if (setUniforms) {
      this.rcPlane.material.uniforms.basePixelsBetweenProbes.value = this.basePixelsBetweenProbes;
      this.rcPlane.material.uniforms.cascadeCount.value = this.radianceCascades;
      this.rcPlane.material.uniforms.cascadeInterval.value = this.radianceInterval;
      this.rcPlane.material.uniforms.cascadeExtent.value = (
        new THREE.Vector2(this.radianceWidth, this.radianceHeight)
      );

    }
  }

  overlayPass(inputTexture) {
    this.overlayPlane.material.uniforms.drawPassTexture.value = this.drawPassTexture;

    if (this.forceFullPass) {
      this.frame = 0;
    }

    if (this.frame == 0 && !this.forceFullPass) {
      const input = this.overlayRenderTargets[0].texture ?? this.drawPassTexture;
      this.overlayPlane.material.uniforms.inputTexture.value = input;
      this.renderer.setRenderTarget(this.overlayRenderTargets[1]);
      this.overlayRender();
    } else {
      this.overlayPlane.material.uniforms.inputTexture.value = inputTexture;
      this.renderer.setRenderTarget(this.overlayRenderTargets[0]);
      this.overlayRender();
    }

    if (this.surface.useFallbackCanvas()) {
      this.renderer.setRenderTarget(null);
      this.overlayRender();
    } else if (!this.isDrawing) {
      this.overlay = true;
      const frame = this.forceFullPass ? 0 : 1 - this.frame;
      this.plane.material.uniforms.inputTexture.value = this.overlayRenderTargets[frame].texture;
      this.plane.material.uniforms.indicator.value = true;
      this.surface.drawSmoothLine(this.surface.currentPoint, this.surface.currentPoint);
      this.plane.material.uniforms.indicator.value = false;
      this.overlay = false;
    }
  }

  triggerDraw() {
    if (this.overlay) {
      this.renderer.setRenderTarget(null);
      this.render();
      return;
    }
    super.triggerDraw();
  }

  canvasModifications() {
    return {
      startDrawing: (e) => {
        this.lastRequest = Date.now();
        this.surface.startDrawing(e);
      },
      onMouseMove: (e) => {
        const needRestart = Date.now() - this.lastRequest > 1000;
        this.lastRequest = Date.now();
        this.surface.onMouseMove(e);
        if (needRestart) {
          this.renderPass();
        }
      },
      stopDrawing: (e, redraw) => {
        this.lastRequest = Date.now();
        this.surface.stopDrawing(e, redraw);
      },
      toggleSun: (e) => {
        if (e.currentTarget.getAttribute("selected") === "true") {
          e.currentTarget.removeAttribute("selected");
        } else {
          e.currentTarget.setAttribute("selected", "true");
        }
        const current = this.rcPlane.material.uniforms.enableSun.value;
        this.sunAngleSlider.disabled = current;
          this.rcPlane.material.uniforms.enableSun.value = !current;
          this.renderPass();
      }
    }
  }

  rcPass(distanceFieldTexture, drawPassTexture) {
    this.rcPlane.material.uniforms.distanceTexture.value = distanceFieldTexture;
    this.rcPlane.material.uniforms.sceneTexture.value = drawPassTexture;

    if (this.frame == 0) {
      this.rcPlane.material.uniforms.lastTexture.value = null;
    }

    const halfway = Math.floor((this.firstLayer - this.lastLayer) / 2);
    const last = this.frame == 0 && !this.forceFullPass ? halfway + 1 : this.lastLayer;
    this.rcPassCount = this.frame == 0 ? this.firstLayer : halfway;

    for (let i = this.firstLayer; i >= last; i--) {
      this.gpuTimer.start(`rcPass-${i}`);
      this.rcPlane.material.uniforms.cascadeIndex.value = i;

      this.renderer.setRenderTarget(this.rcRenderTargets[this.prev]);
      this.rcRender();
      this.rcPlane.material.uniforms.lastTexture.value = this.rcRenderTargets[this.prev].texture;
      this.prev = 1 - this.prev;
      this.gpuTimer.end(`rcPass-${i}`);
    }

    return this.rcRenderTargets[1 - this.prev].texture;
  }

  doRenderPass() {
    if (this.frame == 0) {
      if (this.stage == 0) {
        this.renderer.setRenderTarget(null);
        this.render();
        this.finishRenderPass();
        return;
      }

      this.gpuTimer.start('seedPass');
      let out = this.seedPass(this.drawPassTexture);
      this.gpuTimer.end('seedPass');

      this.gpuTimer.start('jfaPass');
      out = this.jfaPass(out);
      this.gpuTimer.end('jfaPass');

      if (this.stage == 1) {
        this.finishRenderPass();
        this.renderer.setRenderTarget(null);
        this.jfaRender();
        return;
      }

      this.gpuTimer.start('dfPass');
      this.distanceFieldTexture = this.dfPass(out);
      this.gpuTimer.end('dfPass');

      if (this.stage == 2) {
        this.finishRenderPass();
        this.renderer.setRenderTarget(null);
        this.dfRender();
        return;
      }
    }

    let rcTexture = this.rcPass(this.distanceFieldTexture, this.drawPassTexture);

    this.overlayPass(rcTexture);
    this.finishRenderPass();
  }

  finishRenderPass() {
    // Update timer and potentially print results
    this.gpuTimer.update();

    if (!this.forceFullPass) {
      this.frame = 1 - this.frame;
    }
  }

  // foo bar baz!!
  renderPass() {
    this.drawPassTexture = this.drawPass();
    if (!this.animating) {
      this.animating = true;
      requestAnimationFrame(() => {
        this.animate();
      });
    }
  }

  animate() {
    this.animating = true;

    this.doRenderPass();
    this.desiredRenderPass = false;

    requestAnimationFrame(() => {
      if (Date.now() - this.lastRequest > 1000) {
        this.animating = false;
        return;
      }
      this.animate()
    });
  }

  clear() {
    this.lastFrame = null;
    if (this.initialized) {
      this.rcRenderTargets.forEach((target) => {
        this.renderer.setRenderTarget(target);
        this.renderer.clearColor();
      });
    }
    super.clear();
    this.renderPass();
  }

  //foo bar baz!!
  load() {
    this.reduceDemandCheckbox.addEventListener("input", () => {
      this.forceFullPass = !this.reduceDemandCheckbox.checked;
      this.renderPass();
    });
    this.enableSrgb.addEventListener("input", () => {
      this.rcPlane.material.uniforms.srgb.value = this.enableSrgb.checked ? 2.2 : 1.0;
      this.renderPass();
    });
    this.addNoise.addEventListener("input", () => {
      this.rcPlane.material.uniforms.addNoise.value = this.addNoise.checked;
      this.renderPass();
    });
    this.sunAngleSlider.addEventListener("input", () => {
      this.rcPlane.material.uniforms.sunAngle.value = this.sunAngleSlider.value;
      this.renderPass();
    })
    window.mdxishState.onReload = onBuildReload(this, "radianceCascades");
    this.reset();
    this.initialized = true;
  }

  reset() {
    this.clear();
    let last = undefined;
    return new Promise((resolve) => {
      this.setHex("#f9a875");
      getFrame(() => this.draw(last, 0, false, resolve));
    }).then(() => new Promise((resolve) => {
      last = undefined;
      getFrame(() => {
        this.surface.mode = Solid;
        this.setHex("#000000");
        getFrame(() => this.draw(last, 0, true, resolve));
      });
    }))
      .then(() => {
        this.renderPass();
        getFrame(() => this.setHex("#fff6d3"));
        this.surface.mode = Sand;
      });

  }
}
```


```javascript
// @run
class FallingSandDrawingRC extends RC {
  createSurface(width, height, radius) {
    this.surface = new FallingSandSurface({ width, height, radius });
  }

  renderPass() {
    this.forceFullPass = true;
    super.renderPass();
  }

  reset() {
    this.clear();
    let last = undefined;
    return new Promise((resolve) => {
      this.setHex("#f9a875");
      getFrame(() => this.draw(last, 0, false, resolve));
    }).then(() => new Promise((resolve) => {
      last = undefined;
      getFrame(() => {
        this.surface.mode = Solid;
        this.setHex("#000000");
        getFrame(() => this.draw(last, 0, true, resolve));
      });
    }))
      .then(() => {
        this.renderPass();
        getFrame(() => this.setHex("#fff6d3"));
        this.surface.mode = Sand;
      });

  }
}
```

```javascript
// @run
// Get all query parameters
const urlParams = new URLSearchParams(window.location.search);

// Get a specific parameter
const widthString = urlParams.get('width');
const heightString = urlParams.get('height');
const widthParam = widthString ? parseInt(widthString) : (isMobile ? 300 : 512);
const heightParam = heightString ? parseInt(heightString) : (isMobile ? 400 : 512);

document.querySelector("#content").style.maxWidth = `${Math.max(800, widthParam + 56)}px`;

let [width, height] = [widthParam, heightParam];

if (window.location.hash != "#falling-sand-enabled") {
  document.querySelector("#falling-sand-buttons").style.display = "none";
  document.querySelector("#falling-sand-rc-canvas").innerHTML = "";
  document.querySelector(`#swap-to-falling-sand`).innerHTML = "Swap to Falling Sand";
  new RC({id: "radiance-cascades-canvas", width, height, radius: 4});
} else {
  document.querySelector("#radiance-cascades-canvas").innerHTML = "";
  document.querySelector("#falling-sand-buttons").style.display = "flex";
  window.showingFallingSand = true;
  document.querySelector(`#swap-to-falling-sand`).innerHTML = "Swap to Paint Canvas";
  new FallingSandDrawingRC({id: "falling-sand-rc-canvas", width, height, radius: 6});
}

document.querySelector("#swap-to-falling-sand").addEventListener("click", () => {
  // Get the current URL
  let currentUrl = window.location.href;

// Remove the existing hash if present
  let urlWithoutHash = currentUrl.split('#')[0];

// Add your new hash
  let newHash = window.location.hash === "#falling-sand-enabled"
    ? "radiance-cascades-enabled" : "falling-sand-enabled";

// Construct the new URL with the new hash
  let newUrl = urlWithoutHash + '#' + newHash;

// Reload the page with the new URL
  window.location.href = newUrl;
  window.location.reload(true);
});
```