using System;

namespace Nova;

// https://prng.di.unimi.it/xoshiro128plus.c
class MyRandom {
	private const float UNIT = 1f / (1 << 24);

	private uint32[4] s;

	public this() {
		Random random = scope .((.) Platform.BfpSystem_GetTimeStamp());

		s[0] = random.NextU32();
		s[1] = random.NextU32();
		s[2] = random.NextU32();
		s[3] = random.NextU32();
	}

	public float NextFloat() {
		return (float) (Next() >> 8) * UNIT;
	}

	[Inline]
	private uint32 Next() {
		uint32 result = s[0] + s[3];

		uint32 t = s[1] << 9;

		s[2] ^= s[0];
		s[3] ^= s[1];
		s[1] ^= s[2];
		s[0] ^= s[3];

		s[2] ^= t;

		s[3] = Rotl(s[3], 11);

		return result;
	}

	[Inline]
	private static uint32 Rotl(uint32 x, int k) {
		return (x << k) | (x >> (32 - k));
	}
}