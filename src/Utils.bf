using System;
using System.Diagnostics;

using Nova.Math;

namespace Nova;

static class Utils {
	private static MyRandom RANDOM = new .() ~ delete _;

	public static float Random() => RANDOM.NextFloat();

	public static float Random(float min, float max) {
		return min + (max - min) * Random();
	}

	public static int RandomInt(int min, int max) => (.) Random(min, max + 1);

	public static T Min<T>(T a, T b) where bool : operator T < T => a < b ? a : b;
	public static T Max<T>(T a, T b) where bool : operator T < T => a < b ? b : a;

	[NoDiscard]
	public static int CombineHashCode(int h1, int h2) => (((h1 << 5) + h1) ^ h2);
	
	public static Vec3f GetDirection(float yaw, float pitch) {
		return .(
			Math.Cos(Math.DegreesToRadians(yaw)) * Math.Cos(Math.DegreesToRadians(pitch)),
			Math.Sin(Math.DegreesToRadians(pitch)),
			Math.Sin(Math.DegreesToRadians(yaw)) * Math.Cos(Math.DegreesToRadians(pitch))
		).Normalized;
	}
}

struct Timer : IDisposable {
	private StringView verb;
	private Stopwatch sw;

	public this(StringView verb) {
		this.verb = verb;
		this.sw = new .(true);
	}

	public void Dispose() {
		sw.Stop();

		if (sw.Elapsed.TotalSeconds < 1) Log.Info("{} in {:0.000} milliseconds", verb, sw.Elapsed.TotalMilliseconds);
		else Log.Info("{} in {:0.000} seconds", verb, sw.Elapsed.TotalSeconds);

		delete sw;
	}
}