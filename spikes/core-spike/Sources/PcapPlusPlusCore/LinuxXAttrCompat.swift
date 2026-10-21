// Linux compatibility: match Darwin's xattr signatures so upstream call
// sites compile unchanged. Linux requires a namespace prefix (user.) for
// unprivileged extended attributes.
#if os(Linux)
import Glibc

@_silgen_name("setxattr")
private func _tcv_setxattr(
    _ path: UnsafePointer<CChar>, _ name: UnsafePointer<CChar>,
    _ value: UnsafeRawPointer?, _ size: Int, _ flags: Int32
) -> Int32

@_silgen_name("getxattr")
private func _tcv_getxattr(
    _ path: UnsafePointer<CChar>, _ name: UnsafePointer<CChar>,
    _ value: UnsafeMutableRawPointer?, _ size: Int
) -> Int

@_silgen_name("removexattr")
private func _tcv_removexattr(
    _ path: UnsafePointer<CChar>, _ name: UnsafePointer<CChar>, _ flags: Int32
) -> Int32

private func namespaced(_ name: String) -> String {
    name.hasPrefix("user.") || name.hasPrefix("trusted.") || name.hasPrefix("security.")
        ? name : "user." + name
}

func setxattr(
    _ path: String, _ name: String, _ value: UnsafeRawPointer?,
    _ size: Int, _ position: UInt32, _ options: Int32
) -> Int32 {
    path.withCString { p in
        namespaced(name).withCString { n in
            _tcv_setxattr(p, n, value, size, options)
        }
    }
}

func getxattr(
    _ path: String, _ name: String, _ value: UnsafeMutableRawPointer?,
    _ size: Int, _ position: UInt32, _ options: Int32
) -> Int {
    path.withCString { p in
        namespaced(name).withCString { n in
            _tcv_getxattr(p, n, value, size)
        }
    }
}

func removexattr(_ path: String, _ name: String, _ options: Int32) -> Int32 {
    path.withCString { p in
        namespaced(name).withCString { n in
            _tcv_removexattr(p, n, options)
        }
    }
}
#endif
