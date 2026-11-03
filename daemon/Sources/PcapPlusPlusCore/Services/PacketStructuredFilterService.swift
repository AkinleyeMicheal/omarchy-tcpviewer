//
//  PacketStructuredFilterService.swift
//  PcapPlusPlusCore
//
//  Port of upstream PacketStructuredFilterModels' builder engine: the
//  semantic field/condition rows (client, stream, flags…) evaluated
//  per-packet instead of translated into a Wireshark expression. Upstream
//  runs this in the app process; the port's daemon owns the packet
//  workspace, so it evaluates and packets.list carries the rows.
//
//  Conditions are the upstream ten (contains, not-contains, prefix/suffix
//  with their negations, regex with its negation, and the two numeric
//  comparisons < and >=); regex patterns compile once per evaluation
//  context — a case-insensitive match over the field's string values, an
//  invalid pattern matching nothing, like upstream. Rows have an enabled
//  toggle (upstream isEnabled); inactive rows never contribute.
//

import Foundation

public enum PacketStructuredFilterQuery: String, CaseIterable, Codable, Sendable, Hashable {
    case urlDomain
    case `protocol`
    case source
    case destination
    case sourcePort
    case destinationPort
    case client
    case pid
    case bundleIdentifier
    case streamID
    case direction
    case tcpFlags
    case tcpPayload
    case decodeStatus
    case interface
    case length
    case summary
    case tags

    public var supportsNumericComparison: Bool {
        switch self {
        case .sourcePort, .destinationPort, .pid, .streamID, .tcpPayload, .length:
            return true
        default:
            return false
        }
    }
}

public enum PacketStructuredFilterCondition: String, CaseIterable, Codable, Sendable, Hashable {
    case contains
    case notContains
    case hasPrefix
    case notHasPrefix
    case hasSuffix
    case notHasSuffix
    case lessThan
    case greaterThanOrEqual
    case matchesRegex
    case notMatchesRegex
}

public enum PacketStructuredFilterGroupOperator: String, CaseIterable, Codable, Sendable, Hashable {
    case and
    case or
}

public struct PacketStructuredFilter: Codable, Sendable, Hashable {
    public var field: PacketStructuredFilterQuery
    public var condition: PacketStructuredFilterCondition
    public var text: String
    public var isEnabled: Bool

    public init(
        field: PacketStructuredFilterQuery,
        condition: PacketStructuredFilterCondition,
        text: String,
        isEnabled: Bool = true
    ) {
        self.field = field
        self.condition = condition
        self.text = text
        self.isEnabled = isEnabled
    }

    public var normalizedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isActive: Bool {
        isEnabled && !normalizedText.isEmpty
    }
}

public struct PacketStructuredFilterGroup: Codable, Sendable, Hashable {
    /// Upstream caps the builder at five rows.
    public static let maxFilterCount = 5

    public var filters: [PacketStructuredFilter]
    public var join: PacketStructuredFilterGroupOperator

    public init(filters: [PacketStructuredFilter], join: PacketStructuredFilterGroupOperator = .and) {
        self.filters = Array(filters.prefix(Self.maxFilterCount))
        self.join = join
    }

    public var activeFilters: [PacketStructuredFilter] {
        filters.filter(\.isActive)
    }
}

public struct PacketStructuredFilterService {
    public struct PreparedFilter {
        let filter: PacketStructuredFilter
        let normalizedText: String
        let regex: (String) -> Bool?
        let hasInvalidRegex: Bool
        let cost: Int

        init(filter: PacketStructuredFilter) {
            self.filter = filter
            self.normalizedText = filter.normalizedText
            self.cost = Self.evaluationCost(for: filter)
            if filter.condition == .matchesRegex || filter.condition == .notMatchesRegex {
                let pattern = filter.normalizedText
                // Upstream compiles the pattern once with .caseInsensitive;
                // an unparseable pattern is a dead row — it never selects
                // anything, in either polarity.
                let compiled = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
                self.hasInvalidRegex = (compiled == nil)
                self.regex = { value in
                    guard let compiled else { return nil }
                    return compiled.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
                }
            } else {
                self.hasInvalidRegex = false
                self.regex = { _ in nil }
            }
        }

