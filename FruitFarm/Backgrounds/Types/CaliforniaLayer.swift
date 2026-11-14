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
float4 california_drop(float2 p, float cellSize, float seed, float density, float slide) {
    float2 g = p / cellSize;
    g.y += slide * (0.35 + california_hash(float2(floor(g.x), seed)));
    float2 id = floor(g);
    float2 k = california_hash2(id * 1.37 + seed + 37.0);
    if (k.y >= density) { return float4(0.0); }
    float r = mix(0.10, 0.33, k.x * k.x);
    float2 c = r + (1.0 - 2.0 * r) * california_hash2(id + seed);
    float2 q = (fract(g) - c) / r;
    q.x *= 0.88 + 0.24 * k.y / density;   // not perfectly round
    float d2 = dot(q, q);
    if (d2 >= 1.0) { return float4(0.0); }
    return float4(q, sqrt(1.0 - d2), r * cellSize);
}

struct CaliforniaLeaf {
    float3 color;
    float height;
    float sap;
};

CaliforniaLeaf california_leaf(float2 p, float t) {
    // The whole blade sways as one piece.
    p += 0.030 * float2(sin(t * 0.45 + p.y * 2.0), cos(t * 0.36 + p.x * 2.0));

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
    leaf.color = color;

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
// A leg in its swing phase lifts and tucks in slightly.
float2 california_bug_legs(float2 b, float walk) {
    float2 best = float2(1e3, 0.0);
    for (int i = 0; i < 3; i++) {
        float x = 0.50 - 0.52 * float(i);
        float splay = 0.38 * float(1 - i);
        for (int k = 0; k < 2; k++) {
            float sd = (k == 0) ? 1.0 : -1.0;
            float phase = walk + 3.14159 * float(i + k);
            float swing = 0.22 * sin(phase);
            float lift = max(cos(phase), 0.0);
            float2 hip   = float2(x, sd * 0.48);
            float2 knee  = float2(x + splay * 0.40 + swing * 0.30, sd * (1.00 - 0.05 * lift));
            float2 ankle = float2(x + splay * 0.80 + swing * 0.75, sd * (1.30 - 0.10 * lift));
            float2 foot  = float2(x + splay * 1.00 + swing,        sd * (1.46 - 0.13 * lift));
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
float3 california_bug_at(float u, float2 h, float t, float clearance) {
    const float cellSize = 0.46;   // must match the big drops in the fragment
    const float seed = 3.0;
    const float density = 0.50;
    float3 path = california_bug_path(u, h);
    float2 pos = path.xy - 0.030 * float2(sin(t * 0.45 + path.y * 2.0),
                                          cos(t * 0.36 + path.x * 2.0));
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
    return float3(pos + shift, path.z);
}

// Ladybird (seven-spot) in its own frame: x forward, y to its left, wing
// cases 2 units long. `light` is the light direction in that frame.
// Returns colour + coverage.
float4 california_ladybird(float2 b, float walk, float t, float2 light) {
    float ay = abs(b.y);
    float3 L = normalize(float3(light * 0.70, 0.72));
    float3 H = normalize(L + float3(0.0, 0.0, 1.0));
    float3 color = float3(0.0);
    float cover = 0.0;

    // Legs: dark brown chitin with a sheen down each segment.
    float2 leg = california_bug_legs(b, walk);
    float legCover = 1.0 - smoothstep(-0.012, 0.012, leg.x);
    float3 legColor = float3(0.025, 0.018, 0.014) * (0.5 + 0.8 * leg.y)
                    + float3(0.32, 0.28, 0.24) * pow(leg.y, 10.0) * 0.45;
    color = legColor;
    cover = legCover;

    // Clubbed antennae that twitch while it walks.
    float2 ant = float2(1e3, 0.0);
    float twitch = 0.05 * sin(t * 5.0) + 0.03 * sin(walk * 0.5);
    float2 ab = float2(b.x, ay);
    float2 aTip = float2(1.84, 0.36 + twitch);
    california_limb(ab, float2(1.50, 0.15), float2(1.68, 0.30 + twitch * 0.5), 0.026, 0.020, ant);
    california_limb(ab, float2(1.68, 0.30 + twitch * 0.5), aTip, 0.020, 0.018, ant);
    california_limb(ab, aTip - float2(0.04, 0.0), aTip + float2(0.05, 0.02), 0.045, 0.040, ant);
    float antCover = 1.0 - smoothstep(-0.010, 0.010, ant.x);
    color = mix(color, float3(0.05, 0.035, 0.025) * (0.5 + 0.9 * ant.y), antCover);
    cover = max(cover, antCover);

    // Head: glossy black, compound eyes, two cream face spots, palps.
    float2 hq = (b - float2(1.40, 0.0)) / float2(0.22, 0.31);
    float he = length(hq);
    float headCover = 1.0 - smoothstep(0.92, 1.0, he);
    float3 hn = normalize(float3(hq * 0.8, sqrt(max(1.0 - he * he, 0.0)) + 0.1));
    float3 head = float3(0.025, 0.022, 0.02) * (0.4 + 0.8 * max(dot(hn, L), 0.0));
    float face = length(float2(b.x - 1.53, ay - 0.10) / float2(0.06, 0.045));
    head = mix(head, float3(0.86, 0.84, 0.72) * (0.5 + 0.6 * max(dot(hn, L), 0.0)),
               1.0 - smoothstep(0.8, 1.0, face));
    float2 eq = float2(b.x - 1.45, ay - 0.22) / float2(0.075, 0.095);
    float eye = length(eq);
    float3 en = normalize(float3(eq.x, eq.y * sign(b.y), 1.2));
    float3 eyeColor = float3(0.07, 0.05, 0.04) * (0.6 + 0.4 * california_noise(eq * 9.0))
                    + pow(max(dot(en, H), 0.0), 60.0) * 0.9;
    head = mix(head, eyeColor, 1.0 - smoothstep(0.85, 1.0, eye));
    head += pow(max(dot(hn, H), 0.0), 50.0) * 0.6;
    float2 palp = float2(1e3, 0.0);
    california_limb(ab, float2(1.58, 0.06), float2(1.68, 0.11), 0.026, 0.018, palp);
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
    shellColor += float3(0.10, 0.28, 0.06) * fresnel * 0.9;
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
    pron3 += pow(max(dot(pn, H), 0.0), 60.0) * 0.7 + float3(0.06, 0.14, 0.04) * pow(1.0 - pn.z, 3.0);
    // Shadow the pronotum casts onto the front of the wing cases.
    color *= 1.0 - 0.5 * shell * (1.0 - smoothstep(0.0, 0.10, b.x - (0.84 - 0.08 * pq.y * pq.y))) * (1.0 - pron);
    color = mix(color, pron3, pron);
    cover = max(cover, pron);

    return float4(color, cover);
}

fragment float4 fragment_shader_california(
    VertexOut in [[stage_in]],
    constant CaliforniaUniforms &uniforms [[buffer(0)]]) {

    // Leaf space: fruit-centred, y up, fruit spans roughly -1...1 vertically.
    float2 p = (in.position.xy - uniforms.center) / uniforms.radius;
    p.y = -p.y;
    float t = uniforms.time;

    // Light drifts slowly so highlights crawl over the surface.
    float lightAngle = 2.2 + 0.60 * sin(t * 0.27);
    float2 L2 = float2(cos(lightAngle), sin(lightAngle));
    float3 L = normalize(float3(L2 * 0.70, 0.72));
    float3 H = normalize(L + float3(0.0, 0.0, 1.0));

    // Dew: a few big drops and a scatter of small ones.
    float slide = t * 0.45;
    float4 drop = california_drop(p, 0.46, 3.0, 0.50, 0.0);
    if (drop.z <= 0.0) { drop = california_drop(p, 0.15, 9.0, 0.28, slide); }
    bool wet = drop.z > 0.0;

    // A drop is a lens: it magnifies the veins underneath it.
    float2 lp = p - drop.xy * drop.w * 0.50 * drop.z;
    CaliforniaLeaf leaf = california_leaf(lp, t);

    float2 grad = float2(dfdx(leaf.height), -dfdy(leaf.height)) * uniforms.radius;
    grad *= 0.010;
    grad /= max(1.0, length(grad) / 1.5);
    float3 n = normalize(float3(-grad, 1.0));

    float diffuse = max(dot(n, L), 0.0);
    float3 color = leaf.color * (0.38 + 0.95 * diffuse);
    // Waxy cuticle sheen.
    color += float3(0.75, 0.90, 0.60) * pow(max(dot(n, H), 0.0), 24.0) * 0.16;

    color += float3(0.70, 1.00, 0.25) * leaf.sap * 0.80;
    color += float3(0.95, 1.00, 0.75) * leaf.sap * leaf.sap * 0.55;

    if (wet) {
        float toLight = dot(drop.xy, L2);
        // Light focuses on the far side of the drop; the near edge goes dark.
        color *= 1.05 + 1.10 * smoothstep(-0.1, -1.0, toLight) * (1.0 - drop.z * 0.6);
        color *= mix(0.45, 1.0, smoothstep(0.0, 0.40, drop.z));
        float3 dn = normalize(float3(drop.xy, drop.z + 0.35));
        float glint = pow(max(dot(dn, H), 0.0), 260.0);
        float window = pow(max(dot(dn, normalize(float3(-L2 * 0.5, 0.86))), 0.0), 60.0);
        color += float3(1.0) * glint * 1.4 + float3(0.8, 0.95, 0.85) * window * 0.12;
    } else {
        // Contact shadow thrown away from the light.
        float2 sp = p + L2 * 0.022;
        float shade = max(california_drop(sp, 0.46, 3.0, 0.50, 0.0).z,
                          california_drop(sp, 0.15, 9.0, 0.28, slide).z);
        color *= 1.0 - 0.45 * smoothstep(0.0, 0.5, shade);
    }

    // Every so often a ladybird crosses the blade on a new route.
    const float bugPeriod = 40.0;
    const float bugSize = 0.065;
    float bugU = fract(t / bugPeriod) * bugPeriod / 26.0;
    if (bugU < 1.0) {
        float2 route = california_hash2(float2(floor(t / bugPeriod), 5.0));
        float clearance = bugSize * 1.5;
        float3 here = california_bug_at(bugU, route, t, clearance);
        float2 fwd = normalize(california_bug_at(bugU + 0.004, route, t, clearance).xy - here.xy);
        float2 left = float2(-fwd.y, fwd.x);
        float2 rel = (p - here.xy) / bugSize;
        if (dot(rel, rel) < 6.0) {
            float2 b = float2(dot(rel, fwd), dot(rel, left));
            float2 light = float2(dot(L2, fwd), dot(L2, left));
            float walk = here.z * 70.0;
            // Soft cast shadow away from the light, a tight contact shadow
            // under the body and shadows of the legs.
            float2 sb = (b + light * 0.22) / float2(1.15, 0.95);
            float cast = 1.0 - smoothstep(0.6, 1.25, length(sb - float2(0.15, 0.0)));
            float ao = 1.0 - smoothstep(0.90, 1.35, length((b - float2(0.2, 0.0)) / float2(1.15, 0.85)));
            float legShade = 1.0 - smoothstep(-0.02, 0.06, california_bug_legs(b + light * 0.14, walk).x);
            color *= (1.0 - 0.50 * cast) * (1.0 - 0.35 * ao) * (1.0 - 0.40 * legShade);
            float4 bug = california_ladybird(b, walk, t, light);
            color = mix(color, bug.rgb, bug.a);
        }
    }

    color *= 1.0 - 0.35 * smoothstep(0.6, 1.3, length(p));

    return float4(clamp(color, 0.0, 1.0), 1.0);
}
"""

private struct MetalCaliforniaFragmentUniforms {
  var resolution: SIMD2<Float>
  var center: SIMD2<Float>
  var radius: Float
  var time: Float
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
      time: Float(totalElapsedTime)
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
