import Cocoa
import QuartzCore
import Foundation
import MetalKit

private let metalCaliforniaShaderSource = """
using namespace metal;

struct VertexData {
    float2 position;
};

struct VertexOut {
    float4 position [[position]];
};

vertex VertexOut vertex_shader_california(
    const device VertexData* vertex_array [[buffer(0)]],
    unsigned int vid [[vertex_id]]) {
    VertexOut out;
    out.position = float4(vertex_array[vid].position, 0.0, 1.0);
    return out;
}

struct CaliforniaUniforms {
    float2 resolution;
    float2 center;   // fruit centre, pixels
    float radius;    // fruit half-height, pixels
    float time;
    float daylight;  // 1 = day, 0 = night (local clock)
    float bugU;      // ladybird progress along its crossing, >= 1 = off the leaf
    float bugCrossing; // which crossing, picks the route
    float bugSleep;  // 0 = awake, 1 = curled up asleep
    float spring;    // season weights (summer is the rest)
    float fall;
    float winter;
};

float california_hash(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float2 california_hash2(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

float california_noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(california_hash(i), california_hash(i + float2(1.0, 0.0)), u.x),
        mix(california_hash(i + float2(0.0, 1.0)), california_hash(i + float2(1.0, 1.0)), u.x),
        u.y
    );
}

float california_fbm(float2 p) {
    float value = 0.0;
    float amplitude = 0.5;
    float2x2 turn = float2x2(0.86, 0.50, -0.50, 0.86);

    for (int i = 0; i < 4; i++) {
        value += amplitude * california_noise(p);
        p = turn * p * 2.03 + 7.1;
        amplitude *= 0.52;
    }

    return value;
}

// Voronoi. x = F2 - F1 (0 on the cell walls, grows toward the cell centre),
// y = per-cell random. The walls are the vein network.
float2 california_cells(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float f1 = 8.0;
    float f2 = 8.0;
    float id = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float2 g = float2(float(x), float(y));
            float2 o = california_hash2(i + g);
            float2 r = g + o - f;
            float d = dot(r, r);
            if (d < f1) { f2 = f1; f1 = d; id = o.x; }
            else if (d < f2) { f2 = d; }
        }
    }
    return float2(sqrt(f2) - sqrt(f1), id);
}

// Sap pulse travelling along coordinate s: sharp head, long wet tail.
float california_flow(float s, float time) {
    float d = s - time * 0.11;
    d = d - floor(d + 0.5);
    return exp(-(d > 0.0 ? 160.0 : 22.0) * d * d);
}

// One dew drop per grid cell. xy = offset from the drop centre in radii,
// z = dome height (0 outside), w = radius in leaf units. `slide` runs each
// column of drops down the blade at its own pace.
float4 california_drop(float2 p, float cellSize, float seed, float density, float slide, float snow) {
    float2 g = p / cellSize;
    g.y += slide * (0.35 + california_hash(float2(floor(g.x), seed)));
    float2 id = floor(g);
    float2 k = california_hash2(id * 1.37 + seed + 37.0);
    if (k.y >= density) { return float4(0.0); }
    float r = mix(0.10, 0.33, k.x * k.x);
    float2 c = r + (1.0 - 2.0 * r) * california_hash2(id + seed);
    float2 q = (fract(g) - c) / r;
    q.x *= 0.88 + 0.24 * k.y / density;   // not perfectly round
    // Snow: a ragged outline and a lumpy top. The outline only ever shrinks, so
    // it stays inside the round drop the ladybird steers around.
    float rough = snow * (0.22 * california_noise(q * 2.5 + id * 5.0) + 0.06 * california_noise(q * 8.0 + id));
    float d = sqrt(dot(q, q)) + rough;
    if (d >= 1.0) { return float4(0.0); }
    return float4(q, sqrt(1.0 - d * d), r * cellSize);
}

struct CaliforniaLeaf {
    float3 color;
    float height;
    float sap;
    float glow;        // bioluminescence, shown at night
    float3 glowColor;
};

// Season tint on the tissue, keeping its light and dark pattern. Spring pushes
// the greens, autumn turns it light brown, winter greys it to frosted blue.
float3 california_season_tint(float3 c, float spring, float fall, float winter) {
    float lum = dot(c, float3(0.30, 0.59, 0.11));
    float3 lush = float3(c.r * 0.70, min(c.g * 1.40 + 0.03, 1.0), c.b * 0.75);
    float3 autumn = mix(float3(0.22, 0.14, 0.06), float3(0.44, 0.31, 0.18), smoothstep(0.0, 0.6, lum));
    float3 ice = mix(float3(0.52, 0.56, 0.62), float3(0.88, 0.91, 0.94), smoothstep(0.05, 0.6, lum));
    c = mix(c, lush, spring * 0.85);
    c = mix(c, autumn, fall * 0.92);
    return mix(c, ice, winter * 0.95);
}

// Soft sway: the blade wobbles in place (summer and fall).
float2 california_soft_sway(float2 p, float t) {
    return 0.030 * float2(sin(t * 0.45 + p.y * 2.0), cos(t * 0.36 + p.x * 2.0));
}

// Frozen sway: the whole blade rocks side to side as one stiff piece.
float2 california_rigid_sway(float t) {
    return float2(0.040 * sin(t * 0.55), 0.0);
}

CaliforniaLeaf california_leaf(float2 p, float t, float night, float3 season) {
    // The whole blade sways as one piece: softly in place, or rocking when frozen.
    p += (1.0 - season.z) * california_soft_sway(p, t) + season.z * california_rigid_sway(t);

    // Midrib: tapers from base (bottom) to tip (top).
    float spineX = 0.05 * sin(p.y * 1.3 + 0.4) + 0.02 * sin(p.y * 3.1);
    float dx = p.x - spineX;
    float d = abs(dx);
    float midW = mix(0.050, 0.014, clamp(p.y * 0.5 + 0.5, 0.0, 1.0));
    float mid = 1.0 - smoothstep(midW * 0.55, midW, d);

    // Secondary veins: level sets of `anchor`, which is constant along a
    // curve that leaves the midrib and sweeps toward the tip. Sides alternate.
    float curve = 0.75 * d + 0.55 * d * d;
    float slope = 0.75 + 1.10 * d;
    float anchor = p.y - curve;
    const float spacing = 0.23;
    float vc = (anchor + (california_noise(p * 3.0) - 0.5) * 0.06) / spacing
             + (dx < 0.0 ? 0.5 : 0.0);
    float dv = abs(fract(vc) - 0.5) * spacing / sqrt(1.0 + slope * slope);
    float secW = mix(0.015, 0.004, smoothstep(0.0, 0.9, d));
    float sec = 1.0 - smoothstep(secW * 0.5, secW, dv);

    // Tertiary veins bridge the secondaries (cells laid out in vein space),
    // then two finer generations of areoles and epidermal cells.
    float2 tert  = california_cells(float2(d * 8.0, vc * 2.0) + 3.0);
    float2 fine  = california_cells(p * 30.0 + 7.0);
    float2 micro = california_cells(p * 85.0);
    float tertLine = 1.0 - smoothstep(0.03, 0.12, tert.x);
    float fineLine = 1.0 - smoothstep(0.04, 0.16, fine.x);

    CaliforniaLeaf leaf;

    // Lamina bulges between the veins, veins sit in grooves, midrib is a ridge.
    float h = 0.55 * smoothstep(0.0, 0.07, dv)
            + 0.30 * smoothstep(0.0, 0.35, tert.x)
            + 0.16 * smoothstep(0.0, 0.40, fine.x)
            + 0.07 * micro.x;

    // Imperfections: brown blotches with a yellowed halo, and a few scratches
    // running diagonally across the blade.
    float blotch = california_fbm(p * 6.0 + 21.0);
    float spot = smoothstep(0.73, 0.77, blotch);
    float halo = smoothstep(0.65, 0.73, blotch);
    float2 q = float2(0.80 * p.x + 0.60 * p.y, -0.60 * p.x + 0.80 * p.y);
    float lane = q.y * 2.3 + 0.10 * california_noise(q * 2.0);
    float scratch = (1.0 - smoothstep(0.0, 0.012, abs(fract(lane) - 0.5)))
                  * smoothstep(0.60, 0.75, california_noise(float2(q.x * 1.6, floor(lane) * 7.3)));
    h = (h - 0.25 * scratch) * (1.0 - 0.5 * spot);

    // Midrib cross-section: r runs -1...1 across it, fibres run along it.
    float ridge = d / midW;
    float r = dx / midW;
    float fibre = california_noise(float2(r * 5.0, p.y * 2.5 + 4.0));
    float rib = 0.9 * sqrt(max(1.0 - ridge * ridge, 0.0)) + 0.10 * fibre;
    leaf.height = mix(h, rib, mid);

    float mottle = california_fbm(p * 2.6 + float2(1.7, -2.4));
    float3 color = mix(float3(0.04, 0.17, 0.05), float3(0.15, 0.40, 0.09),
                       smoothstep(0.25, 0.75, mottle));
    color *= 0.80 + 0.25 * fine.y + 0.15 * tert.y;         // areole-to-areole variation
    color *= 0.88 + 0.24 * micro.y * smoothstep(0.0, 0.3, micro.x);
    // Dust specks and the odd dead areole.
    color *= 1.0 - 0.60 * step(0.965, micro.y) * smoothstep(0.0, 0.25, micro.x);
    color = mix(color, float3(0.30, 0.20, 0.08),
                step(0.95, fine.y) * smoothstep(0.05, 0.30, fine.x) * 0.70);
    color = mix(color, float3(0.30, 0.55, 0.15), fineLine * 0.40);
    color = mix(color, float3(0.40, 0.64, 0.20), tertLine * 0.60);
    color = mix(color, float3(0.58, 0.78, 0.30), sec);
    color = mix(color, float3(0.42, 0.46, 0.10), halo * 0.55);
    color = mix(color, float3(0.26, 0.17, 0.06), spot * 0.85);
    color = mix(color, float3(0.50, 0.62, 0.30), scratch * 0.50);

    // Midrib: woody at the base, green toward the tip, rounded (lit side to
    // shadow side with a highlight), streaked with fibres and grime, and
    // sitting in a shadowed groove.
    float3 ribColor = mix(float3(0.62, 0.58, 0.28), float3(0.70, 0.85, 0.40),
                          smoothstep(0.0, 0.6, p.y * 0.5 + 0.5));
    ribColor *= 0.78 + 0.38 * fibre;
    float grime = smoothstep(0.55, 0.80, california_noise(float2(r * 3.0, p.y * 9.0) + 9.0));
    ribColor = mix(ribColor, float3(0.22, 0.16, 0.07), grime * 0.55);
    float lit = r + 0.35;
    ribColor *= 0.92 - 0.42 * r + 0.25 * exp(-16.0 * lit * lit);
    float groove = ridge - 1.15;
    color *= 1.0 - 0.45 * exp(-12.0 * groove * groove);
    color = mix(color, ribColor, mid);

    // Seasons. Winter frosts the cell walls and rime patches; autumn eats holes
    // (they spread in as the season comes, never through the midrib) with
    // dried brown edges.
    color = california_season_tint(color, season.x, season.y, season.z);
    float frost = season.z * max(1.0 - smoothstep(0.0, 0.05, california_cells(p * 9.0 + 13.0).x),
                                 0.6 * smoothstep(0.45, 0.75, california_fbm(p * 3.5 + 60.0)));
    color = mix(color, float3(0.92, 0.97, 1.0), frost * 0.55);
    leaf.height += 0.05 * frost;

    float holeField = california_fbm(p * 8.0 + 40.0);
    float cut = 0.68 + 0.5 * (1.0 - season.y);
    float inside = smoothstep(cut - 0.008, cut + 0.008, holeField) * (1.0 - 0.9 * mid);
    float edge = smoothstep(cut - 0.035, cut - 0.008, holeField) * (1.0 - 0.9 * mid) * (1.0 - inside);
    color = mix(color, float3(0.30, 0.18, 0.07), edge * 0.9);
    color = mix(color, float3(0.02, 0.015, 0.01), inside);
    leaf.height -= 0.25 * edge;

    // At night the same tissue reads in purple: keep its light/dark pattern.
    float lum = dot(color, float3(0.30, 0.59, 0.11));
    leaf.color = mix(color, lum * float3(0.62, 0.30, 1.0) * 0.9, night);

    // Bioluminescence: the vein network glows, brightest on the big veins with
    // a soft halo into the tissue; patches breathe slowly and dead spots stay dark.
    float glow = max(max(mid * 0.9, sec * 0.8), max(tertLine * 0.45, fineLine * 0.16));
    glow += 0.35 * exp(-d * 14.0) + 0.30 * exp(-dv * 40.0) * (1.0 - smoothstep(0.5, 1.1, d));
    glow *= (0.65 + 0.35 * sin(t * 0.6 + mottle * 9.0)) * (1.0 - spot);
    leaf.glow = glow * (1.0 - inside);
    leaf.glowColor = mix(float3(0.62, 0.22, 1.0), float3(0.22, 0.80, 1.0),
                         smoothstep(0.35, 0.75, california_noise(p * 1.5 + t * 0.05)));

    // Water rises up the midrib, turns into each secondary where it meets it
    // (anchor == p.y at d == 0, so the wave is continuous), then seeps into
    // the tertiary network.
    float fMid = california_flow(p.y * 0.5, t);
    float fSec = california_flow((anchor + d * 1.3) * 0.5, t);
    float midCore = 1.0 - smoothstep(0.0, midW * 0.7, d);
    float secCore = 1.0 - smoothstep(0.0, secW * 0.9, dv);
    float reach = 1.0 - smoothstep(0.45, 1.0, d);
    leaf.sap = max(fMid * midCore, fSec * reach * max(secCore, 0.30 * tertLine));
    // Wet glow bleeding into the tissue around the veins.
    leaf.sap += 0.30 * fMid * exp(-d * 22.0) + 0.22 * fSec * reach * exp(-dv * 45.0);
    // Frozen plants don't flow, and holes don't carry water.
    leaf.sap *= (1.0 - season.z) * (1.0 - 0.6 * season.y) * (1.0 - inside);
    return leaf;
}

// Adds a tapered limb segment a->c to the nearest-leg record:
// x = signed distance (negative inside), y = 0 at the edge ... 1 on the spine.
void california_limb(float2 p, float2 a, float2 c, float ra, float rc, thread float2 &best) {
    float2 pa = p - a;
    float2 ca = c - a;
    float h = clamp(dot(pa, ca) / dot(ca, ca), 0.0, 1.0);
    float r = mix(ra, rc, h);
    float d = length(pa - ca * h);
    if (d - r < best.x) {
        float k = clamp(d / r, 0.0, 1.0);
        best = float2(d - r, sqrt(1.0 - k * k));
    }
}

// Six jointed legs (femur, tibia, tarsus, claw) in an alternating tripod gait.
// A leg in its swing phase lifts and tucks in slightly. Asleep, the legs fold
// under the wing cases.
float2 california_bug_legs(float2 b, float walk, float sleep) {
    float2 best = float2(1e3, 0.0);
    for (int i = 0; i < 3; i++) {
        float x = 0.50 - 0.52 * float(i);
        float splay = 0.38 * float(1 - i);
        for (int k = 0; k < 2; k++) {
            float sd = (k == 0) ? 1.0 : -1.0;
            float phase = walk + 3.14159 * float(i + k);
            float swing = 0.22 * sin(phase) * (1.0 - sleep);
            float lift = max(cos(phase), 0.0) * (1.0 - sleep);
            float2 hip   = float2(x, sd * 0.48);
            float2 knee  = float2(x + splay * 0.40 + swing * 0.30, sd * (1.00 - 0.05 * lift));
            float2 ankle = float2(x + splay * 0.80 + swing * 0.75, sd * (1.30 - 0.10 * lift));
            float2 foot  = float2(x + splay * 1.00 + swing,        sd * (1.46 - 0.13 * lift));
            knee  = mix(knee,  float2(x + 0.10, sd * 0.62), sleep);
            ankle = mix(ankle, float2(x - 0.05, sd * 0.56), sleep);
            foot  = mix(foot,  float2(x - 0.16, sd * 0.50), sleep);
            float2 claw  = foot + normalize(foot - ankle) * 0.07;
            california_limb(b, hip,   knee,  0.100, 0.075, best);
            california_limb(b, knee,  ankle, 0.068, 0.052, best);
            california_limb(b, ankle, foot,  0.050, 0.040, best);
            california_limb(b, foot,  claw,  0.020, 0.008, best);
        }
    }
    return best;
}

// Ladybird's route for one crossing, u = 0...1: a straight line through the
// blade picked by h, with a meander and a stop-and-go pace. z = distance walked.
float3 california_bug_path(float u, float2 h) {
    float a = h.x * 6.2832;
    float2 dir = float2(cos(a), sin(a));
    float2 side = float2(-dir.y, dir.x);
    float s = u + 0.028 * sin(u * 31.0);
    float2 pos = dir * mix(-1.7, 1.7, s)
               + side * ((h.y - 0.5) * 0.8 + 0.14 * sin(u * 8.0 + h.x * 20.0)
                         + 0.05 * sin(u * 21.0 + h.y * 9.0));
    return float3(pos, s * 3.4);
}

// Where the ladybird is at u: its route, carried by the blade's sway, and
// steered around the big (static) dew drops. Each drop gets a corridor: while
// the bug is within 2R of it along the route it eases sideways until it is at
// least R clear. The side is fixed per drop for the whole crossing (the side
// the straight route already passes on) so the bug never flips around a drop.
float3 california_bug_at(float u, float2 h, float t, float clearance, float winter) {
    const float cellSize = 0.46;   // must match the big drops in the fragment
    const float seed = 3.0;
    const float density = 0.50;
    float3 path = california_bug_path(u, h);
    // Avoidance works in the drops' unswayed frame. Frozen, the whole blade
    // rocks, so the bug and the drops move together (applied at the end).
    float2 pos = path.xy - (1.0 - winter) * california_soft_sway(path.xy, t);
    float a = h.x * 6.2832;
    float2 dir = float2(cos(a), sin(a));
    float2 side = float2(-dir.y, dir.x);
    float2 base = side * (h.y - 0.5) * 0.8;
    float2 home = floor(pos / cellSize);
    float2 shift = float2(0.0);
    for (int y = -2; y <= 2; y++) {
        for (int x = -2; x <= 2; x++) {
            float2 id = home + float2(float(x), float(y));
            float2 k = california_hash2(id * 1.37 + seed + 37.0);
            if (k.y >= density) { continue; }
            float r = mix(0.10, 0.33, k.x * k.x);
            float2 c = (id + r + (1.0 - 2.0 * r) * california_hash2(id + seed)) * cellSize;
            float squash = 0.88 + 0.24 * k.y / density;
            float R = r * cellSize / min(squash, 1.0) + clearance;
            float2 v = pos - c;
            float along = abs(dot(v, dir));
            float sgn = dot(base - c, side) >= 0.0 ? 1.0 : -1.0;
            float gap = R - dot(v, side) * sgn;
            // Smooth ramp of max(gap, 0) so the turn in and out is gradual.
            const float ease = 0.10;
            float push = gap > ease ? gap : (gap > -ease ? (gap + ease) * (gap + ease) / (4.0 * ease) : 0.0);
            shift += side * sgn * push * (1.0 - smoothstep(R, 2.0 * R, along));
        }
    }
    return float3(pos + shift - winter * california_rigid_sway(t), path.z);
}

// Ladybird (seven-spot) in its own frame: x forward, y to its left, wing
// cases 2 units long. `light` is the light direction in that frame.
// Returns colour + coverage.
// `sleep` folds legs and antennae away and draws the head in; `bounce` is
// the light coming up off the leaf.
float4 california_ladybird(float2 b, float walk, float t, float2 light, float sleep, float3 bounce) {
    b /= 1.0 + 0.015 * sin(t * 1.3) * sleep;   // slow breathing
    float ay = abs(b.y);
    float3 L = normalize(float3(light * 0.70, 0.72));
    float3 H = normalize(L + float3(0.0, 0.0, 1.0));
    float3 color = float3(0.0);
    float cover = 0.0;

    // Legs: dark brown chitin with a sheen down each segment.
    float2 leg = california_bug_legs(b, walk, sleep);
    float legCover = 1.0 - smoothstep(-0.012, 0.012, leg.x);
    float3 legColor = float3(0.025, 0.018, 0.014) * (0.5 + 0.8 * leg.y)
                    + float3(0.32, 0.28, 0.24) * pow(leg.y, 10.0) * 0.45;
    color = legColor;
    cover = legCover;

    // Clubbed antennae that twitch while it walks.
    float2 ant = float2(1e3, 0.0);
    float twitch = (0.05 * sin(t * 5.0) + 0.03 * sin(walk * 0.5)) * (1.0 - sleep);
    float2 ab = float2(b.x, ay);
    float2 aMid = mix(float2(1.68, 0.30 + twitch * 0.5), float2(1.46, 0.24), sleep);
    float2 aTip = mix(float2(1.84, 0.36 + twitch), float2(1.36, 0.22), sleep);
    california_limb(ab, float2(1.50, 0.15), aMid, 0.026, 0.020, ant);
    california_limb(ab, aMid, aTip, 0.020, 0.018, ant);
    california_limb(ab, aTip - float2(0.04, 0.0), aTip + float2(0.05, 0.02), 0.045, 0.040, ant);
    float antCover = 1.0 - smoothstep(-0.010, 0.010, ant.x);
    color = mix(color, float3(0.05, 0.035, 0.025) * (0.5 + 0.9 * ant.y), antCover);
    cover = max(cover, antCover);

    // Head: glossy black, compound eyes, two cream face spots, palps.
    // Asleep it is drawn in under the pronotum.
    float2 hb = b + float2(0.12 * sleep, 0.0);
    float hay = abs(hb.y);
    float2 hq = (hb - float2(1.40, 0.0)) / float2(0.22, 0.31);
    float he = length(hq);
    float headCover = 1.0 - smoothstep(0.92, 1.0, he);
    float3 hn = normalize(float3(hq * 0.8, sqrt(max(1.0 - he * he, 0.0)) + 0.1));
    float3 head = float3(0.025, 0.022, 0.02) * (0.4 + 0.8 * max(dot(hn, L), 0.0));
    float face = length(float2(hb.x - 1.53, hay - 0.10) / float2(0.06, 0.045));
    head = mix(head, float3(0.86, 0.84, 0.72) * (0.5 + 0.6 * max(dot(hn, L), 0.0)),
               1.0 - smoothstep(0.8, 1.0, face));
    float2 eq = float2(hb.x - 1.45, hay - 0.22) / float2(0.075, 0.095);
    float eye = length(eq);
    float3 en = normalize(float3(eq.x, eq.y * sign(hb.y), 1.2));
    float3 eyeColor = float3(0.07, 0.05, 0.04) * (0.6 + 0.4 * california_noise(eq * 9.0))
                    + pow(max(dot(en, H), 0.0), 60.0) * 0.9;
    head = mix(head, eyeColor, 1.0 - smoothstep(0.85, 1.0, eye));
    head += pow(max(dot(hn, H), 0.0), 50.0) * 0.6;
    float2 palp = float2(1e3, 0.0);
    california_limb(float2(hb.x, hay), float2(1.58, 0.06), float2(1.68, 0.11), 0.026, 0.018, palp);
    float palpCover = 1.0 - smoothstep(-0.008, 0.008, palp.x);
    color = mix(color, float3(0.16, 0.10, 0.06) * (0.5 + 0.7 * palp.y), palpCover);
    cover = max(cover, palpCover);
    color = mix(color, head, headCover);
    cover = max(cover, headCover);

    // Wing cases: one ellipsoid dome, split by a sunken seam so each half
    // bulges on its own. Fine pitting breaks up the reflections.
    float e = length(b / float2(1.0, 0.82));
    float shell = 1.0 - smoothstep(0.96, 1.0, e);
    float zh = sqrt(max(1.0 - e * e, 0.0));
    float3 n = float3(b.x, b.y / 0.6724, zh / 0.75);
    n.y -= sign(b.y) * 0.9 * exp(-ay * 16.0) * zh;
    n.xy += (float2(california_noise(b * 38.0), california_noise(b * 38.0 + 17.0)) - 0.5) * 0.18;
    n = normalize(n);
    float diffuse = max(dot(n, L), 0.0);
    float fresnel = pow(1.0 - n.z, 3.0);

    // Red with an orange glow at the thin rim where light passes through.
    float3 red = mix(float3(0.80, 0.07, 0.02), float3(1.0, 0.36, 0.06), smoothstep(0.75, 0.98, e) * 0.7);
    // Seven spots, slightly blotchy at the edges like real pigment.
    float wob = (california_noise(b * 9.0 + 3.0) - 0.5) * 0.05;
    float spots = min(min(length(float2(b.x - 0.32, ay - 0.42) / float2(1.0, 0.92)) - 0.17,
                          length(float2(b.x + 0.20, ay - 0.50)) - 0.20),
                      min(length(float2(b.x + 0.64, ay - 0.27) / float2(1.1, 1.0)) - 0.14,
                          length(float2(b.x - 0.76, b.y) / float2(0.85, 1.0)) - 0.16)) + wob;
    float spot = 1.0 - smoothstep(-0.02, 0.02, spots);
    float3 shellColor = mix(red, float3(0.025, 0.02, 0.018), spot);
    shellColor *= 0.30 + 0.95 * diffuse;
    // Darker flange at the rim and a dark seam line.
    shellColor *= mix(1.0, 0.45, smoothstep(0.90, 1.0, e));
    shellColor *= 0.35 + 0.65 * smoothstep(0.006, 0.030, ay);
    // Green bounce from the leaf at grazing angles, a soft sheen and a sharp
    // window highlight, as in a macro photo.
    shellColor += bounce * fresnel * 0.9;
    float nh = max(dot(n, H), 0.0);
    shellColor += float3(1.0) * pow(nh, 12.0) * 0.16;
    shellColor += float3(1.0, 0.98, 0.95) * smoothstep(0.35, 0.75, pow(nh, 70.0)) * 0.95;
    color = mix(color, shellColor, shell);
    cover = max(cover, shell);

    // Pronotum: a black shield narrowing toward the head, with the two big
    // cream patches at its front corners. It overlaps the wing cases.
    float pw = mix(0.70, 0.40, clamp((b.x - 0.84) / 0.50, 0.0, 1.0));
    float2 pq = float2((b.x - 1.07) / 0.27, b.y / pw);
    float pe = pow(abs(pq.x), 3.0) + pow(abs(pq.y), 2.4);
    float pron = 1.0 - smoothstep(0.82, 1.0, pe);
    float3 pn = normalize(float3(pq.x * 0.6, pq.y * 0.9, sqrt(max(1.0 - pe, 0.0)) + 0.15));
    float patchShape = length(float2((b.x - 1.15) / 0.15, (ay - 0.45) / 0.15));
    float3 pron3 = mix(float3(0.025, 0.022, 0.02), float3(0.88, 0.86, 0.76),
                       1.0 - smoothstep(0.80, 1.0, patchShape + wob * 4.0));
    pron3 *= 0.55 + 0.60 * max(dot(pn, L), 0.0);
    pron3 += pow(max(dot(pn, H), 0.0), 60.0) * 0.7 + bounce * 0.55 * pow(1.0 - pn.z, 3.0);
    // Shadow the pronotum casts onto the front of the wing cases.
    color *= 1.0 - 0.5 * shell * (1.0 - smoothstep(0.0, 0.10, b.x - (0.84 - 0.08 * pq.y * pq.y))) * (1.0 - pron);
    color = mix(color, pron3, pron);
    cover = max(cover, pron);

    return float4(color, cover);
}

// Airborne pollen in three depth layers: nearer grains drift faster, are bigger
// and out of focus. Each grain fades in, floats a while, fades out and comes
// back somewhere else. By night the grains glow faintly. `snow` turns the
// grains into falling six-lobed flakes.
float3 california_pollen(float3 color, float2 p, float t, float px, float2 L2, float night, float amount, float snow) {
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float s = 0.20 + 0.18 * fi;
        float2 wind = mix(float2(0.030, 0.010), float2(0.012, -0.075), snow) * (1.0 + 0.7 * fi);
        float2 q = (p - wind * t - float2(0.0, 0.015 * sin(t * 0.21 + fi * 2.0))) / s;
        float2 cell = floor(q);
        float2 h = california_hash2(cell + fi * 31.7);
        float life = t / (7.0 + 6.0 * h.x) + h.y;
        float cycle = floor(life);
        float2 k = california_hash2(cell + float2(cycle * 13.1, fi * 7.7));
        if (k.x > 0.60 * amount) { continue; }   // most cells stay empty this cycle
        float fade = sin(3.14159 * fract(life));
        fade *= fade;
        // Kept 0.2 of a cell from the edges so grain and halo never cross into a neighbour.
        float2 pos = 0.25 + 0.50 * california_hash2(cell + float2(cycle * 5.3 + 1.7, fi))
                   + 0.05 * float2(sin(t * (0.9 + k.y) + h.x * 6.3), cos(t * (0.7 + h.y) + k.y * 6.3));
        float2 d = (fract(q) - pos) * s;
        float r = (0.008 + 0.006 * fi * fi) * (0.7 + 0.6 * k.y);
        // Flakes: six soft arms that slowly tumble.
        float arms = cos(6.0 * atan2(d.y, d.x) + t * (0.6 + k.y) + h.x * 6.3);
        float dl = length(d) * (1.0 + snow * 0.18 * arms);
        float blur = max(px * 1.2, 0.0015 + 0.004 * fi * fi);
        float a = (1.0 - smoothstep(r - blur, r + blur, dl)) * fade * (0.85 - 0.22 * fi);
        float lit = clamp(0.65 + 0.45 * dot(d / r, L2), 0.25, 1.2);
        float3 grain = mix(float3(1.0, 0.80, 0.28) * lit, float3(0.75, 0.62, 1.0) * (0.35 + 0.25 * lit), night);
        // Snow is translucent, so it lights flatter than a pollen grain.
        float3 flake = mix(float3(0.93, 0.96, 1.0) * (0.78 + 0.25 * lit), float3(0.70, 0.76, 1.0) * (0.45 + 0.20 * lit), night);
        grain = mix(grain, flake, snow);
        grain += float3(1.0, 0.97, 0.85) * smoothstep(0.6, 0.0, length(d / r - L2 * 0.4)) * (0.8 - 0.6 * night) * (1.0 - 0.6 * snow);
        color = mix(color, grain, a);
        float halo = 1.0 - smoothstep(0.0, r * 2.0 + blur, dl);
        float3 haloColor = mix(float3(1.0, 0.85, 0.40) * 0.08, float3(0.55, 0.45, 1.0) * 0.22, night);
        haloColor = mix(haloColor, mix(float3(0.85, 0.92, 1.0) * 0.10, float3(0.55, 0.60, 1.0) * 0.18, night), snow);
        color += haloColor * halo * halo * fade * (1.0 - 0.3 * fi);
    }
    return color;
}

fragment float4 fragment_shader_california(
    VertexOut in [[stage_in]],
    constant CaliforniaUniforms &uniforms [[buffer(0)]]) {

    // Leaf space: fruit-centred, y up, fruit spans roughly -1...1 vertically.
    float2 p = (in.position.xy - uniforms.center) / uniforms.radius;
    p.y = -p.y;
    float t = uniforms.time;
    float night = 1.0 - uniforms.daylight;
    // Sunlight by day, dim cool moonlight by night.
    float3 lightColor = mix(float3(1.0), float3(0.26, 0.30, 0.52), night);

    // Light drifts slowly so highlights crawl over the surface; frozen in winter.
    float lightAngle = 2.2 + 0.60 * sin(t * 0.27) * (1.0 - uniforms.winter);
    float2 L2 = float2(cos(lightAngle), sin(lightAngle));
    float3 L = normalize(float3(L2 * 0.70, 0.72));
    float3 H = normalize(L + float3(0.0, 0.0, 1.0));

    // Dew: a few big drops and a scatter of small ones.
    float slide = t * 0.45 * (1.0 - uniforms.winter);
    // Frozen, the drops rock with the blade.
    float2 pd = p + uniforms.winter * california_rigid_sway(t);
    float4 drop = california_drop(pd, 0.46, 3.0, 0.50, 0.0, uniforms.winter);
    if (drop.z <= 0.0) { drop = california_drop(pd, 0.15, 9.0, 0.28, slide, uniforms.winter); }
    bool wet = drop.z > 0.0;

    // A drop is a lens: it magnifies the veins underneath it.
    float2 lp = p - drop.xy * drop.w * 0.50 * drop.z;
    CaliforniaLeaf leaf = california_leaf(lp, t, night, float3(uniforms.spring, uniforms.fall, uniforms.winter));

    float2 grad = float2(dfdx(leaf.height), -dfdy(leaf.height)) * uniforms.radius;
    grad *= 0.010;
    grad /= max(1.0, length(grad) / 1.5);
    float3 n = normalize(float3(-grad, 1.0));

    float diffuse = max(dot(n, L), 0.0);
    float3 color = leaf.color * (0.38 + 0.95 * diffuse) * lightColor;
    // Waxy cuticle sheen.
    color += mix(float3(0.75, 0.90, 0.60), float3(0.70, 0.75, 1.0), night)
           * pow(max(dot(n, H), 0.0), 24.0) * (0.16 * (1.0 - 0.6 * uniforms.fall) + 0.25 * uniforms.winter) * lightColor;

    // Night glow, with the sap pulses turning into bright cyan light.
    color += leaf.glowColor * leaf.glow * night * 0.55;
    color += mix(float3(0.70, 1.00, 0.25), float3(0.30, 0.95, 1.00), night) * leaf.sap * 0.80;
    color += mix(float3(0.95, 1.00, 0.75), float3(0.85, 0.95, 1.00), night) * leaf.sap * leaf.sap * 0.55;

    if (wet) {
        float toLight = dot(drop.xy, L2);
        // Light focuses on the far side of the drop; the near edge goes dark.
        color *= 1.05 + 1.10 * smoothstep(-0.1, -1.0, toLight) * (1.0 - drop.z * 0.6);
        color *= mix(0.45, 1.0, smoothstep(0.0, 0.40, drop.z));
        float3 dn = normalize(float3(drop.xy, drop.z + 0.35));
        if (uniforms.winter > 0.0) {
            // Frozen drops are little snow piles: lumpy clumps over fine grains.
            float2 bq = drop.xy * 5.0;
            float2 bump = float2(california_noise(bq + float2(0.05, 0.0)) - california_noise(bq - float2(0.05, 0.0)),
                                 california_noise(bq + float2(0.0, 0.05)) - california_noise(bq - float2(0.0, 0.05)));
            float2 gq = pd * 160.0;
            float2 grit = float2(california_noise(gq + float2(0.5, 0.0)) - california_noise(gq - float2(0.5, 0.0)),
                                 california_noise(gq + float2(0.0, 0.5)) - california_noise(gq - float2(0.0, 0.5)));
            float3 sn = normalize(dn - float3(bump * 2.0 + grit * 0.5, 0.0));
            // Light scatters inside snow: it wraps into the shadow side and
            // comes out blue there, and the hollows between clumps stay darker.
            float wrap = clamp((dot(sn, L) + 0.35) / 1.35, 0.0, 1.0);
            float3 snow = mix(float3(0.46, 0.56, 0.70), float3(0.97, 0.98, 1.0), wrap);
            snow *= 0.84 + 0.16 * smoothstep(0.2, 0.7, california_noise(bq * 1.8));
            // A blue, shadowed skirt where the pile meets the leaf.
            snow = mix(snow, float3(0.48, 0.60, 0.80) * (0.55 + 0.45 * wrap), (1.0 - smoothstep(0.0, 0.30, drop.z)) * 0.55);
            // Glitter: single crystals, a pixel or two wide, flash in turn.
            float2 gc = pd * uniforms.radius / 4.0;
            float2 cell = floor(gc);
            float2 gk = california_hash2(cell + 31.0);
            float2 fr = fract(gc) - 0.5 - (gk - 0.5) * 0.7;
            float twinkle = pow(max(sin(t * (1.2 + 2.5 * gk.y) + gk.x * 40.0), 0.0), 12.0);
            float sparkle = exp(-dot(fr, fr) * 14.0) * step(0.55, gk.x) * twinkle * smoothstep(0.3, 0.9, wrap);
            snow += float3(1.0, 0.98, 0.94) * sparkle * 1.4;
            // Thin at the rim, so the leaf shows faintly through the edge.
            float cover = mix(0.55, 1.0, smoothstep(0.0, 0.25, drop.z));
            color = mix(color, snow * mix(float3(1.0), lightColor * 1.6, night), uniforms.winter * cover);
        }
        float glint = pow(max(dot(dn, H), 0.0), 260.0) * (1.0 - uniforms.winter);
        float window = pow(max(dot(dn, normalize(float3(-L2 * 0.5, 0.86))), 0.0), 60.0);
        color += (float3(1.0) * glint * 1.4 + float3(0.8, 0.95, 0.85) * window * 0.12)
               * mix(float3(1.0), float3(0.75, 0.80, 1.0), night);
    } else {
        // Contact shadow thrown away from the light.
        float2 sp = pd + L2 * 0.022;
        float shade = max(california_drop(sp, 0.46, 3.0, 0.50, 0.0, uniforms.winter).z,
                          california_drop(sp, 0.15, 9.0, 0.28, slide, uniforms.winter).z);
        // Shadows beside snow go blue (skylight fills them).
        color *= 1.0 - 0.45 * smoothstep(0.0, 0.5, shade) * mix(float3(1.0), float3(0.80, 0.68, 0.40), uniforms.winter);
    }

    // Winter haze: a cold veil, thicker in patches, that washes the blade out.
    float haze = uniforms.winter * (0.45 + 0.55 * smoothstep(0.35, 0.75, california_fbm(p * 2.2 + 80.0)));
    color = mix(color, float3(0.82, 0.85, 0.88), haze * 0.40);

    // Every so often a ladybird crosses the blade on a new route.
    // The schedule (and bedtime) is kept on the CPU; see CaliforniaLayer.
    const float bugSize = 0.065;
    float bugU = uniforms.bugU;
    float sleep = uniforms.bugSleep;
    if (bugU < 1.0) {
        float2 route = california_hash2(float2(uniforms.bugCrossing, 5.0));
        float clearance = bugSize * 1.5;
        float3 here = california_bug_at(bugU, route, t, clearance, uniforms.winter);
        float2 fwd = normalize(california_bug_at(bugU + 0.004, route, t, clearance, uniforms.winter).xy - here.xy);
        float2 left = float2(-fwd.y, fwd.x);
        float2 rel = (p - here.xy) / bugSize;
        if (dot(rel, rel) < 6.0) {
            float2 b = float2(dot(rel, fwd), dot(rel, left));
            float2 light = float2(dot(L2, fwd), dot(L2, left));
            float walk = here.z * 70.0;
            // Soft cast shadow away from the light, a tight contact shadow
            // under the body and shadows of the legs.
            // Asleep it sits lower, so its shadow tucks in under it.
            float2 sb = (b + light * 0.22 * (1.0 - 0.4 * sleep)) / float2(1.15, 0.95);
            float cast = 1.0 - smoothstep(0.6, 1.25, length(sb - float2(0.15, 0.0)));
            float ao = 1.0 - smoothstep(0.90, 1.35, length((b - float2(0.2, 0.0)) / float2(1.15, 0.85)));
            float legShade = 1.0 - smoothstep(-0.02, 0.06, california_bug_legs(b + light * 0.14, walk, sleep).x);
            color *= (1.0 - 0.50 * cast) * (1.0 - 0.35 * ao) * (1.0 - 0.40 * legShade);
            float3 bounce = mix(float3(0.10, 0.28, 0.06), leaf.glowColor * 0.45, night);
            float4 bug = california_ladybird(b, walk, t, light, sleep, bounce);
            float3 lit = bug.rgb * mix(float3(1.0), lightColor * 1.4, night);
            color = mix(color, lit, bug.a);
        }
    }

    // Pollen comes with spring and thins in autumn; in winter it turns to snowfall.
    float pollenAmount = 1.0 + 0.5 * uniforms.spring - 0.6 * uniforms.fall;
    float airAmount = mix(pollenAmount, 1.4, uniforms.winter);
    color = california_pollen(color, p, t, 1.0 / uniforms.radius, L2, night, airAmount, uniforms.winter);

    color *= 1.0 - mix(0.35, 0.55, night) * smoothstep(0.6, 1.3, length(p));

    return float4(clamp(color, 0.0, 1.0), 1.0);
}
"""