        private static func evaluationCost(for filter: PacketStructuredFilter) -> Int {
            if filter.condition == .lessThan || filter.condition == .greaterThanOrEqual {
                return 0
            }

            switch filter.field {
            case .sourcePort, .destinationPort, .pid, .streamID, .tcpPayload, .length:
                return 1
            case .direction, .tcpFlags, .decodeStatus, .interface, .tags:
                return 2
            default:
                return 3
            }
        }
    }

    public struct EvaluationContext {
        let groupOperator: PacketStructuredFilterGroupOperator
        let filters: [PreparedFilter]

        var isEmpty: Bool {
            filters.isEmpty
        }
    }

    public init() {}

    /// Prepare rows once before scanning so regexes are not compiled per
    /// packet; AND groups evaluate cheapest rows first (upstream cost sort).
    public func evaluationContext(for group: PacketStructuredFilterGroup) -> EvaluationContext {
        let prepared = group.activeFilters.map(PreparedFilter.init)
        let ordered = group.join == .and
            ? prepared.sorted { $0.cost < $1.cost }
            : prepared
        return EvaluationContext(groupOperator: group.join, filters: ordered)
    }

    public func matches(_ packet: PacketSummary, context: EvaluationContext) -> Bool {
        guard !context.isEmpty else {
            return true
        }
        switch context.groupOperator {
        case .and:
            return context.filters.allSatisfy { matches(packet, preparedFilter: $0) }
        case .or:
            return context.filters.contains { matches(packet, preparedFilter: $0) }
        }
    }

    public func matches(_ packet: PacketSummary, group: PacketStructuredFilterGroup) -> Bool {
        matches(packet, context: evaluationContext(for: group))
    }

    public func matches(_ packet: PacketSummary, filter: PacketStructuredFilter) -> Bool {
        guard filter.isActive else {
            return true
        }
        return matches(packet, preparedFilter: PreparedFilter(filter: filter))
    }

    private func matches(_ packet: PacketSummary, preparedFilter: PreparedFilter) -> Bool {
        let filter = preparedFilter.filter
        guard filter.isActive else {
            return true
        }

        let text = preparedFilter.normalizedText
        if filter.condition == .lessThan || filter.condition == .greaterThanOrEqual {
            return matchesNumeric(packet, field: filter.field, condition: filter.condition, text: text)
        }

        return matches(
            values: stringValues(for: packet, field: filter.field),
            condition: filter.condition,
            text: text,
            regex: preparedFilter.regex,
            hasInvalidRegex: preparedFilter.hasInvalidRegex
        )
    }

    /// Numeric comparisons apply only to fields that expose numbers; a
    /// non-numeric expectation matches nothing, like upstream.
    private func matchesNumeric(
        _ packet: PacketSummary,
        field: PacketStructuredFilterQuery,
        condition: PacketStructuredFilterCondition,
        text: String
    ) -> Bool {
        guard field.supportsNumericComparison,
              let expected = Double(text) else {
            return false
        }

        let values = numericValues(for: packet, field: field)
        guard !values.isEmpty else {
            return false
        }

        switch condition {
        case .lessThan:
            return values.contains { $0 < expected }
        case .greaterThanOrEqual:
            return values.contains { $0 >= expected }
        default:
            return false
        }
    }

    private func matches(
        values: [String],
        condition: PacketStructuredFilterCondition,
        text: String,
        regex: (String) -> Bool?,
        hasInvalidRegex: Bool
    ) -> Bool {
        switch condition {
        case .contains:
            return values.contains { $0.localizedCaseInsensitiveContains(text) }
        case .notContains:
            return !values.contains { $0.localizedCaseInsensitiveContains(text) }
        case .hasPrefix:
            return values.contains { $0.range(of: text, options: [.caseInsensitive, .anchored]) != nil }
        case .notHasPrefix:
            return !values.contains { $0.range(of: text, options: [.caseInsensitive, .anchored]) != nil }
        case .hasSuffix:
            return values.contains { $0.range(of: text, options: [.caseInsensitive, .anchored, .backwards]) != nil }
        case .notHasSuffix:
            return !values.contains { $0.range(of: text, options: [.caseInsensitive, .anchored, .backwards]) != nil }
        case .matchesRegex:
            return matchRegex(values: values, regex: regex, hasInvalidRegex: hasInvalidRegex, isNegated: false)
        case .notMatchesRegex:
            return matchRegex(values: values, regex: regex, hasInvalidRegex: hasInvalidRegex, isNegated: true)
        case .lessThan, .greaterThanOrEqual:
            return false
        }
    }

