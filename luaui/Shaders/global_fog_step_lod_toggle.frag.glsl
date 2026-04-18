#version 420
#extension GL_ARB_uniform_buffer_object : require
#extension GL_ARB_shading_language_420pack: require
// This shader is (c) Beherith (mysterme@gmail.com)
// Notes:
// texelFetch is hardly faster but has banding artifacts, do not use!

//__ENGINEUNIFORMBUFFERDEFS__
//__DEFINES__

#line 30000

in DataVS {
	vec4 sampleUVs;
};

uniform sampler2D mapDepths;
uniform sampler2D modelDepths;
uniform sampler2D heightmapTex;
uniform sampler2D infoTex;
#if SHADOWSAMPLER == 1 
	uniform sampler2DShadow shadowTex;
#else
	uniform sampler2D shadowTex;
	ivec2 shadowTexSize = textureSize(shadowTex,0);
#endif
uniform sampler3D noise64cube;
uniform sampler2D miniMapTex;
uniform sampler2D blueNoise64;
uniform sampler2D packedNoise;
uniform sampler3D uniformNoiseTex;

uniform vec4 windFractFull;
uniform vec4 heightFogColor;
uniform vec4 cloudGlobalColor;
uniform vec4 distanceFogColor;
uniform vec4 shadowedColor;
uniform vec4 noiseLFParams;
uniform vec4 noiseHFParams;

uniform float cloudDensity;
uniform float heightFogTop;
uniform float heightFogBottom;

uniform vec4 cloudVolumeMin;
uniform vec4 cloudVolumeMax;
uniform vec4 scavengerPlane;

uniform vec4 cameraWorldPos;
uniform float cameraFadeStart;
uniform float cameraFadeEnd;
uniform float cameraFadePower;
uniform float cameraFadeEnabled;
uniform float cameraHeightAboveGround;
uniform float cloudResolutionScale;
uniform float heightFogResolutionScale;
uniform float shadowResolutionScale;
uniform float distanceFogResolutionScale;

uniform int radarCount;
uniform vec4 radarCenters[64]; // x, z, radius, unused

uniform float time;

float Value3D(vec3 P);

out vec4 fragColor;

float radarCoverageAtWorldPos(vec3 worldPos)
{
	vec2 p = worldPos.xz;

	for (int i = 0; i < 64; ++i) {
		if (i >= radarCount) break;

		vec2 d = p - radarCenters[i].xy;
		float r = radarCenters[i].z;
		if (dot(d, d) <= r * r) {
			return 1.0;
		}
	}
	return 0.0;
}

float GetCameraFade(vec3 viewDir)
{
	if (cameraFadeEnabled < 0.5) {
		return 1.0;
	}

	// Fade de base: hauteur de la caméra au-dessus du terrain
	float baseFade = smoothstep(cameraFadeStart, cameraFadeEnd, cameraHeightAboveGround);
	baseFade = pow(max(0.0, baseFade), max(0.01, cameraFadePower));

	// 0 = vue verticale, 1 = horizon
	float horizonFactor = 1.0 - abs(normalize(viewDir).y);
	float horizonLift = smoothstep(0.35, 0.95, horizonFactor);

	// Garde un minimum de visibilité quand on regarde l'horizon
	float horizonMinFade = mix(0.0, 0.90, horizonLift);

	return max(baseFade, horizonMinFade);
}

float ClampResolutionScale(float s)
{
	return clamp(s, 0.5, 1.0);
}

float ScaledSampleCount(float baseSteps, float scale)
{
	return max(1.0, floor(baseSteps * ClampResolutionScale(scale) + 0.5));
}

float ComputeStepLodImportance(float rayLength, float horizonFactor, float densityHint, float visibilityHint)
{
	float lengthTerm = smoothstep(80.0, 2200.0, max(rayLength, 0.0));
	float horizonTerm = clamp(horizonFactor, 0.0, 1.0);
	float densityTerm = clamp(densityHint, 0.0, 1.0);
	float visibilityTerm = clamp(visibilityHint, 0.0, 1.0);
	return clamp(0.22 + 0.34 * lengthTerm + 0.22 * horizonTerm + 0.12 * densityTerm + 0.10 * visibilityTerm, 0.20, 1.0);
}

#ifndef STEPLOD_STRENGTH
#define STEPLOD_STRENGTH 1.0
#endif
#ifndef STEPLOD_CLOUD_MIN
#define STEPLOD_CLOUD_MIN 0.30
#endif
#ifndef STEPLOD_CLOUDSHADOW_MIN
#define STEPLOD_CLOUDSHADOW_MIN 0.25
#endif
#ifndef STEPLOD_HEIGHTNOISE_MIN
#define STEPLOD_HEIGHTNOISE_MIN 0.30
#endif
#ifndef STEPLOD_HEIGHTSHADOW_MIN
#define STEPLOD_HEIGHTSHADOW_MIN 0.35
#endif
#ifndef STEPLOD_DISTANCE_EARLYOUT
#define STEPLOD_DISTANCE_EARLYOUT 0.22
#endif
#ifndef STEPLOD_DISTANCE_ALPHA_MIN
#define STEPLOD_DISTANCE_ALPHA_MIN 0.02
#endif

float StepLodFraction(float importance, float minFraction)
{
	float tunedImportance = clamp(importance, 0.0, 1.0);
#if (STEPLOD > 0)
	tunedImportance = pow(tunedImportance, max(0.001, float(STEPLOD_STRENGTH)));
#endif
	return clamp(mix(minFraction, 1.0, tunedImportance), minFraction, 1.0);
}

float EffectiveSampleCount(float baseSteps, float scale, float importance, float minFraction)
{
	float scaledSteps = ScaledSampleCount(baseSteps, scale);
#if (STEPLOD > 0)
	return max(1.0, floor(scaledSteps * StepLodFraction(importance, minFraction) + 0.5));
#else
	return max(1.0, floor(scaledSteps + 0.5));
#endif
}

float ComputeDistanceFogLodImportance(float rayLength, float rayUpness, float fogAlpha)
{
	float lengthTerm = smoothstep(160.0, 2600.0, max(rayLength, 0.0));
	float upnessTerm = clamp(rayUpness, 0.0, 1.0);
	float alphaTerm = smoothstep(0.02, 0.30, fogAlpha);
	return clamp(0.18 + 0.42 * lengthTerm + 0.25 * upnessTerm + 0.15 * alphaTerm, 0.15, 1.0);
}

vec2 QuantizeScreenUV(vec2 uv, float scale)
{
	float s = ClampResolutionScale(scale);
	if (s >= 0.999) {
		return uv;
	}

	vec2 scaledSize = max(vec2(1.0), floor(vec2(float(VSX), float(VSY)) * s + 0.5));
	vec2 clampedUV = clamp(uv, vec2(0.0), vec2(0.999999));
	vec2 pixel = floor(clampedUV * scaledSize);
	vec2 quantizedUV = (pixel + 0.5) / scaledSize;
	return clamp(quantizedUV, vec2(0.5 / float(VSX), 0.5 / float(VSY)), vec2(1.0 - 0.5 / float(VSX), 1.0 - 0.5 / float(VSY)));
}

const float CLOUD_UPSCALE_SOFTNESS = 0.58;
const float HEIGHTFOG_UPSCALE_SOFTNESS = 0.32;
const float SHADOW_UPSCALE_SOFTNESS = 0.18;
const float DISTANCEFOG_UPSCALE_SOFTNESS = 0.66;

#define BLUENOISESTRENGTH 0.8


vec2 ReconstructUpscaledUV(vec2 uv, float scale, float softness)
{
	float s = ClampResolutionScale(scale);
	if (s >= 0.999) {
		return uv;
	}

	vec2 scaledSize = max(vec2(1.0), floor(vec2(float(VSX), float(VSY)) * s + 0.5));
	vec2 clampedUV = clamp(
		uv,
		vec2(0.5 / float(VSX), 0.5 / float(VSY)),
		vec2(1.0 - 0.5 / float(VSX), 1.0 - 0.5 / float(VSY))
	);
	vec2 quantizedUV = QuantizeScreenUV(clampedUV, s);
	vec2 cellFrac = fract(clampedUV * scaledSize);
	float edgeWeight = smoothstep(0.15, 0.95, max(abs(cellFrac.x - 0.5), abs(cellFrac.y - 0.5)) * 2.0);
	float localSoftness = clamp(softness, 0.0, 1.0) * mix(0.45, 1.0, edgeWeight);
	return mix(quantizedUV, clampedUV, localSoftness);
}

float UpscaleSoftening(float scale, float amount)
{
	return clamp((1.0 - ClampResolutionScale(scale)) * amount, 0.0, 1.0);
}


float DownsampleNoiseStrength(float scale, float minStrength)
{
	float s = ClampResolutionScale(scale);
	return mix(minStrength, 1.0, smoothstep(0.5, 1.0, s));
}

vec2 SampleLayerBlueNoise(vec2 referenceUV, float scale, float minStrength, vec2 phaseOffset)
{
	float s = ClampResolutionScale(scale);
	vec2 noiseUV = referenceUV;
	if (s < 0.999) {
		noiseUV = QuantizeScreenUV(referenceUV, s);
	}
	noiseUV = noiseUV * vec2(float(VSX), float(VSY)) / 64.0 + phaseOffset;
	return textureLod(blueNoise64, noiseUV, 0).xy * (BLUENOISESTRENGTH * DownsampleNoiseStrength(scale, minStrength));
}

void SampleSceneAtUV(
	vec2 uv,
	vec3 camPos,
	out float mapdepthRaw,
	out float modeldepthRaw,
	out vec3 trueWorldPos,
	out vec3 worldPos,
	out vec3 camToWorld,
	out float lengthFromCam,
	out vec3 camToWorldNorm
)
{
	mapdepthRaw = texture(mapDepths, uv).x;
	modeldepthRaw = texture(modelDepths, uv).x;

	float sceneDepth = modeldepthRaw;
	bool mapValid = mapdepthRaw < 0.99999;
	bool modelValid = modeldepthRaw < 0.99999;

	if (mapValid && modelValid) sceneDepth = min(mapdepthRaw, modeldepthRaw);
	else if (mapValid)          sceneDepth = mapdepthRaw;

	vec4 worldPos4 = vec4(vec3(uv * 2.0 - 1.0, sceneDepth), 1.0);
	worldPos4 = cameraViewProjInv * worldPos4;
	trueWorldPos = worldPos4.xyz / worldPos4.w;
	worldPos = trueWorldPos;

	camToWorld = worldPos - camPos;
	if (worldPos.y < 0.0) {
		float abovewaterfraction = camPos.y / max(abs(camToWorld.y), 1e-4);
		worldPos = camToWorld * abovewaterfraction + camPos;
		camToWorld = worldPos - camPos;
	}

	lengthFromCam = max(length(camToWorld), 1e-4);
	camToWorldNorm = camToWorld / lengthFromCam;
}
float SunForwardScatter(vec3 viewDir)
{
	float s = clamp(dot(normalize(viewDir), normalize(sunDir.xyz)), 0.0, 1.0);	//less costly?
	float s2 = s * s;
	return s2 * s2 * s2;
}

float HorizonViewFactor(vec3 viewDir)
{
	float h = 1.0 - abs(normalize(viewDir).y);
	return h * h;
}

vec3 ApplySunTint(vec3 baseColor, vec3 viewDir, float amount)
{
	float sunScatter = SunForwardScatter(viewDir);
	vec3 sunTint = vec3(1.0, 0.92, 0.78);
	return mix(baseColor, baseColor * sunTint, sunScatter * amount);
}

float CloudVerticalProfile(float h)
{
	float baseSoft = smoothstep(0.0, 0.18, h);
	float topFade  = 1.0 - smoothstep(0.65, 1.0, h);
	return clamp(baseSoft * topFade, 0.0, 1.0);
}

float FogCloudBridgeFactor(float y)
{
	return smoothstep(cloudVolumeMin.y - 220.0, cloudVolumeMin.y + 80.0, y);
}

const float CLOUD_PI = 3.14159265359;

float evalDrainePhase(float u, float g, float a)
{
	float gg = g * g;
	float denom = 4.0 * CLOUD_PI * (1.0 + (a * (1.0 + 2.0 * gg)) / 3.0);
	float base  = pow(max(1e-4, 1.0 + gg - 2.0 * g * u), 1.5);
	return ((1.0 - gg) * (1.0 + a * u * u)) / denom / base;
}

float evalHGPhase(float u, float g)
{
	float gg = g * g;
	float denom = 4.0 * CLOUD_PI * pow(max(1e-4, 1.0 + gg - 2.0 * g * u), 1.5);
	return (1.0 - gg) / denom;
}

float evalCloudPhase(vec3 viewDir)
{
	vec3 V = normalize(viewDir);
	vec3 L = normalize(sunDir.xyz);

	float u = clamp(dot(V, L), -1.0, 1.0);

	// Strong forward peak + smoother body
	float phaseHG = evalHGPhase(u, 0.82);
	float phaseDR = evalDrainePhase(u, 0.68, 1.0); // a=1 => Cornette-Shanks-like family

	// NVIDIA-style practical blend spirit: HG forward lobe + Draine body
	return mix(phaseHG, phaseDR, 0.40);
}

float frequency;

