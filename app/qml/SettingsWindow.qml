import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Omarchy.TCPViewer

// Settings window (upstream Settings): appearance (theme, packet font size,
// monospaced packet text), behavior (quit confirmation), and MCP (server
// enable + redaction). Every control writes straight through AppSettings, so
// changes apply live and persist in QSettings — the command bridge's
// settings.* commands read the same store.
Window {
    id: window

    required property SessionController session

    readonly property AppSettings appSettings: session.settings
    // AppSettings stores; a read-back after set keeps the UI honest even when
    // an env override masks the stored value.
    function refreshFromSettings() {
        themeSystem.checked = appSettings.theme === "system"
        themeLight.checked = appSettings.theme === "light"
        themeDark.checked = appSettings.theme === "dark"
        fontSpin.value = appSettings.packetFontSize
        monoCheck.checked = appSettings.monospacedFont
        quitCheck.checked = appSettings.quitConfirmation
        mcpCheck.checked = appSettings.mcpEnabled
        redactionCheck.checked = appSettings.mcpRedaction
    }

    function openAndRaise() {
        refreshFromSettings()
        show()
        requestActivate()
    }

    width: 520
    height: 470
    minimumWidth: 460
    minimumHeight: 430
    title: qsTr("Settings")
    color: Theme.contentBackground

    Component.onCompleted: if (visible) refreshFromSettings()

    ColumnLayout {
        id: content
        anchors.fill: parent
        anchors.margins: 24
        spacing: 14

        Label {
            text: qsTr("Appearance")
            font.pixelSize: Theme.uiTitle - 2
            font.weight: Font.DemiBold
            color: Theme.label
        }

        // Theme (upstream: system, light, or dark)
        RowLayout {
            Layout.fillWidth: true
            spacing: 12
            Label {
                text: qsTr("Theme")
                Layout.preferredWidth: 150
                color: Theme.label
            }
            RowLayout {
                spacing: 14
                ButtonGroup { id: themeGroup }
                RadioButton {
                    id: themeSystem
                    text: qsTr("System")
                    ButtonGroup.group: themeGroup
                    onToggled: window.appSettings.theme = "system"
                }
                RadioButton {
                    id: themeLight
                    text: qsTr("Light")
                    ButtonGroup.group: themeGroup
                    onToggled: window.appSettings.theme = "light"
                }
                RadioButton {
                    id: themeDark
                    text: qsTr("Dark")
                    ButtonGroup.group: themeGroup
                    onToggled: window.appSettings.theme = "dark"
                }
            }
        }

        // Packet font size (upstream packet_font_size: 10 through 24)
        RowLayout {
            Layout.fillWidth: true
            spacing: 12
            Label {
                text: qsTr("Packet font size")
                Layout.preferredWidth: 150
                color: Theme.label
            }
            SpinBox {
                id: fontSpin
                from: 10
                to: 24
                stepSize: 1
                editable: true
                onValueModified: window.appSettings.packetFontSize = value
            }
            Label {
                text: qsTr("10-24")
                color: Theme.secondaryLabel
                font.pixelSize: Theme.uiSmall
            }
        }

        // Monospaced packet text (upstream monospaced_font)
        CheckBox {
            id: monoCheck
            text: qsTr("Monospaced packet text")
            onToggled: window.appSettings.monospacedFont = checked
        }

        CheckBox {
            id: quitCheck
            text: qsTr("Ask before quitting")
            onToggled: window.appSettings.quitConfirmation = checked
        }

        Label {
            text: qsTr("MCP (AI agents)")
            font.pixelSize: Theme.uiTitle - 2
            font.weight: Font.DemiBold
            color: Theme.label
        }

        CheckBox {
            id: mcpCheck
            text: qsTr("Enable MCP server")
            onToggled: window.appSettings.mcpEnabled = checked
        }

        CheckBox {
            id: redactionCheck
            text: qsTr("Redact sensitive data before sending to AI")
            onToggled: window.appSettings.mcpRedaction = checked
        }

        Label {
            Layout.fillWidth: true
            text: qsTr("Settings apply immediately and are stored for this user. "
                     + "The TCPVIEWER_MCP_ENABLED / TCPVIEWER_MCP_REDACTION environment "
                     + "variables override the MCP toggles for CI and smoke runs.")
            wrapMode: Label.Wrap
            color: Theme.secondaryLabel
            font.pixelSize: Theme.uiSmall
        }

        // Push everything up.
        Item { Layout.fillHeight: true }
    }
}
