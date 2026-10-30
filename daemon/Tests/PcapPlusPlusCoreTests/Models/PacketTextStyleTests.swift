//
//  PacketTextStyleTests.swift
//  TCPViewer
//
//  Port of upstream PacketTextStyle/PacketTextStyleMutation behavior used by
//  the CLI annotation commands (packets.set_style / packets.set_comment).
//

import Foundation
import Testing
@testable import PcapPlusPlusCore

struct PacketTextStyleTests {
    // MARK: - Mutation resolution

    @Test func setHighlightColorReplacesOnlyTheColor() {
        let withStrike = PacketTextStyle(highlightColor: .green, isStrikethrough: true)
        #expect(PacketTextStyleMutation.setHighlightColor(.red).applying(to: withStrike)
            == PacketTextStyle(highlightColor: .red, isStrikethrough: true))
        #expect(PacketTextStyleMutation.setHighlightColor(.red).applying(to: .plain)
            == PacketTextStyle(highlightColor: .red, isStrikethrough: false))
    }

    @Test func toggleStrikethroughPreservesTheColor() {
        let styled = PacketTextStyle(highlightColor: .orange, isStrikethrough: false)
        #expect(PacketTextStyleMutation.toggleStrikethrough.applying(to: styled)
            == PacketTextStyle(highlightColor: .orange, isStrikethrough: true))
        #expect(PacketTextStyleMutation.toggleStrikethrough.applying(to: PacketTextStyle(highlightColor: .orange, isStrikethrough: true)) == styled)
    }

    @Test func resetReturnsPlain() {
        #expect(PacketTextStyleMutation.reset.applying(to: PacketTextStyle(highlightColor: .pink, isStrikethrough: true)) == .plain)
    }

    // MARK: - Summary application

    @Test func applyingTextStyleOnSummaryRoundTrips() {
        let packet = Self.makePacket()
        let styled = packet.applying(textStyle: PacketTextStyle(highlightColor: .blue, isStrikethrough: true))

        #expect(styled.textStyle?.highlightColor == .blue)
        #expect(styled.textStyle?.isStrikethrough == true)
        #expect(styled.resolvedTextStyle == PacketTextStyle(highlightColor: .blue, isStrikethrough: true))

        // Reset normalizes back to plain-nil so repeated resets converge.
        let reset = styled.applying(textStyle: PacketTextStyleMutation.reset.applying(to: styled.resolvedTextStyle))
        #expect(reset.textStyle == nil)
        #expect(reset.resolvedTextStyle == .plain)
        #expect(reset.resolvedTextStyle == styled.applying(textStyle: .plain).resolvedTextStyle)
    }

    @Test func applyingCustomCommentSanitizesAndOverrides() {
        let packet = Self.makePacket()
        let commented = packet.applying(customComment: "  \r\nline one\r\nline two  \n")
        #expect(commented.customComment == "line one\nline two")
        #expect(commented.resolvedComment == "line one\nline two")

        // An empty sanitized comment normalizes to nil (no comment stored).
        #expect(packet.applying(customComment: "   \n").customComment == nil)
    }

    @Test func annotationRoundTripKeepsFieldsAcrossCopy() {
        // Mirrors the daemon flow: style first, then a comment, then an
        // unrelated field copy must not drop the annotation.
        let styled = Self.makePacket()
            .applying(textStyle: PacketTextStyle(highlightColor: .teal, isStrikethrough: true))
            .applying(customComment: "poster child")

        let reinterpreted = PacketSummary(
            packetNumber: styled.packetNumber,
            timestamp: styled.timestamp,
            source: styled.source,
            transportHint: styled.transportHint,
            endpoints: styled.endpoints,
            originalLength: styled.originalLength,
            capturedLength: styled.capturedLength,
            infoSummary: styled.infoSummary,
            layers: styled.layers,
            decodeStatus: styled.decodeStatus,
            captureMetadata: styled.captureMetadata,
            textStyle: styled.textStyle,
            customComment: styled.customComment
        )
        #expect(reinterpreted.textStyle == styled.textStyle)
        #expect(reinterpreted.customComment == styled.customComment)
    }

    private static func makePacket() -> PacketSummary {
        PacketSummary(
            packetNumber: 7,
            timestamp: Date(timeIntervalSince1970: 5),
            source: .live,
            transportHint: .tcp,
            endpoints: PacketEndpoints(
                source: PacketEndpoint(address: "10.0.0.2", port: 51000),
                destination: PacketEndpoint(address: "142.250.0.14", port: 443)
            ),
            originalLength: 60,
            capturedLength: 60,
            infoSummary: "TCP 51000 → 443",
            layers: [],
            decodeStatus: PacketDecodeStatus(kind: .complete),
            captureMetadata: PacketCaptureMetadata(
                linkType: .ethernet,
                isTruncated: false,
                packetComment: nil
            )
        )
    }
}
