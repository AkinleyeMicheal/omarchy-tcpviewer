# Test Suites

`PcapPlusPlusCoreTests` is the upstream `PcapPlusPlusCoreTests` suite (Swift
Testing) ported unchanged where possible. It is our regression gate for the
capture/dissection core; `TCPViewerIPCTests` covers the daemon's IPC layer.

## Always run with `--no-parallel`

```sh
swift test --no-parallel
```

Wireshark's `epan` session and dissection state are process-global. The upstream
suites mark themselves `@Suite(.serialized)`, but Swift Testing still runs
different suites concurrently, and concurrent suites then contend for the single
Wireshark session (surfacing as "Wireshark is busy with another capture" fallback
dissections and spurious stream-follow failures). `--no-parallel` makes the gate
deterministic.

## Documented Linux divergences in this suite

- Error round-tripping: the native core's ObjC-style `error:` out-parameters are
  reproduced with NSErrors in the `com.proxyman.tcpviewer.NativeBridge` domain so
  codes/messages survive (`TCPViewerCoreError.nativeBridgeNSError`).
- `WiresharkCriticalExceptionLoggerTests` expects the raw GLib message in the
  on-disk log ("Wireshark Message:"); upstream keeps it out of files.
- `WiresharkDependencyPinTests` pins the system-Wireshark policy and a >= 4.7
  version floor instead of the vendored 4.6.6 checkout.
- `WiresharkFollowStreamTests` loads the Wireshark test captures from
  `Fixtures/CaptureFiles` instead of `Vendor/Wireshark/test/captures`.
- Pure-macOS helpers (`mach_task_basic_info`, `Bundle(for:)`) are ported to
  `/proc/self/status` and `Bundle.module`.
