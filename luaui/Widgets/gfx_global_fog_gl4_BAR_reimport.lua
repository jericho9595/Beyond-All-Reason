--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
function widget:GetInfo()
	return {
		name = "Global Fog GL4#2",
		version = 3,
		desc = "Draws new Global fog",
		author = "Beherith",
		date = "2022.07.14",
		license = "Lua code is GPL V2, GLSL is (c) Beherith",
		layer = 100010,
		enabled = false
	}
end

local GL_RGBA32F_ARB = 0x8814
local GL_R32F = 0x822E

--------------------------------------------------------------------------------
-- TODO: 2022.11.30
-- Expose fog params via uniforms:
	-- Fog Color
	-- Global Fog density
	-- Fog Plane Height
	-- Height-based fog density
-- Pre optimization at full screen on Colorado is 190 -> 120fps, after 190->150fps
-- DONE: Fix mixing of shadow marching and noise sampling, with conditional shadow marching
-- Fix colorization based on sun angle
-- DONE: Use a spherical harmonics equation for this?
-- DONE: Fix colorization of height based and distance based fog
-- DONE Use non constant density fog (maybe exponential is better?) (using linear at the moment)
-- Create a better noise texture (also use this for other occasions!)
-- DONE: Expose params to be easily tunable
-- Create quality 'presets' and auto apply them?//done
-- DONE: better LOS shader usage?
-- DONE: minimap color backscatter
-- DONE: Fix blending of shadowed and non-shadowed
-- DONE handle out-of-map better!//done
-- DONE: Fix non raytraced fog nonlinearity
-- TODO: Make it also be clouds//what u mean?
-- TODO: handle pullback of min(mapdepth, modeldepth); better than now.
-- TODO: Volumetric "water shadow scattering" pass
-- TODO: Reflections shader
-- TODO: HDR blending
-- VERY IMPORTANT NOTES:
-- WHEN NOT USING RAYTRACING, SET FOG RESOLUTION TO 1!!!!!!!!!
-- TODO: Switch to premultiplied alpha, which is needed for proper raymarchcing compositing:
	-- https://lightrun.com/answers/mrdoob-three-js-incorrect-brightness-when-gl_fragcolor-is-semi-transparent
	-- So gl.Blending(GL.ONE, GL.ONE_MINUS_SRC_ALPHA) -- GL.ONE instead of GL.SRC_ALPHA
	-- Which means that the final, compositing fragment output needs its fragColor.rgb = fragColor.rgb * fragColor.a


-- Most fucked up idea ever:
	-- a simple 2d texture lookup is _still_ faster than a fucking noise gen, even the cheapest goddamned FBM noise too
	-- ping-pong between two textures every gameframe, and render all units into that. What should the texture contain?
	-- Well it should always read the first ping, to be able to decay it
	-- red and blue contain XY offset of all unit's triggered noise swirl shit
	-- green could contain the 'height' of the turbulence
	
	-- 
	-- Alpha of it should contain like a global noise offset, which should blow with the wind, but contain some underlying moderate frequency noise

