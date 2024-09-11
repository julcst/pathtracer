const COMPUTE_SIZE: u32 = 8u;
const PI: f32 = 3.14159265359;
const TWO_PI: f32 = 2.0 * PI;

struct CameraData {
    world_to_clip: mat4x4f,
    clip_to_world: mat4x4f,
};

@group(0) @binding(0) var output: texture_storage_2d<rgba32float, read_write>;
@group(0) @binding(1) var<uniform> camera: CameraData;
@group(0) @binding(2) var<storage, read> sobol_burley: array<vec4f>;

struct PushConstants {
    sample: u32,
    weight: f32,
    bounces: u32,
    throughput: f32,
};

var<push_constant> c: PushConstants;

// TODO: Match with rasterization
fn generate_ray(id: vec3u, rand: vec2f) -> Ray {
    let dim = vec2f(textureDimensions(output));
    let uv = 2.0 * (vec2f(id.xy) + rand) / dim - 1.0;

    // let clip_pos = vec4f(0.0, 0.0, 0.0, 1.0);
    // let world_pos = camera.clip_to_world * clip_pos;
    let world_pos = camera.clip_to_world[3]; // Equivalent to the above
    let pos = world_pos.xyz / world_pos.w;

    let clip_dir = vec4f(-uv, -1.0, 1.0);
    let world_dir = camera.clip_to_world * clip_dir;
    let dir = pos - world_dir.xyz / world_dir.w;

    return Ray(pos, dir, 1.0 / dir);
}

fn mat3(m: mat4x4f) -> mat3x3f {
    return mat3x3f(m[0].xyz, m[1].xyz, m[2].xyz);
}

/// Sample visible normal distribution function using the algorithm
/// from "Sampling Visible GGX Normals with Spherical Caps" by Dupuy et al. 2023.
/// https://cdrdv2-public.intel.com/782052/sampling-visible-ggx-normals.pdf
fn sample_vndf(rand: vec2f, wi: vec3f, alpha: vec2f) -> vec3f {
    // warp to the hemisphere configuration
    let wiStd = normalize(vec3f(wi.xy * alpha, wi.z));
    // sample a spherical cap in (-wi.z, 1]
    let phi = TWO_PI * rand.x;
    let z = fma((1.0 - rand.y), (1.0 + wiStd.z), -wiStd.z);
    let sinTheta = sqrt(clamp(1.0 - z * z, 0.0, 1.0));
    let x = sinTheta * cos(phi);
    let y = sinTheta * sin(phi);
    // compute halfway direction as standard normal
    let wmStd = vec3(x, y, z) + wiStd;
    // warp back to the ellipsoid configuration
    let wm = normalize(vec3f(wmStd.xy * alpha, wmStd.z));
    // return final normal
    return wm;
}

fn sample_vndf_iso(rand: vec2f, wi: vec3f, alpha: f32, n: vec3f) -> vec3f {
    // decompose the vector in parallel and perpendicular components
    let wi_z = n * dot(wi, n);
    let wi_xy = wi - wi_z;
    // warp to the hemisphere configuration
    let wiStd = normalize(wi_z - alpha * wi_xy);
    // sample a spherical cap in (-wiStd.z, 1]
    let wiStd_z = dot(wiStd, n);
    let phi = (2.0 * rand.x - 1.0) * PI;
    let z = (1.0 - rand.y) * (1.0 + wiStd_z) - wiStd_z;
    let sinTheta = sqrt(clamp(1.0 - z * z, 0.0, 1.0));
    let x = sinTheta * cos(phi);
    let y = sinTheta * sin(phi);
    let cStd = vec3(x, y, z);
    // reflect sample to align with normal
    let up = vec3f(0, 0, 1);
    var wr = n + up;
    if wr.z == 0.0 { wr.z = 0.0000001; } // TODO: Find better solution
    let c = dot(wr, cStd) * wr / wr.z - cStd;
    // compute halfway direction as standard normal
    let wmStd = c + wiStd;
    let wmStd_z = n * dot(n, wmStd);
    let wmStd_xy = wmStd_z - wmStd;
    // warp back to the ellipsoid configuration
    let wm = normalize(wmStd_z + alpha * wmStd_xy);
    // return final normal
    return wm;
}

fn sample_cosine_hemisphere(rand: vec2f) -> vec3f {
    let phi = TWO_PI * rand.x;
    let sinTheta = sqrt(1.0 - rand.y);
    let cosTheta = sqrt(rand.y);
    return vec3f(cos(phi) * sinTheta, sin(phi) * sinTheta, cosTheta);
}

