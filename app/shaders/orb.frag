#version 460 core
// Woi orb core: a lit plasma sphere (domain-warped fbm on the sphere
// surface, fresnel rim, specular highlight, inner glow).
#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 uSize;     // square, in logical pixels
uniform float uTime;
uniform float uEnergy;  // 0..1 voice energy
uniform vec3 uColA;     // primary
uniform vec3 uColB;     // deep
uniform vec3 uColC;     // highlight
uniform float uTurb;    // turbulence (thinking / tools)
uniform float uSpin;    // accumulated rotation angle

out vec4 fragColor;

float hash(vec3 p) {
  p = fract(p * 0.3183099 + vec3(0.1, 0.2, 0.3));
  p *= 17.0;
  return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float noise(vec3 x) {
  vec3 i = floor(x);
  vec3 f = fract(x);
  f = f * f * (3.0 - 2.0 * f);
  return mix(
    mix(mix(hash(i + vec3(0, 0, 0)), hash(i + vec3(1, 0, 0)), f.x),
        mix(hash(i + vec3(0, 1, 0)), hash(i + vec3(1, 1, 0)), f.x), f.y),
    mix(mix(hash(i + vec3(0, 0, 1)), hash(i + vec3(1, 0, 1)), f.x),
        mix(hash(i + vec3(0, 1, 1)), hash(i + vec3(1, 1, 1)), f.x), f.y),
    f.z);
}

float fbm(vec3 p) {
  float v = 0.0;
  float a = 0.5;
  for (int i = 0; i < 4; i++) {
    v += a * noise(p);
    p = p * 2.03 + vec3(1.7, 9.2, 3.1);
    a *= 0.5;
  }
  return v;
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize * 2.0 - 1.0;
  float r = length(uv);
  float px = 2.0 / uSize.x;
  float alpha = 1.0 - smoothstep(1.0 - px * 1.5, 1.0, r);
  if (alpha <= 0.0) {
    fragColor = vec4(0.0);
    return;
  }
  float z = sqrt(max(0.0, 1.0 - r * r));
  vec3 n = vec3(uv, z);

  // Rotate the sampling point around the vertical axis.
  float cs = cos(uSpin);
  float sn = sin(uSpin);
  vec3 p = vec3(n.x * cs - n.z * sn, n.y, n.x * sn + n.z * cs);

  float t = uTime * (0.18 + 0.25 * uTurb);
  vec3 q = p * (1.7 + 0.6 * uTurb) + vec3(0.0, t, t * 0.6);
  float warp = fbm(q * 1.3 + vec3(t * 0.7));
  float f = fbm(q + warp * (1.1 + 1.4 * uEnergy + 0.8 * uTurb));

  // Deep base -> primary plasma; the noise also drives emissive veins.
  vec3 col = mix(uColB, uColA, smoothstep(0.28, 0.72, f));
  float fil = pow(1.0 - abs(f * 2.0 - 1.0), 6.0);
  vec3 veinCol = mix(uColA, uColC, 0.35);
  col += veinCol * fil * (0.55 + 1.2 * uEnergy);
  float hot = pow(smoothstep(0.55, 0.85, warp), 2.0);
  col += uColA * hot * (0.25 + 0.5 * uEnergy);

  // Lighting (Flutter's y axis points down, so the light is top-left).
  vec3 L = normalize(vec3(-0.45, -0.6, 0.75));
  float diff = clamp(dot(n, L), 0.0, 1.0);
  col *= 0.5 + 0.65 * diff;

  // Inner core glow and fresnel rim (primary-tinted, not white).
  col += uColA * pow(z, 3.0) * (0.12 + 0.4 * uEnergy);
  float fres = pow(1.0 - z, 2.4);
  col += mix(uColA, uColC, 0.25) * fres * (1.2 + 0.8 * uEnergy);

  // Specular highlight.
  vec3 H = normalize(L + vec3(0.0, 0.0, 1.0));
  float spec = pow(max(dot(n, H), 0.0), 64.0);
  col += mix(uColC, vec3(1.0), 0.5) * spec * 0.6;

  // Saturation lift, then a luminance-based tonemap that keeps hue.
  float lum = dot(col, vec3(0.2126, 0.7152, 0.0722));
  col = max(mix(vec3(lum), col, 1.3), 0.0);
  float peak = max(max(col.r, col.g), col.b);
  col *= 1.0 / (1.0 + max(peak - 0.85, 0.0) * 0.8);
  fragColor = vec4(col * alpha, alpha);
}
