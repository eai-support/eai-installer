/* Paper shaders for the two-column art panel.

   Ported from prototypes/bamako-v2/assets/setup-shader.js. The prototype
   loads @paper-design/shaders from esm.sh; here the same build is
   vendored under ui/vendor/ because the installer's CSP is 'self' only. */

import {
  ShaderMount,
  ShaderFitOptions,
  WarpPatterns,
  DitheringShapes,
  DitheringTypes,
  getShaderColorFromString,
  getShaderNoiseTexture,
  warpFragmentShader,
  ditheringFragmentShader,
} from "./vendor/paper-shaders/index.js";

const PATTERN_SIZING = {
  u_fit: ShaderFitOptions.none,
  u_scale: 1,
  u_rotation: 0,
  u_offsetX: 0,
  u_offsetY: 0,
  u_originX: 0.5,
  u_originY: 0.5,
  u_worldWidth: 0,
  u_worldHeight: 0,
};

async function noiseTexture() {
  const img = getShaderNoiseTexture();
  await img.decode();
  if (img.naturalWidth && img.naturalWidth < 1024 && img.naturalHeight < 1024) {
    const aspect = img.naturalWidth / img.naturalHeight;
    img.width = Math.round(aspect > 1 ? 1024 * aspect : 1024);
    img.height = Math.round(aspect > 1 ? 1024 : 1024 / aspect);
  }
  return img;
}

const WARP_COLORS = ["#0D3856", "#0E3755", "#0A180D"];

const STYLES = {
  warp: {
    fragmentShader: warpFragmentShader,
    speed: 1.8,
    frame: 511917.6999996658,
    async uniforms() {
      return {
        u_colors: WARP_COLORS.map(getShaderColorFromString),
        u_colorsCount: WARP_COLORS.length,
        u_proportion: 0.64,
        u_softness: 1.5,
        u_distortion: 0.2,
        u_swirl: 0.86,
        u_swirlIterations: 7,
        u_shapeScale: 0.6,
        u_shape: WarpPatterns.edge,
        u_noiseTexture: await noiseTexture(),
        ...PATTERN_SIZING,
      };
    },
  },

  dither: {
    fragmentShader: ditheringFragmentShader,
    speed: 1,
    frame: 1443085.659999127,
    async uniforms() {
      return {
        u_colorBack: getShaderColorFromString("#00000000"),
        u_colorFront: getShaderColorFromString("#145788"),
        u_shape: DitheringShapes.warp,
        u_type: DitheringTypes.random,
        u_pxSize: 0.1,
        ...PATTERN_SIZING,
      };
    },
  },
};

const DEFAULT_STYLE = "warp";
const STORE_KEY = "eai-setup-art";

const stage = document.getElementById("setupShader");
const panel = document.querySelector(".setup-split-art");
const reduced = window.matchMedia("(prefers-reduced-motion: reduce)");

const layers = new Map();
let current = null;

async function layerFor(name) {
  if (layers.has(name)) return layers.get(name);

  const style = STYLES[name];
  const host = document.createElement("div");
  host.dataset.art = name;
  stage.appendChild(host);

  const mount = new ShaderMount(
    host,
    style.fragmentShader,
    await style.uniforms(),
    undefined,
    reduced.matches ? 0 : style.speed,
    style.frame,
  );

  const layer = { host, mount, speed: style.speed };
  layers.set(name, layer);
  return layer;
}

async function showArt(name) {
  if (!STYLES[name] || name === current) return;

  const layer = await layerFor(name);

  for (const [key, other] of layers) {
    const on = key === name;
    other.host.classList.toggle("on", on);
    other.mount.setSpeed(on && !reduced.matches ? other.speed : 0);
  }

  current = name;
  if (panel) panel.dataset.art = name;

  try {
    sessionStorage.setItem(STORE_KEY, name);
  } catch {
    // Private browsing or storage blocked — the background still switches.
  }
}

async function bootShader() {
  if (!stage) return;
  try {
    reduced.addEventListener("change", (event) => {
      const layer = layers.get(current);
      if (layer) layer.mount.setSpeed(event.matches ? 0 : layer.speed);
    });

    const asked = new URLSearchParams(window.location.search).get("art");
    let stored = null;
    try {
      stored = sessionStorage.getItem(STORE_KEY);
    } catch {
      stored = null;
    }
    await showArt(STYLES[asked] ? asked : STYLES[stored] ? stored : DEFAULT_STYLE);
  } catch (error) {
    console.error("EAI Setup: the art shader could not start.", error);
  }
}

if (stage) bootShader();
