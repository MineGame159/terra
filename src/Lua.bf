using System;
using System.Interop;

namespace Nova;

static class Lua {
	public typealias State = void*;
	public typealias Error = c_int;

	public typealias Func = function c_int(State state);

	public enum Type : c_int {
		None = -1,
		Nil,
		Bool,
		LightUserData,
		Number,
		String,
		Table,
		Function,
		UserData,
		Thread
	}

	public const c_int REGISTRY_INDEX = -1000000 - 1000;
	public static c_int GetUpValueIndex(c_int index) => REGISTRY_INDEX - index;

	[LinkName("luaL_newstate")]
	public static extern State NewState();

	[LinkName("lua_close")]
	public static extern void CloseState(State state);

	[LinkName("luaL_openlibs")]
	public static extern void OpenLibs(State state);



	[LinkName("luaL_loadfilex")]
	public static extern Error LoadFile(State state, char8* filename, char8* mode = null);

	[LinkName("lua_pcallk")]
	public static extern Error PCall(State state, c_int argCount, c_int resultCount, c_int errFunc, int ctx = 0, void* kFunc = null);



	[LinkName("lua_pushcclosure")]
	public static extern void PushClosure(State state, Func func, c_int upvalueCount = 0);

	[LinkName("lua_setglobal")]
	public static extern void SetGloal(State state, char8* name);

	public static void SetFunction(State state, StringView name, Func func) {
		PushClosure(state, func);
		SetGloal(state, name.ToScopeCStr!());
	}



	[LinkName("lua_gettop")]
	public static extern c_int GetArgCount(State state);

	[LinkName("lua_settop")]
	private static extern void SetTop(State state, c_int index);

	public static void Pop(State state, c_int count = 1) => SetTop(state, -count - 1);

	[LinkName("lua_getfield")]
	public static extern Type GetField(State state, c_int index, char8* name);

	[LinkName("lua_rawgeti")]
	public static extern Type GetRawI(State state, c_int index, int64 n);

	[LinkName("lua_rawseti")]
	public static extern void SetRawI(State state, c_int index, int64 n);

	[LinkName("lua_tonumberx")]
	public static extern double ToNumber(State state, c_int index, c_int* isNumber = null);

	[LinkName("lua_pushnumber")]
	public static extern void PushNumber(State state, double number);

	[LinkName("lua_tolstring")]
	private static extern char8* ToString(State state, int32 index, c_size* length);

	[LinkName("lua_pushstring")]
	public static extern char8* PushString(State state, char8* str);

	public static StringView ToString(State state, int32 index) {
		c_size length = 0;
		char8* str = ToString(state, index, &length);

		return .(str, (.) length);
	}

	[LinkName("lua_setmetatable")]
	public static extern c_int SetMetatable(State state, c_int index);

	[LinkName("lua_createtable")]
	public static extern void CreateTable(State state, c_int narr = 0, c_int nrec = 0);

	[LinkName("lua_setfield")]
	public static extern void SetField(State state, c_int index, char8* name);

	[LinkName("lua_type")]
	public static extern Type GetType(State state, c_int index);

	[LinkName("lua_pushnil")]
	public static extern void PushNil(State state);



	[LinkName("lua_newuserdatauv")]
	private static extern void* NewUserData(State state, c_size size, c_int nuvalue = 0);

	public static void NewUserData<T>(State state, T value) => *(T*) NewUserData(state, (.) sizeof(T)) = value;

	[LinkName("lua_touserdata")]
	private static extern void* ToUserData(State state, c_int index);

	public static T* ToUserData<T>(State state, c_int index) => (.) ToUserData(state, index);



	[LinkName("luaL_error")]
	public static extern Error Error(State state, char8* fmt, ...);
}