    private func matchRegex(
        values: [String],
        regex: (String) -> Bool?,
        hasInvalidRegex: Bool,
        isNegated: Bool
    ) -> Bool {
        // Upstream: invalid pattern → the row never matches, both polarities.
        guard !hasInvalidRegex else {
            return false
        }
        let didMatch = values.contains { regex($0) == true }
        return isNegated ? !didMatch : didMatch
    }

    // MARK: - Field value extraction (upstream stringValues / numericValues)

    private func stringValues(for packet: PacketSummary, field: PacketStructuredFilterQuery) -> [String] {
        switch field {
        case .urlDomain:
            return compact([
                packet.domainName,
                packet.infoSummary,
                packet.layers.compactMap(\.detailSummary).joined(separator: " "),
            ])
        case .protocol:
            var values = compact([
                packet.transportHint.rawValue,
                packet.protocolSummary,
            ])
            values.append(packet.layers.map(\.name).joined(separator: " "))
            values.append(contentsOf: packet.layers.map(\.name))
            // Match on lowercase spellings so "TCP" finds "tcp" chips and
            // vice versa; the string matcher is case-insensitive on top.
            return values.map { $0.lowercased() }
        case .source:
            return endpointValues(packet.endpoints.source)
        case .destination:
            return endpointValues(packet.endpoints.destination)
        case .sourcePort:
            return compact([packet.endpoints.source.port.map(String.init)])
        case .destinationPort:
            return compact([packet.endpoints.destination.port.map(String.init)])
        case .client:
            return compact([
                packet.client?.displayName,
                packet.client?.name,
                packet.client?.executablePath,
                packet.client?.bundlePath,
            ])
        case .pid:
            return compact([packet.client.map { String($0.pid) }])
        case .bundleIdentifier:
            return compact([packet.client?.bundleIdentifier])
        case .streamID:
            return compact([packet.streamID.map(String.init)])
        case .direction:
            return compact([
                packet.direction?.rawValue,
                packet.direction.map { $0.rawValue.capitalized },
            ])
        case .tcpFlags:
            return compact([packet.tcpFlags])
        case .tcpPayload:
            return compact([packet.tcpPayloadLength.map(String.init)])
        case .decodeStatus:
            return compact([
                packet.decodeStatus.kind.rawValue,
                packet.decodeStatus.kind.rawValue.capitalized,
                packet.decodeStatus.reason,
            ])
        case .interface:
            return compact([packet.captureMetadata.interfaceName, packet.interfaceID])
        case .length:
            return compact([String(packet.capturedLength)])
        case .summary:
            return compact([packet.infoSummary])
        case .tags:
            return Self.tags(for: packet).map(\.label)
        }
    }

    private func numericValues(for packet: PacketSummary, field: PacketStructuredFilterQuery) -> [Double] {
        switch field {
        case .sourcePort:
            return compact([packet.endpoints.source.port]).map(Double.init)
        case .destinationPort:
            return compact([packet.endpoints.destination.port]).map(Double.init)
        case .pid:
            return compact([packet.client?.pid]).map { Double($0) }
        case .streamID:
            return compact([packet.streamID]).map(Double.init)
        case .tcpPayload:
            return compact([packet.tcpPayloadLength]).map(Double.init)
        case .length:
            return [Double(packet.capturedLength)]
        default:
            return []
        }
    }

    private func endpointValues(_ endpoint: PacketEndpoint) -> [String] {
        compact([
            endpoint.address,
            endpoint.port.map(String.init),
        ])
    }

    private func compact<T>(_ values: [T?]) -> [T] {
        values.compactMap { $0 }
    }

    private static func tags(for packet: PacketSummary) -> [(label: String, severity: String)] {
        var tags: [(label: String, severity: String)] = []
        if packet.captureMetadata.isTruncated {
            tags.append(("Truncated", "truncated"))
        }
        switch packet.decodeStatus.kind {
        case .complete:
            break
        case .partial:
            tags.append(("Partial", "partial"))
        case .malformed:
            tags.append(("Malformed", "malformed"))
        case .unsupported:
            tags.append(("Unsupported", "unsupported"))
        }
        return tags
    }
}
