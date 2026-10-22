pragma Singleton
import QtQuick
import QtQuick.Controls

// Design tokens extracted from the upstream AppKit sources; see
// app/design/tokens.md for the provenance of every value.
QtObject {
    id: theme

    readonly property bool dark: Application.styleHints.colorScheme === Qt.ColorScheme.Dark

    // Chrome
    readonly property color windowBackground: dark ? "#1e1e1e" : "#ececec"
    readonly property color contentBackground: dark ? "#252525" : "#ffffff"
    readonly property color label: dark ? Qt.rgba(1, 1, 1, 0.85) : Qt.rgba(0, 0, 0, 0.85)
    readonly property color secondaryLabel: dark ? Qt.rgba(1, 1, 1, 0.55) : Qt.rgba(0, 0, 0, 0.5)
    readonly property color separator: dark ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(0, 0, 0, 0.1)
    readonly property color accent: dark ? "#0a84ff" : "#007aff"
    readonly property color rowAlternate: dark ? "#2a2a2a" : "#f5f5f5"
    readonly property color headerBackground: dark ? "#2c2c2c" : "#f2f2f2"
    readonly property color selection: dark ? "#0a84ff" : "#007aff"

    // System colors used by the protocol palette.
    readonly property color systemOrange: "#ff9f0a"
    readonly property color systemCyan: "#32ade6"
    readonly property color systemGreen: "#34c759"
    readonly property color systemPink: "#ff2d55"
    readonly property color systemPurple: "#af52de"
    readonly property color systemRed: "#ff3b30"
    readonly property color systemTeal: "#30b0c7"
    readonly property color systemBlue: "#007aff"
    readonly property color systemGray: "#8e8e93"

    // Typography (SF Pro -> Inter, SF Mono -> JetBrainsMono Nerd Font).
    readonly property string uiFont: "Inter"
    readonly property string monoFont: "JetBrainsMono Nerd Font"
    readonly property int uiSize: 13
    readonly property int uiSmall: 11
    readonly property int uiTitle: 19
    readonly property int packetFontSize: 12
    readonly property int packetRowHeight: 24

    // Layout metrics.
    readonly property int sidebarDefaultWidth: 280
    readonly property int sidebarMinimumWidth: 220
    readonly property int inspectorDefaultWidth: 360
    readonly property int inspectorMinimumWidth: 100
    readonly property real inspectorSummaryFraction: 0.70
    readonly property int sidebarRowHeight: 28
    readonly property int inspectorRowHeight: 20
    readonly property int quickFilterHeight: 34
    readonly property int quickFilterButtonHeight: 24
    readonly property int statusStripHeight: 33

    // Packet table columns, in upstream order (PacketTableColumnService.swift).
    // `visible` mirrors the default visibility; hidden columns stay available for
    // the header context menu in a later milestone.
    readonly property var columns: [
        { title: "#", role: "number", width: 68, visible: true },
        { title: "Time", role: "time", width: 112, visible: true },
        { title: "Source", role: "source", width: 180, visible: true },
        { title: "Destination", role: "destination", width: 180, visible: true },
        { title: "Source Port", role: "sourcePort", width: 92, visible: false },
        { title: "Destination Port", role: "destinationPort", width: 118, visible: false },
        { title: "Protocol", role: "protocol", width: 96, visible: true, pill: true },
        { title: "Client", role: "client", width: 140, visible: true },
        { title: "Domain", role: "domain", width: 150, visible: true },
        { title: "Stream ID", role: "streamId", width: 96, visible: false },
        { title: "Length", role: "length", width: 80, visible: true },
        { title: "Summary", role: "summary", width: 320, visible: true },
    ]

    // Columns whose text uses the secondary label color upstream
    // (PacketTablePresentation.textStyle).
    readonly property var secondaryRoles: [
        "number", "time", "sourcePort", "destinationPort", "streamId",
        "length"
    ]

    function isSecondary(role) {
        return secondaryRoles.indexOf(role) >= 0
    }

    function protocolTint(name) {
        switch (String(name).toUpperCase()) {
        case "TCP": return systemOrange
        case "UDP": return systemCyan
        case "TLS", "SSL", "HTTPS", "TLSV1", "TLSV1.1", "TLSV1.2", "TLSV1.3": return systemGreen
        case "HTTP": return systemPink
        case "DNS": return systemPurple
        case "ICMP", "ICMPV6": return systemRed
        case "ARP": return systemTeal
        case "IPV4", "IPV6", "IP": return systemBlue
        case "ETHERNET", "ETH": return systemGray
        default: return accent
        }
    }

    function protocolFill(name) {
        var tint = protocolTint(name)
        var alpha = 0.14
        switch (String(name).toUpperCase()) {
        case "TCP": alpha = 0.16; break
        case "UDP": alpha = 0.18; break
        case "TLS", "SSL", "HTTPS", "TLSV1", "TLSV1.1", "TLSV1.2", "TLSV1.3": alpha = 0.16; break
        case "HTTP": alpha = 0.16; break
        case "DNS": alpha = 0.16; break
        case "ICMP", "ICMPV6": alpha = 0.14; break
        case "ARP": alpha = 0.16; break
        case "IPV4", "IPV6", "IP": alpha = 0.14; break
        case "ETHERNET", "ETH": alpha = 0.18; break
        }
        return Qt.rgba(tint.r, tint.g, tint.b, alpha)
    }
}
