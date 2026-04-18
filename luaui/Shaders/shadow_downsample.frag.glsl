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
	vec2 uv;
};

uniform sampler2D shadowTex;

out float shadowDownsampled;

void main() {
	vec2 texel = 1.0 / vec2(textureSize(shadowTex, 0));
	float center = texture(shadowTex, uv).r * 4.0;
	float axis =
		texture(shadowTex, uv + vec2(texel.x, 0.0)).r +
		texture(shadowTex, uv - vec2(texel.x, 0.0)).r +
		texture(shadowTex, uv + vec2(0.0, texel.y)).r +
		texture(shadowTex, uv - vec2(0.0, texel.y)).r;
	float diag =
		texture(shadowTex, uv + texel).r +
		texture(shadowTex, uv + vec2(texel.x, -texel.y)).r +
		texture(shadowTex, uv + vec2(-texel.x, texel.y)).r +
		texture(shadowTex, uv - texel).r;
	shadowDownsampled = (center + axis * 2.0 + diag) / 16.0;
}
