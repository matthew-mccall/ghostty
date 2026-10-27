// CRT glass for Ghostty: one sharp sample plus eight weighted glow samples.
// Static effects redraw only when terminal content changes.
// Set CURVATURE to 0.0 for an undistorted text grid.
const float CURVATURE = 0.012;
// Halo intensity. Set to 0.0 to disable glow without dimming the text.
const float GLOW_BRIGHTNESS = 0.15;
// Glow radius in render pixels. Start around 1.0 to 6.0.
const float GLOW_RADIUS = 4.0;
const float VIGNETTE = 0.24;
// Relative brightness added at the screen center; edges keep the config background.
// This matches the native tab titlebar, which uses the same background color.
const float BACKGROUND_CENTER_LIFT = 0.75;
// Static dither amplitude in 8-bit color steps. 1.0 is plus/minus half a step.
const float BACKGROUND_DITHER = 1.0;

// Static interleaved noise uses inexpensive float math to break color bands.
float backgroundNoise(vec2 pixel) {
    return fract(52.9829189 * fract(dot(pixel, vec2(0.06711056, 0.00583715)))) - 0.5;
}

vec3 phosphor(vec2 uv) {
    // The warped center stays inside the screen. Guard the outer halo taps.
    if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) {
        return vec3(0.0);
    }
    return texture(iChannel0, uv).rgb;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec2 p = uv * 2.0 - 1.0;
    // Small barrel distortion. The inset preserves the outer text cells.
    vec2 curved = p * (1.0 + CURVATURE * p.yx * p.yx);
    uv = (curved / (1.0 + CURVATURE) + 1.0) * 0.5;

    vec2 spread = max(GLOW_RADIUS, 0.0) / iResolution.xy;
    vec3 core = phosphor(uv);
    vec3 halo = vec3(0.0);
    // Symmetric, low-intensity halo; the sharp original stays intact.
    halo += phosphor(uv + spread * vec2( 0.5,  0.0));
    halo += phosphor(uv + spread * vec2(-0.5,  0.0));
    halo += phosphor(uv + spread * vec2( 0.0,  0.5));
    halo += phosphor(uv + spread * vec2( 0.0, -0.5));
    halo += phosphor(uv + spread * vec2( 1.0,  0.0)) * 0.5;
    halo += phosphor(uv + spread * vec2(-1.0,  0.0)) * 0.5;
    halo += phosphor(uv + spread * vec2( 0.0,  1.0)) * 0.5;
    halo += phosphor(uv + spread * vec2( 0.0, -1.0)) * 0.5;
    halo /= 6.0;

    // Separate the background so glow and text shading cannot darken the seam.
    halo = max(halo - iBackgroundColor, vec3(0.0));
    vec3 ink = core - iBackgroundColor + halo * max(GLOW_BRIGHTNESS, 0.0);
    float edge = smoothstep(0.10, 1.65, dot(p, p));
    ink *= 1.0 - clamp(VIGNETTE, 0.0, 1.0) * edge;

    // A smooth rectangular falloff reaches the same base along EVERY edge.
    // Normalized coordinates keep the blend proportional when resizing.
    vec2 fade = 1.0 - smoothstep(vec2(0.0), vec2(1.0), p * p);
    float center = fade.x * fade.y;
    vec3 lift = iBackgroundColor * max(BACKGROUND_CENTER_LIFT, 0.0) * center;
    vec3 glass = iBackgroundColor + lift;
    // Break up quantization bands before output rounding. Protect the text
    // and fade to zero at the frame so the native titlebar blend stays clean.
    float backgroundOnly = 1.0 - smoothstep(0.02, 0.25, max(abs(core.r - iBackgroundColor.r),
        max(abs(core.g - iBackgroundColor.g), abs(core.b - iBackgroundColor.b))));
    float ditherFade = smoothstep(0.0, 0.04, center) * backgroundOnly;
    float dither = backgroundNoise(fragCoord) * max(BACKGROUND_DITHER, 0.0) / 255.0;
    fragColor = vec4(clamp(glass + ink + vec3(dither * ditherFade), 0.0, 1.0), 1.0);
}
