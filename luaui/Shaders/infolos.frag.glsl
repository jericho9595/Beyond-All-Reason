#version 430 core
//__DEFINES__

//__ENGINEUNIFORMBUFFERDEFS__
uniform float time;
uniform float outputAlpha;
uniform vec2 losTexSize;
uniform vec2 airlosTexSize;
uniform vec2 radarTexSize;

uniform sampler2D tex0;
uniform sampler2D tex1;
uniform sampler2D tex2;

in DataVS {
    vec4 texCoord;
};
out vec4 fragColor;
/*
// from http://www.java-gaming.org/index.php?topic=35123.0
vec4 cubic(float v){
    vec4 n = vec4(1.0, 2.0, 3.0, 4.0) - v;
    vec4 s = n * n * n;
    float x = s.x;
    float y = s.y - 4.0 * s.x;
    float z = s.z - 4.0 * s.y + 6.0 * s.x;
    float w = 6.0 - x - y - z;
    return vec4(x, y, z, w) * (1.0/6.0);
}

//https://stackoverflow.com/questions/13501081/efficient-bicubic-filtering-code-in-glsl
vec4 textureBicubic(sampler2D sampler, vec2 texCoords){

   vec2 texSize = textureSize(sampler, 0);
   vec2 invTexSize = 1.0 / texSize;
   
   texCoords = texCoords * texSize - 0.5;

   
    vec2 fxy = fract(texCoords);
    texCoords -= fxy;

    vec4 xcubic = cubic(fxy.x);
    vec4 ycubic = cubic(fxy.y);

    vec4 c = texCoords.xxyy + vec2 (-0.5, +1.5).xyxy;
    
    vec4 s = vec4(xcubic.xz + xcubic.yw, ycubic.xz + ycubic.yw);
    vec4 offset = c + vec4 (xcubic.yw, ycubic.yw) / s;
    
    offset *= invTexSize.xxyy;
    
    vec4 sample0 = texture(sampler, offset.xz);
    vec4 sample1 = texture(sampler, offset.yz);
    vec4 sample2 = texture(sampler, offset.xw);
    vec4 sample3 = texture(sampler, offset.yw);

    float sx = s.x / (s.x + s.y);
    float sy = s.z / (s.z + s.w);

    return mix(
       mix(sample3, sample2, sx), mix(sample1, sample0, sx)
    , sy);
}

*/


//! source: http://www.ozone3d.net/blogs/lab/20110427/glsl-random-generator/
float rand(const in vec2 n)
{
	return fract(sin(dot(n, vec2(12.9898, 78.233))) * 43758.5453);

}

vec4 getTexel(in sampler2D tex, in vec2 p, in vec2 sizes)
{
	vec4 c = vec4(0.0);
	for (int i = 0; i < SAMPLES; i++) {
		vec2 off = vec2(time + float(i) * 0.02);
		off = (vec2(rand(p.st + off.st), rand(p.ts - off.ts)) * 2.0 - 1.0);
		off = off / sizes;
		c += texture(tex, p + off * RESOLUTION);
	}
	c *= 1.0 / SAMPLES;
	return c;
}

float getTexelF(in sampler2D tex, in vec2 p, in vec2 sizes)
{
	float c = 0.0;
	for (int i = 0; i < SAMPLES; i++) {
		vec2 off = vec2(time + float(i) * 0.02);
		off = (vec2(rand(p.st + off.st), rand(p.ts - off.ts)) * 2.0 - 1.0);
		off = off / sizes;
		float t = texture(tex, p + off * RESOLUTION).r;
		c += t;
	}
	c *= 1.0 / SAMPLES;
	return smoothstep(0.0, 1.0, c);
}

// This is the fake cubic blending function, which is extremely useful for upsizing without bilinear artifacts
// Could be done ass-backwards if needed
float gatherBlend(vec4 samples, vec2 coords, vec2 sizes)
{
	vec2 fracCoords = fract(coords * sizes + vec2(0.5));
	fracCoords = smoothstep(0.0, 1.0, fracCoords);

	vec2 mixx = mix(samples.ra, samples.gb, fracCoords.x);
	float mixy = mix(mixx.y, mixx.x, fracCoords.y);

	#define THRESHOLD 0.2
	return smoothstep(THRESHOLD, 1.0 - THRESHOLD, mixy);
}

// These sampler functions are for smooth magnification via cubic blending, and are better than the gatherBlend approach, cause its way less samples

vec2 CubicSampler(vec2 uvsin, vec2 texdims){
    vec2 r = uvsin * texdims - 0.5;
    vec2 tf = fract(r);
    vec2 ti = r - tf;
    tf = tf * tf * (3.0 - 2.0 * tf);
    return (tf + ti + 0.5)/texdims;
}

vec2 QuinticSampler(vec2 uvsin, vec2 texdims){
    vec2 r = uvsin * texdims - 0.5;
    vec2 tf = fract(r);
    vec2 ti = r - tf;
    tf = tf * tf * tf * (tf * (6.0 * tf - 15.0) + 10.0);
    return (tf + ti + 0.5)/texdims;
}

vec2 OctalSampler(vec2 uvsin, vec2 texdims){
    vec2 r = uvsin * texdims - 0.5;
    vec2 tf = fract(r);
    vec2 ti = r - tf;
    tf = tf * tf * (3.0 - 2.0 * tf);
    tf = tf * tf * tf * (tf * (6.0 * tf - 15.0) + 10.0);
    return (tf + ti + 0.5)/texdims;
}

