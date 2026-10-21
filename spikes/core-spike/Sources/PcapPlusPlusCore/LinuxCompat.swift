// Linux compatibility shims for the Omarchy TCPViewer port.
// AutoreleasingUnsafeMutablePointer exists only with the ObjectiveC runtime;
// on Linux, C `NSError **`-style out-parameters import as UnsafeMutablePointer.
#if os(Linux)
public typealias AutoreleasingUnsafeMutablePointer<Pointee> = UnsafeMutablePointer<Pointee>
#endif

#if os(Linux)
import Glibc

/// Linux has no autorelease pools; drain eagerly (no-op).
public func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result {
    try body()
}

/// Minimal stand-in so upstream `Darwin.close/pread/dup` call sites compile.
/// The real calls go straight to Glibc.
enum Darwin {
    static func close(_ fd: Int32) -> Int32 { Glibc.close(fd) }
    static func dup(_ fd: Int32) -> Int32 { Glibc.dup(fd) }
    static func pread(
        _ fd: Int32, _ buf: UnsafeMutableRawPointer, _ n: Int, _ offset: off_t
    ) -> Int {
        Glibc.pread(fd, buf, n, offset)
    }
}
#endif
