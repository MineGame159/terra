using System;
using System.IO;
using System.Collections;

namespace Terra.Scene.Loaders;

struct LineEnumerator : IEnumerator<int> {
	private StreamReader reader;
	private String line;

	public this(StreamReader reader, String line) {
		this.reader = reader;
		this.line = line;
	}

	public Result<int> GetNext() {
		while (true) {
			if (GetNextRaw() == .Err)
				return .Err;
			
			if (!line.IsEmpty && line[0] != '#')
				return 0;
		}
	}

	private Result<void> GetNextRaw() {
		line.Clear();

		if (reader.ReadLine(line) == .Err)
			return .Err;

		line.Trim();
		return .Ok;
	}
}