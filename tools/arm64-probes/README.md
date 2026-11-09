# arm64 probes

Small user-space programs used while porting to Apple Silicon. None of them needs the NVIDIA hardware.

- `probe.m`: which Metal private classes exist on this macOS (`MTLIOAccelDevice`, `MTLIOAccel*`, `_MTLDevice`) and the
  class chain of the default (AGX) device.
- `accelprobe.m` + `interpose.c`: hands `MTLIOAccelDevice` an `IOAccelerator` service and logs every IOKit call it makes
  (`DYLD_INSERT_LIBRARIES` interposition of IOServiceOpen / IOConnectCall* / IOConnectMapMemory64 / property reads).
  This is the kernel ABI a new accelerator kext has to answer for Metal to accept a device on Apple Silicon.

Build and run:

    xcrun clang -fobjc-arc -framework Metal -framework Foundation probe.m -o probe && ./probe
    xcrun clang -dynamiclib -framework IOKit -framework CoreFoundation interpose.c -o libiointerpose.dylib
    xcrun clang -fobjc-arc -framework Metal -framework Foundation -framework IOKit accelprobe.m -o accelprobe
    DYLD_INSERT_LIBRARIES=$PWD/libiointerpose.dylib ./accelprobe [IOAccelerator class name]

Result on macOS 27.0.1 / M1 Pro (AGX accelerator as the target): `initWithAcceleratorPort:` opens the accelerator
with user client **type 5**, then calls struct selector **9** (16 B in) and struct selector **2** (600 B out); both
return kIOReturnUnsupported on AGX (whose type-5 client is an IOGPU one) and the init returns nil.

With `FAKE=1` the interposer answers kIOReturnBadArgument/Unsupported with zeroed success, and serves a user-client
type the accelerator lacks with a type-5 connect, so the client walks further. Sequence observed (macOS 27.0.1):

| step | client | call | sizes |
|---|---|---|---|
| 1 | type 5 (device) | struct sel 9 | 16 B in |
| 2 | type 5 | struct sel 2 | 600 B out (device info) |
| 3 | type 5 | struct sel 0 | 64 B out (answered for real by AGX) |
| 4 | type 5 | struct sel 7 | 24 B out |
| 5 | IOSurfaceRoot | sel 13 / 44 / 32 | surface root handshake, not ours |
| 6 | type 6 (shared) | struct sel 9 | 16 B out |
| 7 | type 6 | struct sel 10 | 24 B out, then the process stops (zeroed data) |

Type 5 and 6 match the x86 IOAcceleratorFamily2 user-client types the plugin's reconstructed headers call
IOAccelDevice2 and IOAccelSharedUserClient2; the selector numbers are the ones a new arm64 accelerator must serve.