#if 1 // These are globally useful helpers
	// UNUSED, returns 0 for in shadow, 1 for not in shadow, has various options for what kind of shadow sampling should be used. 
	float shadowAtWorldPos(vec3 worldPos){
			vec4 shadowVertexPos = shadowView * vec4(worldPos,1.0);
			shadowVertexPos.xy += vec2(0.5);
			#define SHADOWLODBIAS 2
			// Details on textureProj PCF http://www.opengl-tutorial.org/intermediate-tutorials/tutorial-16-shadow-mapping/
			// Idea for using texelFetch https://community.khronos.org/t/can-you-use-sampler2d-and-sampler2dshadow-on-the-same-texture/76203
			#if SHADOWSAMPLER == 1 // TextureProj does 4 sample PCF filtering in hardware
				return clamp(textureProj(shadowTex, shadowVertexPos, - SHADOWLODBIAS), 0.0, 1.0);
			#endif
			#if SHADOWSAMPLER == 0 // Regular Texture Fetch operation
				return step(shadowVertexPos.z, texture(shadowTex, shadowVertexPos.xy, 10).z);
			#endif
			#if SHADOWSAMPLER == 2 // http://www.opengl-tutorial.org/intermediate-tutorials/tutorial-16-shadow-mapping/
				//float clampy = 
				// TODO: if ray starts or ends outside of shadow map, just stop
				if (any(bvec4(greaterThan(shadowVertexPos.xy, vec2(0.999)), lessThan(shadowVertexPos.xy, vec2(0.0))))) return 1.0;
				else 
					return step(shadowVertexPos.z, texelFetch(shadowTex, ivec2(shadowTexSize *shadowVertexPos.xy) , 0).z);
			#endif			
			#if SHADOWSAMPLER == 3 // This one results in the most interesting, ambient-occlusion-like effect i have ever seen!
				float near = 0.1; 
				float far  = 100.0; 
				float shadowZ = texelFetch(shadowTex, ivec2(shadowTexSize *shadowVertexPos.xy) , 0).z; 
				float linearShad = (20) / (100.1 - shadowZ * (99.9 )) * 100;
				float linearSamp = (20) / (100.1 - shadowVertexPos.z * (99.9 )) * 100;
				
				return clamp((linearShad -  linearSamp ) * 2, 0,1);
			#endif
	}

	// UNUSED, returns 0 for not in los, 1 for in los, -100 for never seen
	// returns:
	//   >= 0.0 : amount of fog reduction when in LOS
	//   <  0.0 : not in LOS
	float losLevelAtWorldPos(vec3 worldPos){ 
		vec2 losUV = clamp(worldPos.xz, vec2(0.0), mapSize.xy) / mapSize.xy;
		vec4 infoTexSample = texture(infoTex, losUV);

		if (infoTexSample.r > 0.2) {
			return clamp((infoTexSample.r - 0.2) / 0.70, 0.0, 1.0) * LOSREDUCEFOG;
		} else {
			return -1.0;
		}
	}


	// UNUSED fast, filthy 2D random function. Not good for much
	float rand(vec2 co){
		return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);
	}
	
	// UNUSED returns the linear distance to the closest edge of the map in 3d
	float linearDistanceMap(vec3 worldpos){
		vec3 worldMax = vec3(float(MAPSIZEX), float(MAPSIZEY),float(MAPSIZEZ));
		vec3 minDist = max(-1 * worldpos, worldpos - worldMax);
		minDist = max(minDist, vec3(0.0));
		return max(minDist.x, max(minDist.y, minDist.z));
	}

	// UNUSED returns the linear distance to the closest edge of the map, in elmos
	vec2 linearDistanceMapXZ(vec2 worldpos){
		vec2 worldMax = vec2(float(MAPSIZEX), float(MAPSIZEZ));
		vec2 minDist = max(-1 * worldpos, worldpos - worldMax);
		minDist = max(minDist, vec2(0.0));
		return minDist;
	}

	float linearDistanceMapXZThreshold(vec2 worldpos, float thresholdElmos){
		vec2 worldMax = vec2(float(MAPSIZEX), float(MAPSIZEZ));
		vec2 minDist = max(-1 * worldpos, worldpos - worldMax);
		minDist = max(minDist, vec2(0.0));
		float realdist = sqrt(dot(minDist, minDist));
		realdist = (thresholdElmos - realdist + 1.0) / max(1.0, thresholdElmos);
		return realdist;
	}
	// This will bound within the min/max values, with feathering along the w coordinates of CloudVolume
	float CloudVolumeWeight(vec2 worldpos){
		vec2 cloudDist = max(vec2(0), max(cloudVolumeMin.xz - worldpos, worldpos - cloudVolumeMax.xz));
		float cloudEdgeDistanceWeight = sqrt(dot(cloudDist, cloudDist));
		cloudEdgeDistanceWeight = ((cloudVolumeMax.w + 1) - cloudEdgeDistanceWeight)/(1 +cloudVolumeMax.w);
		//cloudEdgeDistanceWeight = clamp(cloudEdgeDistanceWeight,0,1);
		cloudEdgeDistanceWeight = smoothstep(0.0, 1.0, cloudEdgeDistanceWeight);
		return cloudEdgeDistanceWeight;
	}
	
	// Signed distance to a rounded axis-aligned box defined by corners cornerA and cornerB.
	// cornerA, cornerB: opposite corners of the box (order doesn’t matter)
	// roundingRadius: uniform edge/face rounding radius
	float sdRoundedBoxFromCorners(vec3 point, vec3 boxMin, vec3 boxMax, float roundingRadius)
	{
		// Compute center and half extents
		vec3 boxCenter = 0.5 * (boxMin + boxMax);
		vec3 halfSize  = 0.5 * (boxMax - boxMin);

		// Rounded box distance
		vec3 offset = abs(point - boxCenter) - (halfSize - vec3(roundingRadius));
		return length(max(offset, 0.0)) 
			+ min(max(offset.x, max(offset.y, offset.z)), 0.0) 
			- roundingRadius;
	}


#endif

#if 1 // These are all standard, useful Noise functions 
//  https://github.com/BrianSharpe/Wombat/blob/master/Value3D.glsl
float Value3D( vec3 P )// actually works and is correct and fast and random
{
    // establish our grid cell and unit position
    vec3 Pi = floor(P);
    vec3 Pf = P - Pi;

    // clamp the domain
    Pi.xyz = Pi.xyz - floor(Pi.xyz * ( 1.0 / 69.0 )) * 69.0;
    vec3 Pi_inc1 = step( Pi, vec3( 69.0 - 1.5 ) ) * ( Pi + 1.0 );

    // calculate the hash
    vec4 Pt = vec4( Pi.xy, Pi_inc1.xy ) + vec2( 50.0, 161.0 ).xyxy;
    Pt *= Pt;
    Pt = Pt.xzxz * Pt.yyww;
    vec2 hash_mod = vec2( 1.0 / ( 635.298681 + vec2( Pi.z, Pi_inc1.z ) * 48.500388 ) );
    vec4 hash_lowz = fract( Pt * hash_mod.xxxx );
    vec4 hash_highz = fract( Pt * hash_mod.yyyy );

    //	blend the results and return
    //vec3 blend = Pf * Pf * Pf * (Pf * (Pf * 6.0 - 15.0) + 10.0);
    //vec3 blend = smoothstep(0,1,Pf); // better than 5th order as above (and faster)
    vec3 blend = Pf * Pf * (3.0 - 2.0 * Pf); // better than 5th order as above (and faster)
    vec4 res0 = mix( hash_lowz, hash_highz, blend.z );
    vec4 blend2 = vec4( blend.xy, vec2( 1.0 - blend.xy ) );
    return dot( res0, blend2.zxzx * blend2.wwyy );
}

vec4 Value3D_Deriv( vec3 P ) // actually works and is correct and fast and random
{
    // establish our grid cell and unit position
    vec3 Pi = floor(P);
    vec3 Pf = P - Pi;

    // clamp the domain
    Pi.xyz = Pi.xyz - floor(Pi.xyz * ( 1.0 / 69.0 )) * 69.0;
    vec3 Pi_inc1 = step( Pi, vec3( 69.0 - 1.5 ) ) * ( Pi + 1.0 );

    // calculate the hash
    vec4 Pt = vec4( Pi.xy, Pi_inc1.xy ) + vec2( 50.0, 161.0 ).xyxy;
    Pt *= Pt;
    Pt = Pt.xzxz * Pt.yyww;
    vec2 hash_mod = vec2( 1.0 / ( 635.298681 + vec2( Pi.z, Pi_inc1.z ) * 48.500388 ) );
    vec4 hash_lowz = fract( Pt * hash_mod.xxxx );
    vec4 hash_highz = fract( Pt * hash_mod.yyyy );

	// better than 5th order poly used previously
    vec3 blend = Pf * Pf * (3.0 - 2.0 * Pf); 

    //	blend the results and return
	// res0 results in the 2d squash along Z:
    vec4 res0 =  mix(hash_lowz, hash_highz, blend.z );
	vec2 res1 =  mix(res0.xy  , res0.zw   , blend.y);
	float res2 = mix(res1.x   , res1.y    , blend.x);

	// Below is the simple derivative based approach
	// DERIVATIVES
	#define DERIVSTEP 1024.0
	vec3 derivatives = vec3(0);
	// Move the Pf vector a bit
	vec3 blendderiv = min(vec3(1), Pf + 1.0/DERIVSTEP); // The min is to ensure we dont move out of smoothstep range
	blendderiv =   blendderiv * blendderiv * (3.0 - 2.0 * blendderiv);
	// Calculate the same three as above, just at a the derivative step of Z
	vec4 res0deriv   = mix(hash_lowz   , hash_highz  , blendderiv.z);
	vec2 res1derivz  = mix(res0deriv.xy, res0deriv.zw, blend.y);
	derivatives.z    = mix(res1derivz.x, res1derivz.y, blend.x);

	// Then on derivative step of Y
	vec2 res1derivy =  mix(res0.xy  , res0.zw   , blendderiv.y);
	derivatives.y   =  mix(res1derivy.x   , res1derivy.y    , blend.x);
	
	// then on derivatie step of X
	derivatives.x   =  mix(res1.x   , res1.y    , blendderiv.x);
	derivatives = (res2 - derivatives) * DERIVSTEP;
    return vec4(derivatives, res2);
}

// fastest 3d noise ever? https://www.shadertoy.com/view/WslGWl
// its nice, but not random enough
float fbmhash(float n){return fract(sin(n) * 43758.5453);}
vec4 FBMNoise3DDeriv(in vec3 x) // uses S
{
	vec3 p = floor(x);
	vec3 f = fract(x);
	vec3 oldf = f;
	
	vec3 fd =  - 6.0 * f * f + 6.0 * f; 
	f = f * f * (3.0 - 2.0 * f);
	
	float n = p.x + p.y * 57.0 + p.z * 113.0;
	
	vec4 hash_0 = fract(sin(vec4(0, 57, 113, 170)+ n    ) * 43758.5453);
	vec4 hash_1 = fract(sin(vec4(0, 57, 113, 170)+ n + 1) * 43758.5453);
	vec4 mix_4 = mix(hash_0, hash_1, f.x);
	vec2 mix_2 = mix(mix_4.xz, mix_4.yw, f.y);
	float myn = mix(mix_2.x, mix_2.y, f.z);
	
	// This is simple directional derivative inspired by https://iquilezles.org/articles/derivative/ 
	float stepsize = 0.001;
	vec3 dir = sunDir.xyz * stepsize;
	vec3 f2 = oldf - dir * fd;
	
	f2 = smoothstep(0,1,f2);
	vec4 mix2_4 = mix(hash_0, hash_1, f2.x);
	vec2 mix2_2 = mix(mix2_4.xz, mix2_4.yw, f2.y);
	float myn2 = mix(mix2_2.x, mix2_2.y, f2.z);
	vec3 deriv =  vec3(myn - myn2)/ stepsize;
	return vec4(myn, deriv * myn);
}

float FBMNoise3D(in vec3 x) // nah this is the fastest!
{
	vec3 p = floor(x);
	vec3 f = fract(x);
	
	f = f * f * (3.0 - 2.0 * f);
	
	float n = p.x + p.y * 57.0 + p.z * 113.0;
	
	vec4 hash_0 = fract(sin(vec4(0, 57, 113, 170)+ n    ) * 43758.5453);
	vec4 hash_1 = fract(sin(vec4(0, 57, 113, 170)+ n + 1) * 43758.5453);
	vec4 mix_4 = mix(hash_0, hash_1, f.x);
	vec2 mix_2 = mix(mix_4.xz, mix_4.yw, f.y);
	float myn = mix(mix_2.x, mix_2.y, f.z);
	return myn;
}

float FBMNoise3DXF(in vec3 x) // nah this is the fastest!
{
	vec3 p = floor(x);
	vec3 f = x - p;
	 
	//f = f * f * (3.0 - 2.0 * f);
	float n = p.x + p.y * 57.0 + p.z * 113.0;
	//vec4 H1Pre = sin(vec4(0, 57, 113, 170)+ n    ) ;
	vec4 hash_0 = fract(sin(vec4(0, 57, 113, 170)+ n    ) * 43758.5453);
	vec4 hash_1 = fract(sin(vec4(0, 57, 113, 170)+ n  + 1) * 43758.5453);
	vec4 mix_4 = mix(hash_0, hash_1, f.x);
	vec2 mix_2 = mix(mix_4.xz, mix_4.yw, f.y);
	float myn = mix(mix_2.x, mix_2.y, f.z);
	return myn;
}


vec2 FBMNoise3D_rg(in vec3 x) // return two noise floats
{
	vec3 p = floor(x);
	vec3 f = x - p;
	 
	//f = f * f * (3.0 - 2.0 * f);
	
	float n = p.x + p.y * 57.0 + p.z * 113.0;
	//vec4 H1Pre = sin(vec4(0, 57, 113, 170)+ n    ) ;
	vec4 pos_0 = sin(vec4(0, 57, 113, 170)+ n    );
	vec4 pos_1 = sin(vec4(0, 57, 113, 170)+ n  + 1);

	vec4 hash_r_0 = fract( pos_0 * 43758.5453);
	vec4 hash_r_1 = fract( pos_1 * 43758.5453);
	vec4 mix_r_4 = mix(hash_r_0, hash_r_1, f.x);

	vec4 hash_g_0 = fract( pos_0 * 41758.5453);
	vec4 hash_g_1 = fract( pos_1 * 41758.5453);
	vec4 mix_g_4 = mix(hash_g_0, hash_g_1, f.x);
	
	vec4 mix_rg = mix(vec4(mix_r_4.xz, mix_g_4.xz), vec4(mix_r_4.yw, mix_g_4.yw), f.y);
	return mix(mix_rg.xz, mix_rg.yw,f.z);
}

vec4 FBMNoise3D_rgba(in vec3 x) // return 4 noise floats
{
	vec3 p = floor(x);
	vec3 f = x - p;
	 
	f = f * f * (3.0 - 2.0 * f);
	
	float n = p.x + p.y * 57.0 + p.z * 113.0;
	//vec4 H1Pre = sin(vec4(0, 57, 113, 170)+ n    ) ;
	vec4 pos_0 = sin(vec4(0, 57, 113, 170)+ n    );
	vec4 pos_1 = sin(vec4(0, 57, 113, 170)+ n  + 1);

	vec4 hash_r_0 = fract( pos_0 * 43758.5453);
	vec4 hash_r_1 = fract( pos_1 * 43758.5453);
	vec4 mix_r_4 = mix(hash_r_0, hash_r_1, f.x);

	vec4 hash_g_0 = fract( pos_0 * 41758.5453);
	vec4 hash_g_1 = fract( pos_1 * 41758.5453);
	vec4 mix_g_4 = mix(hash_g_0, hash_g_1, f.x);
	
	vec4 mix_rg = mix(vec4(mix_r_4.xz, mix_g_4.xz), vec4(mix_r_4.yw, mix_g_4.yw), f.y);

	vec4 hash_b_0 = fract( pos_0 * 39758.5453);
	vec4 hash_b_1 = fract( pos_1 * 39758.5453);
	vec4 mix_b_4 = mix(hash_b_0, hash_b_1, f.x);

	vec4 hash_a_0 = fract( pos_0 * 31758.5453);
	vec4 hash_a_1 = fract( pos_1 * 31758.5453);
	vec4 mix_a_4 = mix(hash_a_0, hash_a_1, f.x);

	vec4 mix_ba = mix(vec4(mix_b_4.xz, mix_a_4.xz), vec4(mix_b_4.yw, mix_a_4.yw), f.y);
	
	return mix(vec4(mix_rg.xz, mix_ba.xz), vec4(mix_rg.yw, mix_ba.yw),f.z);
}



