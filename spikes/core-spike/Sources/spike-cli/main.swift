import Foundation
import PcapPlusPlusCore

// Omarchy TCPViewer Spike #1: prove the upstream core links against system
// libwireshark and dissects a real capture end-to-end on Linux.
print("spike: PcapPlusPlusCore linked OK")

let fixture = NSString(string: "~/Work/TCPViewer/PcapPlusPlusCoreTests/Fixtures/CaptureFiles/tinyshield-sanitized-sample.pcapng")
    .expandingTildeInPath

guard FileManager.default.fileExists(atPath: fixture) else {
    print("spike: fixture missing at \(fixture)")
    exit(2)
}

let core = NativeTCPViewerCore()
let done = DispatchSemaphore(value: 0)
var outcome = "timeout"

core.loadPacketSummaries(from: URL(fileURLWithPath: fixture)) { result in
    switch result {
    case .success(let summaries):
        outcome = "success: \(summaries.count) packets"
        for summary in summaries {
            outcome += "\n  #\(summary.packetNumber) \(summary.protocolSummary ?? "?") — \(summary.infoSummary)"
        }
    case .failure(let error):
        outcome = "failure: \(error)"
    }
    done.signal()
}

_ = done.wait(timeout: .now() + 30)
print("spike result: \(outcome)")
exit(outcome.hasPrefix("success") ? 0 : 1)
