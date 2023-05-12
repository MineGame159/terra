using System;

using Terra.Math;

namespace Terra.Scene;

[CRepr]
struct Material {
	public Vec4f albedo;
	public Vec4f emission;

	public float metallic;
	public float subsurface;
	public float roughness = 0.5f;
	public float specularTint;
	public float sheen;
	public float sheenTint = 0.5f;
	public float clearcoat;

	public float clearcoatRoughness;
	public float specTrans;
	public float anisotropic;
	public float ior = 1.5f;

	public uint32 albedoTexture;
	public uint32 metallicRoughnessTexture;
	public uint32 emissionTexture;
	public uint32 normalTexture;

	private float _;
}