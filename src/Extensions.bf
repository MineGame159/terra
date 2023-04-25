namespace System;

extension Result<T> {
	public mixin GetOrPropagate() {
		if (this == .Err) return .Err;
		Value
	}
}

extension Console {
	public static Result<void> MyReadLine(String str) {
		while (true) {
			char8 c = Console.Read().GetOrPropagate!();

			if (c == '\n' || c == '\r') {
				Console.WriteLine();
				break;
			}
			
			if (c == '\b') {
				if (str.Length > 0) {
					str.RemoveFromEnd(1);

					Console.MyCursorLeft--;
					Console.Write(' ');
					Console.MyCursorLeft--;
				}
			}
			else {
				str.Append(c);
				Console.Write(c);
			}
		}

		return .Ok;
	}

	public static int32 MyCursorLeft
	{
		public get
		{
			let handle = GetStdHandle(STD_OUTPUT_HANDLE);
			CONSOLE_SCREEN_BUFFER_INFO consoleInfo = .();
			GetConsoleScreenBufferInfo(handle,out consoleInfo);
			return consoleInfo.mCursorPosition[0]; //1 = y position
		}
		public set
		{
			//This has to be done afaik to ensure x stays the same
			let handle = GetStdHandle(STD_OUTPUT_HANDLE);
			CONSOLE_SCREEN_BUFFER_INFO consoleInfo = .();
			GetConsoleScreenBufferInfo(handle,out consoleInfo);

			SetConsoleCursorPosition(handle, COORD((.)value,(.)consoleInfo.mCursorPosition[1]));
		}
	}
}