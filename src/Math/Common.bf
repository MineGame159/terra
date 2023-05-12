using System;

namespace Terra.Math;

struct _Yes;
struct _No;

struct _IsEqual<T, U>
    where T : const int
    where U : const int
{
    public typealias Result = comptype(_isEqual(T, U));
	
    [Comptime]
    private static Type _isEqual(int lhs, int rhs) => lhs == rhs ? typeof(_Yes) : typeof(_No);
}

struct _IsLargerEqual<T, U>
	where T : const int
	where U : const int
{
	public typealias Result = comptype(_isLargerEqual(T, U));

	[Comptime]
	private static Type _isLargerEqual(int lhs, int rhs) => lhs >= rhs ? typeof(_Yes) : typeof(_No);
}