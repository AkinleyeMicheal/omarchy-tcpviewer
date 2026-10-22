//
//  PcapPlusPlusCore.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 23/4/26.
//

import Foundation

public enum PcapPlusPlusCoreModule {
    public static let coreImplementation = "Swift native capture, capture-file I/O, and packet dissection"
    // Linux divergence: the daemon builds against the SYSTEM Wireshark
    // (Arch: wireshark-cli); upstream vendored and patched Wireshark 4.6.6.
    // The pinned-constant names are kept for compatibility but now declare
    // the system-library dependency policy.
    public static let wiresharkVendorPath = "System Wireshark (/usr/include/wireshark)"
    public static let wiresharkPinnedTag = "system"
    public static let wiresharkPinnedCommit = "n/a (system library)"
}
