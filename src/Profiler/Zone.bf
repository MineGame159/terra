using System;

namespace Terra.Profiler;

struct Zone : IDisposable {
	int64 start;

	public this(uint16 locationI) {
		EventQueue.Begin(locationI);
		start = Internal.GetTickCountMicro();
	}

	public void Dispose() {
		EventQueue.End(Internal.GetTickCountMicro() - start);
	}
}