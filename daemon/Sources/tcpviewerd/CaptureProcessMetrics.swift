//
//  CaptureProcessMetrics.swift
//  tcpviewerd
//
//  The daemon's own footprint — /proc/self/statm resident pages, the Linux
//  analogue of upstream's phys_footprint reading ("close to the Activity
//  Monitor Memory column"). Upstream samples its app process; the port's
//  daemon owns the packet workspace, so its resident set is the number the
//  status strip should show.
//

import Foundation

enum CaptureProcessMetrics {
    static func memoryBytes() -> UInt64? {
        guard let statm = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8) else {
            return nil
        }
        let fields = statm.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2, let residentPages = UInt64(fields[1]) else {
            return nil
        }
        let pageSize = UInt64(getpagesize())
        return residentPages * pageSize
    }
}