//https://www.shadertoy.com/view/4sfGzS

float hash3(vec3 p)  // replace this by something better
{
    p  = fract( p*0.3183099+.1 );
	p *= 17.0;
    return fract( p.x*p.y*p.z*(p.x+p.y+p.z) );
}

float noiseIQ3( in vec3 x )
{
    vec3 f = fract(x);
    vec3 i = x-f;
    //vec3 f = fract(x);
    f = f*f*(3.0-2.0*f);
	
    return mix(mix(mix( hash3(i+vec3(0,0,0)), 
                        hash3(i+vec3(1,0,0)),f.x),
                   mix( hash3(i+vec3(0,1,0)), 
                        hash3(i+vec3(1,1,0)),f.x),f.y),
               mix(mix( hash3(i+vec3(0,0,1)), 
                        hash3(i+vec3(1,0,1)),f.x),
                   mix( hash3(i+vec3(0,1,1)), 
                        hash3(i+vec3(1,1,1)),f.x),f.y),f.z);
}

float FBMNoise2D(in vec2 x) // nah this is the fastest!
{
	vec2 f = fract(x);
	vec2 p = x-f;
	
	f = f * f * (3.0 - 2.0 * f);
	
	float n = p.x + p.y * 57;
	
	vec4 hash_0 = fract((vec4(0, 57, 1, 58) + n) * 20.7453);
	//hash_0 = vec4(0,0,1,0);
	vec2 mix_2 = mix(hash_0.xy, hash_0.zw, f.x);
	float myn = mix(mix_2.x, mix_2.y, f.y);
	return myn;
}

//  https://github.com/BrianSharpe/Wombat/blob/master/Value3D.glsl
vec4 Value3D3( vec3 P )
{
    // establish our grid cell and unit position
    vec3 Pi = floor(P);
    vec3 Pf = P - Pi;
    vec3 Pf_min1 = Pf - 1.0;

    // clamp the domain
    Pi.xyz = Pi.xyz - floor(Pi.xyz * ( 1.0 / 69.0 )) * 69.0;
    vec3 Pi_inc1 = step( Pi, vec3( 69.0 - 1.5 ) ) * ( Pi + 1.0 );

    // calculate the hash
    vec4 Pt = vec4( Pi.xy, Pi_inc1.xy ) + vec2( 50.0, 161.0 ).xyxy;
    Pt *= Pt;
    Pt = Pt.xzxz * Pt.yyww;
    vec2 hash_mod = vec2( 1.0 / ( 635.298681 + vec2( Pi.z, Pi_inc1.z ) * 48.500388 ) );
    vec4 hash_lowz = fract( Pt * hash_mod.xxxx );
    vec4 hash_highz = fract( Pt * hash_mod.yyyy );

    //	blend the results and return
    //vec3 blend = Pf * Pf * Pf * (Pf * (Pf * 6.0 - 15.0) + 10.0);
    vec3 blend = Pf * Pf * (3.0 - 2.0 * Pf); // better than 5th order as above (and faster)
    vec4 res0 = mix( hash_lowz, hash_highz, blend.z );
    vec4 blend2 = vec4( blend.xy, vec2( 1.0 - blend.xy ) );
	
    return vec4(dot( res0, blend2.zxzx * blend2.wwyy ), blend);
}

float SimplexPerlin3D( vec3 P ){
    //  https://github.com/BrianSharpe/Wombat/blob/master/SimplexPerlin3D.glsl

    //  simplex math constants
    const float SKEWFACTOR = 1.0/3.0;
    const float UNSKEWFACTOR = 1.0/6.0;
    const float SIMPLEX_CORNER_POS = 0.5;
    const float SIMPLEX_TETRAHEDRON_HEIGHT = 0.70710678118654752440084436210485;    // sqrt( 0.5 )

    //  establish our grid cell.
    P *= SIMPLEX_TETRAHEDRON_HEIGHT;    // scale space so we can have an approx feature size of 1.0
    vec3 Pi = floor( P + dot( P, vec3( SKEWFACTOR) ) );

    //  Find the vectors to the corners of our simplex tetrahedron
    vec3 x0 = P - Pi + dot(Pi, vec3( UNSKEWFACTOR ) );
    vec3 g = step(x0.yzx, x0.xyz);
    vec3 l = 1.0 - g;
    vec3 Pi_1 = min( g.xyz, l.zxy );
    vec3 Pi_2 = max( g.xyz, l.zxy );
    vec3 x1 = x0 - Pi_1 + UNSKEWFACTOR;
    vec3 x2 = x0 - Pi_2 + SKEWFACTOR;
    vec3 x3 = x0 - SIMPLEX_CORNER_POS;

    //  pack them into a parallel-friendly arrangement
    vec4 v1234_x = vec4( x0.x, x1.x, x2.x, x3.x );
    vec4 v1234_y = vec4( x0.y, x1.y, x2.y, x3.y );
    vec4 v1234_z = vec4( x0.z, x1.z, x2.z, x3.z );

    // clamp the domain of our grid cell
    Pi.xyz = Pi.xyz - floor(Pi.xyz * ( 1.0 / 69.0 )) * 69.0;
    vec3 Pi_inc1 = step( Pi, vec3( 69.0 - 1.5 ) ) * ( Pi + 1.0 );

    //	generate the random vectors
    vec4 Pt = vec4( Pi.xy, Pi_inc1.xy ) + vec2( 50.0, 161.0 ).xyxy;
    Pt *= Pt;
    vec4 V1xy_V2xy = mix( Pt.xyxy, Pt.zwzw, vec4( Pi_1.xy, Pi_2.xy ) );
    Pt = vec4( Pt.x, V1xy_V2xy.xz, Pt.z ) * vec4( Pt.y, V1xy_V2xy.yw, Pt.w );
    const vec3 SOMELARGEFLOATS = vec3( 635.298681, 682.357502, 668.926525 );
    const vec3 ZINC = vec3( 48.500388, 65.294118, 63.934599 );
    vec3 lowz_mods = vec3( 1.0 / ( SOMELARGEFLOATS.xyz + Pi.zzz * ZINC.xyz ) );
    vec3 highz_mods = vec3( 1.0 / ( SOMELARGEFLOATS.xyz + Pi_inc1.zzz * ZINC.xyz ) );
    Pi_1 = ( Pi_1.z < 0.5 ) ? lowz_mods : highz_mods;
    Pi_2 = ( Pi_2.z < 0.5 ) ? lowz_mods : highz_mods;
    vec4 hash_0 = fract( Pt * vec4( lowz_mods.x, Pi_1.x, Pi_2.x, highz_mods.x ) ) - 0.49999;
    vec4 hash_1 = fract( Pt * vec4( lowz_mods.y, Pi_1.y, Pi_2.y, highz_mods.y ) ) - 0.49999;
    vec4 hash_2 = fract( Pt * vec4( lowz_mods.z, Pi_1.z, Pi_2.z, highz_mods.z ) ) - 0.49999;

    //	evaluate gradients
    vec4 grad_results = inversesqrt( hash_0 * hash_0 + hash_1 * hash_1 + hash_2 * hash_2 ) * ( hash_0 * v1234_x + hash_1 * v1234_y + hash_2 * v1234_z );

    //	Normalization factor to scale the final result to a strict 1.0->-1.0 range
    //	http://briansharpe.wordpress.com/2012/01/13/simplex-noise/#comment-36
    const float FINAL_NORMALIZATION = 37.837227241611314102871574478976;

    //  evaulate the kernel weights ( use (0.5-x*x)^3 instead of (0.6-x*x)^4 to fix discontinuities )
    vec4 kernel_weights = v1234_x * v1234_x + v1234_y * v1234_y + v1234_z * v1234_z;
    kernel_weights = max(0.5 - kernel_weights, 0.0);
    kernel_weights = kernel_weights*kernel_weights*kernel_weights;

    //	sum with the kernel and return
    return dot( kernel_weights, grad_results ) * FINAL_NORMALIZATION;
}


vec4 SimplexPerlin3D_Deriv(vec3 P)
{
    //  https://github.com/BrianSharpe/Wombat/blob/master/SimplexPerlin3D_Deriv.glsl

    //  simplex math constants
    const float SKEWFACTOR = 1.0/3.0;
    const float UNSKEWFACTOR = 1.0/6.0;
    const float SIMPLEX_CORNER_POS = 0.5;
    const float SIMPLEX_TETRAHEDRON_HEIGHT = 0.70710678118654752440084436210485;    // sqrt( 0.5 )

    //  establish our grid cell.
    P *= SIMPLEX_TETRAHEDRON_HEIGHT;    // scale space so we can have an approx feature size of 1.0
    vec3 Pi = floor( P + dot( P, vec3( SKEWFACTOR) ) );

    //  Find the vectors to the corners of our simplex tetrahedron
    vec3 x0 = P - Pi + dot(Pi, vec3( UNSKEWFACTOR ) );
    vec3 g = step(x0.yzx, x0.xyz);
    vec3 l = 1.0 - g;
    vec3 Pi_1 = min( g.xyz, l.zxy );
    vec3 Pi_2 = max( g.xyz, l.zxy );
    vec3 x1 = x0 - Pi_1 + UNSKEWFACTOR;
    vec3 x2 = x0 - Pi_2 + SKEWFACTOR;
    vec3 x3 = x0 - SIMPLEX_CORNER_POS;

    //  pack them into a parallel-friendly arrangement
    vec4 v1234_x = vec4( x0.x, x1.x, x2.x, x3.x );
    vec4 v1234_y = vec4( x0.y, x1.y, x2.y, x3.y );
    vec4 v1234_z = vec4( x0.z, x1.z, x2.z, x3.z );

    // clamp the domain of our grid cell
    Pi.xyz = Pi.xyz - floor(Pi.xyz * ( 1.0 / 69.0 )) * 69.0;
    vec3 Pi_inc1 = step( Pi, vec3( 69.0 - 1.5 ) ) * ( Pi + 1.0 );

    //	generate the random vectors
    vec4 Pt = vec4( Pi.xy, Pi_inc1.xy ) + vec2( 50.0, 161.0 ).xyxy;
    Pt *= Pt;
    vec4 V1xy_V2xy = mix( Pt.xyxy, Pt.zwzw, vec4( Pi_1.xy, Pi_2.xy ) );
    Pt = vec4( Pt.x, V1xy_V2xy.xz, Pt.z ) * vec4( Pt.y, V1xy_V2xy.yw, Pt.w );
    const vec3 SOMELARGEFLOATS = vec3( 635.298681, 682.357502, 668.926525 );
    const vec3 ZINC = vec3( 48.500388, 65.294118, 63.934599 );
    vec3 lowz_mods = vec3( 1.0 / ( SOMELARGEFLOATS.xyz + Pi.zzz * ZINC.xyz ) );
    vec3 highz_mods = vec3( 1.0 / ( SOMELARGEFLOATS.xyz + Pi_inc1.zzz * ZINC.xyz ) );
    Pi_1 = ( Pi_1.z < 0.5 ) ? lowz_mods : highz_mods;
    Pi_2 = ( Pi_2.z < 0.5 ) ? lowz_mods : highz_mods;
    vec4 hash_0 = fract( Pt * vec4( lowz_mods.x, Pi_1.x, Pi_2.x, highz_mods.x ) ) - 0.49999;
    vec4 hash_1 = fract( Pt * vec4( lowz_mods.y, Pi_1.y, Pi_2.y, highz_mods.y ) ) - 0.49999;
    vec4 hash_2 = fract( Pt * vec4( lowz_mods.z, Pi_1.z, Pi_2.z, highz_mods.z ) ) - 0.49999;

    //	normalize random gradient vectors
    vec4 norm = inversesqrt( hash_0 * hash_0 + hash_1 * hash_1 + hash_2 * hash_2 );
    hash_0 *= norm;
    hash_1 *= norm;
    hash_2 *= norm;

    //	evaluate gradients
    vec4 grad_results = hash_0 * v1234_x + hash_1 * v1234_y + hash_2 * v1234_z;

    //  evaulate the kernel weights ( use (0.5-x*x)^3 instead of (0.6-x*x)^4 to fix discontinuities )
    vec4 m = v1234_x * v1234_x + v1234_y * v1234_y + v1234_z * v1234_z;
    m = max(0.5 - m, 0.0);
    vec4 m2 = m*m;
    vec4 m3 = m*m2;

    //  calc the derivatives
    vec4 temp = -6.0 * m2 * grad_results;
    float xderiv = dot( temp, v1234_x ) + dot( m3, hash_0 );
    float yderiv = dot( temp, v1234_y ) + dot( m3, hash_1 );
    float zderiv = dot( temp, v1234_z ) + dot( m3, hash_2 );

    //	Normalization factor to scale the final result to a strict 1.0->-1.0 range
    //	http://briansharpe.wordpress.com/2012/01/13/simplex-noise/#comment-36
    const float FINAL_NORMALIZATION = 37.837227241611314102871574478976;

    //  sum and return all results as a vec3
    return vec4( dot( m3, grad_results ), xderiv, yderiv, zderiv ) * FINAL_NORMALIZATION;
}