private struct MetalCaliforniaFragmentUniforms {
  var resolution: SIMD2<Float>
  var center: SIMD2<Float>
  var radius: Float
  var time: Float
  var daylight: Float
  var bugU: Float
  var bugCrossing: Float
  var bugSleep: Float
  var spring: Float
  var fall: Float
  var winter: Float
}

final class CaliforniaLayer: CAMetalLayer, Background {

  // MARK: - Metal Objects
  private var metalDevice: MTLDevice?
  private var commandQueue: MTLCommandQueue?
  private var pipelineState: MTLRenderPipelineState?
  private var vertexBuffer: MTLBuffer?

  // MARK: - Animation
  private var totalElapsedTime: CGFloat = 0
  private var lastUpdateTime: CGFloat = 0
  private let minUpdateInterval: CGFloat = 1.0 / 30.0

  // MARK: - Day and night
  private var daylight: Float = 1

  /// 0 = night, 1 = day, from the local clock: day 07:00-18:00, night
  /// 20:00-05:00, with smooth two-hour dawn (05-07) and dusk (18-20).
  static func daylight(at date: Date, calendar: Calendar = .current) -> Float {
    let c = calendar.dateComponents([.hour, .minute, .second], from: date)
    let hour = Double(c.hour ?? 12) + Double(c.minute ?? 0) / 60 + Double(c.second ?? 0) / 3600
    func ramp(_ a: Double, _ b: Double) -> Double {
      let x = min(max((hour - a) / (b - a), 0), 1)
      return x * x * (3 - 2 * x)
    }
    return Float(ramp(5, 7) * (1 - ramp(18, 20)))
  }