-- Performance Notes 2023.10.13
	-- Combine Shader eats .35 ms in rez == 2 mode, but only 100 ms in rez >= 3
	-- Total cost at rez = 2 is like 2.4 ms, broken down into:
		-- combine shader 0.35ms
		-- clouds 0.85ms
		-- cloud shadows 0.45ms
		-- uw shadows 0.10 ms
		-- height fog 0.2 ms
		-- rest of the shit 0.4 ms
		-- VGPR Pressure according to RGA tool is 48. This did require some finagling:
			-- layout(binding = 4) uniform sampler2D modelDepths;
			-- layout(set=0, binding = 15) uniform TheBlock{
				-- uniform float windX;
				-- 

-- TODO 20250822
	-- [x] RMLUI Sliders are 1 update late always //jlm-seem to cause lag otherwise when recompiling 
	-- [ ] Combine shader sample neighbour texels with texelgather
	-- [x] Fix map edge extension
	-- [x] Add uniform sliders 
	-- [x] Better grouping for individual effects:
		-- Global
		-- Ground fog + self-shadowing
		-- Height Fog 
		-- Underwater shadow absorbtion 
		-- Cloud layer 
		-- Cloud shadows 
		-- Distance fog 
		-- ScavCloud
	-- [ ] Better control over defines vs uniforms
	-- [ ] Add save and load config buttons //jlm donee
		-- [ ] Load does not load ... //jlm fix
	-- [ ] Try to add tooltips? for the slider? there are
	-- [x] Minimize the rml window
	-- [ ] Prep all work for correct blending order to the compositing pass 
	-- [ ] Add dynamic api to control params
	-- [ ] Fix wind noise looping //should not be looping? what would be the alternative
	-- [ ] Bottom / top of cloud layer too sharp when viewed horizontally //not sure what u mean by sharp
	-- [x] Spacing of sliders is too much



------------- Literature and Reading: ---
-- blue noise sampling:  https://blog.demofox.org/2020/05/10/ray-marching-fog-with-blue-noise/
-- Inigo quliez fog lighting tips: https://iquilezles.org/articles/fog/
-- Analyitic fog density: https://blog.demofox.org/2014/06/22/analytic-fog-density/
--------------------------------------------------------------------------------

local vsx, vsy = Spring.GetViewGeometry()
local hsx, hsy

local minHeight, maxHeight = Spring.GetGroundExtremes()

local shaderConfig = {
	MAPSIZEX = Game.mapSizeX,
	MAPSIZEZ = Game.mapSizeZ,
	MAPSIZEY = maxHeight,
	VSX = vsx,
	VSY = vsy,
	HSX = hsx,
	HSY = hsy,
}

local document
widget.rmlContext = nil

local DEBUG_LOGS = false
local SHOW_DRAWTIME = false
local debugToggleButton = nil
local drawtimeToggleButton = nil

local function UpdateDebugUIButtons()
	if debugToggleButton then
		debugToggleButton.inner_rml = "DEBUG: " .. (DEBUG_LOGS and "ON" or "OFF")
	end
	if drawtimeToggleButton then
		drawtimeToggleButton.inner_rml = "DRAWTIME: " .. (SHOW_DRAWTIME and "ON" or "OFF")
	end
end

local function Log(...)
	if DEBUG_LOGS then
		Spring.Echo(...)
	end
end

local eventCallback = function(ev, ...) Log("orig function says", ...) end
local dataModelHandle

--------------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------------
local function goodbye(reason)
	Spring.Echo("Exiting", reason)
	widgetHandler:RemoveWidget()
end

-- BAR import: prefer the engine-provided GL shader helper again, like before.
local LuaShader = (gl and gl.LuaShader) or nil
if not LuaShader and VFS.FileExists("LuaUI/Include/LuaShader.lua") then
	LuaShader = VFS.Include("LuaUI/Include/LuaShader.lua")
end

Log("[GlobalFog] LuaShader =", LuaShader)
Log("[GlobalFog] LuaShader.CheckShaderUpdates =", LuaShader and LuaShader.CheckShaderUpdates)
Log("[GlobalFog] LuaShader.CreateShader =", LuaShader and LuaShader.CreateShader)
Log("[GlobalFog] type(LuaShader) =", type(LuaShader))

local function CheckShader(srccache, oldShader)
	if not LuaShader then
		Log("[GlobalFog] LuaShader missing")
		return oldShader
	end

	if LuaShader.CheckShaderUpdates then
		return LuaShader.CheckShaderUpdates(srccache) or oldShader
	end

	if LuaShader.CreateShader then
		Log("[GlobalFog] fallback LuaShader.CreateShader")
		return LuaShader.CreateShader(srccache) or oldShader
	end

	Log("[GlobalFog] no shader creation function found on LuaShader")
	return oldShader
end

local InstanceVBOTable = (gl and gl.InstanceVBOTable) or nil
local makePlaneVBO = nil
local makePlaneIndexVBO = nil
local makeRectVBO = nil

do
	if not InstanceVBOTable and VFS.FileExists("LuaUI/Include/instancevbotable.lua") then
		local ok, result = pcall(VFS.Include, "LuaUI/Include/instancevbotable.lua")
		Log("[GlobalFog] include fallback ok =", ok, "result =", result)
		if ok and type(result) == "table" then
			InstanceVBOTable = result
		end
	end

	if InstanceVBOTable and type(InstanceVBOTable) == "table" then
		makePlaneVBO = InstanceVBOTable.makePlaneVBO
		makePlaneIndexVBO = InstanceVBOTable.makePlaneIndexVBO
		makeRectVBO = InstanceVBOTable.makeRectVBO
	end

	Log("[GlobalFog] InstanceVBOTable type =", type(InstanceVBOTable))
	Log("[GlobalFog] makePlaneVBO =", makePlaneVBO)
	Log("[GlobalFog] makePlaneIndexVBO =", makePlaneIndexVBO)
	Log("[GlobalFog] makeRectVBO =", makeRectVBO)
end

local function hexToVec4(hex, alpha)
	hex = hex:gsub("#", "")
	if #hex ~= 6 then
		return {1, 1, 1, alpha or 1}
	end
	local r = tonumber(hex:sub(1, 2), 16) or 255
	local g = tonumber(hex:sub(3, 4), 16) or 255
	local b = tonumber(hex:sub(5, 6), 16) or 255
	return {r / 255, g / 255, b / 255, alpha or 1}
end

local MAX_RADARS = 64
local radarCircles = {}

local spGetAllUnits = Spring.GetAllUnits
local spGetUnitDefID = Spring.GetUnitDefID
local spGetUnitPosition = Spring.GetUnitPosition
local spGetUnitAllyTeam = Spring.GetUnitAllyTeam
local myAllyTeamID = Spring.GetMyAllyTeamID()

local function NoShockwaveCompat()
	return false
end

local function UpdateRadarCircles()
	radarCircles = {}

	local units = spGetAllUnits()
	for i = 1, #units do
		local unitID = units[i]
		local unitDefID = spGetUnitDefID(unitID)
		local ud = unitDefID and UnitDefs[unitDefID]

		if ud and ud.radarRadius and ud.radarRadius > 0 then
			if spGetUnitAllyTeam(unitID) == myAllyTeamID then
				local x, _, z = spGetUnitPosition(unitID)
				if x and z then
					radarCircles[#radarCircles + 1] = {
						x = x,
						z = z,
						r = ud.radarRadius,
					}
					if #radarCircles >= MAX_RADARS then
						break
					end
				end
			end
		end
	end
end

--------------------------------------------------------------------------------
-- fog params
--------------------------------------------------------------------------------

local paramGroups = {
	global = "Global Parameters",
	ground = "Ground Fog Parameters",
	underwater = "Underwater Shadows Parameters",
	cloud = "Cloud Layer Parameters",
	cloudshadows = "Cloud Shadow Parameters",
	height = "Height Fog Parameters",
	distance = "Distance Fog Parameters",
	scavenger = "Scavenger Cloud Parameters",
	shadow = "Shadow Parameters",
}

local definesSlidersParamsList = {
	{name = "RESOLUTION", displayName = "MASTERRESOLUTION_DISABLED", default = 1, min = 1, max = 1, digits = 0, tooltip = "Disabled: separate cloud/fog/shadow/distance sliders now control resolution independently. Keep this at 1.", group = "global"},
	{name = "OFFSETX", default = 0, min = -4, max = 4, digits = 0, tooltip = "OFFSETX", group = "global"},
	{name = "OFFSETY", default = 0, min = -4, max = 4, digits = 0, tooltip = "OFFSETY", group = "global"},
	{name = "HALFSHIFT", default = 1, min = 0, max = 1, digits = 0, tooltip = "If the resolution is half, perform a half-pixel shifting", group = "global"},
	{name = "WEIGHTFACTOR", default = 0.56, min = 0, max = 1, digits = 2, tooltip = "Squared weight for each texel in PQM", group = "global"},
	{name = "QUADNOISEFETCHING", default = 1, min = 0, max = 1, digits = 0, tooltip = "Enable Quad Message Passing [0 or 1]", group = "global"},
	{name = "NOISESCALE", default = 0.3, min = 0.001, max = 0.999, digits = 3, tooltip = "The tiling frequency of noise", group = "global"},
	{name = "SHADOWSAMPLER", default = 1, min = 0, max = 3, digits = 0, tooltip = "0 use texture fetch, 1 use sampler fetch, 2 use texelfetch", group = "global"},
	{name = "MINISHADOWS", default = 1, min = 0, max = 1, digits = 0, tooltip = "0 = use direct $shadow, 1 = use shadow downsample/minishadow pass", group = "shadow"},
	{name = "STEPLOD", default = 1, min = 0, max = 1, digits = 0, tooltip = "0 = fixed step counts, 1 = automatic per-pixel step LOD for clouds / height fog / distance fog early-out", group = "global"},
{name = "STEPLOD_STRENGTH", default = 1.0, min = 0.5, max = 3.0, digits = 2, tooltip = "Global Step LOD aggressiveness. 1.0 = default, >1 = more aggressive LOD, <1 = keep more steps", group = "global"},
{name = "STEPLOD_CLOUD_MIN", default = 0.30, min = 0.10, max = 1.00, digits = 2, tooltip = "Minimum cloud step fraction kept by Step LOD. Lower = more aggressive cloud LOD", group = "cloud"},
{name = "STEPLOD_CLOUDSHADOW_MIN", default = 0.25, min = 0.10, max = 1.00, digits = 2, tooltip = "Minimum cloud shadow step fraction kept by Step LOD. Lower = more aggressive cloud shadow LOD", group = "cloudshadows"},
{name = "STEPLOD_HEIGHTNOISE_MIN", default = 0.30, min = 0.10, max = 1.00, digits = 2, tooltip = "Minimum height fog noise step fraction kept by Step LOD. Lower = more aggressive height fog noise LOD", group = "height"},
{name = "STEPLOD_HEIGHTSHADOW_MIN", default = 0.35, min = 0.10, max = 1.00, digits = 2, tooltip = "Minimum height fog shadow step fraction kept by Step LOD. Lower = more aggressive height fog shadow LOD", group = "shadow"},
{name = "STEPLOD_DISTANCE_EARLYOUT", default = 0.22, min = 0.00, max = 1.00, digits = 2, tooltip = "Distance fog Step LOD early-out threshold. Higher = more aggressive distance fog culling", group = "distance"},
{name = "STEPLOD_DISTANCE_ALPHA_MIN", default = 0.02, min = 0.00, max = 0.20, digits = 3, tooltip = "Distance fog alpha threshold for Step LOD early-out. Higher = more aggressive distance fog culling", group = "distance"},
	{name = "CLOUDSENABLED", default = 1, min = 0, max = 1, digits = 0, tooltip = "0 = disable clouds/cloud shadows, 1 = enable them", group = "cloud"},
	{name = "HEIGHTFOGENABLED", default = 1, min = 0, max = 1, digits = 0, tooltip = "0 = disable height fog, 1 = enable it", group = "height"},
	{name = "DISTANCEFOGENABLED", default = 1, min = 0, max = 1, digits = 0, tooltip = "0 = disable distance fog, 1 = enable it", group = "distance"},
	{name = "TEXTURESAMPLER", default = 1, min = 0, max = 6, digits = 0, tooltip = "0:None 1=Packed3D 2=Tex2D 3=Tex2D 4=FBM 5=Value3D 6=SimplexPerlin", group = "global"},
	{name = "USEDDS", default = 0, min = 0, max = 1, digits = 0, tooltip = "Use DDS compressed version of packedNoise", group = "global"},
	{name = "USELOS", default = 1, min = 0, max = 1, digits = 0, tooltip = "Use the LOS map", group = "global"},
	{name = "LOSREDUCEFOG", default = 0, min = 0, max = 1, digits = 2, tooltip = "How much less fog there is in LOS", group = "global"},
	{name = "LOSFOGUNDISCOVERED", default = 1.0, min = 0, max = 1, digits = 2, tooltip = "Extra fog in undiscovered areas", group = "global"},
	{name = "RADARFOGUNDISCOVERED", default = 0, min = 0, max = 1, digits = 2, tooltip = "Extra fog in radar-only areas (less than LOS undiscovered)", group = "global"},
	{name = "USEMINIMAP", default = 0, min = 0, max = 1, digits = 0, tooltip = "Use minimap for back-scatter", group = "global"},
	{name = "SUNCHROMASHIFT", default = 0.2, min = -0.5, max = 1, digits = 2, tooltip = "How much colors are shifted towards sun", group = "global"},
	{name = "RISERATE", default = 0.025, min = 0.00, max = 0.2, digits = 3, tooltip = "Rate at which cloud noise rises", group = "global"},
	{name = "WINDSTRENGTH", default = 0.01, min = 0, max = 0.1, digits = 2, tooltip = "Speed multiplier for wind", group = "global"},
	{name = "MINIMAPSCATTER", default = 0.1, min = -0.5, max = 0.5, digits = 2, tooltip = "Minimap back-scatter amount", group = "global"},
	{name = "FULLALPHA", default = 0, min = 0, max = 1, digits = 0, tooltip = "Show ONLY fog", group = "global"},
	{name = "COMBINESHADER", default = 1, min = 0, max = 1, digits = 0, tooltip = "Run combine shader if RESOLUTION > 1", group = "global"},
	{name = "ENABLED", default = 1, min = 0, max = 1, digits = 0, tooltip = "Dont do anything", group = "global"},
	{name = "EASEHEIGHT", default = 1, min = 0.0, max = 5, digits = 2, tooltip = "Reduce height-based fog close to camera", group = "global"},
	{name = "HEIGHTNOISESTEPS", default = 8, min = 0, max = 32, digits = 0, tooltip = "Ground fog noise samples", group = "ground"},
	{name = "HEIGHTSHADOWSTEPS", default = 12, min = 0, max = 32, digits = 0, tooltip = "Height fog shadow samples", group = "ground"},
	{name = "HEIGHTSHADOWQUAD", default = 2, min = 0, max = 2, digits = 0, tooltip = "Quad sample mode for height fog", group = "shadow"},
	{name = "UWSHADOWSTEPS", default = (minHeight < -20) and 8 or 0, min = 0, max = 64, digits = 0, tooltip = "Underwater shadow samples", group = "underwater"},
	{name = "UWCAUSTICS", default = 2, min = 0, max = 8, digits = 1, tooltip = "Underwater caustics amount", group = "underwater"},
	{name = "CLOUDSTEPS", default = 16, min = 0, max = 64, digits = 0, tooltip = "Cloud samples", group = "cloud"},
	{name = "NOISETHRESHOLD", default = 0, min = -1, max = 1, digits = 2, tooltip = "Noise threshold", group = "global"},
	{name = "CLOUDSHADOWS", default = 8, min = 0, max = 16, digits = 0, tooltip = "Cloud shadow rays", group = "cloudshadows"},
	{name = "DISTANCEFOGPOWER", default = 4, min = 0, max = 10, digits = 2, tooltip = "Distance fog power", group = "distance"},
}

for _, shaderDefine in ipairs(definesSlidersParamsList) do
	if shaderConfig[shaderDefine.name] == nil then
		shaderConfig[shaderDefine.name] = shaderDefine.default
	end
end

local fogUniforms = {
	heightFogColor = {0.6, 0.7, 0.8, 0.98},
	cloudGlobalColor = {0.6, 0.7, 0.8, 0.98},
	distanceFogColor = {1.0, 0.9, 0.8, 0.35},
	shadowedColor = {0.1, 0.05, 0.1, 0.5},
	heightFogTop = maxHeight * 0.5,
	heightFogBottom = 0,
	cloudDensity = 0.01,
	cloudVolumeMin = {0, maxHeight, 0, 0},
	cloudVolumeMax = {Game.mapSizeX, 2 * maxHeight, Game.mapSizeZ, 1024},
	scavengerPlane = {Game.mapSizeX, Game.mapSizeZ, 100, 100},
	noiseLFParams = {0.31, 0.4, 0.77, 0.0},
	noiseHFParams = {0.4, 0.1, 0.2, 0.2},
	cameraFadeStart = 400,
	cameraFadeEnd = 2000,
	cameraFadePower =3.0,
	cameraFadeEnabled = 1,
	cloudResolutionScale = 1.0,
	heightFogResolutionScale = 1.0,
	shadowResolutionScale = 1.0,
	distanceFogResolutionScale = 1.0,
}

function onFogColorChange(uniformName, hexColor)
	local current = fogUniforms[uniformName]
	local alpha = (type(current) == "table" and current[4]) or 1
	local vec4 = hexToVec4(hexColor, alpha)
	fogUniforms[uniformName] = vec4
	Log("Fog color updated:", uniformName, vec4[1], vec4[2], vec4[3], vec4[4])
	-- Keep fog colors local to this widget in BAR, so external day/night cycle
	-- code does not push values back through WG and re-couple the effect.
end
function widget:OnFogColorChange(uniformName, hexColor)
	onFogColorChange(uniformName, hexColor)
end
local uniformSliderParamsList = {
	{name = "cloudResolutionScale", default = fogUniforms.cloudResolutionScale, min = 0.5, max = 1.0, digits = 2, step = 0.25, tooltip = "Cloud downscale factor", group = "cloud"},
	{name = "heightFogResolutionScale", default = fogUniforms.heightFogResolutionScale, min = 0.5, max = 1.0, digits = 2, step = 0.25, tooltip = "Height fog downscale factor", group = "height"},
	{name = "shadowResolutionScale", default = fogUniforms.shadowResolutionScale, min = 0.5, max = 1.0, digits = 2, step = 0.25, tooltip = "Shadow downscale factor", group = "shadow"},
	{name = "distanceFogResolutionScale", default = fogUniforms.distanceFogResolutionScale, min = 0.5, max = 1.0, digits = 2, step = 0.25, tooltip = "Distance fog downscale factor", group = "distance"},
	{name = "distanceFogColor", default = fogUniforms.distanceFogColor, min = 0, max = 2, digits = 3, tooltip = "distanceFogColor", group = "distance", membernames = {"r","g","b","a"}},
	{name = "shadowedColor", default = fogUniforms.shadowedColor, min = 0, max = 2, digits = 3, tooltip = "shadowedColor", group = "shadow", membernames = {"r","g","b","a"}},
	{name = "heightFogColor", default = fogUniforms.heightFogColor, min = 0, max = 2, digits = 3, tooltip = "heightFogColor", group = "height", membernames = {"r","g","b","a"}},
	{name = "heightFogTop", default = fogUniforms.heightFogTop, min = math.floor(minHeight), max = math.floor(maxHeight * 2), digits = 0, tooltip = "heightFogTop", group = "height"},
	{name = "heightFogBottom", default = fogUniforms.heightFogBottom, min = math.floor(minHeight), max = math.floor(maxHeight), digits = 0, tooltip = "heightFogBottom", group = "height"},
	{name = "scavengerPlane", default = fogUniforms.scavengerPlane, min = 0, max = math.max(Game.mapSizeX, Game.mapSizeZ), digits = 0, tooltip = "scavengerPlane", group = "scavenger", membernames = {"minx","maxx","minz","maxz"}},
	{name = "cloudVolumeMin", default = fogUniforms.cloudVolumeMin, min = 0, max = math.max(Game.mapSizeX, Game.mapSizeZ), digits = 0, tooltip = "cloudVolumeMin", group = "cloud", membernames = {"x","y","z","NONE"}},
	{name = "cloudVolumeMax", default = fogUniforms.cloudVolumeMax, min = 0, max = math.max(Game.mapSizeX, Game.mapSizeZ), digits = 0, tooltip = "cloudVolumeMax", group = "cloud", membernames = {"x","y","z","edge"}},
	{name = "cloudGlobalColor", default = fogUniforms.cloudGlobalColor, min = 0, max = 2, digits = 3, tooltip = "cloudGlobalColor", group = "cloud", membernames = {"r","g","b","a"}},
	{name = "cloudDensity", default = fogUniforms.cloudDensity, min = 0.000, max = 0.1, digits = 3, tooltip = "cloudDensity", group = "cloud"},
	{name = "noiseLFParams", default = fogUniforms.noiseLFParams, min = -1, max = 5, digits = 3, tooltip = "noiseLFParams", group = "cloud", membernames = {"hfscale","hfbias","lfscale","lfbias"}},
	{name = "noiseHFParams", default = fogUniforms.noiseHFParams, min = -1, max = 5, digits = 3, tooltip = "noiseHFParams", group = "cloud", membernames = {"hfscale","perturb","speedx","speedz"}},
	{name = "cameraFadeStart", default = fogUniforms.cameraFadeStart, min = 0, max = math.floor(maxHeight * 5), digits = 0, tooltip = "Camera fade start Y", group = "cloud"},
	{name = "cameraFadeEnd", default = fogUniforms.cameraFadeEnd, min = 0, max = math.floor(maxHeight * 8), digits = 0, tooltip = "Camera fade end Y", group = "cloud"},
	{name = "cameraFadePower", default = fogUniforms.cameraFadePower, min = 0.1, max = 10.0, digits = 2, tooltip = "Camera fade power", group = "cloud"},
	{name = "cameraFadeEnabled", default = fogUniforms.cameraFadeEnabled, min = 0, max = 1, digits = 0, tooltip = "Enable camera fade", group = "cloud"},

}

local fogUniformSliders = {
	windowtitle = "Fog Uniforms",
	name = "fogUniformSliders",
	left = vsx - 270,
	right = vsx - 270 + 250,
	bottom = 200,
	top = 1200,
	width = 250,
	height = 20,
	sliderheight = 20,
	valuetarget = fogUniforms,
	sliderParamsList = uniformSliderParamsList,
	callbackfunc = nil
}

local uniformSlidersLayer, uniformSlidersWindow
local autoreload = true

--------------------------------------------------------------------------------
-- textures / shader objects
--------------------------------------------------------------------------------

local noisetex3dcube = "LuaUI/images/noisetextures/uniform3d_16x16x16_L.dds"
local blueNoise64 = "LuaUI/images/noisetextures/blue_noise_64.tga"
local uniformNoiseTex = "LuaUI/images/noisetextures/uniform3d_16x16x16_RGBA.dds"
local distortiontex = "LuaUI/images/fractal_voronoi_tiled_1024_1.png"
local packedNoise = "LuaUI/images/noisetextures/worley3_256x128x64_RBGA_LONG." .. ((shaderConfig.USEDDS == 1) and "dds" or "png")

local fogPlaneVAO
local resolution = 4
local groundFogShader
local combineShader
local fogTexture
local shadowTexture
local quadVAO
local shadowShader

local vsSrcPath = "LuaUI/Shaders/global_fog.vert.glsl"
local fsSrcPath = "LuaUI/Shaders/global_fog_step_lod_toggle.frag.glsl"

local shaderSourceCache = {
	vssrcpath = vsSrcPath,
	fssrcpath = fsSrcPath,
	uniformInt = {
		mapDepths = 0,
		modelDepths = 1,
		heightmapTex = 2,
		infoTex = 3,
		shadowTex = 4,
		noise64cube = 5,
		miniMapTex = 6,
		packedNoise = 7,
		blueNoise64 = 8,
		uniformNoiseTex = 9,
		radarCount = 0,
	},
	uniformFloat = {
		windFractFull = {0,0,0,0},
		heightFogColor = fogUniforms.heightFogColor,
		distanceFogColor = fogUniforms.distanceFogColor,
		shadowedColor = fogUniforms.shadowedColor,
		cloudDensity = fogUniforms.cloudDensity,
		heightFogTop = fogUniforms.heightFogTop,
		heightFogBottom = fogUniforms.heightFogBottom,
		cameraFadeStart = fogUniforms.cameraFadeStart,
		cameraFadeEnd = fogUniforms.cameraFadeEnd,
		cameraFadePower = fogUniforms.cameraFadePower,
		cameraFadeEnabled = fogUniforms.cameraFadeEnabled,
		cloudResolutionScale = fogUniforms.cloudResolutionScale,
		heightFogResolutionScale = fogUniforms.heightFogResolutionScale,
		shadowResolutionScale = fogUniforms.shadowResolutionScale,
		distanceFogResolutionScale = fogUniforms.distanceFogResolutionScale,
		radarCount = 0,
	},
	shaderName = "Ground Fog GL4",
	shaderConfig = shaderConfig
}

local vsSrcPathCombine = "LuaUI/Shaders/global_fog_combine.vert.glsl"
local fsSrcPathCombine = "LuaUI/Shaders/global_fog_combine.frag.glsl"

local combineShaderSourceCache = {
	vssrcpath = vsSrcPathCombine,
	fssrcpath = fsSrcPathCombine,
	uniformInt = { mapDepths = 0, modelDepths = 1, fogbase = 2 },
	uniformFloat = { gameframe = 0, resolution = 2 },
	shaderName = "Global Fog Combine GL4",
	shaderConfig = shaderConfig,
}

local shadowMinifierShaderSourceCache = {
	vssrcpath = "LuaUI/Shaders/shadow_downsample.vert.glsl",
	fssrcpath = "LuaUI/Shaders/shadow_downsample.frag.glsl",
	uniformInt = { shadowTex = 0 },
	uniformFloat = { gameframe = 0, resolution = 2 },
	shaderName = "shadowMinifierShader",
	shaderConfig = { VSX = vsx, VSY = vsy, HSX = hsx, HSY = hsy }
}

--------------------------------------------------------------------------------
-- config save/load helpers
--------------------------------------------------------------------------------

local loadConfig
local getAvailableConfigs
local getSanitizedMapName
local getDefaultConfigPath
local getLatestConfigPath
local getNamedPresetConfigPath
local autoLoadMapConfig

local function SetFogParams(paramname, paramvalue, paramIndex)
	Log("SetFogParams", paramname, paramvalue, paramIndex)
	if fogUniforms[paramname] then
		if paramIndex then
			fogUniforms[paramname][paramIndex] = paramvalue
		else
			fogUniforms[paramname] = paramvalue
		end
	end
end

local function CopyFogValue(value)
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for i = 1, #value do
		out[i] = value[i]
	end
	return out
end

local function GetFogParamsSnapshot()
	local snapshot = {}
	for k, v in pairs(fogUniforms) do
		snapshot[k] = CopyFogValue(v)
	end
	return snapshot
end


local function getCurrentConfig()
	local config = {
		shaderConfig = {},
		fogUniforms = {},
	}

	for _, param in ipairs(definesSlidersParamsList) do
		if param.name == "RESOLUTION" then
			config.shaderConfig[param.name] = 1
		else
			config.shaderConfig[param.name] = shaderConfig[param.name]
		end
	end

	for _, param in ipairs(uniformSliderParamsList) do
		local value = fogUniforms[param.name]
		if type(value) == "table" then
			config.fogUniforms[param.name] = {}
			for i, v in ipairs(value) do
				config.fogUniforms[param.name][i] = v
			end
		else
			config.fogUniforms[param.name] = value
		end
	end


	return config
end

getSanitizedMapName = function()
	local mapName = Game.mapName or "UnknownMap"
	return mapName:gsub("[^%w%-_]", "_")
end

getDefaultConfigPath = function()
	local mapName = getSanitizedMapName()
	return "LuaUI/Config/GlobalFog/FogConfig_" .. mapName .. "_default.lua"
end

getNamedPresetConfigPath = function(presetName)
	local mapName = getSanitizedMapName()
	local safePresetName = tostring(presetName or "preset"):lower():gsub("[^%w%-_]", "_")
	return "LuaUI/Config/GlobalFog/FogConfig_" .. mapName .. "_" .. safePresetName .. ".lua"
end

getAvailableConfigs = function()
	local mapName = getSanitizedMapName()

	local configDir = "LuaUI/Config/GlobalFog/"
	local files = VFS.DirList(configDir, "*.lua")
	table.sort(files, function(a, b) return a > b end)

	local configs = {}
	for _, filepath in ipairs(files) do
		local filename = filepath:match("([^/\\]+)$")
		if filename
			and filename:match("^FogConfig_" .. mapName .. "_")
			and not filename:match("_default%.lua$") then

			local timestamp = filename:match("^FogConfig_" .. mapName .. "_(.+)%.lua$")
			if timestamp then
				table.insert(configs, {
					filename = filename,
					filepath = filepath,
					timestamp = timestamp,
					displayName = filename,
				})
			end
		end
	end

	table.sort(configs, function(a, b) return a.timestamp > b.timestamp end)
	return configs
end

getLatestConfigPath = function()
	local configs = getAvailableConfigs()
	if configs and #configs > 0 then
		return configs[1].filepath, configs[1]
	end
	return nil, nil
end

local function AddElementToDropDown(dropdown, optionText, optionValue, optionID)
	if not dropdown or not optionText or not optionValue then
		return
	end

	if optionID and document and document.GetElementById then
		local existingOption = document:GetElementById(optionID)
		if existingOption then
			existingOption:SetAttribute("value", optionValue)
			existingOption.inner_rml = optionText
			return existingOption
		end
	end

	local option = document:CreateElement("option")
	option:SetAttribute("value", optionValue)
	option.inner_rml = optionText
	if optionID then
		option.id = optionID
	end
	dropdown:AppendChild(option)
	return option
end

local function serializeTableForConfig(t, indent)
	indent = indent or 0
	local tabs = string.rep("\t", indent)
	local result = "{\n"
	for k, v in pairs(t) do
		local key = type(k) == "string" and k or "[" .. tostring(k) .. "]"
		if type(v) == "table" then
			result = result .. tabs .. "\t" .. key .. " = " .. serializeTableForConfig(v, indent + 1) .. ",\n"
		elseif type(v) == "string" then
			result = result .. tabs .. "\t" .. key .. " = " .. string.format("%q", v) .. ",\n"
		else
			result = result .. tabs .. "\t" .. key .. " = " .. tostring(v) .. ",\n"
		end
	end
	result = result .. tabs .. "}"
	return result
end

local function writeConfigFile(fullPath, titleLabel)
	local configDir = "LuaUI/Config/GlobalFog/"
	Spring.CreateDir(configDir)

	local config = getCurrentConfig()
	local configStr = "-- Global Fog " .. (titleLabel or "Configuration") .. "\n"
	configStr = configStr .. "-- Generated on " .. os.date() .. "\n"
	configStr = configStr .. "-- Map: " .. (Game.mapName or "Unknown") .. "\n\n"
	configStr = configStr .. "return " .. serializeTableForConfig(config) .. "\n"

	local file = io.open(fullPath, "w")
	if file then
		file:write(configStr)
		file:close()
		Log("[GlobalFog] Saved " .. (titleLabel or "config") .. " to: " .. fullPath)
		return true
	else
		Spring.Echo("[GlobalFog] Error: Could not save " .. (titleLabel or "config") .. " to " .. fullPath)
		return false
	end
end

local function saveNamedPresetConfig(presetName)
	local normalizedPresetName = tostring(presetName or "preset")
	local fullPath = getNamedPresetConfigPath(normalizedPresetName)
	local ok = writeConfigFile(fullPath, normalizedPresetName:upper() .. " Preset")

	if ok and document and document:GetElementById("configDropdown") then
		local optionID = "configPreset_" .. normalizedPresetName:lower():gsub("[^%w%-_]", "_")
		AddElementToDropDown(document:GetElementById("configDropdown"), normalizedPresetName:upper() .. " preset", fullPath, optionID)
	end

	return ok
end

local function saveConfig()
	local mapName = getSanitizedMapName()
	local timestamp = os.date("%Y%m%d_%H%M%S")
	local filename = string.format("FogConfig_%s_%s.lua", mapName, timestamp)
	local configDir = "LuaUI/Config/GlobalFog/"
	local fullPath = configDir .. filename

	local ok = writeConfigFile(fullPath, "Configuration")
	if ok and document and document:GetElementById("configDropdown") then
		AddElementToDropDown(document:GetElementById("configDropdown"), filename, fullPath)
	end
	return ok
end

local function saveDefaultConfig()
	local fullPath = getDefaultConfigPath()
	return writeConfigFile(fullPath, "DEFAULT Configuration")
end

updateUIFromConfig = function()
	for _, param in ipairs(definesSlidersParamsList) do
		local element = document:GetElementById(param.name)
		if element then
			element.attributes.value = tostring(shaderConfig[param.name])
		end
	end

	for _, param in ipairs(uniformSliderParamsList) do
		local value = fogUniforms[param.name]
		if type(value) == "table" then
			for _, v in ipairs(value) do
				local element = document:GetElementById(param.name)
				if element then
					element.attributes.value = tostring(v)
				end
			end
		else
			local element = document:GetElementById(param.name)
			if element then
				element.attributes.value = tostring(value)
			end
		end
	end

end

loadConfig = function(filepath)
	if not VFS.FileExists(filepath) then
		Spring.Echo("Error: Config file does not exist: " .. filepath)
		return false
	end

	local configData = VFS.Include(filepath)
	if not configData then
		Spring.Echo("Error: Could not load config from " .. filepath)
		return false
	end

	Log("Loaded config data from " .. filepath)

	if configData.shaderConfig then
		for key, value in pairs(configData.shaderConfig) do
			if shaderConfig[key] ~= nil then
				shaderConfig[key] = value
			end
		end
		shaderConfig.RESOLUTION = 1
		shaderSourceCache.forceupdate = true
		combineShaderSourceCache.forceupdate = true
	end

	if configData.fogUniforms then
		for key, value in pairs(configData.fogUniforms) do
			Log("Loading fog uniform:", key, value)
			if fogUniforms[key] ~= nil then
				fogUniforms[key] = value
			end
		end
	end


	Log("Fog config loaded from: " .. filepath)

	if document then
		updateUIFromConfig()
	end

	if shadowTexture and widget and widget.ViewResize then
		widget:ViewResize()
	end

	return true
end

autoLoadMapConfig = function()
	local defaultPath = getDefaultConfigPath()

	if VFS.FileExists(defaultPath) then
		Log("[GlobalFog] Auto-loading DEFAULT config for map: " .. defaultPath)
		return loadConfig(defaultPath)
	end

	local latestPath, latestConfig = getLatestConfigPath()
	if latestPath then
		Log("[GlobalFog] Auto-loading LATEST config for map: " .. latestConfig.displayName)
		return loadConfig(latestPath)
	end

	Log("[GlobalFog] No fog config found for map: " .. (Game.mapName or "Unknown"))
	return false
end

local function createConfigDropDown(documentArg)
	if not documentArg then
		return
	end

	local configDropdown = documentArg:CreateElement("select")
	configDropdown.id = "configDropdown"

	AddElementToDropDown(configDropdown, "Select config to load...", "Select config to load...")

	local configs = getAvailableConfigs()
	for _, config in ipairs(configs) do
		AddElementToDropDown(configDropdown, config.displayName, config.filepath)
	end

	configDropdown:AddEventListener("change", function(event)
		Log("Chose config file to load:", event.parameters.value)
		loadConfig(event.parameters.value)
	end)

	return configDropdown
end

--------------------------------------------------------------------------------
-- texture / vao init
--------------------------------------------------------------------------------

local function makeFogTexture()
	if fogTexture then
		gl.DeleteTexture(fogTexture)
		fogTexture = nil
	end

	vsx, vsy = Spring.GetViewGeometry()

	hsx = math.ceil(vsx / shaderConfig.RESOLUTION)
	hsy = math.ceil(vsy / shaderConfig.RESOLUTION)

	if shaderConfig.HALFSHIFT == 1 then
		hsx = math.ceil(math.ceil((vsx + 1) / shaderConfig.RESOLUTION) / 2) * 2
		hsy = math.ceil(math.ceil((vsy + 1) / shaderConfig.RESOLUTION) / 2) * 2
	end

	shaderConfig.HSX = hsx
	shaderConfig.HSY = hsy
	shaderConfig.VSX = vsx
	shaderConfig.VSY = vsy

	combineShaderSourceCache.forceupdate = true
	shaderSourceCache.forceupdate = true

	combineShader = CheckShader(combineShaderSourceCache, combineShader)

	fogTexture = gl.CreateTexture(hsx, hsy, {
		min_filter = GL.LINEAR,
		mag_filter = GL.LINEAR,
		wrap_s = GL.CLAMP_TO_EDGE,
		wrap_t = GL.CLAMP_TO_EDGE,
		fbo = true,
		format = GL_RGBA32F_ARB,
	})

	if shadowTexture then
		gl.DeleteTexture(shadowTexture)
		shadowTexture = nil
	end

	local shadowScale = math.max(0.5, math.min(1.0, tonumber(fogUniforms.shadowResolutionScale) or 1.0))
	local shadowSize = math.max(2, math.floor(math.min(vsx, vsy) * shadowScale + 0.5))
	shadowTexture = gl.CreateTexture(shadowSize, shadowSize, {
		min_filter = GL.LINEAR,
		mag_filter = GL.LINEAR,
		wrap_s = GL.CLAMP_TO_EDGE,
		wrap_t = GL.CLAMP_TO_EDGE,
		fbo = true,
		format = GL_R32F,
	})

	Log(string.format(
		"MakeFogTexture: vsx=%d, vsy=%d, hsx=%d, hsy=%d, HALFSHIFT=%d, shadowScale=%.2f, shadowSize=%d",
		vsx, vsy, hsx, hsy, shaderConfig.HALFSHIFT, shadowScale, shadowSize
	))
end

function widget:ViewResize()
	makeFogTexture()
end

widget:ViewResize()

local function initGL4()
	if not makePlaneVBO then
		goodbye("makePlaneVBO unavailable")
		return false
	end
	if not makePlaneIndexVBO then
		goodbye("makePlaneIndexVBO unavailable")
		return false
	end
	if not makeRectVBO then
		goodbye("makeRectVBO unavailable")
		return false
	end

	local planeVBO, numVertices = makePlaneVBO(1, 1, resolution, resolution)
	local planeIndexVBO, numIndices = makePlaneIndexVBO(resolution, resolution)
	local quadVBO, quadNumVertices = makeRectVBO(-1, 0, 1, -1, 0, 1, 1, 0)

	Log("[GlobalFog] planeVBO =", planeVBO, "numVertices =", numVertices)
	Log("[GlobalFog] planeIndexVBO =", planeIndexVBO, "numIndices =", numIndices)
	Log("[GlobalFog] quadVBO =", quadVBO, "quadNumVertices =", quadNumVertices)

	if not planeVBO then
		goodbye("makePlaneVBO returned nil")
		return false
	end
	if not planeIndexVBO then
		goodbye("makePlaneIndexVBO returned nil")
		return false
	end
	if not quadVBO then
		goodbye("makeRectVBO returned nil")
		return false
	end

	quadVAO = gl.GetVAO()
	quadVAO:AttachVertexBuffer(quadVBO)

	fogPlaneVAO = gl.GetVAO()
	fogPlaneVAO:AttachVertexBuffer(planeVBO)
	fogPlaneVAO:AttachIndexBuffer(planeIndexVBO)

	groundFogShader = CheckShader(shaderSourceCache, groundFogShader)
	if not groundFogShader then
		goodbye("Failed to compile Ground Fog GL4")
		return false
	end

	return true
end

--------------------------------------------------------------------------------
-- slider callback
--------------------------------------------------------------------------------

local updateUIFromConfig

local combineShaderTriggers = {
	RESOLUTION = true, -- kept only to rebuild fixed full-res texture when config reloads
	HALFSHIFT = true,
	OFFSETX = true,
	OFFSETY = true,
}

local toggleStateBackup = {
	cloud = {
		CLOUDSTEPS = shaderConfig.CLOUDSTEPS or 16,
		CLOUDSHADOWS = shaderConfig.CLOUDSHADOWS or 8,
		cloudAlpha = (fogUniforms.cloudGlobalColor and fogUniforms.cloudGlobalColor[4]) or 0.98,
	},
	height = {
		heightAlpha = (fogUniforms.heightFogColor and fogUniforms.heightFogColor[4]) or 0.98,
	},
	distance = {
		distanceAlpha = (fogUniforms.distanceFogColor and fogUniforms.distanceFogColor[4]) or 0.35,
	},
}

local function syncToggleBackupsFromCurrentState()
	if (shaderConfig.CLOUDSTEPS or 0) > 0 then
		toggleStateBackup.cloud.CLOUDSTEPS = shaderConfig.CLOUDSTEPS
	end
	if (shaderConfig.CLOUDSHADOWS or 0) > 0 then
		toggleStateBackup.cloud.CLOUDSHADOWS = shaderConfig.CLOUDSHADOWS
	end
	if fogUniforms.cloudGlobalColor and (fogUniforms.cloudGlobalColor[4] or 0) > 0 then
		toggleStateBackup.cloud.cloudAlpha = fogUniforms.cloudGlobalColor[4]
	end
	if fogUniforms.heightFogColor and (fogUniforms.heightFogColor[4] or 0) > 0 then
		toggleStateBackup.height.heightAlpha = fogUniforms.heightFogColor[4]
	end
	if fogUniforms.distanceFogColor and (fogUniforms.distanceFogColor[4] or 0) > 0 then
		toggleStateBackup.distance.distanceAlpha = fogUniforms.distanceFogColor[4]
	end
end

local function applyLayerToggle(name, value)
	value = (tonumber(value) or 0) >= 1 and 1 or 0

	if name == "CLOUDSENABLED" then
		if value == 0 then
			syncToggleBackupsFromCurrentState()
			shaderConfig.CLOUDSTEPS = 0
			shaderConfig.CLOUDSHADOWS = 0
			if fogUniforms.cloudGlobalColor then
				fogUniforms.cloudGlobalColor[4] = 0
			end
		else
			shaderConfig.CLOUDSTEPS = math.max(1, toggleStateBackup.cloud.CLOUDSTEPS or 16)
			shaderConfig.CLOUDSHADOWS = math.max(0, toggleStateBackup.cloud.CLOUDSHADOWS or 8)
			if fogUniforms.cloudGlobalColor then
				fogUniforms.cloudGlobalColor[4] = math.max(0.001, toggleStateBackup.cloud.cloudAlpha or 0.98)
			end
		end
	elseif name == "HEIGHTFOGENABLED" then
		if value == 0 then
			syncToggleBackupsFromCurrentState()
			if fogUniforms.heightFogColor then
				fogUniforms.heightFogColor[4] = 0
			end
		else
			if fogUniforms.heightFogColor then
				fogUniforms.heightFogColor[4] = math.max(0.001, toggleStateBackup.height.heightAlpha or 0.98)
			end
		end
	elseif name == "DISTANCEFOGENABLED" then
		if value == 0 then
			syncToggleBackupsFromCurrentState()
			if fogUniforms.distanceFogColor then
				fogUniforms.distanceFogColor[4] = 0
			end
		else
			if fogUniforms.distanceFogColor then
				fogUniforms.distanceFogColor[4] = math.max(0.001, toggleStateBackup.distance.distanceAlpha or 0.35)
			end
		end
	else
		return false
	end

	shaderConfig[name] = value
	shaderSourceCache.forceupdate = true
	groundFogShader = CheckShader(shaderSourceCache, groundFogShader)

	if document then
		updateUIFromConfig()
	end

	return true
end

local function fogUniformChangedCallback(name, value, index, oldvalue)
	SetFogParams(name, value, index)

	local numericOldValue = tonumber(oldvalue)
	if numericOldValue == nil or value ~= numericOldValue then
		if name == "shadowResolutionScale" and widget and widget.ViewResize then
			widget:ViewResize()
		end
	end
end


local function shaderDefinesChangedCallback(name, value, index, oldvalue)
	if name == "RESOLUTION" then
		value = 1
	end

	Log(string.format(
		"shaderDefinesChangedCallback() name=%s, value=%s, shaderConfig[%s]=%s",
		tostring(name), tostring(value), tostring(name), tostring(shaderConfig[name])
	))

	if oldvalue == nil or value ~= oldvalue then
		if name == "CLOUDSENABLED" or name == "HEIGHTFOGENABLED" or name == "DISTANCEFOGENABLED" then
			applyLayerToggle(name, value)
			return
		end

		if shaderConfig[name] ~= nil then
			shaderConfig[name] = value
		end

		shaderSourceCache.forceupdate = true
		groundFogShader = CheckShader(shaderSourceCache, groundFogShader)

		if combineShaderTriggers[name] then
			makeFogTexture()
			combineShaderSourceCache.forceupdate = true
			combineShader = CheckShader(combineShaderSourceCache, combineShader)
		end
	end
end

local shaderDefinedSliders = {
	windowtitle = "Fog Defines",
	name = "shaderDefinedSliders",
	left = vsx - 540,
	bottom = 200,
	right = vsx - 540 + 250,
	sliderheight = 20,
	valuetarget = shaderConfig,
	sliderParamsList = definesSlidersParamsList,
	callbackfunc = shaderDefinesChangedCallback
}
shaderDefinedSliders.top = shaderDefinedSliders.bottom + shaderDefinedSliders.sliderheight * (#definesSlidersParamsList + 3)

local shaderDefinedSlidersLayer, shaderDefinedSlidersWindow
local initfps = 1
local lastfps = 1

--------------------------------------------------------------------------------
-- initialize / shutdown
--------------------------------------------------------------------------------

function widget:Initialize()
	Log("[GlobalFog] Loaded widget")
	initfps = Spring.GetFPS()
	minHeight, maxHeight = Spring.GetGroundExtremes()

	if WG["infolosapi"] then
		Log("Global Fog using INFOLOS api")
	else
		goodbye("Global Fog REQUIRES Infolos API widget, please enable it first")
		return
	end

	if Spring.GetConfigString("AllowDeferredMapRendering") == "0"
		or Spring.GetConfigString("AllowDeferredModelRendering") == "0" then
		Spring.Echo("Ground Fog GL4 requires AllowDeferredMapRendering and AllowDeferredModelRendering to be enabled in springsettings.cfg!")
		widgetHandler:RemoveWidget()
		return
	end
	autoLoadMapConfig()
	widget:ViewResize()

	if initGL4() == false then
		return
	end

	combineShader = CheckShader(combineShaderSourceCache, combineShader)
	if combineShader == nil then
		widgetHandler:RemoveWidget()
		goodbye("[Global Fog::combineShader] combineShader compilation failed")
		return false
	end

	shadowShader = CheckShader(shadowMinifierShaderSourceCache, shadowShader)
	if shadowShader == nil then
		widgetHandler:RemoveWidget()
		goodbye("[Global Fog::shadowShader] shadowShader compilation failed")
		return false
	end

	-- BAR import: do not expose fog param setters globally, otherwise external
	-- day/night or atmosphere cycle code can drive this widget again.
	WG.GlobalFog_AddShockwave = NoShockwaveCompat
	WG.GlobalFog_AddCEGShockwave = NoShockwaveCompat
	WG.GlobalFog_RegisterCEGShockwaveProfile = NoShockwaveCompat
	if widgetHandler and widgetHandler.RegisterGlobal then
		widgetHandler:RegisterGlobal("GlobalFog_AddShockwave", NoShockwaveCompat)
		widgetHandler:RegisterGlobal("GlobalFog_AddCEGShockwave", NoShockwaveCompat)
		widgetHandler:RegisterGlobal("GlobalFog_RegisterCEGShockwaveProfile", NoShockwaveCompat)
	end

	if RmlUi then
		widget.rmlContext = RmlUi.CreateContext(widget.whInfo.name)

		if not widget.rmlContext then
			Spring.Echo("[Global Fog GL4] failed to create RmlUi context")
		else
			Log("[Global Fog GL4] RmlUi context created")

			if widget.rmlContext.LoadFontFace then
				Log("[Global Fog GL4] Exo2-Regular exists:", VFS.FileExists("fonts/Exo2-Regular.otf"))
				Log("[Global Fog GL4] Exo2-SemiBold exists:", VFS.FileExists("fonts/Exo2-SemiBold.otf"))

				Log("[Global Fog GL4] LoadFontFace regular:", widget.rmlContext:LoadFontFace("fonts/Exo2-Regular.otf"))
				Log("[Global Fog GL4] LoadFontFace bold:", widget.rmlContext:LoadFontFace("fonts/Exo2-SemiBold.otf"))
			else
				Log("[Global Fog GL4] widget.rmlContext.LoadFontFace missing")
			end

			dataModelHandle = widget.rmlContext:OpenDataModel("data_model_test", {
				exampleValue = "Changes when clicked",
				exampleEventHook = function(...) eventCallback(...) end,
				callShaderDefinesChangedCallback = shaderDefinesChangedCallback,
				my_rect = "",
				context_name_list = "",
			})

			eventCallback = function(ev, ...)
				Log(ev.parameters.mouse_x, ev.parameters.mouse_y, ev.parameters.button, ...)
				local options = {"ow", "oof!", "stop that!", "clicking go brrrr"}
				dataModelHandle.exampleValue = options[math.random(1, 4)]
			end



			document = widget.rmlContext:LoadDocument("LuaUI/Widgets/rml_widget_assets/global_fog.rml", widget)

			if not document then
				Spring.Echo("[Global Fog GL4] failed to load RML document")
			end
		end
	end

	if document then
		local function createSliderElement(sliderConfig, eventCb)
			local sliderElement = document:CreateElement("label")
			local maxstring = string.format("%." .. sliderConfig.digits .. "f", sliderConfig.max)
			local maxstringPadded = string.format("%5s", maxstring):gsub(" ", "&#x2007;")

			local sliderhtmlstring = string.format(
				'<div class="code" style="text-align: right; padding: 0; line-height: 0.9;"> %s %f <input type="range" id="%s" min="%f" max="%f" step="%f" value="%f" /> %s </div>',
				sliderConfig.displayName or sliderConfig.name,
				sliderConfig.value,
				sliderConfig.name,
				sliderConfig.min,
				sliderConfig.max,
				(sliderConfig.step or math.pow(10, -1 * sliderConfig.digits)),
				sliderConfig.value,
				maxstringPadded
			)

			sliderElement.inner_rml = sliderhtmlstring

			sliderElement:AddEventListener("change", function(event)
				local newvalue = nil
				if event and event.parameters and event.parameters.value then
					newvalue = tonumber(event.parameters.value)
				end

				local slider = event.target_element
				if slider.attributes.value == newvalue then
					Log("Slider value did not change", slider.id, slider.attributes.value, newvalue)
					return
				end

				local value = newvalue or tonumber(slider.attributes.value)
				eventCb(slider.id, value, sliderConfig.paramIndex, slider.attributes.value)
			end)

			return sliderElement
		end

		local function createAllGroupedSliders()
			Log(string.format("[GlobalFog] UI slider counts defines=%d uniforms=%d", #definesSlidersParamsList, #uniformSliderParamsList))
			local allSliders = {}

			for _, slider in ipairs(definesSlidersParamsList) do
				table.insert(allSliders, {
					type = "define",
					config = slider,
					eventCallback = shaderDefinesChangedCallback
				})
			end

			for _, slider in ipairs(uniformSliderParamsList) do
				table.insert(allSliders, {
					type = "uniform",
					config = slider,
					eventCallback = fogUniformChangedCallback
				})
			end


			local sliderGroups = {}
			for _, sliderData in ipairs(allSliders) do
				local group = sliderData.config.group or "other"
				if not sliderGroups[group] then
					sliderGroups[group] = {}
				end
				table.insert(sliderGroups[group], sliderData)
			end

			local groupOrder = {"global", "ground", "height", "other", "cloud", "cloudshadows", "distance", "underwater", "shadow", "scavenger"}

			for _, groupKey in ipairs(groupOrder) do
				local groupSliders = sliderGroups[groupKey]
				if groupSliders and #groupSliders > 0 then
					local divId = "fogparameters-" .. (groupKey or "other")
					local parentDiv = document:GetElementById(divId)

					if not parentDiv then
						Log("Warning: Could not find parent element " .. divId .. " for group " .. groupKey)
					else
						for _, sliderData in ipairs(groupSliders) do
							if sliderData.type == "define" then
								local config = {
									name = sliderData.config.name,
									displayName = sliderData.config.displayName or sliderData.config.name,
									min = sliderData.config.min,
									max = sliderData.config.max,
									digits = sliderData.config.digits,
									value = shaderConfig[sliderData.config.name] or sliderData.config.default
								}
								parentDiv:AppendChild(createSliderElement(config, sliderData.eventCallback))
							else
								local defaultType = type(fogUniforms[sliderData.config.name])
								local defaultValues = (defaultType == "table") and fogUniforms[sliderData.config.name] or {fogUniforms[sliderData.config.name]}

								for j, v in ipairs(defaultValues) do
									local config = {
										name = sliderData.config.name,
										displayName = sliderData.config.name .. "." .. (sliderData.config.membernames and sliderData.config.membernames[j] or ""),
										min = sliderData.config.min,
										max = sliderData.config.max,
										digits = sliderData.config.digits,
										value = v or 0.0,
										paramIndex = (defaultType == "table") and j or nil
									}
									parentDiv:AppendChild(createSliderElement(config, sliderData.eventCallback))
								end
							end
						end
					end
				end
			end
		end

		createAllGroupedSliders()

		local buttonsDiv = document:GetElementById("fogbuttons")
		if buttonsDiv then
			local function appendButton(label, onClick)
				local button = document:CreateElement("button")
				button.inner_rml = label
				button:AddEventListener("click", onClick)
				buttonsDiv:AppendChild(button)
				return button
			end

			appendButton("Save", function()
				saveConfig()
			end)

			appendButton("Save Default", function()
				saveDefaultConfig()
			end)

			appendButton("Save Low", function()
				saveNamedPresetConfig("low")
			end)

			appendButton("Save Medium", function()
				saveNamedPresetConfig("medium")
			end)

			appendButton("Save High", function()
				saveNamedPresetConfig("high")
			end)

			debugToggleButton = appendButton("", function()
				DEBUG_LOGS = not DEBUG_LOGS
				UpdateDebugUIButtons()
				Spring.Echo("[GlobalFog] Debug logs: " .. (DEBUG_LOGS and "ON" or "OFF"))
			end)

			drawtimeToggleButton = appendButton("", function()
				SHOW_DRAWTIME = not SHOW_DRAWTIME
				UpdateDebugUIButtons()
				Spring.Echo("[GlobalFog] Draw time overlay: " .. (SHOW_DRAWTIME and "ON" or "OFF"))
			end)

			UpdateDebugUIButtons()

			local loadLabel = document:CreateElement("label")
			loadLabel.inner_rml = "Load:"
			buttonsDiv:AppendChild(loadLabel)

			local configDropdown = createConfigDropDown(document)
			if configDropdown then
				configDropdown.style.width = "100%"
				buttonsDiv:AppendChild(configDropdown)
			end
		end

		document:ReloadStyleSheet()
		document:Show()

		if widget.rmlContext and widget.rmlContext.Update then
			widget.rmlContext:Update()
		end

		local slidersVisible = true
		local toggleButton = document:GetElementById("toggleSliders")
		local slidersDiv = document:GetElementById("sliders")
		local buttonsDiv2 = document:GetElementById("buttons")

		if toggleButton and slidersDiv then
			toggleButton:AddEventListener("click", function()
				slidersVisible = not slidersVisible
				if slidersVisible then
					slidersDiv.style.display = "flex"
					if buttonsDiv2 then
						buttonsDiv2.style.display = "flex"
					end
					toggleButton.inner_rml = "Hide"
				else
					slidersDiv.style.display = "none"
					if buttonsDiv2 then
						buttonsDiv2.style.display = "none"
					end
					toggleButton.inner_rml = "Show"
				end

				if widget.rmlContext and widget.rmlContext.Update then
					widget.rmlContext:Update()
				end
			end)
		end
	end
end
function widget:Shutdown()
	if fogTexture then gl.DeleteTexture(fogTexture) end
	if shadowTexture then gl.DeleteTexture(shadowTexture) end
	WG.GlobalFog_AddShockwave = nil
	WG.GlobalFog_AddCEGShockwave = nil
	WG.GlobalFog_RegisterCEGShockwaveProfile = nil
	if widgetHandler and widgetHandler.DeregisterGlobal then
		widgetHandler:DeregisterGlobal("GlobalFog_AddShockwave")
		widgetHandler:DeregisterGlobal("GlobalFog_AddCEGShockwave")
		widgetHandler:DeregisterGlobal("GlobalFog_RegisterCEGShockwaveProfile")
	end

	if fogUniformSliders and fogUniformSliders.Destroy then fogUniformSliders:Destroy() end
	if shaderDefinedSlidersLayer and shaderDefinedSlidersLayer.Destroy then shaderDefinedSlidersLayer:Destroy() end

	if RmlUi then
		if document then
			document:Close()
		end
		if widget.rmlContext then
			RmlUi.RemoveContext(widget.whInfo.name)
		end
	end
end

--------------------------------------------------------------------------------
-- update / draw
--------------------------------------------------------------------------------

local windFractFull = {0, 0, 0, 0}
local lastGameFrame = Spring.GetGameFrame()
local prevTimeOffset = Spring.GetFrameTimeOffset()

function widget:Update()
	local thisGameFrame = Spring.GetGameFrame()
	local thisTimeOffset = Spring.GetFrameTimeOffset()
	local deltaOffset = math.max(0, thisTimeOffset - prevTimeOffset)

	prevTimeOffset = thisTimeOffset
	local deltaFrame = thisGameFrame - lastGameFrame + deltaOffset

	local windDirX, _, windDirZ = Spring.GetWind()
	local windStrength = shaderConfig.WINDSTRENGTH * deltaFrame
	local deltaWindX = windDirX * windStrength
	local deltaWindZ = windDirZ * windStrength

	windFractFull[3] = windFractFull[3] + deltaWindX
	windFractFull[4] = windFractFull[4] + deltaWindZ
	windFractFull[1] = windFractFull[1] + deltaWindX
	windFractFull[2] = windFractFull[2] + deltaWindZ

	local noiseScale = shaderConfig.NOISESCALE / 1024.0

	local windXFract = windFractFull[1] * noiseScale
	if windXFract > 1 or windXFract < 0 then
		Log("windXFract", windXFract, windFractFull[1])
		windFractFull[1] = 1024.0 * (windXFract - math.floor(windXFract)) / shaderConfig.NOISESCALE
	end

	local windZFract = windFractFull[2] * noiseScale
	if windZFract > 1 or windZFract < 0 then
		Log("windZFract", windZFract, windFractFull[2])
		windFractFull[2] = 1024.0 * (windZFract - math.floor(windZFract)) / shaderConfig.NOISESCALE
	end
		if thisGameFrame % 15 == 0 then
		UpdateRadarCircles()
	end


	lastGameFrame = thisGameFrame
end

local toTexture = true

local function renderToTextureFunc()
	gl.Blending(GL.ONE, GL.ZERO)
	fogPlaneVAO:DrawElements(GL.TRIANGLES)
end

local function minifyShadowToTextureFunc()
	gl.Texture(0, "$shadow")
	quadVAO:DrawArrays(GL.TRIANGLES)
end

function widget:Explosion(weaponDefID, px, py, pz, ownerID)
	return false
end

function YCLine(horz, vert)
	local vsx2, vsy2 = Spring.GetViewGeometry()
	if horz then
		gl.Color(1,1,0,1)
		gl.Rect(2, horz, vsx2 - 2, horz + 1)
		gl.Color(0,1,1,1)
		gl.Rect(2, horz, vsx2 - 2, horz - 1)
	else
		gl.Color(1,1,0,1)
		gl.Rect(vert, 2, vert + 1, vsy2 - 2)
		gl.Color(0,1,1,1)
		gl.Rect(vert, 2, vert - 1, vsy2 - 2)
	end
end

function widget:DrawWorld()
	if autoreload then
		groundFogShader = CheckShader(shaderSourceCache, groundFogShader)
		combineShader = CheckShader(combineShaderSourceCache, combineShader)
		shadowShader = CheckShader(shadowMinifierShaderSourceCache, shadowShader)
	end

	if shaderConfig.ENABLED == 0 then
		initfps = Spring.GetFPS()
		return
	end

	if not groundFogShader then
		return
	end

	gl.DepthMask(false)
	gl.Culling(GL.FRONT)

	if shaderConfig.MINISHADOWS == 1 and shadowShader and quadVAO and shadowTexture then
		shadowShader:Activate()
		gl.RenderToTexture(shadowTexture, minifyShadowToTextureFunc)
		shadowShader:Deactivate()
	end

	gl.Texture(0, "$map_gbuffer_zvaltex")
	gl.Texture(1, "$model_gbuffer_zvaltex")
	gl.Texture(2, distortiontex)

	if shaderConfig.USELOS == 1 and WG["infolosapi"] and WG["infolosapi"].GetInfoLOSTexture then
		gl.Texture(3, WG["infolosapi"].GetInfoLOSTexture())
	else
		gl.Texture(3, "$info")
	end

	if shaderConfig.MINISHADOWS == 1 then
		gl.Texture(4, shadowTexture)
	else
		gl.Texture(4, "$shadow")
	end

	gl.Texture(5, noisetex3dcube)

	if shaderConfig.USEMINIMAP > 0 then
		gl.Texture(6, "$minimap")
	end

	packedNoise = "LuaUI/images/noisetextures/worley3_256x128x64_RBGA_LONG." .. ((shaderConfig.USEDDS == 1) and "dds" or "png")
	gl.Texture(7, packedNoise)
	gl.Texture(8, blueNoise64)
	gl.Texture(9, uniformNoiseTex)

	groundFogShader:Activate()
	local camX, camY, camZ = Spring.GetCameraPosition()
	local groundY = Spring.GetGroundHeight(camX, camZ) or 0
	local camHeightAboveGround = math.max(0, camY - groundY)

	groundFogShader:SetUniformFloat("cameraWorldPos", camX, camY, camZ, 1.0)
	groundFogShader:SetUniformFloat("cameraHeightAboveGround", camHeightAboveGround)
	groundFogShader:SetUniformFloat("cameraWorldPos", camX, camY, camZ, 1.0)
	groundFogShader:SetUniformFloat("windFractFull", windFractFull[1], windFractFull[2], windFractFull[3], windFractFull[4])
	groundFogShader:SetUniformInt("radarCount", #radarCircles)

	for i = 1, MAX_RADARS do
		local radar = radarCircles[i]
		if radar then
			groundFogShader:SetUniformFloat("radarCenters[" .. (i - 1) .. "]", radar.x, radar.z, radar.r, 0.0)
		else
			groundFogShader:SetUniformFloat("radarCenters[" .. (i - 1) .. "]", -999999.0, -999999.0, 0.0, 0.0)
		end
	end

	for uniformName, uniformValue in pairs(fogUniforms) do
		local vtype = type(uniformValue)
		if vtype == "number" then
			groundFogShader:SetUniformFloat(uniformName, uniformValue)
		elseif vtype == "table" then
			groundFogShader:SetUniformFloat(uniformName, uniformValue[1], uniformValue[2], uniformValue[3], uniformValue[4])
		end
	end

	toTexture = shaderConfig.RESOLUTION ~= 1

	if toTexture then
		if fogTexture and fogPlaneVAO then
			gl.RenderToTexture(fogTexture, renderToTextureFunc)
		end
	else
		if fogPlaneVAO then
			gl.Blending(GL.ONE, GL.ONE_MINUS_SRC_ALPHA)
			fogPlaneVAO:DrawElements(GL.TRIANGLES)
		end
	end

	groundFogShader:Deactivate()

	gl.Culling(GL.BACK)
	gl.Culling(false)

	if toTexture and shaderConfig.COMBINESHADER == 1 and combineShader and fogTexture then
		gl.Blending(GL.ONE, GL.ONE_MINUS_SRC_ALPHA)
		combineShader:Activate()
		combineShader:SetUniformFloat("resolution", shaderConfig.RESOLUTION)
		gl.Texture(2, fogTexture)
		gl.TexRect(-1, -1, 1, 1, 0, 0, 1, 1)
		combineShader:Deactivate()
	end

	for i = 0, 9 do
		gl.Texture(i, false)
	end

	gl.Blending(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)
	gl.DepthMask(false)
end

--------------------------------------------------------------------------------
-- misc / debug
--------------------------------------------------------------------------------

local function DumpShaderSource(srccache)
	for keyname, fileextension in pairs({vsSrcComplete = ".vert", fsSrcComplete = ".frag", gsSrcComplete = ".geom"}) do
		if srccache[keyname] then
			local outf = io.open(srccache.shaderName .. fileextension, "w")
			outf:write(srccache[keyname])
			outf:close()
		end
	end
end

function widget:TextCommand(cmd)
	if string.find(cmd, "fogdrawtime", nil, true) then
		SHOW_DRAWTIME = not SHOW_DRAWTIME
		UpdateDebugUIButtons()
		Spring.Echo("[GlobalFog] Draw time overlay: " .. (SHOW_DRAWTIME and "ON" or "OFF"))
	elseif string.find(cmd, "fogdebug", nil, true) then
		DEBUG_LOGS = not DEBUG_LOGS
		UpdateDebugUIButtons()
		Spring.Echo("[GlobalFog] Debug logs: " .. (DEBUG_LOGS and "ON" or "OFF"))
	elseif string.find(cmd, "fogdumpshaders", nil, true) then
		Spring.Echo("Dumping shaders")
		DumpShaderSource(combineShaderSourceCache)
		DumpShaderSource(shaderSourceCache)
	elseif string.find(cmd, "fogsaveconfig", nil, true) then
		Spring.Echo("Saving fog config...")
		saveConfig()
	elseif string.find(cmd, "fogsavedefault", nil, true) then
		Spring.Echo("Saving default fog config...")
		saveDefaultConfig()
	elseif string.find(cmd, "fogautoload", nil, true) then
		Spring.Echo("Auto-loading fog config for this map...")
		autoLoadMapConfig()
	elseif string.find(cmd, "foglistconfigs", nil, true) then
		Spring.Echo("Available fog configs:")
		local configs = getAvailableConfigs()
		for i, config in ipairs(configs) do
			Spring.Echo(i .. ": " .. config.displayName .. " (" .. config.filepath .. ")")
		end
	elseif string.find(cmd, "fogloadconfig ", nil, true) then
		local index = tonumber(cmd:match("fogloadconfig (%d+)"))
		if index then
			local configs = getAvailableConfigs()
			if configs[index] then
				Spring.Echo("Loading config: " .. configs[index].displayName)
				loadConfig(configs[index].filepath)
			else
				Spring.Echo("Invalid config index. Use /foglistconfigs to see available configs.")
			end
		else
			Spring.Echo("Usage: /fogloadconfig <index>")
		end
	end
end

if autoreload then
	function widget:DrawScreen()
		if not SHOW_DRAWTIME then
			return
		end

		local newfps = math.max(Spring.GetFPS(), 1)

		if shaderSourceCache.updateFlag then
			shaderSourceCache.updateFlag = nil
			lastfps = newfps
		end

		local hasprintf = false

		if groundFogShader and groundFogShader.DrawPrintf then
			groundFogShader.DrawPrintf()
			hasprintf = true
		end

		if combineShader and combineShader.DrawPrintf then
			combineShader.DrawPrintf(nil, nil, -70)
			hasprintf = true
		end

		local fogdrawus = (1000 / newfps - 1000 / initfps)
		local fogdrawlast = (1000 / lastfps - 1000 / initfps)
		if fogdrawlast == 0 then
			fogdrawlast = 0.001
		end

		local debugline = ""
		if hasprintf then
			debugline = debugline .. "PRINTF IS ON, PERF NUMBERS MEAN NOTHING!\n"
		end
		debugline = debugline .. string.format("Fog draw time = %.3f ms, previous = %.3f ms", fogdrawus, fogdrawlast)

		local percentChange = 100 * fogdrawus / fogdrawlast - 100.0
		debugline = debugline .. "\n" .. string.format(
			"%.3f delta ms (%.1f%%) since last recompilation \n%.3f ms total draw time\nNo fog FPS = %d, current FPS =%d",
			fogdrawus - fogdrawlast,
			percentChange,
			1000 / newfps,
			initfps,
			newfps
		)

		gl.Text(debugline, vsx - 800, 80, 16, "d")
	end
end