fn hash2u(s: vec2u) -> vec2u {
    var v = s * 1664525u + 1013904223u;
    v.x += v.y * 1664525u; v.y += v.x * 1664525u;
    v ^= v >> vec2u(16u);
    v.x += v.y * 1664525u; v.y += v.x * 1664525u;
    v ^= v >> vec2u(16u);
    return v;
}

fn hash4u(s: vec4u) -> vec4u {
    var v = s * 1664525u + 1013904223u;
    v.x += v.y * v.w; v.y += v.z * v.x; v.z += v.x * v.y; v.w += v.y * v.z;
    v ^= v >> vec4u(16u);
    v.x += v.y * v.w; v.y += v.z * v.x; v.z += v.x * v.y; v.w += v.y * v.z;
    return v;
}

/// Maps a random u32 to a random float in [0,1), see https://blog.bithole.dev/blogposts/random-float/
fn map4f(x: vec4u) -> vec4f {
    return bitcast<vec4f>((x >> vec4u(9u)) | vec4u(0x3F800000u)) - 1.0;
}

/// Maps a random u32 to a random float in [0,1), see https://blog.bithole.dev/blogposts/random-float/
fn map2f(x: vec2u) -> vec2f {
    return bitcast<vec2f>((x >> vec2u(9u)) | vec2u(0x3F800000u)) - 1.0;
}

/**
 * Schlick's approximation for the Fresnel term (see https://en.wikipedia.org/wiki/Schlick%27s_approximation).
 * The Fresnel term describes how light is reflected at the surface.
 * For conductors the reflection coefficient R0 is chromatic, for dielectrics it is achromatic.
 * R0 = ((n1 - n2) / (n1 + n2))^2 with n1, n2 being the refractive indices of the two materials.
 * We can set n1 = 1.0 (air) and n2 = IoR of the material.
 * Most dielectrics have an IoR near 1.5 => R0 = ((1 - 1.5) / (1 + 1.5))^2 = 0.04.
 */
fn F_SchlickApprox(HdotV: f32, R0: vec3f) -> vec3f {
    return R0 + (1.0 - R0) * pow(1.0 - HdotV, 5.0);
}

/**
 * Lambda for the Trowbridge-Reitz NDF
 * Measures invisible masked microfacet area per visible microfacet area.
 */
fn Lambda_TrowbridgeReitz(NdotV: f32, alpha2: f32) -> f32 {
    let cosTheta = NdotV;
    let cos2Theta = cosTheta * cosTheta;
    let sin2Theta = 1.0 - cos2Theta;
    let tan2Theta = sin2Theta / cos2Theta;
    return (-1.0 + sqrt(1.0 + alpha2 * tan2Theta)) / 2.0;
}

/**
 * Smith's shadowing-masking function for the Trowbridge-Reitz NDF.
 */
fn G2_TrowbridgeReitz(NdotL: f32, NdotV: f32, alpha2: f32) -> f32 {
    let lambdaL = Lambda_TrowbridgeReitz(NdotL, alpha2);
    let lambdaV = Lambda_TrowbridgeReitz(NdotV, alpha2);
    return 1.0 / (1.0 + lambdaL + lambdaV);
}

/**
 * Smith's shadowing-masking function for the Trowbridge-Reitz NDF.
 */
fn G1_TrowbridgeReitz(NdotV: f32, alpha2: f32) -> f32 {
    let lambdaV = Lambda_TrowbridgeReitz(NdotV, alpha2);
    return 1.0 / (1.0 + lambdaV);
}

fn build_tbn(hit: HitInfo) -> mat3x3f {
    let t = hit.tangent.xyz;
    let b = hit.tangent.w * cross(hit.tangent.xyz, hit.normal);
    let n = hit.normal;
    return mat3x3f(t, b, n);
}

const LDS_PER_BOUNCE: u32 = 2u;

/// Takes a precomputed Sobol-Burley sample and performs a Cranly-Patterson-Rotation with a per pixel shift.
/// For each sample the precomputed Sobol-Burley array contains first one vec4f for lens and pixel sampling and
/// then two vec4f for each bounce.
fn sample_sobol_burley_bounce(i: u32, bounce: u32, shift: vec4f, dim: u32) -> vec4f {
    let sample = sobol_burley[(i * (c.bounces + 1u) + bounce + 1u) * LDS_PER_BOUNCE + dim];
    return fract(sample + shift);
}

fn sample_sobol_burley_extra(i: u32, shift: vec4f) -> vec4f {
    let sample = sobol_burley[i * (c.bounces + 1u)];
    return fract(sample + shift);
}

