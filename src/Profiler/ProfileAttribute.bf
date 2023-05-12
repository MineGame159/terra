using System;
using System.Reflection;

namespace Terra.Profiler;

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
			if (__locationI == 0) __locationI = Terra.Profiler.Locations.Create();

			Terra.Profiler.Zone __zone = .(__locationI);
			""");

		if (dispose) {
			Compiler.EmitMethodExit(methodInfo, """
				__zone.Dispose();
				""");
		}
	}
}