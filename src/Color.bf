using System;

namespace Nova;

[CRepr]
struct Color {
	public uint8 r, g, b;

	public this(uint8 r, uint8 g, uint8 b) {
		this.r = r;
		this.g = g;
		this.b = b;
	}
}