//  Cellular Noise 3D Deriv
//  Return value range of 0.0->1.0, with format vec4( value, xderiv, yderiv, zderiv )
//
vec4 Cellular3D_Deriv( vec3 P )
{
    //  https://github.com/BrianSharpe/Wombat/blob/master/Cellular3D_Deriv.glsl

    //	establish our grid cell and unit position
    vec3 Pi = floor(P);
    vec3 Pf = P - Pi;

    // clamp the domain
    Pi.xyz = Pi.xyz - floor(Pi.xyz * ( 1.0 / 69.0 )) * 69.0;
    vec3 Pi_inc1 = step( Pi, vec3( 69.0 - 1.5 ) ) * ( Pi + 1.0 );

    // calculate the hash ( over -1.0->1.0 range )
    vec4 Pt = vec4( Pi.xy, Pi_inc1.xy ) + vec2( 50.0, 161.0 ).xyxy;
    Pt *= Pt;
    Pt = Pt.xzxz * Pt.yyww;
    const vec3 SOMELARGEFLOATS = vec3( 635.298681, 682.357502, 668.926525 );
    const vec3 ZINC = vec3( 48.500388, 65.294118, 63.934599 );
    vec3 lowz_mod = vec3( 1.0 / ( SOMELARGEFLOATS + Pi.zzz * ZINC ) );
    vec3 highz_mod = vec3( 1.0 / ( SOMELARGEFLOATS + Pi_inc1.zzz * ZINC ) );
    vec4 hash_x0 = fract( Pt * lowz_mod.xxxx ) * 2.0 - 1.0;
    vec4 hash_x1 = fract( Pt * highz_mod.xxxx ) * 2.0 - 1.0;
    vec4 hash_y0 = fract( Pt * lowz_mod.yyyy ) * 2.0 - 1.0;
    vec4 hash_y1 = fract( Pt * highz_mod.yyyy ) * 2.0 - 1.0;
    vec4 hash_z0 = fract( Pt * lowz_mod.zzzz ) * 2.0 - 1.0;
    vec4 hash_z1 = fract( Pt * highz_mod.zzzz ) * 2.0 - 1.0;

    //  generate the 8 point positions
    const float JITTER_WINDOW = 0.166666666;	// 0.166666666 will guarentee no artifacts.
    hash_x0 = ( ( hash_x0 * hash_x0 * hash_x0 ) - sign( hash_x0 ) ) * JITTER_WINDOW + vec4( 0.0, 1.0, 0.0, 1.0 );
    hash_y0 = ( ( hash_y0 * hash_y0 * hash_y0 ) - sign( hash_y0 ) ) * JITTER_WINDOW + vec4( 0.0, 0.0, 1.0, 1.0 );
    hash_x1 = ( ( hash_x1 * hash_x1 * hash_x1 ) - sign( hash_x1 ) ) * JITTER_WINDOW + vec4( 0.0, 1.0, 0.0, 1.0 );
    hash_y1 = ( ( hash_y1 * hash_y1 * hash_y1 ) - sign( hash_y1 ) ) * JITTER_WINDOW + vec4( 0.0, 0.0, 1.0, 1.0 );
    hash_z0 = ( ( hash_z0 * hash_z0 * hash_z0 ) - sign( hash_z0 ) ) * JITTER_WINDOW + vec4( 0.0, 0.0, 0.0, 0.0 );
    hash_z1 = ( ( hash_z1 * hash_z1 * hash_z1 ) - sign( hash_z1 ) ) * JITTER_WINDOW + vec4( 1.0, 1.0, 1.0, 1.0 );

    //	return the closest squared distance + derivatives ( thanks to Jonathan Dupuy )
    vec4 dx1 = Pf.xxxx - hash_x0;
    vec4 dy1 = Pf.yyyy - hash_y0;
    vec4 dz1 = Pf.zzzz - hash_z0;
    vec4 dx2 = Pf.xxxx - hash_x1;
    vec4 dy2 = Pf.yyyy - hash_y1;
    vec4 dz2 = Pf.zzzz - hash_z1;
    vec4 d1 = dx1 * dx1 + dy1 * dy1 + dz1 * dz1;
    vec4 d2 = dx2 * dx2 + dy2 * dy2 + dz2 * dz2;
    vec4 r1 = d1.x < d1.y ? vec4( d1.x, dx1.x, dy1.x, dz1.x ) : vec4( d1.y, dx1.y, dy1.y, dz1.y );
    vec4 r2 = d1.z < d1.w ? vec4( d1.z, dx1.z, dy1.z, dz1.z ) : vec4( d1.w, dx1.w, dy1.w, dz1.w );
    vec4 r3 = d2.x < d2.y ? vec4( d2.x, dx2.x, dy2.x, dz2.x ) : vec4( d2.y, dx2.y, dy2.y, dz2.y );
    vec4 r4 = d2.z < d2.w ? vec4( d2.z, dx2.z, dy2.z, dz2.z ) : vec4( d2.w, dx2.w, dy2.w, dz2.w );
    vec4 t1 = r1.x < r2.x ? r1 : r2;
    vec4 t2 = r3.x < r4.x ? r3 : r4;
    return ( t1.x < t2.x ? t1 : t2 ) * vec4( 1.0, vec3( 2.0 ) ) * ( 9.0 / 12.0 ); // return a value scaled to 0.0->1.0
}
#endif

#if 1 // The packed 3D noise sampler by Beherith

float packedNoiseLod = 0;
vec4 getPackedNoise(vec3 P){
	// e.g. worley3_256x128x64_RBGA_LONG.png/dds
	// This system assumes that a noise texture is packed into 2D with the following rules:
	// The noises Z axis is tiled along the X axis of the 2D texture
	// The G and A channels are higher precision in DXT5
	// The R ang B channels are lower precision
	// the RG and BA channels are offset by one step along the Z tiling so that interpolation can be done
	// needs textureLOD to prevent seams from warping.
	// perf Benefits from DDS compression greatly, but quality suffers a bit
	// The LOD level selection needs to be done carefully, as DDS suffers from shitty compression artifacts
	// can we fix LOD issues? yes cause .png suffers from bad lodding and hammering the memory subsystem, which is fixed by the packedNoiseLod dependent on camera distance.
	// VERY IMPORTANT NOTE: the fract operations + wide texture means precision is lost after a lot of offset in X
	// Thus must be mitigated by FRACT-ing the wind offsets from Lua to ensure they stay within [0-1] throughout the game
	// returns noise G + A in x, R + B in y, and the uninterpolated results in zw
	
	#define PACKX 256 // MUST BE SET TO PACKED TEXTURE DIMS
	#define PACKY 128
	#define PACKZ 64
	P = P.xzy; // swizzle coords here, because Z and Y are swapped
	P = P * vec3(1,2,4);
	

	//X is Y, 
	// Split Z into PACKZ levels, and put it into Y
	vec2 packedUV = vec2(P.x, fract(P.y));
	float fractZ = fract(P.z * PACKZ);
	float floorz = P.z * PACKZ - fractZ;
	packedUV.y = (packedUV.y + floorz) / PACKZ;
	//fractZ *= fractZ * fractZ * (3.0 - 2.0 * fractZ); // optional smoothing?
	vec4 packedSample = textureLod(packedNoise, packedUV.yx, packedNoiseLod); //yz is swapped here cause tex is tiled along X
	vec2 mixedSample = mix(packedSample.rg, packedSample.ba,  fractZ );
 
	return vec4(mixedSample.y, mixedSample.x,packedSample.w, packedSample.z);
}
#endif

#line 31000

#if 1 // Fast and simple FBM noises
//from : https://www.shadertoy.com/view/4dS3Wd
// Precision-adjusted variations of https://www.shadertoy.com/view/4djSRW
float hash(float p) { p = fract(p * 0.011); p *= p + 7.5; p *= p + p; return fract(p); }
float hash(vec2 p) {vec3 p3 = fract(vec3(p.xyx) * 0.13); p3 += dot(p3, p3.yzx + 3.333); return fract((p3.x + p3.y) * p3.z); }

float noise(float x) {
    float i = floor(x);
    float f = fract(x);
    float u = f * f * (3.0 - 2.0 * f);
    return mix(hash(i), hash(i + 1.0), u);
}


float noise(vec2 x) {
    vec2 i = floor(x);
    vec2 f = fract(x);

	// Four corners in 2D of a tile
	float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));

    // Simple 2D lerp using smoothstep envelope between the values.
	// return vec3(mix(mix(a, b, smoothstep(0.0, 1.0, f.x)),
	//			mix(c, d, smoothstep(0.0, 1.0, f.x)),
	//			smoothstep(0.0, 1.0, f.y)));

	// Same code, with the clamps in smoothstep and common subexpressions
	// optimized away.
    vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}


float noise(vec3 x) {
    const vec3 step = vec3(110, 241, 171);

    vec3 i = floor(x);
    vec3 f = fract(x);
 
    // For performance, compute the base input to a 1D hash from the integer part of the argument and the 
    // incremental change to the 1D based on the 3D -> 1D wrapping
    float n = dot(i, step);

    vec3 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(mix( hash(n + dot(step, vec3(0, 0, 0))), hash(n + dot(step, vec3(1, 0, 0))), u.x),
                   mix( hash(n + dot(step, vec3(0, 1, 0))), hash(n + dot(step, vec3(1, 1, 0))), u.x), u.y),
               mix(mix( hash(n + dot(step, vec3(0, 0, 1))), hash(n + dot(step, vec3(1, 0, 1))), u.x),
                   mix( hash(n + dot(step, vec3(0, 1, 1))), hash(n + dot(step, vec3(1, 1, 1))), u.x), u.y), u.z);
}
#endif

#line 32000

#if 1 // QUAD MESSAGE PASSING LIBRARY
// https://github.com/libretro/common-shaders/blob/master/include/quad-pixel-communication.h 
vec4 get_quad_vector_naive(vec4 output_pixel_num_wrt_uvxy)
	{
		//  Requires:   Two measures of the current fragment's output pixel number
		//              in the range ([0, IN.output_size.x), [0, IN.output_size.y)):
		//              1.) output_pixel_num_wrt_uvxy.xy increase with uv coords.
		//              2.) output_pixel_num_wrt_uvxy.zw increase with screen xy.
		//  Returns:    Two measures of the fragment's position in its 2x2 quad:
		//              1.) The .xy components are its 2x2 placement with respect to
		//                  uv direction (the origin (0, 0) is at the top-left):
		//                  top-left     = (-1.0, -1.0) top-right    = ( 1.0, -1.0)
		//                  bottom-left  = (-1.0,  1.0) bottom-right = ( 1.0,  1.0)
		//                  You need this to arrange/weight shared texture samples.
		//              2.) The .zw components are its 2x2 placement with respect to
		//                  screen xy direction (IN.position); the origin varies.
		//                  quad_gather needs this measure to work correctly.
		//              Note: quad_vector.zw = quad_vector.xy * float2(
		//                      ddx(output_pixel_num_wrt_uvxy.x),
		//                      ddy(output_pixel_num_wrt_uvxy.y));
		//  Caveats:    This function assumes the GPU driver always starts 2x2 pixel
		//              quads at even pixel numbers.  This assumption can be wrong
		//              for odd output resolutions (nondeterministically so).
		vec4 pixel_odd = fract(output_pixel_num_wrt_uvxy * 0.5) * 2.0;
		vec4 quad_vector = pixel_odd * 2.0 - vec4(1.0);
		return quad_vector;
	}
vec4 get_quad_vector(vec4 output_pixel_num_wrt_uvxy)
{
    //  Requires:   Same as get_quad_vector_naive() (see that first).
    //  Returns:    Same as get_quad_vector_naive() (see that first), but it's
    //              correct even if the 2x2 pixel quad starts at an odd pixel,
    //              which can occur at odd resolutions.
    vec4 quad_vector_guess =
        get_quad_vector_naive(output_pixel_num_wrt_uvxy);
    //  If quad_vector_guess.zw doesn't increase with screen xy, we know
    //  the 2x2 pixel quad starts at an odd pixel:
    vec2 odd_start_mirror = 0.5 * vec2(dFdx(quad_vector_guess.z),
                                                dFdy(quad_vector_guess.w));
    return quad_vector_guess * odd_start_mirror.xyxy;
}
/*

vec4 quad_gather(const vec4 quad_vector, const float curr)
{
    //  Float version:
    //  Returns:    return.x == current
    //              return.y == adjacent x
    //              return.z == adjacent y
    //              return.w == diagonal
    //vec4 all = vec4(curr);
    //all.y = all.x - dFdx(all.x) * quad_vector.z;
    //all.zw = all.xy - dFxy(all.xy) * quad_vector.w;
    //return all;
}

vec4 quad_gather_sum(const vec4 quad_vector, const vec4 curr)
{
    //  Requires:   Same as quad_gather()
    //  Returns:    Sum of an input vector (curr) at all fragments in a quad.
    //vec4 adjx, adjy, diag;
    //quad_gather(quad_vector, curr, adjx, adjy, diag);
    //return (curr + adjx + adjy + diag);
}
*/
#line 32100
// Most of what follows is the based on the paper
// Shader Amortization using Pixel Quad Message // Passing
// https://gitea.yiem.net/QianMo/Real-Time-Rendering-4th-Bibliography-Collection/raw/branch/main/Chapter%201-24/[1368]%20[GPU%20Pro2%202011]%20Shader%20Amortization%20Using%20Pixel%20Quad%20Message%20Passing.pdf

vec2 quadVector = vec2(0); // REQUIRED, contains the [-1,1] mappings
// one-hot encoding of thread ID
//vec4 threadMask = vec4(0); // contains the thread ID in one-hot

const vec4 selfWeights = vec4(WEIGHTFACTOR*WEIGHTFACTOR, WEIGHTFACTOR*(1.0-WEIGHTFACTOR), WEIGHTFACTOR*(1.0-WEIGHTFACTOR), (1.0-WEIGHTFACTOR)*(1.0-WEIGHTFACTOR)); // F*F, F*(1.0-F), F*(1.0-F), (1-F)*(1-F)
#define selfWeightFactor 0.07
//vec4 selfWeights = vec4(0.25) + vec4(selfWeightFactor, selfWeightFactor/ -3.0, selfWeightFactor/ -3.0, selfWeightFactor/-3.0);

vec4 quadGetThreadMask(vec2 qv){ 
	vec4 threadMask =  step(vec4(qv.xy,0,0),vec4( 0,0,qv.xy));
	return threadMask.xzxz * threadMask.yyww;
}

// [-1,1] quad vector as per get_quad_vector_naive
vec2 quadGetQuadVector(vec2 screenCoords){
	vec2 quadVector =  fract(floor(screenCoords) * 0.5) * 4.0 - 1.0;
	vec2 odd_start_mirror = 0.5 * vec2(dFdx(quadVector.x), dFdy(quadVector.y));
	quadVector = quadVector * odd_start_mirror;
	return sign(quadVector);
}

// Swizzle thread mask to be able to sort values from individual threads 
// Only needed if thread order matters, unlike with Sum
// NOTE THAT THIS ALLOWS FOR AMAZING FILTERING STEPS!
mat4 quadGetThreadMatrix(float smoothfactor){
	vec4 threadMask =  step(vec4(quadVector.xy,0,0),vec4( 0,0,quadVector.xy));
	return mat4(
		clamp(vec4(threadMask.xyzw),smoothfactor/3, 1.0-smoothfactor),
		clamp(vec4(threadMask.yxwz),smoothfactor/3, 1.0-smoothfactor),
		clamp(vec4(threadMask.zwxy),smoothfactor/3, 1.0-smoothfactor),
		clamp(vec4(threadMask.wzyx),smoothfactor/3, 1.0-smoothfactor) );
}