  // MARK: - Seasons
  private var seasonWeights = (spring: Float(0), fall: Float(0), winter: Float(0))

  /// Season weights from the local date. Winter, spring, summer and autumn peak
  /// around the 20th of Jan, Apr, Jul and Oct; neighbouring seasons blend
  /// smoothly and the weights always add up to 1 (summer is what is left).
  static func seasons(at date: Date, calendar: Calendar = .current)
    -> (spring: Float, fall: Float, winter: Float) {
    let day = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
    var s = ((day - 20) / 365.25 * 4).truncatingRemainder(dividingBy: 4)  // 0 winter, 1 spring, 2 summer, 3 autumn
    if s < 0 { s += 4 }
    func weight(_ k: Double) -> Float {
      var d = s - k
      if d > 2 { d -= 4 } else if d < -2 { d += 4 }
      return abs(d) < 1 ? Float(pow(cos(Double.pi / 2 * d), 2)) : 0
    }
    return (spring: weight(1), fall: weight(3), winter: weight(0))
  }

  // MARK: - Ladybird
  // By day it crosses every 40 s (26 s on the leaf). Once it is night it
  // finishes its crossing, then walks in on the bed route and falls asleep at
  // that route's midpoint; at dawn it wakes and walks off the other side.
  private static let crossingPeriod: CGFloat = 40
  private static let crossingTime: CGFloat = 26
  /// Route whose midpoint (the bed) lands in the left lobe, clear of the bite.
  private static let bedCrossing: Float = -13
  private var bugTime: CGFloat = 0
  private var bugCrossing: Float = 0
  private var nextCrossing: Float = 1
  private var bugSleep: CGFloat = 0

