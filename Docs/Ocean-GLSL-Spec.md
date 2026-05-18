# Ocean GLSL Shader Spec

## Overview

This document describes the GLSL ocean shader used as the reference for the Fruit ocean background. The shader renders a stylized animated sea by ray marching against a procedural height field, computing normals from that field, and mixing sky reflection, water refraction, diffuse lighting, and specular highlights.

The original shader is written in the Shadertoy style:

- `mainImage(out vec4 fragColor, in vec2 fragCoord)` is the fragment entry point.
- `iResolution` provides the render target size in pixels.
- `iTime` drives animation.

In Fruit, the equivalent implementation is hosted by a `CAMetalLayer` background. A Metal shader is compiled at runtime, a full-screen two-triangle rectangle is drawn, and fragment uniforms provide the current drawable resolution and elapsed time. The layer can restrict rendering to the Fruit logo bounds with a Metal scissor rect, so the ocean appears inside the logo rather than across the whole screen.

## Visual Goal

The shader produces a moving ocean viewed from a low camera angle:

- A procedural wave height field defines the sea surface.
- The camera ray is traced until it intersects the height field.
- The sky color is reflected by grazing angles through Fresnel blending.
- The water body is tinted with deep blue-green refraction.
- Specular highlights sharpen on closer waves.
- A final gamma curve brightens the result for display.

The effect is not a physical ocean simulation. It is a compact procedural approximation designed to look convincing in real time.

## Shader Inputs

| Input | Purpose |
| --- | --- |
| `iResolution.xy` | Converts fragment coordinates into normalized viewport coordinates and scales normal sampling. |
| `iTime` | Advances waves and camera motion. |
| `fragCoord` | Pixel coordinate for the current fragment. |

Fruit's Metal implementation should map these inputs to a uniform struct similar to:

```metal
struct OceanUniforms {
    float2 resolution;
    float time;
};
```


## Constants

### Ray Marching

- `NUM_STEPS = 32`: Maximum number of root-finding iterations used to locate the sea surface along a view ray.
- `EPSILON = 1e-3`: Early-exit threshold for the height-field intersection.
- `EPSILON_NRM = 0.1 / iResolution.x`: Resolution-scaled offset used for finite-difference normal sampling.
- `AA`: Optional 3x3 supersampling block. Disabled by default because it multiplies fragment cost by nine.

### Sea Shape

- `ITER_GEOMETRY = 3`: Lower-detail height evaluation used while tracing rays.
- `ITER_FRAGMENT = 5`: Higher-detail height evaluation used for normals and final shading.
- `SEA_HEIGHT = 0.6`: Base amplitude for the first octave.
- `SEA_CHOPPY = 4.0`: Controls how sharp and peaked the waves are.
- `SEA_SPEED = 0.8`: Scales time in the wave field.
- `SEA_FREQ = 0.16`: Base spatial frequency.
- `SEA_TIME = 1.0 + iTime * SEA_SPEED`: Shared animation phase for wave movement.
- `octave_m`: Rotates and scales each octave so repeated wave layers do not align.

### Color

- `SEA_BASE`: Deep base water color.
- `SEA_WATER_COLOR`: Warm reflected/refracted water tint.

## Rendering Pipeline

The shader follows this per-fragment flow:

1. Convert `fragCoord` into aspect-correct normalized screen coordinates.
2. Build a camera origin and view direction.
3. Rotate the view direction with a time-varying Euler matrix.
4. Ray march from the camera into the procedural sea height field.
5. Estimate the surface normal at the intersection point.
6. Shade the sea from sky reflection, water refraction, diffuse light, attenuation, and specular highlights.
7. Blend between sky and sea based on whether the ray points below the horizon.
8. Apply a final gamma-style color curve.

## Function Reference

### `fromEuler(vec3 ang)`

Builds a 3x3 rotation matrix from Euler angles. `getPixel` uses this to animate the camera orientation:

- `ang.x` rocks the camera slightly.
- `ang.y` changes pitch.
- `ang.z` slowly rolls/yaws with time.

When porting to Metal, this can remain as a helper returning `float3x3`. Matrix multiplication order must be checked because GLSL and Metal matrix conventions can differ depending on how values are constructed.

### `hash(vec2 p)` and `noise(vec2 p)`

