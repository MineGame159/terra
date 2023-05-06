using System;
using System.IO;
using System.Collections;

namespace Nova.Profiler;

static class ProfileTxtExporter {
	private static String str = new .(256) ~ delete _;

	public static Result<void> Export(Profile profile, StringView path) {
		StreamWriter writer = scope .();
		if (writer.Create(path) case .Err) return .Err;

		for (let entry in profile) {
			if (@entry.Index > 0) writer.WriteLine();

			int depth = 0;
			Export(writer, entry, ref depth);
		}

		return .Ok;
	}

	private static void Export(StreamWriter writer, Profile.Entry entry, ref int depth) {
		str.Clear();

		for (let i < depth) str.Append("    ");
		str.AppendF("{}:{}", entry.location.name, entry.location.line);

		int spaces = 100 - str.Length;
		for (let i < spaces) str.Append(' ');

		TimeSpan childrenTime = 0;
		for (let child in entry) childrenTime += child.total;

		let a = entry.total.TotalMilliseconds;
		str.AppendF("{,5} {,16:0.000} {,16:0.000}", entry.calls, a, (entry.total - childrenTime).TotalMilliseconds);

		writer.WriteLine(str);
		depth++;

		for (let child in entry) {
			Export(writer, child, ref depth);
		}

		depth--;
	}
}