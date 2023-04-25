using System;
using System.Interop;

namespace Nova;

static class OID {
	public enum DeviceType : c_int {
		Default,
		CPU
	}

	public enum Format : c_int {
		Undefined,

		Float = 1,
		Float2,
		Float3,
		Float4,

		Half = 257,
		Half2,
		Half3,
		Half4
	}

	public enum Error : c_int {
		None,
		Unknown,
		InvalidArgument,
		InvalidOperation,
		OutOfMemory,
		UnsupportedHardware,
		Cancelled
	}

	[CRepr]
	public struct Device : uint64 {}

	[CRepr]
	public struct Filter : uint64 {}

	public typealias ErrorFunction = function void(void* userPtr, Error error, c_char* message);


	[LinkName("oidnNewDevice")]
	public static extern Device NewDevice(DeviceType type);

	[LinkName("oidnReleaseDevice")]
	public static extern void ReleaseDevice(Device device);

	[LinkName("oidnCommitDevice")]
	public static extern void CommitDevice(Device device);

	[LinkName("oidnSetDeviceErrorFunction")]
	public static extern void SetDeviceErrorFunction(Device device, ErrorFunction func, void* userPtr);


	[LinkName("oidnNewFilter")]
	public static extern Filter NewFilter(Device device, c_char* type);

	[LinkName("oidnReleaseFilter")]
	public static extern void ReleaseFilter(Filter filter);

	[LinkName("oidnSetSharedFilterImage")]
	public static extern void SetSharedFilterImage(Filter filter, c_char* name, void* ptr, Format format, c_size width, c_size height, c_size offset, c_size pixelStride, c_size rowStride);

	[LinkName("oidnCommitFilter")]
	public static extern void CommitFilter(Filter filter);

	[LinkName("oidnExecuteFilter")]
	public static extern void ExecuteFilter(Filter filter);
}