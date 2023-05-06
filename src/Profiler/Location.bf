using System;
using System.Collections;

namespace Nova.Profiler;

class Location {
	public String name;
	public int line;

	private this(BumpAllocator alloc, StringView type, StringView member, bool isMemberName, int line) {
		this.name = new:alloc $"{GetType(type)}.{isMemberName ? member : GetFunctionName(member)}";
		this.line = line;
	}

	private static StringView GetType(StringView type) {
		var type;

		int i = type.IndexOf('<');
		if (i != -1) type = type.Substring(0, i);

		return type.Substring(type.LastIndexOf('.') + 1);
	}

	private static StringView GetFunctionName(StringView member) {
		var member;

		int i = member.IndexOf('(');
		if (i != -1) member = member.Substring(0, i);

		i = member.LastIndexOf('.');
		if (i != -1) member = member.Substring(i + 1);

		i = member.LastIndexOf('<');
		if (i != -1) member = member.Substring(0, i);

		return member;
	}
}

static class Locations {
	private static BumpAllocator alloc = new .() ~ delete _;
	private static List<Location> locations = new .() ~ delete _;

	public static uint16 Create(StringView name = "", String type = Compiler.CallerTypeName, String member = Compiler.CallerMemberName, int line = Compiler.CallerLineNum) {
		locations.Add(new:alloc [Friend].(alloc, type, name.IsEmpty ? member : name, !name.IsEmpty, line));
		return (.) locations.Count;
	}

	public static Location Get(uint16 index) {
		return locations[index - 1];
	}
}