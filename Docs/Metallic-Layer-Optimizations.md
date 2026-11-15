# Metallic Layer Optimizations

How the Metallic background's fragment shader
(`FruitFarm/Backgrounds/Types/MetallicLayer.swift`) was made cheaper, and why each
change is safe.

## Result

| Stage | GPU time per frame |
|---|---|
| Before any optimization | 0.48 ms |
| Pass 1: early exit + one heightfield evaluation | 0.33 ms |
| Visual work (iridescence, ACES, uniform blobs, contrast) | 0.39 ms |
| Pass 2: precomputation, gradient extrapolation, half precision | **0.235 ms** |

Measured on an Apple M4 Pro with an offscreen harness: a 1455×1736 px logo box,
one draw per command buffer, median of 150 frames. About 0.17 ms of every number is
fixed clear/store cost, so the shading itself shrank by much more than the totals show.

After each step, three frames from the 30 s loop (t = 0, 7, 19) were rendered and
diffed against the previous version. Unless noted, differences are at most a few
levels out of 255.

## Groundwork that already existed

These were already in place, in the same pattern as `PuppyLayer` and `GlassLayer`:

- The logo relief (`PuppyLayer.bakeHeightTexture`) is baked on a background queue
  and only re-baked when the logo rect changes.
- A scissor rect limits rasterization to the logo's bounding box.
- Redraws are throttled to 30 fps.

## Pass 1

### Skip pixels outside the logo

The layer is masked to the fruit and leaf (`FruitView.swift`), but the shader shaded
the whole bounding box. It now samples the baked map once and returns black where the
logo is absent. The mask hides those pixels anyway, so the output is identical.

> Assumes the layer is always masked to the logo. Unmasked, the box corners would
> render black.

### Evaluate the liquid heightfield once, not four times

Surface normals use central differences: the height is sampled at `lp ± e` on both
axes. The liquid heightfield (`metallic_gallium`) was evaluated at all four taps.
It now returns its height **plus an analytic gradient**. The four taps are linear
extrapolations, `h ± e·∂h`, which are exact to first order at `e = 0.01`.

## Visual work: constant tables

The uniform hex blob layout first computed each blob's orbit with `sin`/`cos` inside
the loop, which cost 0.38 → 0.54 ms. Each orbit's phase offset was baked into a
constant table and rotated by `a`, which brought it back to 0.39 ms.

## Pass 2

### 1. Per-frame values move to the CPU

Everything that depends only on time or layout is now computed once per frame in
`display()` and passed in `MetallicUniforms`:

| Value | Previously, per pixel |
|---|---|
| `anim = (a, sin a, cos a, grain seed)` | `fract`, `sin`, `cos` on uniform time |
| `blobs[7]`: each blob's centre this frame | 4 trig + table rotation per blob |
| `lp_scale` / `lp_offset`: screen → liquid space | subtract, two divides |
| `uv_scale` / `uv_offset`: screen → logo texture | subtract, divide |
| `lp_to_uv`: d(uv)/d(lp) | rebuilt in every tap |

The struct is declared twice: in Metal (`MetallicUniforms`) and in Swift
(`MetalMetallicFragmentUniforms`). **Keep their field order in sync.** The `float4`
comes first so the struct packs to 112 bytes with no padding.

### 2. Bake the slab profile once (`bakeSlabTexture`)

Each normal tap used to read the RGBA32F relief (16 bytes per texel) and turn it into
a height with a `sqrt` and a `mix`. Since the logo only changes on re-bake, that
conversion now happens once, on the CPU, right after `bakeHeightTexture`, into an
**RG32F** texture:

- R = slab height: `0.55·sqrt(1 − k²·mix(k, 1, leafness)) + 0.45·crown`
- G = face: 1 on the flat top, falling to 0 down the bevel and outside the logo

The shader saves 5 texture reads' worth of bandwidth (half the bytes each) and
4 `sqrt` per pixel. The early exit now tests `G <= 0`, which is equivalent to the old
`ramp <= 0`.

### 3. Extrapolate the logo forming and its drag (the biggest win)

Pass 1 extrapolated only the liquid. The other per-tap terms were still computed four
times:

- `form`: where the liquid has "set" into the logo, which uses 2 `sin`.
- the outline drag: an offset to the logo UV, which uses 1 `sin` + 1 `cos`.

Both now run **once** at the pixel centre, along with their gradients:

- `form` uses the derivative of `smoothstep`, `6t(1−t)/0.6`, chained through the
  skew from `lp` to `p`.
- The drag gradient gives each tap's texture offset:
  `uv ± e·(lp_to_uv + ∂drag)`. The taps follow the bent outline exactly as before.

That removes about 16 trig calls per pixel. The four taps differ only in their
texture reads. Liquid height, `form` and the final heights are computed as `float4`
across the four taps.

### 4. Cheaper math

- Every `exp(x)` became `exp2(x·log2 e)`, with the constant folded at compile time.
  The blob loop also moves the `−2k` gradient factor out of the loop.
- `pow(1 − n.z, 3)` became `f·f·f`.
- The glint's light direction is normalized ahead of time.
- The thin-film constants (`4πn/λ`, `1/n²`) are folded.
- `sincos` returns both values from one call.
- The 7-blob loop is marked `#pragma unroll`. It has a constant trip count and no
  branches.
- Two unused helpers (`metallic_line`, `metallic_bloom`) were removed.

### 5. Half precision for colour

Everything after the surface normal runs in `half`: the environment lookup, Fresnel,
thin-film tint, glint, seams, grain, ACES and the contrast S-curve. Apple GPUs run
16-bit ALU at up to twice the rate. Colour differs by at most 7/255.

Exceptions that stay in `float`:

- **Heights and gradients.** Small differences between taps would vanish in 16-bit.
- **The thin-film phase.** It reaches about 120 rad, where `half` has no
  fractional precision left.
- **The `pow(·, 400)` glint exponent.** The `pow` runs in `float`, and only its
  result is converted.

### Image differences in Pass 2

Mean difference about 0.05/255. About 0.04% of pixels differ strongly: the hard
horizon edge in the reflected environment moves by about one pixel. That comes from
the slightly different extrapolated normals and is not visible.

## Tried and rejected

| Idea | Outcome |
|---|---|
| RG16F slab texture | Only 3% faster. Brought back stair-stepped highlights on the bevel (1.3% of pixels off by up to 186/255), as `PuppyLayer`'s bake comment warns. |
| Forward differences (3 taps instead of 4) | Faster, but shifted highlights by about 3 px. |
| Pass 1: moving time-only trig to the CPU alone | No measurable gain then. In Pass 2 it was combined with the other changes, so it was not measured on its own again. |

## Branching

The only branch is the early exit for pixels outside the logo. It is coherent:
whole corner regions of the box take it together, and it skips all shading there.
The rest of the shader is straight-line code: `smoothstep`/`mix`/`max` instead of
conditionals, and a fully unrolled blob loop.

## Tuning knobs

All in `metallic_surface_color` / `metallic_gallium`:

- Blob size: `3.6` (the `k` in `exp2(-3.6 * …)` and `-2.0 * 3.6`). Change both together.
- Edge reflection strength: `1.4` in `0.85h + 1.4h * fr * fr * fr`.
- Contrast: `0.7h` in the final S-curve `mix`.
- Normal tap spacing: `e = 0.010`. The extrapolations assume it stays small.