vec4 quadFBM(vec3 Pos, vec4 frequencies, vec2 screenUV, vec2 screenCoords){
	// identify each fragment
	vec4 quad_vector = get_quad_vector_naive(vec4(screenUV, floor(screenCoords))); // div screencoods by 2 wtf?
	// zw of this is [-1,1]
	//return vec4(0.0);
	
		//vec4 pixel_odd = fract(output_pixel_num_wrt_uvxy * 0.5) * 2.0;
		//vec4 quad_vector = pixel_odd * 2.0 - vec4(1.0);
	
	vec4 threadMask = vec4(0);
	//if ((quad_vector.z < -0.5 )&& (quad_vector.w < -0.5 )) threadMask.x = 1;
	//if ((quad_vector.z > 0.5 )&& (quad_vector.w < -0.5 )) threadMask.y = 1;
	//if ((quad_vector.z < -0.5 )&& (quad_vector.w > 0.5 )) threadMask.z = 1;
	//if ((quad_vector.z > 0.5 )&& (quad_vector.w > 0.5 )) threadMask.w = 1;
	threadMask = step(vec4(quad_vector.zw,0,0),vec4( 0,0,quad_vector.zw));
	threadMask = threadMask.spsp * threadMask.ttqq;
	
	// establish a common position as the average?
	//	Not always needed... and expensive too!
	#if 0
		vec3 adjx = Pos - dFdx(Pos) * quad_vector.z;
		vec3 adjy = Pos - dFdy(Pos) * quad_vector.w;
		vec3 diag = adjx - dFdy(adjx) * quad_vector.w;
		Pos = Pos + adjx + adjy + diag;
		Pos = Pos /4;
	#endif
	
	vec4 octaves = vec4(0);
	
	#if (0) // 2d nosie
	//everyone do the noise
		vec4 noise = FBMNoise3DDeriv(Pos * dot(threadMask, frequencies));
		
		//gather the noise like above
		vec4 nadjx = noise - dFdx(noise) * quad_vector.z;
		vec4 nadjy = noise - dFdy(noise) * quad_vector.w;
		vec4 ndiag = nadjx - dFdy(nadjy) * quad_vector.w;
		octaves.x = dot(vec4(noise.x, nadjx.x, nadjy.x, ndiag.x), 1.0/frequencies);
		octaves.y = dot(vec4(noise.y, nadjx.y, nadjy.y, ndiag.y), 1.0/frequencies);
	#else
		float noise = FBMNoise3D(Pos * dot(threadMask, frequencies)) * dot(threadMask, 1.0/frequencies);
		//gather the noise like above
		float nadjx = noise - dFdx(noise) * quad_vector.z;
		float nadjy = noise - dFdy(noise) * quad_vector.w;
		float ndiag = nadjx - dFdy(nadjx) * quad_vector.w;
		
		vec4 result = vec4(0.0);
		octaves = vec4(noise , nadjx, nadjy, ndiag);
		#if 0
			result.r = dot(octaves.xyzw,threadMask);
			result.g = dot(octaves.yxwz,threadMask);
			result.b = dot(octaves.zwxy,threadMask);
			result.a = dot(octaves.wzyx,threadMask);
			octaves = result;
		#else 
			octaves = vec4(dot(vec4(0.25), octaves));
		#endif
	#endif
	//return vec4(vec3(quad_vector.zwx), 1.0);
	return octaves;
}

#line 32300
// takes a float, and gathers it from the adjacent fragments
vec4 quadGather(float myvalue){
		float inputadjx = myvalue - dFdx(myvalue) * quadVector.x;
		float inputadjy = myvalue - dFdy(myvalue) * quadVector.y;
		float inputdiag = inputadjx - dFdy(inputadjx) * quadVector.y;
		return vec4(myvalue, inputadjx, inputadjy, inputdiag);
}

vec4 quadGather(float myvalue, vec2 qv){
		float inputadjx = myvalue - dFdx(myvalue) * quadVector.x;
		float inputadjy = myvalue - dFdy(myvalue) * quadVector.y;
		float inputdiag = inputadjx - dFdy(inputadjx) * quadVector.y;
		return vec4(myvalue, inputadjx, inputadjy, inputdiag);
}

float quadGatherWeighted(float myvalue){
		float inputadjx = myvalue - dFdx(myvalue) * quadVector.x;
		float inputadjy = myvalue - dFdy(myvalue) * quadVector.y;
		float inputdiag = inputadjx - dFdy(inputadjx) * quadVector.y;
		return dot( vec4(myvalue, inputadjx, inputadjy, inputdiag), selfWeights);
}

// takes a gentype, and gathers and sums it from adjacent fragments
float quadGatherSumFloat(float myvalue){
		float inputadjx = myvalue - dFdx(myvalue) * quadVector.x;
		float inputadjy = myvalue - dFdy(myvalue) * quadVector.y;
		float inputdiag = inputadjx - dFdy(inputadjx) * quadVector.y;
		return dot( vec4(myvalue, inputadjx, inputadjy, inputdiag), vec4(0.25));
}


vec2 quadGatherSum2D(vec2 myvalue){
		vec2 inputadjx = myvalue - dFdx(myvalue) * quadVector.x;
		vec2 inputadjy = myvalue - dFdy(myvalue) * quadVector.y;
		vec2 inputdiag = inputadjx - dFdy(inputadjx) * quadVector.y;
		return vec2(
			dot( vec4(myvalue.x, inputadjx.x, inputadjy.x, inputdiag.x), vec4(1.0)),
			dot( vec4(myvalue.y, inputadjx.y, inputadjy.y, inputdiag.y), vec4(1.0))
			);
}
vec3 quadGatherSum3D(vec3 myvalue){
		vec3 inputadjx = myvalue - dFdx(myvalue) * quadVector.x;
		vec3 inputadjy = myvalue - dFdy(myvalue) * quadVector.y;
		vec3 inputdiag = inputadjx - dFdy(inputadjx) * quadVector.y;
		return vec3(
			dot( vec4(myvalue.x, inputadjx.x, inputadjy.x, inputdiag.x), vec4(1.0)),
			dot( vec4(myvalue.y, inputadjx.y, inputadjy.y, inputdiag.y), vec4(1.0)),
			dot( vec4(myvalue.z, inputadjx.z, inputadjy.z, inputdiag.z), vec4(1.0))
			);
}
vec4 quadGatherSum4D(vec4 myvalue){
		vec4 inputadjx = myvalue - dFdx(myvalue) * quadVector.x;
		vec4 inputadjy = myvalue - dFdy(myvalue) * quadVector.y;
		vec4 inputdiag = inputadjx - dFdy(inputadjx) * quadVector.y;
		return vec4(
			dot( vec4(myvalue.x, inputadjx.x, inputadjy.x, inputdiag.x), vec4(1.0)),
			dot( vec4(myvalue.y, inputadjx.y, inputadjy.y, inputdiag.y), vec4(1.0)),
			dot( vec4(myvalue.z, inputadjx.z, inputadjy.z, inputdiag.z), vec4(1.0)),
			dot( vec4(myvalue.w, inputadjx.w, inputadjy.w, inputdiag.w), vec4(1.0))
			);
}

vec4 quadGatherWeighted4D(vec4 myvalue){
		vec4 inputadjx = myvalue - dFdx(myvalue) * quadVector.x;
		vec4 inputadjy = myvalue - dFdy(myvalue) * quadVector.y;
		vec4 inputdiag = inputadjx - dFdy(inputadjx) * quadVector.y;
		return vec4(
			dot( vec4(myvalue.x, inputadjx.x, inputadjy.x, inputdiag.x), selfWeights),
			dot( vec4(myvalue.y, inputadjx.y, inputadjy.y, inputdiag.y), selfWeights),
			dot( vec4(myvalue.z, inputadjx.z, inputadjy.z, inputdiag.z), selfWeights),
			dot( vec4(myvalue.w, inputadjx.w, inputadjy.w, inputdiag.w), selfWeights)
			);
}
vec2 quadGatherWeighted2D(vec2 myvalue){
		vec2 inputadjx = myvalue - dFdx(myvalue) * quadVector.x;
		vec2 inputadjy = myvalue - dFdy(myvalue) * quadVector.y;
		vec2 inputdiag = inputadjx - dFdy(inputadjx) * quadVector.y;
		return vec2(
			dot( vec4(myvalue.x, inputadjx.x, inputadjy.x, inputdiag.x), selfWeights),
			dot( vec4(myvalue.y, inputadjx.y, inputadjy.y, inputdiag.y), selfWeights)
			);
}

// Sorts an unsorted vec4 from the quad threads into a sorted vec4, 
vec4 quadGatherSortFloat(vec4 unsorted){ // this could really use modification into a threadmask matrix!
	vec4 threadMask =  step(vec4(quadVector.xy,0,0),vec4( 0,0,quadVector.xy));
	vec4 sorted = vec4(0.0);
	sorted.r = dot(unsorted.xyzw, threadMask);
	sorted.g = dot(unsorted.yxwz, threadMask);
	sorted.b = dot(unsorted.zwxy, threadMask);
	sorted.a = dot(unsorted.wzyx, threadMask);
	return sorted;
}

vec4 debugQuad(vec2 qv){
	// Returns a checkerboard pattern of quads. Yay?
	// B R
	// G Y
	vec2 sharedCoords = quadGatherSum2D(gl_FragCoord.xy);
	float quadAlpha = 0.0;
	if (fract((sharedCoords.x + sharedCoords.y) * 0.2) > 0.25) quadAlpha = 1.0;
	vec3 QVC = vec3(// [[BR],[GY]]
		step(0, qv.x), // red if x positive
		step(qv.y, 0), // Green if y negative
		step(qv.x, 0) * step(0, qv.y)    // blue if x negative and y positive
	);
	//if (step(0, qv.x) * step(qv.y, 0) > 0 ){
	//	
	//}
	return vec4(QVC,quadAlpha);
}



// UNUSED Use this to sample 4 octaves on any noise you want, and return the sum of its octaves
float fastQuadFBM3D(vec3 Pos, vec4 frequencies, vec4 weights, vec2 screenCoords){
	vec2 quad_vector = fract(floor(screenCoords) * 0.5) * 4.0 - 1.0;
	vec4 threadMask = quadGetThreadMask(quad_vector);
	
	float noise = FBMNoise3D(Pos * dot(threadMask, frequencies)) * dot(threadMask, weights);
	return dot(vec4(1.0),  quadGather(noise, quad_vector));
}

// UNUSED Fast single channel texture lookup
float fastQuadTexture3DLookupSum(sampler3D ttt, vec3 Pos, vec3 stepsize, vec4 weights, vec2 screenCoords){ 
	vec2 quad_vector = fract(floor(screenCoords) * 0.5) * 4.0 - 1.0;
	vec4 threadMask =  quadGetThreadMask(quad_vector);
	vec4 offsets = vec4(0,0.25,0.5, 0.75);
	
	float noise = texture(ttt, Pos + stepsize * dot(threadMask, offsets)).r * dot(threadMask, weights);
	return dot(vec4(1.0), quadGather(noise, quad_vector));
}

// UNUSED Fast single channel texture lookup
float fastQuadTexture2DLookupSum(sampler2D t, vec2 Pos, vec2 stepsize, vec4 weights, vec2 screenCoords){ 
	vec2 quad_vector = fract(floor(screenCoords) * 0.5) * 4.0 - 1.0;
	vec4 threadMask =  quadGetThreadMask(quad_vector);
	vec4 offsets = vec4(0,0.25,0.5, 0.75);
	
	float noise = texture(t,Pos + stepsize * dot(threadMask, offsets)).r * dot(threadMask, weights);
	return dot(quadGather(noise, quad_vector), vec4(1.0));
}

// UNUSED Fast single channel texture lookup
float fastQuadTexture2DLookupInd(sampler2D t, vec2 Pos, vec2 stepsize, vec4 weights, vec2 screenCoords){ 
	vec2 quad_vector = fract(floor(screenCoords) * 0.5) * 4.0 - 1.0;
	vec4 threadMask =  quadGetThreadMask(quad_vector);
	vec4 offsets = vec4(0,0.25,0.5, 0.75);
	
	float noise = texture(t,Pos + stepsize * dot(threadMask, offsets)).r * dot(threadMask, weights);
	return dot( quadGather(noise, quad_vector), vec4(1.0));
}
#endif



////-----------------------------STATIC DEFINES-----------------
// These defines were empirically determined to be the kind that its not worth touching

#define NOISESKEW vec3(0.21, 0.32, 0.26)
//#define NOISESKEW vec3(0.0, 0.1, 0.0)
#define NOISESCALE1024 NOISESCALE/1024.0

#define FASTSMOOTHSTEP(A) (A * A * (3.0 - 2.0 * A))
// HIGHFREQUENCY UNIFORM NOISE PARAMS
// noiseHFParams perturbation stuff
// this is uniform 16x16x16 noise, pretty fast
// x - relative scale (FROM NOISE)
// y - perturb strength
// z - offset speedx, as a fraction of base speed
// w - offset speedy, as a fraction of base speed

// LOWFREQUENCY WORLEY NOISE PARAMS
// x - scale
// y - threshold


// sample: (sample an exact deflection cosine)
//   xi = a uniform random real in [0,1]
float sampleDraineCos(in float xi, in float g, in float a)
{
    const float g2 = g * g;
	const float g3 = g * g2;
	const float g4 = g2 * g2;
	const float g6 = g2 * g4;
	const float pgp1_2 = (1 + g2) * (1 + g2);
	const float T1 = (-1 + g2) * (4 * g2 + a * pgp1_2);
	const float T1a = -a + a * g4;
	const float T1a3 = T1a * T1a * T1a;
	const float T2 = -1296 * (-1 + g2) * (a - a * g2) * (T1a) * (4 * g2 + a * pgp1_2);
	const float T3 = 3 * g2 * (1 + g * (-1 + 2 * xi)) + a * (2 + g2 + g3 * (1 + 2 * g2) * (-1 + 2 * xi));
	const float T4a = 432 * T1a3 + T2 + 432 * (a - a * g2) * T3 * T3;
	const float T4b = -144 * a * g2 + 288 * a * g4 - 144 * a * g6;
	const float T4b3 = T4b * T4b * T4b;
	const float T4 = T4a + sqrt(-4 * T4b3 + T4a * T4a);
	const float T4p3 = pow(T4, 1.0 / 3.0);
	const float T6 = (2 * T1a + (48 * pow(2, 1.0 / 3.0) *
		(-(a * g2) + 2 * a * g4 - a * g6)) / T4p3 + T4p3 / (3. * pow(2, 1.0 / 3.0))) / (a - a * g2);
	const float T5 = 6 * (1 + g2) + T6;
	return (1 + g2 - pow(-0.5 * sqrt(T5) + sqrt(6 * (1 + g2) - (8 * T3) / (a * (-1 + g2) * sqrt(T5)) - T6) / 2., 2)) / (2. * g);
}
// bitsquid.blogspot.com/2016/07/volumetric-clouds.html
// https://advances.realtimerendering.com/s2015/The%20Real-time%20Volumetric%20Cloudscapes%20of%20Horizon%20-%20Zero%20Dawn%20-%20ARTR.pdf
// https://www.scratchapixel.com/lessons/3d-basic-rendering/volume-rendering-for-developers/intro-volume-rendering.html
//https://www.scratchapixel.com/lessons/3d-basic-rendering/volume-rendering-for-developers/ray-marching-algorithm.html
//https://pbr-book.org/3ed-2018/contents