// Slight blur helpers for EXACT == 0
float blur5R(sampler2D tex, vec2 uv, vec2 texSize, float radiusPx)
{
	vec2 px = radiusPx / texSize;

	float v = 0.0;
	v += texture(tex, uv).r * 0.52;
	v += texture(tex, uv + vec2( px.x, 0.0)).r * 0.12;
	v += texture(tex, uv + vec2(-px.x, 0.0)).r * 0.12;
	v += texture(tex, uv + vec2(0.0,  px.y)).r * 0.12;
	v += texture(tex, uv + vec2(0.0, -px.y)).r * 0.12;
	return v;
}

vec2 blur5RG(sampler2D tex, vec2 uv, vec2 texSize, float radiusPx)
{
	vec2 px = radiusPx / texSize;

	vec2 v = vec2(0.0);
	v += texture(tex, uv).rg * 0.52;
	v += texture(tex, uv + vec2( px.x, 0.0)).rg * 0.12;
	v += texture(tex, uv + vec2(-px.x, 0.0)).rg * 0.12;
	v += texture(tex, uv + vec2(0.0,  px.y)).rg * 0.12;
	v += texture(tex, uv + vec2(0.0, -px.y)).rg * 0.12;
	return v;
}

void main() {
	fragColor = vec4(0.0);

	#if (EXACT == 0)
		const float BLUR_RADIUS = 0.85;
		const float LOS_BLUR_MIX = 0.35;
		const float AIRLOS_BLUR_MIX = 0.30;
		const float RADAR_BLUR_MIX = 0.25;

		vec2 losSize    = vec2(LOSXSIZE, LOSYSIZE);
		vec2 airlosSize = vec2(AIRLOSXSIZE, AIRLOSYSIZE);
		vec2 radarSize  = vec2(RADARXSIZE, RADARYSIZE);

		float losBase = getTexelF(tex0, texCoord.xy, losSize * 2.0);
		float airlosBase = getTexelF(tex1, texCoord.xy, airlosSize * 2.5);
		vec2 radarBase = getTexel(tex2, texCoord.xy, radarSize * 2.5).rg;

		float losBlur = smoothstep(0.0, 1.0, blur5R(tex0, texCoord.xy, losSize, BLUR_RADIUS));
		float airlosBlur = smoothstep(0.0, 1.0, blur5R(tex1, texCoord.xy, airlosSize, BLUR_RADIUS));
		vec2 radarBlur = blur5RG(tex2, texCoord.xy, radarSize, BLUR_RADIUS);

		float los = mix(losBase, losBlur, LOS_BLUR_MIX);
		float airlos = mix(airlosBase, airlosBlur, AIRLOS_BLUR_MIX);
		vec2 radarJammer = mix(radarBase, radarBlur, RADAR_BLUR_MIX);

		fragColor.r = 0.2 + 0.8 * los;
		fragColor.g = 0.2 + 0.8 * airlos;
		fragColor.b = 0.2 + 0.8 * clamp(0.75 * radarJammer.r - 0.5 * (radarJammer.g - 0.5), 0.0, 1.0);
		fragColor.a = outputAlpha;

	#else
		// textureGather returns in rgba order, TL, TR, BR, BL
		/*
		vec4 los_samples = textureGather(tex0, texCoord.xy, 0);
		vec4 airlos_samples = textureGather(tex1, texCoord.xy, 0);
		vec4 radar_samples = textureGather(tex2, texCoord.xy, 0);
		vec4 jammer_samples = textureGather(tex2, texCoord.xy, 1);

		float smooth_los = gatherBlend(los_samples, texCoord.xy, vec2(LOSXSIZE,LOSYSIZE));
		float smooth_airlos = gatherBlend(airlos_samples, texCoord.xy, vec2(AIRLOSXSIZE,AIRLOSYSIZE));
		float smooth_radar = gatherBlend(radar_samples, texCoord.xy, vec2(RADARXSIZE,RADARYSIZE));
		float smooth_jammer = gatherBlend(jammer_samples, texCoord.xy, vec2(RADARXSIZE,RADARYSIZE));
		*/

		float smooth_los = textureLod(tex0, QuinticSampler(texCoord.xy, vec2(LOSXSIZE, LOSYSIZE)), 0).r;
		smooth_los = smoothstep(0.0, 1.0, smooth_los);

		float smooth_airlos = textureLod(tex1, CubicSampler(texCoord.xy, vec2(AIRLOSXSIZE, AIRLOSYSIZE)), 0).r;
		smooth_airlos = smoothstep(0.0, 1.0, smooth_airlos);

		vec2 smooth_radars = textureLod(tex2, CubicSampler(texCoord.xy, vec2(RADARXSIZE, RADARYSIZE)), 0).rg;

		fragColor.r = 0.2 + 0.8 * smooth_los;
		fragColor.g = 0.2 + 0.8 * smooth_airlos;
		fragColor.b = 0.2 + 0.8 * clamp(0.75 * smooth_radars.r - 0.5 * (smooth_radars.g - 0.5), 0.0, 1.0);
		fragColor.a = outputAlpha;
	#endif
}