// TODO: Use Owen-Scrambled-Sobol
fn sample_rendering_eq(sample: u32, shift: vec4f, dir: Ray) -> vec3f {
    var throughput = vec3f(1.0);
    var ray = dir;
    for (var bounce = 0u; bounce <= c.bounces; bounce += 1u) {
        let sobol_0 = sample_sobol_burley_bounce(sample, bounce, shift, 0u);
        let hit = intersect_TLAS(ray);
        // TODO: Multiple Importance Sampling?
        if (hit.flags & EMISSIVE) != 0u {
            return throughput * hit.color.xyz;
        }
        let alpha = hit.roughness * hit.roughness;
        let alpha2 = alpha * alpha;
        let wo = normalize(-ray.direction);
        let wm = sample_vndf_iso(sobol_0.xy, wo, alpha, hit.normal); // Sample microfacet normal after Trowbridge-Reitz VNDF
        var wi = reflect(-wo, wm);
        let cosThetaD = dot(wo, wm); // = dot(wi, wm)
        let cosThetaI = dot(wi, hit.normal);
        let cosThetaO = dot(wo, hit.normal);
        // TODO: Importance Sample
        if sobol_0.z < 0.5 { // Trowbridge-Reitz-Specular
            // FIXME: Artifacts on the blue suzanne head, maybe because of rotation
            let F0 = mix(vec3f(0.04), hit.color.xyz, hit.metallic);
            let F = F_SchlickApprox(cosThetaD, F0);
            let LambdaL = Lambda_TrowbridgeReitz(cosThetaI, alpha2);
            let LambdaV = Lambda_TrowbridgeReitz(cosThetaO, alpha2);
            let specular = F * (1 + LambdaV) / (1 + LambdaL + LambdaV); // = F * (G2 / G1)
            throughput *= specular * 2.0;
        } else { // Brent-Burley-Diffuse
            let sobol_1 = sample_sobol_burley_bounce(sample, bounce, shift, 1u);
            let FD90 = 0.5 + 2 * alpha * pow(cosThetaD, 2.0);
            let diffuse = (1 - hit.metallic) * hit.color.xyz * (1 + (FD90 - 1) * pow(1 - cosThetaI, 5.0)) * (1 + (FD90 - 1) * pow(1 - cosThetaO, 5.0));
            let tangent_to_world = build_tbn(hit);
            wi = normalize(tangent_to_world * sample_cosine_hemisphere(sobol_1.xy));
            throughput *= diffuse * 2.0;
        }
        
        if luminance(throughput) <= c.throughput { break; }
        ray = Ray(hit.position, wi, 1.0 / wi);
    }
    return vec3f(0.0);
}

fn luminance(linear_rgb: vec3f) -> f32 {
    return dot(vec3f(0.2126, 0.7152, 0.0722), linear_rgb);
}

@compute
@workgroup_size(COMPUTE_SIZE, COMPUTE_SIZE)
fn main(@builtin(global_invocation_id) id: vec3u) {
    var color = vec4f(0.0);
    if c.weight > 0.0 {
        color = textureLoad(output, vec2i(id.xy));
    }

    let shift = map4f(hash4u(vec4u(id.xyzx)));

    let jitter = sample_sobol_burley_extra(c.sample, shift);
    let ray = generate_ray(id, jitter.xy);

    let sample = sample_rendering_eq(c.sample, shift, ray);
    color = vec4f(mix(color.xyz, sample, c.weight), 1.0);

    textureStore(output, id.xy, color);

    // let hit = intersect_TLAS(ray);
    // textureStore(output, id.xy, vec4f(hash2f(id.xy), 0.0, 1.0));
    // textureStore(output, id.xy, vec4f(f32(hit.n_aabb) * 0.02, select(0.0, 1.0, hit.dist != NO_HIT), f32(hit.n_tri) * 0.2, 1.0));
    // textureStore(output, id.xy, hit.color);
    // textureStore(output, id.xy, vec4f(vec3f(hit.roughness), 1.0));
    // textureStore(output, id.xy, vec4f(vec3f(hit.metallic), 1.0));
    // textureStore(output, id.xy, vec4f(hit.tangent.xyz * 0.5 + 0.5, 1.0));
    // textureStore(output, id.xy, vec4f(vec3f(hit.tangent.w) * 0.5 + 0.5, 1.0));
    // textureStore(output, id.xy, vec4f(hit.normal * 0.5 + 0.5, 1.0));
    // textureStore(output, id.xy, vec4f(hit.texcoord, 0.0, 1.0));
    // textureStore(output, id.xy, vec4f(hit.position, 1.0));
}