////------------------------------GLOBAL NOISE SAMPLING FUNCTIONS ---------------------------------

// static vars:
vec3 noiseOffset;
// everything that has to do with initializing the actual noise stuff 

void WorldToNoiseSpace(in vec3 wp, out vec3 lf, out vec3 hf){
	lf = wp * NOISESCALE1024 * noiseLFParams.x;
	hf = lf * noiseHFParams.x * 10;
	hf -= hf.zxx * NOISESKEW;
	hf.xz += noiseOffset.xz * noiseHFParams.zw * 1;
	hf -= noiseOffset.xyz;

	lf += lf.zxx * NOISESKEW * 1.0;
	lf -= noiseOffset.xyz;
}

vec4 SampleNoiseSpace(in vec3 noiseLFSpacePos, in vec3 noiseHFSpacePos, in float perturbfactor){

	vec4 highFreqNoise = textureLod(uniformNoiseTex, noiseHFSpacePos,0);
	//vec4 highFreqNoise =  texture(uniformNoiseTex, noiseHFSpacePos);
	
	highFreqNoise.rgb = highFreqNoise.rgb * 0.5 - 0.25; // scale down to [-0.25, 0.25]
	highFreqNoise *= (highFreqNoise.a) * perturbfactor; // Further modulate with own alpha channel
	
	noiseLFSpacePos += highFreqNoise.rgb * noiseHFParams.y;
	
	vec4 textureNoise = vec4(0.0);

	#if (TEXTURESAMPLER == 1)
		textureNoise = getPackedNoise(noiseLFSpacePos); 
	#endif
	#if (TEXTURESAMPLER == 2)
		textureNoise = texture(noise64cube, noiseLFSpacePos.xzy).argb; // almost universally the best :'( 
	#endif
	#if (TEXTURESAMPLER == 3)
		textureNoise = 1.0 - Cellular3D_Deriv(noiseLFSpacePos.xzy).rgba; // almost universally the best :'( 
	#endif
	#if (TEXTURESAMPLER == 4)
		//textureNoise = 1.0 - noiseLFSpacePos.xzy;
		vec3 centers = fract(noiseLFSpacePos.xyz) - 0.5;
		float disttocenter = max(0.0, 1.0 - sqrt(dot(centers, centers)));
		textureNoise = vec4(step(0.6,disttocenter),disttocenter,disttocenter,disttocenter);
	#endif
	
	#if (QUADNOISEFETCHING == 1) // this sure as FUCK does not need to be done here!
		//textureNoise.r = quadGatherWeighted(textureNoise.r);
		//textureNoise.g = quadGatherWeighted(textureNoise.g);
	#endif

	return textureNoise.xyzw;
}
vec4 SampleNoiseSpaceFast(in vec3 noiseLFSpacePos){
	vec4 textureNoise = vec4(0.0);

	#if (TEXTURESAMPLER == 1)
		textureNoise = getPackedNoise(noiseLFSpacePos); 
	#endif
	#if (TEXTURESAMPLER == 2)
		textureNoise = texture(noise64cube, noiseLFSpacePos.xzy).argb;
	#endif
	#if (TEXTURESAMPLER == 3)
		textureNoise = 1.0 - Cellular3D_Deriv(noiseLFSpacePos.xzy).rgba;
	#endif
	#if (TEXTURESAMPLER == 4)
		vec3 centers = fract(noiseLFSpacePos.xyz) - 0.5;
		float disttocenter = max(0.0, 1.0 - sqrt(dot(centers, centers)));
		textureNoise = vec4(step(0.6, disttocenter), disttocenter, disttocenter, disttocenter);
	#endif

	return textureNoise;
}


float expImpulse( float x, float k )
{
    float h = k*x;
    return h*exp(1.0-h);
}


float expSustainedImpulse( float x, float f, float k )
{
    float s = max(x-f,0.0);
    return min( x*x/(f*f), 1.0+(2.0/f)*s*exp(-k*s));
}

float BeersLaw(float d,float k){
	return exp(-1*k*d);
}

float PowderLaw(float d, float k){
	return 1.0 - exp(-2*k*d);
}

float BeersPowder(float d, float k){
	return BeersLaw(d,k) * PowderLaw(d,k);
}

// UNUSED https://github.com/erickTornero/realtime-volumetric-cloudscapes/blob/master/shaders/RayMarching2.glsl
float HenyeyGreenstein(in vec3 inLightVector, in vec3 inViewVector, in float g){
    // Cos of angle
    float cos_angle = dot(normalize(inLightVector), normalize(inViewVector));

    // Define the HenyeyGreenstein function
    return (1.0 - g * g)/(pow(1.0 + g * g - 2.0 * g * cos_angle, 1.50) * 4 * 3.14159265);
}

// UNUSED, Define the total energy 
float GetLightEnergy(float density, float probRain, float henyeyGreensteinFactor){
    float beer_laws = exp( -density * probRain);
    float powdered_sugar = 1.0 - exp( -2.0 * density);

    //float henyeyGreensteinFactor = HenyeyGreenstein(lightVector, rayDirection, g);
    float totalEnergy = 2.0 * beer_laws * powdered_sugar * henyeyGreensteinFactor;

    return totalEnergy;
}

//https://encreative.blogspot.com/2019/05/forward-and-backward-alpha-blending-for.html 

// remember that accumulatedColor.a is (1.0 - alpha)
void BackwardBlend(inout vec4 accumulatedColor, in vec4 currentColor){
	accumulatedColor.rgb += accumulatedColor.rgb * (accumulatedColor.a * currentColor.a);
	accumulatedColor.a *= (1.0 - currentColor.a);
}
//------------------------------------

vec4 WorldToShadowSpace(vec3 worldPos){
		vec4 shadowVertexPos = shadowView * vec4(worldPos,1.0);
		shadowVertexPos.xy += vec2(0.5);
		return shadowVertexPos;
		//return clamp(textureProj(shadowTex, shadowVertexPos), 0.0, 1.0);
}

////0000000000000000000000000000000000000000000000000000000000000000
////------------------------------MAIN------------------------------
////0000000000000000000000000000000000000000000000000000000000000000


