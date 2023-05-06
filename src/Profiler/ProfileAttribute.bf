using System;
using System.Reflection;

namespace Nova.Profiler;

[AttributeUsage(.Method)]
struct ProfileAttribute : Attribute, IOnMethodInit {
	private bool dispose;

	public this(bool dispose = true) {
		this.dispose = dispose;
	}

	[Comptime]
	public void OnMethodInit(MethodInfo methodInfo, Self* prev) {
		Compiler.EmitMethodEntry(methodInfo, """
			static uint16 __locationI = 0;
			if (__locationI == 0) __locationI = Nova.Profiler.Locations.Create();

			Nova.Profiler.Zone __zone = .(__locationI);
			""");

		if (dispose) {
			Compiler.EmitMethodExit(methodInfo, """
				__zone.Dispose();
				""");
		}
	}
}