`hash` generates repeatable pseudo-random values from a 2D grid coordinate. `noise` interpolates four hash samples with a smooth cubic curve:

```glsl
vec2 u = f * f * (3.0 - 2.0 * f);
```

The result is value noise in the `[-1, 1]` range. The noise is used to disturb wave coordinates, preventing overly regular sine-wave patterns.

### `diffuse(vec3 n, vec3 l, float p)`

Computes a softened diffuse term:

```glsl
pow(dot(n, l) * 0.4 + 0.6, p)
```

The `0.4 + 0.6` bias keeps water from becoming fully black when it faces away from the light. The high exponent makes the contribution subtle and concentrated.

### `specular(vec3 n, vec3 l, vec3 e, float s)`

Computes a normalized Phong-style specular highlight using `reflect(e, n)`. The `s` value controls sharpness. In `getSeaColor`, sharpness is scaled by inverse distance so close wave glints are tighter and brighter than distant ones.

### `getSkyColor(vec3 e)`

Returns a simple procedural sky gradient from the view direction. The sky is warmer near the horizon and brighter/cooler higher up. This sky is also sampled through reflected water rays.

### `sea_octave(vec2 uv, float choppy)`

Creates one choppy wave octave:

1. Distort `uv` with value noise.
2. Build wave bands from `sin` and `cos`.
3. Blend between those bands to create sharper crests.
4. Raise the result by `choppy`.

Higher `choppy` values produce pointed, energetic waves. Later octaves blend `choppy` toward `1.0`, making small details softer than the primary waves.

### `map(vec3 p)`

Evaluates the signed height difference between a world-space point and the sea surface:

```glsl
return p.y - h;
```

Positive values mean the point is above the water surface. Negative values mean it is below. `map` uses `ITER_GEOMETRY` octaves for speed during ray marching.

Each octave:

- Samples waves moving in opposite directions with `(uv + SEA_TIME)` and `(uv - SEA_TIME)`.
- Adds the result to height `h`.
- Rotates/scales `uv` with `octave_m`.
- Increases frequency.
- Reduces amplitude.
- Reduces choppiness.

### `map_detailed(vec3 p)`

Same as `map`, but uses `ITER_FRAGMENT` octaves. It is more expensive and more detailed, so it is reserved for final normal calculation.

### `getNormal(vec3 p, float eps)`

Approximates the water normal with finite differences:

- Sample the detailed height field at `p`.
- Sample again slightly offset in `x`.
- Sample again slightly offset in `z`.
- Use those deltas plus `eps` as the normal vector.

The caller scales `eps` by distance:

```glsl
dot(dist, dist) * EPSILON_NRM
```

This reduces high-frequency shimmer in distant waves by sampling normals over a larger footprint.

### `heightMapTracing(vec3 ori, vec3 dir, out vec3 p)`

Finds the intersection between the view ray and the procedural water surface.

The method is a bounded secant/binary-style search:

1. Start at the camera with `tm = 0.0`.
2. Set a far point with `tx = 1000.0`.
3. If the far point is still above water, return it because the ray never hits the sea.
4. Otherwise, repeatedly interpolate between the near and far distances using the signed height values.
5. Keep the interval half that crosses the surface.
6. Stop once the height error is below `EPSILON` or `NUM_STEPS` is reached.

This is efficient because the sea is a height field rather than arbitrary 3D geometry.

### `getSeaColor(vec3 p, vec3 n, vec3 l, vec3 eye, vec3 dist)`

Shades the water at the intersection point.

The function combines:

- Fresnel reflection: grazing angles reflect more sky.
- Refraction tint: base water color plus a small diffuse lighting term.
- Distance attenuation: nearby wave faces receive more visible water color.
- Specular highlight: sharp reflected light from the wave normal.

The Fresnel factor is clamped to `0.5`, preventing reflections from completely overpowering the water color.

### `getPixel(vec2 coord, float time)`

Builds the camera and returns the final RGB color for one pixel.

Important steps:

- Normalizes the pixel coordinate to `[-1, 1]`.
- Corrects `uv.x` by aspect ratio.
- Sets camera origin to `vec3(0.0, 3.5, time * 5.0)`, moving forward over time.
- Builds a ray toward `z = -2.0` and bends it slightly with `length(uv) * 0.14`.
- Rotates the ray by `fromEuler`.
- Traces the sea surface.
- Computes normal and light.
- Blends sea with sky around the horizon:

```glsl
pow(smoothstep(0.0, -0.02, dir.y), 0.2)
```

This keeps upward-facing rays as sky and downward-facing rays as ocean.

### `mainImage(out vec4 fragColor, in vec2 fragCoord)`

Entry point for Shadertoy. It computes shader time, optionally performs 3x3 antialiasing, then applies final color correction:

```glsl
fragColor = vec4(pow(color, vec3(0.65)), 1.0);
```

The power curve brightens midtones and gives the ocean a more display-ready contrast.

## Fruit Implementation Notes

Fruit backgrounds are layer-based, so the GLSL effect is implemented through a Metal-backed layer rather than a Shadertoy runtime.

The expected structure is:

1. Store the translated shader source in a Swift string.
2. Compile the source with `device.makeLibrary(source:options:)`.
3. Create a render pipeline with a pass-through vertex function and the ocean fragment function.
4. Upload six vertices for a full-screen rectangle.
5. On each display pass, send resolution and elapsed time as fragment uniforms.
6. Draw the rectangle into the current drawable.
7. Apply a scissor rect matching the Fruit logo bounds when the background should only fill the logo.

The existing `OceanLayer` follows this shape:

- It subclasses `CAMetalLayer`.
- It creates a `MTLCommandQueue`, `MTLRenderPipelineState`, and shared vertex buffer.
- It tracks elapsed time in `update(deltaTime:)`.
- It redraws at a capped interval of 30 FPS.
- It passes `resolution` and `time` to the fragment shader.
- It uses the Fruit path bounds to restrict rendering to the visible logo region.

## GLSL to Metal Translation Notes

Most GLSL functions map directly to Metal Shading Language, but these differences matter:

| GLSL | Metal |
| --- | --- |
| `vec2`, `vec3`, `vec4` | `float2`, `float3`, `float4` |
| `mat2`, `mat3` | `float2x2`, `float3x3` |
| `mix(a, b, t)` | `mix(a, b, t)` |
| `fract(x)` | `fract(x)` |
| `in`, `out` params | Regular parameters or references, depending on use |
| `mainImage` | `fragment` function |
| `iResolution`, `iTime` | Uniform buffer fields |

The GLSL `out vec3 p` in `heightMapTracing` should become a thread reference in Metal:

```metal
float heightMapTracing(float3 ori, float3 dir, thread float3 &p)
```

Metal fragment shaders receive interpolated vertex output rather than Shadertoy's `fragCoord`. The Fruit vertex shader should output either clip-space position plus pixel position, or the fragment shader should derive pixel coordinates from `in.position.xy`, matching the existing Metal layer pattern.

## Performance Considerations

This shader is more expensive than a pure 2D procedural background:

- Each pixel can run up to `NUM_STEPS` height evaluations.
- Each height evaluation samples multiple wave octaves.
- Final normal calculation uses the more detailed height function three times.
- Enabling `AA` multiplies the whole cost by nine.

For Fruit, keep antialiasing disabled by default. Prefer controlling quality through:

- Lowering `NUM_STEPS`.
- Reducing `ITER_FRAGMENT`.
- Capping redraws at 30 FPS.
- Rendering only inside the Fruit logo with a scissor rect.

## Tuning Guide

| Parameter | Increase Effect | Decrease Effect |
| --- | --- | --- |
| `SEA_HEIGHT` | Taller waves | Flatter water |
| `SEA_CHOPPY` | Sharper crests | Rounder waves |
| `SEA_SPEED` | Faster wave animation | Slower water |
| `SEA_FREQ` | More frequent waves | Larger wave spacing |
| `ITER_GEOMETRY` | More accurate ray hits | Faster tracing |
| `ITER_FRAGMENT` | More detailed normals | Smoother, cheaper shading |
| `NUM_STEPS` | Fewer intersection artifacts | Better performance |

## Expected Output

The final render should look like an animated, reflective ocean with a clear horizon. Near the horizon, sky reflection dominates. Below the horizon, the water shows layered choppy wave shapes, deep base color, subtle green-yellow tinting, and small bright specular flashes.

Inside Fruit, the same visual can be treated as a dynamic fill for the logo silhouette. The shader does not need scene geometry, textures, or precomputed assets; all motion and detail come from procedural math and elapsed time.