#line 33000
void main(void)
{

	float time = timeInfo.x + timeInfo.w;
	vec3 camPos = cameraViewInv[3].xyz ;
	
	// ----------------- BEGIN UNIVERSAL PART ------------------------------ 
	#if 1 
		#line 33200
		quadVector = quadGetQuadVector(gl_FragCoord.xy);

		//fragColor.rgba = debugQuad(quadVector);return;
		// Note that the offsets are not in ascending order. This has the fun side effect of being bluer in noise
		float thisQuadOffset = dot (quadGetThreadMask(quadVector), vec4(0.5, 0.25, 0.0, 0.75));  // = vec4(0.5, 0.25, 0.0, 0.75)

		// ---------- Calculate the UV coordinates of the depth textures ---------
	
		#if (RESOLUTION == 2)
			// Exploit hardware linear sampling in best case
			vec2 screenUV = sampleUVs.zw;
			// The following clamp is needed cause the UV's of gbuffers arent clamped for some reason
			screenUV = clamp(
			screenUV,
			vec2(0.5/VSX, 0.5/VSY),
			vec2(1.0 - 0.5/VSX, 1.0 - 0.5/VSY)
);
		#else
			vec2 screenUV = gl_FragCoord.xy * RESOLUTION / viewGeometry.xy;
		#endif

		float mapdepthRaw;
		float modeldepthRaw;
		vec3 trueMapWorldPos;
		vec3 mapWorldPos;
		vec3 mapFromCam;
		float lengthMapFromCam;
		vec3 camToMapNorm;
		SampleSceneAtUV(screenUV, camPos, mapdepthRaw, modeldepthRaw, trueMapWorldPos, mapWorldPos, mapFromCam, lengthMapFromCam, camToMapNorm);

		float mapdepth = mapdepthRaw;
		float modeldepth = modeldepthRaw;

		#if 0
			// This is the debugging yellow row that should be present in bottom left
			if (any(lessThan(abs(gl_FragCoord.xy - 2.5) ,vec2( 0.5)))) {
				fragColor.rgba = vec4(1,1,0,1); return;
			}
			// This is the debug grid
			if (any(lessThan(fract(gl_FragCoord.xy / 64.0) ,vec2( 1.0/64.0)))) {
				fragColor.rgba = vec4(0,step( modeldepth, 0.9999),0,1); return;
			}
		#endif

		vec2 heightFogScreenUV = ReconstructUpscaledUV(screenUV, heightFogResolutionScale, HEIGHTFOG_UPSCALE_SOFTNESS);
		vec2 cloudScreenUV = ReconstructUpscaledUV(screenUV, cloudResolutionScale, CLOUD_UPSCALE_SOFTNESS);
		vec2 shadowScreenUV = ReconstructUpscaledUV(screenUV, shadowResolutionScale, SHADOW_UPSCALE_SOFTNESS);
		vec2 distanceScreenUV = ReconstructUpscaledUV(screenUV, distanceFogResolutionScale, DISTANCEFOG_UPSCALE_SOFTNESS);

		float heightMapdepthRaw = mapdepthRaw;
		float heightModeldepthRaw = modeldepthRaw;
		vec3 heightTrueMapWorldPos = trueMapWorldPos;
		vec3 heightMapWorldPos = mapWorldPos;
		vec3 heightMapFromCam = mapFromCam;
		float heightLengthMapFromCam = lengthMapFromCam;
		vec3 heightCamToMapNorm = camToMapNorm;
		if (heightFogResolutionScale < 0.999) {
			SampleSceneAtUV(heightFogScreenUV, camPos, heightMapdepthRaw, heightModeldepthRaw, heightTrueMapWorldPos, heightMapWorldPos, heightMapFromCam, heightLengthMapFromCam, heightCamToMapNorm);
		}

		float cloudMapdepthRaw = mapdepthRaw;
		float cloudModeldepthRaw = modeldepthRaw;
		vec3 cloudTrueMapWorldPos = trueMapWorldPos;
		vec3 cloudMapWorldPos = mapWorldPos;
		vec3 cloudMapFromCam = mapFromCam;
		float cloudLengthMapFromCam = lengthMapFromCam;
		vec3 cloudCamToMapNorm = camToMapNorm;
		if (cloudResolutionScale < 0.999) {
			SampleSceneAtUV(cloudScreenUV, camPos, cloudMapdepthRaw, cloudModeldepthRaw, cloudTrueMapWorldPos, cloudMapWorldPos, cloudMapFromCam, cloudLengthMapFromCam, cloudCamToMapNorm);
		}

		float shadowMapdepthRaw = mapdepthRaw;
		float shadowModeldepthRaw = modeldepthRaw;
		vec3 shadowTrueMapWorldPos = trueMapWorldPos;
		vec3 shadowMapWorldPos = mapWorldPos;
		vec3 shadowMapFromCam = mapFromCam;
		float shadowLengthMapFromCam = lengthMapFromCam;
		vec3 shadowCamToMapNorm = camToMapNorm;
		if (shadowResolutionScale < 0.999) {
			SampleSceneAtUV(shadowScreenUV, camPos, shadowMapdepthRaw, shadowModeldepthRaw, shadowTrueMapWorldPos, shadowMapWorldPos, shadowMapFromCam, shadowLengthMapFromCam, shadowCamToMapNorm);
		}

		float distanceMapdepthRaw = mapdepthRaw;
		float distanceModeldepthRaw = modeldepthRaw;
		vec3 distanceTrueMapWorldPos = trueMapWorldPos;
		vec3 distanceMapWorldPos = mapWorldPos;
		vec3 distanceMapFromCam = mapFromCam;
		float distanceLengthMapFromCam = lengthMapFromCam;
		vec3 distanceCamToMapNorm = camToMapNorm;
		if (distanceFogResolutionScale < 0.999) {
			SampleSceneAtUV(distanceScreenUV, camPos, distanceMapdepthRaw, distanceModeldepthRaw, distanceTrueMapWorldPos, distanceMapWorldPos, distanceMapFromCam, distanceLengthMapFromCam, distanceCamToMapNorm);
		}
	#endif 
	
	// rayStart is the distant point through fog 
	vec3 rayStart = heightMapWorldPos; 
	// rayEnd is the close point through fog
	vec3 rayEnd = camPos; 
	vec3 heightMapFromCamLocal = heightMapFromCam;
	
	float heightLengthMapFromCamLocal = heightLengthMapFromCam;
	
	// ----------------- NOISE UNIVERSAL PART ------------------------------
	vec2 baseBlueNoiseSample = textureLod(blueNoise64, gl_FragCoord.xy / 64.0, 0).xy * BLUENOISESTRENGTH;
	vec2 heightBlueNoiseSample = SampleLayerBlueNoise(heightFogScreenUV, heightFogResolutionScale, 0.38, vec2(0.11, 0.37));
	vec2 shadowBlueNoiseSample = SampleLayerBlueNoise(shadowScreenUV, shadowResolutionScale, 0.45, vec2(0.29, 0.17));
	vec2 cloudBlueNoiseSample  = SampleLayerBlueNoise(cloudScreenUV, cloudResolutionScale, 0.52, vec2(0.43, 0.59));
	vec2 distanceBlueNoiseSample = SampleLayerBlueNoise(distanceScreenUV, distanceFogResolutionScale, 0.60, vec2(0.67, 0.23));
	
	float noiseScale = NOISESCALE;
	// we must ensure that this is rolled over, especially the time part at units of 1
	noiseOffset = vec3(windFractFull.x,  time * RISERATE, windFractFull.y ) * NOISESCALE1024;
	noiseOffset.y = fract(noiseOffset.y); // time can only be rolled over here

	// ----------------- END UNIVERSAL PART -------------------------------
	
// ----------------- BEGIN DISTANCE-BASED FOG ------------------------------
	#line 33400
	// Modulate distance fog density with angle of ray compared to sky?
	vec3 distanceCamToMap = distanceMapFromCam;
	vec3 distanceCamToMapNormLocal = distanceCamToMapNorm;
	float rayUpness = 1.0;
	if (distanceCamToMapNormLocal.y > 0) {
		rayUpness = pow(1.0 - distanceCamToMapNormLocal.y, 8.0);
	}
	float distanceFogAmountAlpha = exp(-1 * 0.0005 * distanceLengthMapFromCam * rayUpness * distanceFogColor.a);
	// Use a large power here to ease the transition for almost no fog close up. Looks way better in general
	distanceFogAmountAlpha =  pow(1.0 - distanceFogAmountAlpha, DISTANCEFOGPOWER);
	float distanceFogLodImportance = ComputeDistanceFogLodImportance(distanceLengthMapFromCam, rayUpness, distanceFogAmountAlpha);
#if (STEPLOD > 0)
	if (distanceFogLodImportance < STEPLOD_DISTANCE_EARLYOUT && distanceFogAmountAlpha < STEPLOD_DISTANCE_ALPHA_MIN) {
		distanceFogAmountAlpha = 0.0;
	}
#endif
	distanceFogAmountAlpha = mix(
		distanceFogAmountAlpha,
		smoothstep(0.0, 1.0, distanceFogAmountAlpha),
		UpscaleSoftening(distanceFogResolutionScale, 0.12)
	);
	//Uncomment to test output distance fog:
	//fragColor.rgba = vec4(distanceFogColor.rgb * distanceFogAmountAlpha, distanceFogAmountAlpha);	return; 
// ----------------- END DISTANCE-BASED FOG ------------------------------
	
	
// ----------------- BEGIN HEIGHT-BASED FOG -------------------------------
#line 33600
vec4 heightBasedFogColor = vec4(0.0);

// If raystart is above the fog plane height
if (heightMapWorldPos.y > heightFogTop) {
	if (camPos.y < heightFogTop) { // But cam is below fog (C)
		float rayFractionInFog = clamp((heightFogTop - camPos.y) / (heightMapWorldPos.y - camPos.y), 0.0, 1.0);
		rayStart = rayEnd * (1.0 - rayFractionInFog) + rayStart * rayFractionInFog;
	} else { // Cam and Ray both above fog
		rayStart = rayEnd;
	}
} else { // Ray starts below fog plane
	if (camPos.y > heightFogTop) { // Camera is Above fog (A)
		float rayFractionInFog = clamp((heightFogTop - heightMapWorldPos.y) / (camPos.y - heightMapWorldPos.y), 0.0, 1.0);
		rayEnd = rayStart + (rayEnd - rayStart) * rayFractionInFog;
	}
}

float rayLength = length(rayEnd - rayStart);

vec2 rayMid = clamp((rayEnd.xz + rayStart.xz) * 0.5, vec2(0.0), mapSize.xy);
float edgeDistanceWeight = linearDistanceMapXZThreshold(rayMid, max(MAPSIZEX, MAPSIZEZ) * 0.25);
edgeDistanceWeight = clamp(edgeDistanceWeight, 0.0, 1.0);

float fogPlaneSizeInv = 1.0 / (heightFogTop - heightFogBottom);
float startDensity = clamp((heightFogTop - rayStart.y) * fogPlaneSizeInv, 0.0, 1.0);
float endDensity   = clamp((heightFogTop - rayEnd.y)   * fogPlaneSizeInv, 0.0, 1.0);
float heightFogDensityHint = clamp((startDensity + endDensity) * 0.5, 0.0, 1.0);
float heightLodImportance = ComputeStepLodImportance(
	rayLength,
	HorizonViewFactor(heightCamToMapNorm),
	heightFogDensityHint,
	edgeDistanceWeight
);
heightLodImportance *= mix(0.82, 1.0, smoothstep(0.0, 1.0, heightFogColor.a));
heightLodImportance = clamp(heightLodImportance, 0.22, 1.0);

float heightBasedFog = 0.0;
float heightShadow = 1.0;
float densityModulation = 1.0;

// ----------------- BEGIN HEIGHT-BASED FOG AND SHADOWING -------------------------------
#line 33700
#if (HEIGHTSHADOWSTEPS > 0) || (HEIGHTNOISESTEPS > 0)
		if (rayLength <= 0.01) {////cheap eject
		heightBasedFog = 0.0;
		heightShadow = 1.0;
		densityModulation = 1.0;
	} else {

		#if (HEIGHTSHADOWSTEPS > 0)
			uint heightShadowSteps = uint(EffectiveSampleCount(float(HEIGHTSHADOWSTEPS), shadowResolutionScale, heightLodImportance, STEPLOD_HEIGHTSHADOW_MIN));
			vec4 heightShadowStartPos = WorldToShadowSpace(rayStart);
			vec4 heightShadowEndStep  = WorldToShadowSpace(rayEnd);
			heightShadowEndStep = (heightShadowEndStep - heightShadowStartPos) / float(heightShadowSteps);
			heightShadowStartPos += heightShadowEndStep * (thisQuadOffset + shadowBlueNoiseSample.x * 0.18);

			heightShadow = 0.0;
			for (uint i = 0; i < HEIGHTSHADOWSTEPS; i++) {
				if (i >= heightShadowSteps) break;
				heightShadow += textureProj(shadowTex, heightShadowStartPos, -2).r;
				heightShadowStartPos += heightShadowEndStep;
			}
			heightShadow = quadGatherWeighted(heightShadow);
			heightShadow /= float(heightShadowSteps);
		#endif

		#if HEIGHTNOISESTEPS > 0
			uint heightNoiseSteps = uint(EffectiveSampleCount(float(HEIGHTNOISESTEPS), heightFogResolutionScale, heightLodImportance, STEPLOD_HEIGHTNOISE_MIN));
			vec3 noiseOffset2 = vec3(windFractFull.z, time * RISERATE, windFractFull.w) * 5.0;

			vec3 heightFogRayStep = (rayEnd - rayStart) / float(heightNoiseSteps);
			vec3 heightFogRayStart = (quadGatherSum3D(rayStart) * 0.33) +
				(thisQuadOffset + heightBlueNoiseSample.x * (float(heightNoiseSteps) / 96.0)) * heightFogRayStep;

			float myfreq = (thisQuadOffset + 0.1);
			densityModulation = 0.0;

			for (uint i = 0; i < HEIGHTNOISESTEPS; i++) {
				if (i >= heightNoiseSteps) break;
				vec3 lfnoisepos = (heightFogRayStart * 0.1 - noiseOffset2.xyz * 0.01) * NOISESCALE;
				float cloudy = Value3D(lfnoisepos.xyz * vec3(1.0) * myfreq) / myfreq;
				densityModulation += cloudy;
				heightFogRayStart += heightFogRayStep;
			}

			densityModulation = quadGatherSumFloat(densityModulation);
			densityModulation = densityModulation / float(heightNoiseSteps);
		#endif
	}
#endif

heightBasedFog = (startDensity + endDensity) * 2.0 * rayLength;
heightBasedFog *= densityModulation;
heightBasedFog = cloudDensity * heightBasedFog *
	smoothstep(0.0, 2000.0 * EASEHEIGHT, length(rayStart - camPos));

float heightBasedFogExp = 1.0 - exp(-heightBasedFog * heightFogColor.a * 0.1);

// visual fusion with cloud base
float fogBridge = FogCloudBridgeFactor(0.5 * (rayStart.y + rayEnd.y));
heightBasedFogExp *= mix(1.0, 1.12, fogBridge * 0.35);

// color
heightBasedFogColor.rgb = mix(shadowedColor.rgb, heightFogColor.rgb, heightShadow);
heightBasedFogColor.rgb = ApplySunTint(heightBasedFogColor.rgb, heightCamToMapNorm, 0.22);

// horizon enrichment
float horizonFog = HorizonViewFactor(heightCamToMapNorm);
heightBasedFogColor.rgb = mix(
	heightBasedFogColor.rgb,
	distanceFogColor.rgb * 1.04,
	horizonFog * 0.10
);

heightBasedFogColor.a = heightBasedFogExp;
heightBasedFogColor.a = mix(
	heightBasedFogColor.a,
	smoothstep(0.0, 1.0, heightBasedFogColor.a),
	UpscaleSoftening(heightFogResolutionScale, 0.08)
);
heightBasedFogColor.a *= edgeDistanceWeight;
	// ----------------- END HEIGHT-BASED FOG AND SHADOWING -------------------------------





// ----------------- END HEIGHT-BASED FOG -------------------------------
	
	// ----------------- BEGIN UNDERWATER SHADOW RAYS -------------------------------
	#line 33800

	float uwShadowAlpha = 0.0;
	#if UWSHADOWSTEPS > 0
		if (shadowTrueMapWorldPos.y < 0) {
			float uwShadowTransparency = 0.0;
			// Draw these back to front
			// Each shadow sample costs on average, 0.5 FPS at 1080p and half resolution
			// Indeed, stepping in shadow space is much faster, and possible due to the linear transformation of it. 
			// Now to also handle clipping within shadow space as not to get out of hand!
			// NEEDS SHADOWSAMPLER == 1 

			// Attempt to emulate some caustics offset: 
			uint uwShadowSteps = uint(ScaledSampleCount(float(UWSHADOWSTEPS), shadowResolutionScale));
			vec3 causticsOffset = Value3D_Deriv(vec3(gl_FragCoord.x,  1, gl_FragCoord.y) * 0.1 + noiseOffset + time * 0.1).rgb; // 0-1
			causticsOffset = causticsOffset * UWCAUSTICS / RESOLUTION; // -10 to +10

			vec4 shadStart = WorldToShadowSpace(shadowTrueMapWorldPos + causticsOffset); 
			vec4 shadEnd   = WorldToShadowSpace(shadowMapWorldPos.xyz);
			vec4 shadStep  = (shadEnd - shadStart) / float(uwShadowSteps); // points toward camera

			shadStart += (thisQuadOffset + shadowBlueNoiseSample.x * 0.18) * shadStep;
			
			//fragColor.rgba = vec4(vec3(causticsOffset),1.0); return;
			for (uint i = 0; i < UWSHADOWSTEPS ; i++){
				if (i >= uwShadowSteps) break;
				uwShadowTransparency += textureProj(shadowTex, shadStart, -2).r; // 1 for lit, 0 
				shadStart += shadStep;
			}
			// This was Floris's idea, to add a bit of additional surface shadow
			float lastunderwatershadow = quadGatherWeighted(textureProj(shadowTex, shadEnd, -2).r);
			// Special sauce PQM
			uwShadowTransparency = quadGatherWeighted(uwShadowTransparency);
			// Discount by # rays
			uwShadowTransparency /= float(uwShadowSteps);
			// half it a little bit:
			uwShadowAlpha = (1.0 - uwShadowTransparency) ;
			// This was Floris's idea, to add a bit of additional surface shadow
			uwShadowAlpha += 0.3 * (1.0 - lastunderwatershadow);
			// modulate density up to shallowdepth:
			uwShadowAlpha *= smoothstep(0, 20, -1 * shadowTrueMapWorldPos.y);
			uwShadowAlpha = clamp(uwShadowAlpha, 0, 1) * shadowedColor.a;
		}
		// Debug underwater shadow rays:
		//fragColor.rgba = vec4(vec3(shadowedColor.rgb),uwShadowAlpha * 2); return;	
	#endif
	// ----------------- END UNDERWATER SHADOW RAYS -------------------------------

	
	// ----------------- BEGIN CLOUD LAYER -------------------------------
	// ----------------- BEGIN CLOUD LAYER -------------------------------
#line 34000

vec4 cloudBlendRGBT = vec4(0.0);

#if (CLOUDSTEPS > 0)
if (cloudDensity > 0.001 && cloudGlobalColor.a > 0.001) {

	vec3 cloudRayDir = cloudCamToMapNorm;
	vec3 dir = cloudCamToMapNorm;
	vec3 cloudRayDirInv = 1.0 / max(abs(dir), vec3(1e-4)) * sign(dir);

	vec3 cloudBoxSize   = (cloudVolumeMax.xyz - cloudVolumeMin.xyz) * 0.5 + vec3(cloudVolumeMax.w, 0.0, cloudVolumeMax.w);
	vec3 cloudBoxCenter = (cloudVolumeMax.xyz + cloudVolumeMin.xyz) * 0.5;
	vec3 rayOriginInbox = camPos - cloudBoxCenter;

	vec3 rayNormal = cloudRayDirInv * rayOriginInbox;
	vec3 k = abs(cloudRayDirInv) * cloudBoxSize;
	vec3 t1 = -rayNormal - k;
	vec3 t2 = -rayNormal + k;

	float nearDist = max(max(t1.x, t1.y), t1.z);
	float farDist  = min(min(t2.x, t2.y), t2.z);

	vec3 cloudRayEnd   = camPos + nearDist * cloudRayDir;
	vec3 cloudRayStart = camPos + farDist  * cloudRayDir;

	if (farDist > cloudLengthMapFromCam)  cloudRayStart = cloudMapWorldPos.xyz;
	if (nearDist < 0.0)                   cloudRayEnd   = camPos;
	if (nearDist > cloudLengthMapFromCam) cloudRayEnd   = cloudMapWorldPos.xyz;

	if (step(nearDist, farDist) * step(0.0, farDist) < 0.5)
		cloudRayStart = cloudRayEnd;

	float cloudEdgeDistanceWeight = CloudVolumeWeight((cloudRayStart.xz + cloudRayEnd.xz) * 0.5);
	float cloudRayLength = length(cloudRayStart - cloudRayEnd);

	if (cloudEdgeDistanceWeight > 0.0 && cloudRayLength > 0.01) {
		float cloudLodImportance = ComputeStepLodImportance(
			cloudRayLength,
			HorizonViewFactor(cloudCamToMapNorm),
			clamp(cloudDensity, 0.0, 1.0),
			cloudEdgeDistanceWeight
		);
		cloudLodImportance *= mix(0.70, 1.0, GetCameraFade(cloudCamToMapNorm));
		cloudLodImportance = clamp(cloudLodImportance, 0.24, 1.0);
		uint cloudSteps = uint(EffectiveSampleCount(float(CLOUDSTEPS), cloudResolutionScale, cloudLodImportance, STEPLOD_CLOUD_MIN));
		vec3 cloudRayStep = (cloudRayEnd - cloudRayStart) / float(cloudSteps);
		float stepLength = cloudRayLength / float(cloudSteps);

		vec3 quadStep = cloudRayStep * (thisQuadOffset + (float(cloudSteps) / 128.0) * cloudBlueNoiseSample.y);

		float fogHeightInv = 1.0 / (cloudVolumeMax.y - cloudVolumeMin.y);
		float heightFractionStartPos = clamp((cloudRayStart.y - cloudVolumeMin.y) * fogHeightInv, 0.0, 1.0);
		float heightFractionEndStep  = clamp((cloudRayEnd.y   - cloudVolumeMin.y) * fogHeightInv, 0.0, 1.0);
		heightFractionEndStep = (heightFractionEndStep - heightFractionStartPos) / float(cloudSteps);

		#if (QUADNOISEFETCHING == 1)
			cloudRayStart += quadStep;
			cloudRayEnd   += quadStep;
		#else
			cloudRayStart += cloudRayStep * cloudBlueNoiseSample.y;
			cloudRayEnd   += cloudRayStep * cloudBlueNoiseSample.y;
		#endif

		vec3 noiseLFStart;
		vec3 noiseLFEndStep;
		vec3 noiseHFStart;
		vec3 noiseHFEndStep;

		WorldToNoiseSpace(cloudRayStart, noiseLFStart, noiseHFStart);
		WorldToNoiseSpace(cloudRayEnd,   noiseLFEndStep, noiseHFEndStep);

		noiseLFEndStep = (noiseLFEndStep - noiseLFStart) / float(cloudSteps);
		noiseHFEndStep = (noiseHFEndStep - noiseHFStart) / float(cloudSteps);

		float prevdensity = 0.0;
		cloudBlendRGBT.rgb = cloudGlobalColor.rgb;

		bool useHFNoise = (abs(noiseHFParams.y) > 0.0001);

		for (uint ns = 0; ns < CLOUDSTEPS; ns++) {
			if (ns >= cloudSteps) break;
			if (cloudBlendRGBT.w > 4.0) break;

			heightFractionStartPos += heightFractionEndStep;

			vec4 textureNoise;
			if (useHFNoise) {
				textureNoise = SampleNoiseSpace(noiseLFStart, noiseHFStart, 1.0);
				noiseHFStart += noiseHFEndStep;
			} else {
				textureNoise = SampleNoiseSpaceFast(noiseLFStart);
			}
			noiseLFStart += noiseLFEndStep;

			float verticalProfile = CloudVerticalProfile(heightFractionStartPos);
			float baseBridge = clamp(heightFractionStartPos * 3.57142857, 0.0, 1.0);

			float clampedNoise = max(
				0.0,
				(textureNoise.r - noiseLFParams.y) *
				cloudDensity *
				verticalProfile *
				mix(0.85, 1.0, baseBridge) *
				stepLength
			);

			cloudBlendRGBT.w += clampedNoise;

			float currdens = clampedNoise / max(stepLength, 0.0001);
			float gradient_density = currdens - prevdensity;
			prevdensity = currdens;

			gradient_density *= 10.0;
			gradient_density -= gradient_density * step(0.0, gradient_density) * 10.5;
			cloudBlendRGBT.rgb = mix(cloudBlendRGBT.rgb, vec3(0.0), gradient_density * 0.05);
		}

				cloudBlendRGBT.a = quadGatherWeighted(1.0 - exp(-cloudBlendRGBT.w)) * cloudGlobalColor.a;
		cloudBlendRGBT.a = mix(
			cloudBlendRGBT.a,
			smoothstep(0.0, 1.0, cloudBlendRGBT.a),
			UpscaleSoftening(cloudResolutionScale, 0.10)
		);
		cloudBlendRGBT.a *= cloudEdgeDistanceWeight;

		float cameraFade = GetCameraFade(cloudCamToMapNorm);
		cloudBlendRGBT.rgb *= cameraFade;
		cloudBlendRGBT.a   *= cameraFade;

		float horizonCloud = HorizonViewFactor(cloudCamToMapNorm);
		float sunScatter   = SunForwardScatter(cloudCamToMapNorm);
		float silverLining = pow(sunScatter, 1.6);

		// --- New phase-based cloud lighting ---
		float cloudPhase = evalCloudPhase(cloudCamToMapNorm);

		// Raw phase values are small; scale into a useful artistic range
		float phaseLight = clamp(cloudPhase * 10.0, 0.0, 1.5);

		// Ambient/base preserve
		float ambientLift = 0.82 + horizonCloud * 0.10;

		// Forward scattering brightening when looking toward sun
		float forwardLift = 1.0 + phaseLight * 0.45;

		cloudBlendRGBT.rgb *= ambientLift * forwardLift;

		// Keep your original sun tint, but drive it partly from phase too
		cloudBlendRGBT.rgb = ApplySunTint(
			cloudBlendRGBT.rgb,
			cloudCamToMapNorm,
			0.18 + 0.22 * clamp(phaseLight, 0.0, 1.0)
		);

		// Slight horizon softening
		cloudBlendRGBT.rgb = mix(
			cloudBlendRGBT.rgb,
			cloudGlobalColor.rgb * 1.04,
			horizonCloud * 0.08
		);

		// Silver lining / sun edge highlight
		cloudBlendRGBT.rgb += vec3(1.0, 0.95, 0.84) *
			(0.03 * silverLining + 0.06 * phaseLight * silverLining) *
			cloudBlendRGBT.a;

		// Tiny warm boost from phase alone, even away from hard lining
		cloudBlendRGBT.rgb += vec3(1.0, 0.97, 0.90) *
			(0.035 * phaseLight) * cloudBlendRGBT.a;
	}
}
#endif
	// ----------------- BEGIN CLOUD SHADOWS -------------------------------

		#line 38000
		vec4 cloudShadowColor = vec4(0);
		#if (CLOUDSHADOWS > 0 )

		if (shadowMapdepthRaw < 0.9998 ){ // No cloud shadows on distant areas
				// TODO: also clip to within cloudvolume
					
				vec3 cloudShadowRayGroundPos = shadowTrueMapWorldPos.xyz;

				// adjust rayEnd to point from rayStart to the sun direction!
				// the pos at which the vector in sun dir intercepts fog plane

				//
				float cloudBottomDistanceMultiplier = (cloudVolumeMin.y - cloudShadowRayGroundPos.y) / sunDir.y;
				vec3 cloudShadowRayStartPos = cloudShadowRayGroundPos + sunDir.xyz * cloudBottomDistanceMultiplier;

				float cloudTopDistanceMultiplier = (cloudVolumeMax.y - cloudShadowRayGroundPos.y) / sunDir.y;
				vec3 cloudShadowRayEndStep = cloudShadowRayGroundPos + sunDir.xyz * cloudTopDistanceMultiplier;
				
				float cloudShadowEdgeDistanceWeight = CloudVolumeWeight((cloudShadowRayStartPos.xz + cloudShadowRayEndStep.xz) * 0.5);

				if (cloudShadowEdgeDistanceWeight > 0){

				float cloudShadowRayLength = length(cloudShadowRayStartPos - cloudShadowRayEndStep);
				float cloudShadowLodImportance = ComputeStepLodImportance(
					cloudShadowRayLength,
					HorizonViewFactor(shadowCamToMapNorm),
					clamp(cloudDensity, 0.0, 1.0),
					cloudShadowEdgeDistanceWeight
				);
				cloudShadowLodImportance = clamp(cloudShadowLodImportance, 0.22, 1.0);
				uint cloudShadowSteps = uint(EffectiveSampleCount(float(CLOUDSHADOWS), shadowResolutionScale, cloudShadowLodImportance, STEPLOD_CLOUDSHADOW_MIN));
				float stepLength = cloudShadowRayLength / float(cloudShadowSteps); 

				

				vec3 noiseLFStart;
				vec3 noiseLFEndStep;
				vec3 noiseHFStart;
				vec3 noiseHFEndStep;
				
				WorldToNoiseSpace(cloudShadowRayStartPos, noiseLFStart, noiseHFStart); // near point
				WorldToNoiseSpace(cloudShadowRayEndStep, noiseLFEndStep, noiseHFEndStep); // far point
				
				noiseLFEndStep = (noiseLFEndStep - noiseLFStart) / float(cloudShadowSteps);
				noiseHFEndStep = (noiseHFEndStep - noiseHFStart) / float(cloudShadowSteps);

				noiseLFStart.xyz += noiseLFEndStep *( thisQuadOffset + 0.18 * shadowBlueNoiseSample.x ) ;
			


				for (uint i = 0; i < CLOUDSHADOWS; i++){
					if (i >= cloudShadowSteps) break;
					float perturbmod = 1.0;
					vec4 textureNoise = SampleNoiseSpace(noiseLFStart, noiseHFStart,  perturbmod);
					noiseHFStart += noiseHFEndStep;
					noiseLFStart += noiseLFEndStep;

					float clampedNoise = max(0.0, (textureNoise.r - noiseLFParams.y) * cloudDensity * stepLength);
					cloudShadowColor.w += clampedNoise;
				}
				cloudShadowColor.w = quadGatherWeighted(cloudShadowColor.w);
				cloudShadowColor.w *=cloudShadowEdgeDistanceWeight;
				}
			}
		cloudShadowColor.w = (1.0 - exp(-1 * cloudShadowColor.w ) ) * shadowedColor.a * cloudGlobalColor.a;
		cloudShadowColor.w = mix(
			cloudShadowColor.w,
			smoothstep(0.0, 1.0, cloudShadowColor.w),
			UpscaleSoftening(shadowResolutionScale, 0.06)
		);
		#endif
		//fragColor = vec4(step(0.5,threadMask.rga), 1.0);return;
		//fragColor.rgba = vec4(vec3(1.0 - cloudShadowColor.w), 0.95); return;
		


	// ----------------- END CLOUD SHADOWS -------------------------------
	
	// ----------------- BEGIN CHROMA SHIFTING /SCATTERING ---------------------
	// ----------------- END CHROMA SHIFTING /SCATTERING ---------------------

	// ----------------- BEGIN COMPOSITING ---------------------
// ----------------- BEGIN COMPOSITING ---------------------
vec4 outColor = vec4(0.0);

// 1. Blend uwShadowAlpha
outColor.a = 1.0 - (1.0 - outColor.a) * (1.0 - uwShadowAlpha);
outColor.rgb = mix(outColor.rgb, shadowedColor.rgb, uwShadowAlpha);

// 2. Blend cloudShadowColor.rgba
outColor.a = 1.0 - (1.0 - outColor.a) * (1.0 - cloudShadowColor.a);
outColor.rgb = mix(outColor.rgb, shadowedColor.rgb, cloudShadowColor.a);

// 3/4. Height fog + cloud layer, order blended by camera angle
float viewAngle = abs(camToMapNorm.y);
float cloudPriority = smoothstep(0.05, 0.30, viewAngle);

// Height-first composition
vec4 heightFirst = outColor;
float newalpha1 = 1.0 - (1.0 - heightFirst.a) * (1.0 - heightBasedFogColor.a);
heightFirst.rgb = mix(
	heightFirst.rgb,
	heightBasedFogColor.rgb,
	clamp(heightBasedFogColor.a - heightFirst.a * heightFirst.a, 0.0, 1.0)
);
heightFirst.a = newalpha1;

heightFirst.rgb = mix(heightFirst.rgb, cloudBlendRGBT.rgb, cloudBlendRGBT.a);
heightFirst.a = 1.0 - (1.0 - heightFirst.a) * (1.0 - cloudBlendRGBT.a);

// Cloud-first composition
vec4 cloudFirst = outColor;
cloudFirst.rgb = mix(cloudFirst.rgb, cloudBlendRGBT.rgb, cloudBlendRGBT.a);
cloudFirst.a = 1.0 - (1.0 - cloudFirst.a) * (1.0 - cloudBlendRGBT.a);

float newalpha2 = 1.0 - (1.0 - cloudFirst.a) * (1.0 - heightBasedFogColor.a);
cloudFirst.rgb = mix(
	cloudFirst.rgb,
	heightBasedFogColor.rgb,
	clamp(heightBasedFogColor.a - cloudFirst.a * cloudFirst.a, 0.0, 1.0)
);
cloudFirst.a = newalpha2;

// Final interpolation based on view angle
outColor = mix(heightFirst, cloudFirst, cloudPriority);

// 5. Blend distance fog
outColor.a = 1.0 - (1.0 - outColor.a) * (1.0 - distanceFogAmountAlpha);
outColor.rgb = mix(outColor.rgb, distanceFogColor.rgb, distanceFogAmountAlpha);

// subtle horizon air boost
float finalHorizon = HorizonViewFactor(distanceCamToMapNormLocal);
outColor.rgb = mix(outColor.rgb, distanceFogColor.rgb * 1.03, finalHorizon * 0.08);

	vec3 losWorldPos = trueMapWorldPos;
	bool losPosValid =
		losWorldPos.x >= 0.0 && losWorldPos.x <= mapSize.x &&
		losWorldPos.z >= 0.0 && losWorldPos.z <= mapSize.y;

	float losLevel = -1.0;
	float losCoverage = 0.0;
	float radarCoverage = 0.0;

	if (losPosValid) {
		losWorldPos.x = clamp(losWorldPos.x, 0.0, mapSize.x);
		losWorldPos.z = clamp(losWorldPos.z, 0.0, mapSize.y);

		losLevel = losLevelAtWorldPos(losWorldPos);
		if (losLevel >= 0.0) {
			losCoverage = 1.0;
		}

		radarCoverage = radarCoverageAtWorldPos(losWorldPos);
	}

	float radarOnlyCoverage = radarCoverage;
	if (losCoverage > 0.5) {
		radarOnlyCoverage = 0.0;
	}

	float fogMul = 1.0;

	// Existing LOS reduction based on LOS strength
	if (losLevel >= 0.0) {
		float losReduce = clamp(losLevel, 0.0, 1.0);
		fogMul *= (1.0 - losReduce);
	}

	// Extra reduction inside LOS
	fogMul *= (1.0 - clamp(float(LOSFOGUNDISCOVERED), 0.0, 1.0) * losCoverage);

	// Extra reduction inside radar-only
	fogMul *= (1.0 - clamp(float(RADARFOGUNDISCOVERED), 0.0, 1.0) * radarOnlyCoverage);

	outColor.a *= clamp(fogMul, 0.0, 1.0);

	fragColor = outColor;
	
	#if (FULLALPHA == 1) 
		fragColor.a = 1.0;
	#endif
	#if (RESOLUTION == 1) // When not using combine shader, we must pre-multiple color with alpha!
		fragColor.rgb *= fragColor.a;
	#endif
	
	//printf(fragColor.rgba);
	return;


	// ----------------- END COMPOSITING   ---------------------
	
	return;
	
	fragColor.rgb = fragColor.rgb * debugQuad(quadVector).rgb * 0.5;
	if (step(0, quadVector.x) * step(quadVector.y, 0) > 0 ){
		//fragColor.rgb = vec3(step(modeldepth, mapdepth));
	}
	fragColor.b = step(modeldepth, mapdepth) * 0.75;
	return;

// ********************************* END COMPLETE REWRITE *******************************

}