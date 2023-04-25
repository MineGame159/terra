using System;

namespace Nova;

enum LogLevel {
	case Debug, Info, Warning, Error;

	public ConsoleColor Color { get {
		switch (this) {
		case .Debug:	return .DarkGray;
		case .Info:		return .White;
		case .Warning:	return .Yellow;
		case .Error:	return .Red;
		}
	} };

	public override void ToString(String str) {
		switch (this) {
		case .Debug:	str.Append("DEBUG  ");
		case .Info:		str.Append("INFO   ");
		case .Warning:	str.Append("WARNING");
		case .Error:	str.Append("ERROR  ");
		}
	}
}

static class Log {
	public static void Debug(StringView fmt, params Object[] args) => Log(.Debug, fmt, params args);
	public static void Info(StringView fmt, params Object[] args) => Log(.Info, fmt, params args);
	public static void Warning(StringView fmt, params Object[] args) => Log(.Warning, fmt, params args);
	public static void Error(StringView fmt, params Object[] args) => Log(.Error, fmt, params args);

	public static Result<void> ErrorResult(StringView fmt, params Object[] args) {
		Log(.Error, fmt, params args);
		return .Err;
	}

	public static Result<T> ErrorResult<T>(StringView fmt, params Object[] args) {
		Log(.Error, fmt, params args);
		return .Err;
	}

	public static void Log(LogLevel level, StringView fmt, params Object[] args) {
		// Check minimum log level
		//if (MIN_LEVEL > level || DELETED) return;

		// Header
		String msg = scope .("[");
		level.ToString(msg);

#if BF_PLATFORM_WINDOWS
		DateTime time = .Now;
		msg.AppendF(" - {:D2}:{:D2}:{:D2}", time.Hour, time.Minute, time.Second);
#endif
		
		msg.Append("] ");

		// Text
		msg.AppendF(fmt, params args);

		// Log
		//Console.ForegroundColor = level.Color;
		//Console.WriteLine(msg);
	}
}