  private func updateLadybird(_ dt: CGFloat) {
    let bedtime = daylight < 0.5
    if bugCrossing == Self.bedCrossing {
      let midway = Self.crossingTime / 2
      if bedtime {
        bugTime = min(bugTime + dt, midway)
        if bugTime >= midway { bugSleep = min(bugSleep + dt / 3, 1) }
      } else if bugSleep > 0 {
        bugSleep = max(bugSleep - dt / 3, 0)
      } else {
        bugTime += dt
        if bugTime >= Self.crossingPeriod {
          bugTime = 0
          bugCrossing = nextCrossing
          nextCrossing += 1
        }
      }
      return
    }
    bugTime += dt
    if bedtime && bugTime >= Self.crossingTime {
      bugTime = 0
      bugCrossing = Self.bedCrossing
    } else if bugTime >= Self.crossingPeriod {
      bugTime -= Self.crossingPeriod
      bugCrossing = nextCrossing
      nextCrossing += 1
    }
  }

  deinit {
    vertexBuffer = nil
    pipelineState = nil
    commandQueue = nil
    metalDevice = nil
  }

  // MARK: - Initialization
  init(frame: CGRect, fruit: Fruit, leaf: Leaf, contentsScale: CGFloat) {
    super.init()
    self.frame = frame
    self.contentsScale = contentsScale
    self.currentFruit = fruit
    self.currentLeaf = leaf
    self.pixelFormat = .bgra8Unorm
    self.isOpaque = true
    self.framebufferOnly = true

    setupMetal()
    setupPipeline()
    createVertexBuffers()

    // Started at night: the ladybird is already asleep in its spot.
    daylight = 1  // TEMP: forced day for testing; restore Self.daylight(at: Date())
    seasonWeights = Self.seasons(at: Date())
    if daylight < 0.5 {
      bugCrossing = Self.bedCrossing
      bugTime = Self.crossingTime / 2
      bugSleep = 1
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override init(layer: Any) {
    super.init(layer: layer)
    guard let other = layer as? CaliforniaLayer else { return }
    self.totalElapsedTime = other.totalElapsedTime
  }

  private func setupMetal() {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    self.metalDevice = device
    self.device = device

    guard let commandQueue = device.makeCommandQueue() else { return }
    self.commandQueue = commandQueue
  }

  private func setupPipeline() {
    guard let metalDevice = metalDevice else { return }
    do {
      let library = try metalDevice.makeLibrary(source: metalCaliforniaShaderSource, options: nil)
      guard let vertexFunction = library.makeFunction(name: "vertex_shader_california"),
            let fragmentFunction = library.makeFunction(name: "fragment_shader_california") else {
        return
      }

      let pipelineDescriptor = MTLRenderPipelineDescriptor()
      pipelineDescriptor.vertexFunction = vertexFunction
      pipelineDescriptor.fragmentFunction = fragmentFunction
      pipelineDescriptor.colorAttachments[0].pixelFormat = self.pixelFormat

      pipelineState = try metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
    } catch {
      return
    }
  }

  private func createVertexBuffers() {
    let vertices: [SIMD2<Float>] = [
      SIMD2<Float>(-1.0, -1.0), SIMD2<Float>( 1.0, -1.0), SIMD2<Float>(-1.0, 1.0),
      SIMD2<Float>( 1.0, -1.0), SIMD2<Float>( 1.0, 1.0), SIMD2<Float>(-1.0, 1.0)
    ]
    vertexBuffer = metalDevice?.makeBuffer(
      bytes: vertices,
      length: MemoryLayout<SIMD2<Float>>.stride * vertices.count,
      options: .storageModeShared
    )
  }

  private weak var currentFruit: Fruit?
  private weak var currentLeaf: Leaf?

  // MARK: - Background Protocol
  func update(frame: NSRect, fruit: Fruit, leaf: Leaf) {
    currentFruit = fruit
    currentLeaf = leaf
    setFrameAndDrawableSizeWithoutAnimation(frame)
    setNeedsDisplay()
  }

  func config(fruit: Fruit, leaf: Leaf) {
    currentFruit = fruit
    currentLeaf = leaf
    setNeedsDisplay()
  }

  func update(deltaTime: CGFloat) {
    totalElapsedTime += deltaTime
    daylight = 1  // TEMP: forced day for testing; restore Self.daylight(at: Date())
    seasonWeights = Self.seasons(at: Date())
    updateLadybird(deltaTime)
    lastUpdateTime += deltaTime

    if lastUpdateTime >= minUpdateInterval {
      lastUpdateTime = 0
      setNeedsDisplay()
    }
  }

  // MARK: - Drawing
  override func display() {
    guard let pipelineState = pipelineState,
          let commandQueue = commandQueue,
          let vertexBuffer = vertexBuffer,
          let drawable = nextDrawable() else { return }
    let texture = drawable.texture

    // The leaf is framed on the fruit, so detail scales with it, not the screen.
    let cs = Float(contentsScale)
    var center = SIMD2<Float>(Float(texture.width), Float(texture.height)) / 2
    var radius = min(center.x, center.y)
    if let fruit = currentFruit, let leaf = currentLeaf {
      let body = fruit.bounds(including: leaf)
      center = SIMD2<Float>(Float(body.midX), Float(bounds.height - body.midY)) * cs
      radius = max(Float(body.height) / 2 * cs, 1)
    }
    var uniforms = MetalCaliforniaFragmentUniforms(
      resolution: SIMD2<Float>(Float(texture.width), Float(texture.height)),
      center: center,
      radius: radius,
      time: Float(totalElapsedTime),
      daylight: daylight,
      bugU: Float(bugTime / Self.crossingTime),
      bugCrossing: bugCrossing,
      bugSleep: Float(bugSleep),
      spring: seasonWeights.spring,
      fall: seasonWeights.fall,
      winter: seasonWeights.winter
    )

    let renderPassDescriptor = MTLRenderPassDescriptor()
    renderPassDescriptor.colorAttachments[0].texture = texture
    renderPassDescriptor.colorAttachments[0].loadAction = .clear
    renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
      red: 0, green: 0, blue: 0, alpha: 1
    )

    guard let commandBuffer = commandQueue.makeCommandBuffer(),
          let renderEncoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: renderPassDescriptor
          ) else {
      return
    }

    renderEncoder.setRenderPipelineState(pipelineState)
    if let fruit = currentFruit, let leaf = currentLeaf {
      let body = fruit.bounds(including: leaf)
      let fb = CGRect(x: body.minX - 4, y: body.minY - 4,
                       width: body.width + 8, height: body.height + 8)
      let cs = contentsScale
      let sx = max(0, Int(fb.minX * cs))
      let sy = max(0, Int((bounds.height - fb.maxY) * cs))
      let sw = min(Int(fb.width * cs), texture.width - sx)
      let sh = min(Int(fb.height * cs), texture.height - sy)
      if sw > 0 && sh > 0 {
        renderEncoder.setScissorRect(MTLScissorRect(x: sx, y: sy, width: sw, height: sh))
      }
    }
    renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
    renderEncoder.setFragmentBytes(
      &uniforms,
      length: MemoryLayout<MetalCaliforniaFragmentUniforms>.stride,
      index: 0
    )
    renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

    renderEncoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }
}
