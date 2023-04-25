using System;

namespace Nova.Math.Tests;

static class VecTests {
	private static Vec3f VEC = .(1, 2, 3);

	[Test]
	public static void Constructors() {
		Equals(Vec2f(1), .(1, 1));
		Equals(Vec2f(1, 2), .(1, 2));
		Equals(Vec2f(.(1, 2)), .(1, 2));
		Equals(Vec2f.ZERO, .(0, 0));
		Equals(Vec2f.MIN, .(float.MinValue, float.MinValue));
		Equals(Vec2f.MAX, .(float.MaxValue, float.MaxValue));

		Equals(Vec3f(1), .(1, 1, 1));
		Equals(Vec3f(1, 2, 3), .(1, 2, 3));
		Equals(Vec3f(.(1, 2, 3)), .(1, 2, 3));
		Equals(Vec3f.ZERO, .(0, 0, 0));
		Equals(Vec3f.MIN, .(float.MinValue, float.MinValue, float.MinValue));
		Equals(Vec3f.MAX, .(float.MaxValue, float.MaxValue, float.MaxValue));

		Equals(Vec4f(1), .(1, 1, 1, 1));
		Equals(Vec4f(1, 2, 3, 4), .(1, 2, 3, 4));
		Equals(Vec4f(.(1, 2, 3, 4)), .(1, 2, 3, 4));
		Equals(Vec4f.ZERO, .(0, 0, 0, 0));
		Equals(Vec4f.MIN, .(float.MinValue, float.MinValue, float.MinValue, float.MinValue));
		Equals(Vec4f.MAX, .(float.MaxValue, float.MaxValue, float.MaxValue, float.MaxValue));
	}

	[Test]
	public static void Indexing() {
		Equals(VEC[0], 1);
		Equals(VEC[1], 2);
		Equals(VEC[2], 3);
		
		Equals(VEC.x, 1);
		Equals(VEC.y, 2);
		Equals(VEC.z, 3);
	}

	[Test]
	public static void Negation() {
		Equals(-VEC, .(-1, -2, -3));
	}

	[Test]
	public static void Addition() {
		Equals(VEC + VEC, .(2, 4, 6));
		Equals(VEC + 1, .(2, 3, 4));
		Equals(1 + VEC, .(2, 3, 4));
	}

	[Test]
	public static void Subtraction() {
		Equals(VEC - VEC, .ZERO);
		Equals(VEC - 1, .(0, 1, 2));
		Equals(1 - VEC, .(0, -1, -2));
	}

	[Test]
	public static void Multiplication() {
		Equals(VEC * VEC, .(1, 4, 9));
		Equals(VEC * 1, VEC);
		Equals(1 * VEC, VEC);
	}
	
	[Test]
	public static void Division() {
		Equals(VEC / VEC, .(1));
		Equals(VEC / 1, VEC);
		Equals(1 / VEC, .(1, 0.5f, 0.33333f));
	}

	[Test]
	public static void Remainder() {
		Equals(VEC % VEC, .ZERO);
		Equals(VEC % 1, .ZERO);
		Equals(1 % VEC, .(0, 1, 1));
	}

	[Test]
	public static void Length() {
		Equals(VEC.LengthSquared, 14);
		Equals(VEC.Length, 3.74166f);
	}

	[Test]
	public static void Normalization() {
		Equals(VEC.Normalized.x, 0.26726f);
		Equals(VEC.Normalized.y, 0.53452f);
		Equals(VEC.Normalized.z, 0.80178f);

		Equals(VEC.Normalized.LengthSquared, 1);
		Equals(VEC.Normalized.Length, 1);
	}

	[Test]
	public static void Cross() {
		Equals(VEC.Cross(VEC), .ZERO);
	}

	[Test]
	public static void MaxMinClamp() {
		Equals(VEC.Min(.ZERO), .(0));
		Equals(VEC.Max(.ZERO), .VEC);
		Equals(VEC.Clamp(1, 2), .(1, 2, 2));
	}

	[Test]
	public static void Power() {
		Equals(VEC.Pow(2), .(1, 4, 9));
		Equals(VEC.Pow(.(2, 3, 4)), .(1, 8, 81));
	}

	[Test]
	public static void Lerp() {
		Equals(VEC.Lerp(VEC * 2, 0.5f), .(1.5f, 3, 4.5f));
	}

	[Test]
	public static void Absolute() {
		Equals(Vec3f(2, -9, -0.05f).Absolute, .(2, 9, 0.05f));
	}

	[Test]
	public static void Casts() {
		Equals((Vec3f) (Vec2f) VEC, .(1, 2, 0));
		Equals((Vec4f) (Vec2f) VEC, .(1, 2, 0, 0));

		Equals((Vec2f) VEC, .(1, 2));
		Equals((Vec4f) VEC, .(1, 2, 3, 0));

		Equals((Vec2f) (Vec4f) VEC, .(1, 2));
		Equals((Vec3f) (Vec4f) VEC, .(1, 2, 3));
	}

	// Utils

	private static void Equals(float v, float target, String error = Compiler.CallerExpression[0], String filePath = Compiler.CallerFilePath, int line = Compiler.CallerLineNum) {
		Test.Assert(v >= target - 0.00001f && v <= target + 0.00001f, error, filePath, line);
	}

	private static void Equals<C>(Vec<float, C> v, Vec<float, C> target, String error = Compiler.CallerExpression[0], String filePath = Compiler.CallerFilePath, int line = Compiler.CallerLineNum) where C : const int {
		for (let i < C) {
			Equals(v[i], target[i], error, filePath, line);
		}
	}
}