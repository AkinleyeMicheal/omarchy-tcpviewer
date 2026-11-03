import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Omarchy.TCPViewer
import "BuilderFormat.js" as BuilderFormat

// Quick filter chips and the display-filter field (PacketQuickFilterViewController
// and the upstream display filter). Chips are local predicates in the daemon;
// the text field is a sticky source-level Wireshark display filter.
Rectangle {
    id: root

    required property SessionController session

    implicitHeight: Theme.quickFilterHeight
    color: Theme.contentBackground

    function focusDisplayFilter() {
        filterField.forceActiveFocus()
        filterField.selectAll()
    }

    // Save-as dialog state: the expression captured when the dialog opens, so
    // editing the field afterwards cannot save a mismatched query. The dialog
    // also saves structured presets (mode "builder" captures the popup rows).
    property string pendingSaveQuery: ""
    property string pendingSaveMode: "expression"  // "expression" | "builder"

    function commitSaveFilter() {
        if (pendingSaveMode === "builder") {
            // activeBuilderRecords() records numeric validation failures in
            // builderError; surface that before the controller's name check.
            if (root.builderError.length > 0) {
                errorLabel.text = root.builderError
                return
            }
            const error = session.saveStructuredFilter(nameField.text,
                activeBuilderRecords(), root.builderMatchAny ? "or" : "and")
            if (error.length > 0) {
                errorLabel.text = error
                return
            }
            saveFilterPopup.close()
            filterBuilderPopup.close()
            return
        }
        const error = session.saveFilter(nameField.text, pendingSaveQuery)
        if (error.length > 0) {
            errorLabel.text = error
            return
        }
        saveFilterPopup.close()
    }

    // ---- Structured filter builder (upstream PacketStructuredFilterViewController) ----
    // Rows are semantic conditions the daemon evaluates per packet (upstream
    // builder engine, PacketStructuredFilterGroup): client, stream and flags
    // rows have no Wireshark translation, so the builder no longer compiles
    // a display filter. The display-filter field above stays separate.
    // Field/condition vocabulary lives in BuilderFormat.js (shared with the
    // sidebar's saved presets); field ids match the daemon's IPC contract.
    readonly property var builderFields: BuilderFormat.FIELDS

    property bool builderMatchAny: false
    property string builderPreview: ""
    property string builderError: ""
    property bool builderHookDone: false

    function builderFieldById(id) {
        for (var i = 0; i < builderFields.length; ++i) {
            if (builderFields[i].id === id)
                return builderFields[i]
        }
        return builderFields[0]
    }

    // Upstream PacketStructuredFilterCondition order; < and >= ride along
    // only on fields that expose numbers (the shared vocabulary enforces it).
    function builderConditionsFor(fieldId) {
        return BuilderFormat.conditionsFor(fieldId)
    }

    function builderConditionById(fieldId, conditionId) {
        return BuilderFormat.conditionById(fieldId, conditionId)
    }

    // The summary is readability only: the daemon receives the row objects.
    // Disabled rows are annotated so the preview shows what will be skipped.
    function builderRowSummary(row) {
        return BuilderFormat.rowSummary({
            field: row.fieldId,
            condition: row.condId,
            text: String(row.rowValue || "").trim(),
            enabled: row.rowEnabled
        })
    }

    function builderSummary() {
        var records = []
        for (var i = 0; i < builderModel.count; ++i) {
            var row = builderModel.get(i)
            records.push({
                field: row.fieldId,
                condition: row.condId,
                text: String(row.rowValue || "").trim(),
                enabled: row.rowEnabled
            })
        }
        return BuilderFormat.summaryFor(records, root.builderMatchAny ? "or" : "and")
    }

    function refreshBuilder() {
        builderError = ""
        builderPreview = builderSummary()
    }

    function addBuilderRow() {
        if (builderModel.count >= 5)
            return
        builderModel.append({ fieldId: "urlDomain", condId: "contains", rowValue: "", rowEnabled: true })
        refreshBuilder()
    }

    function openFilterBuilder() {
        filterBuilderPopup.open()
    }

    // Enabled non-blank rows are the ones that reach the daemon (upstream
    // isActive = enabled && non-empty).
    function activeBuilderRecords() {
        builderError = ""
        var rows = []
        for (var i = 0; i < builderModel.count; ++i) {
            var row = builderModel.get(i)
            var value = String(row.rowValue || "").trim()
            if (!row.rowEnabled || value.length === 0)
                continue
            var field = builderFieldById(row.fieldId)
            if (field.kind === "numeric" && !/^\d+$/.test(value)) {
                builderError = "Enter a number for " + field.label + "."
                return []
            }
            rows.push({
                field: row.fieldId,
                condition: row.condId,
                text: value,
                enabled: true
            })
        }
        return rows
    }

    function applyBuilder() {
        var rows = activeBuilderRecords()
        if (builderError.length > 0)
            return
        // Nothing active clears the structured stage (the daemon treats an
        // empty group as "match all").
        session.setStructuredFilter(rows, root.builderMatchAny ? "or" : "and")
        filterBuilderPopup.close()
    }

    // CI screenshot helper: seed two representative conditions (a string
    // contains and a numeric comparison) to review the row UI.
    function seedBuilderDemo() {
        builderModel.clear()
        builderModel.append({ fieldId: "urlDomain", condId: "contains", rowValue: "example", rowEnabled: true })
        builderModel.append({ fieldId: "destinationPort", condId: "lessThan", rowValue: "65535", rowEnabled: true })
        refreshBuilder()
    }

    // The popup mirrors the session's active builder state (restore on open
    // for app restarts with seeded filters and for saved-structured loads).
    function restoreBuilderFromSession() {
        builderModel.clear()
        var rows = session.structuredRows
        if (rows.length === 0) {
            root.addBuilderRow()
            return
        }
        for (var i = 0; i < rows.length && i < 5; ++i) {
            var row = rows[i]
            builderModel.append({
                fieldId: String(row.field || "urlDomain"),
                condId: String(row.condition || "contains"),
                rowValue: String(row.text || ""),
                rowEnabled: row.enabled !== false
            })
        }
        root.builderMatchAny = session.structuredJoin === "or"
        root.refreshBuilder()
    }

    property var selectedIDs: []
    // Quick filters can be set before this bar appears (CI startup hook) or
    // by an outside actor (saved-filter restore). Chips must show the
    // session's truth, so mirror it whenever the two sets disagree.
    // toggleChip writes local state before calling session, so the mirror
    // never loops back into an edit.
    function syncSelectedIDs() {
        const sessionIds = session.quickFilters
        const local = selectedIDs
        if (sessionIds.length !== local.length) {
            selectedIDs = sessionIds.slice()
            return
        }
        for (var i = 0; i < sessionIds.length; ++i) {
            if (sessionIds[i] !== local[i]) {
                selectedIDs = sessionIds.slice()
                return
            }
        }
    }
    Component.onCompleted: syncSelectedIDs()
    Connections {
        target: root.session
        function onQuickFiltersChanged() {
            root.syncSelectedIDs()
        }
    }
    readonly property var chips: [
        { id: "all", label: "All" },
        { id: "tcp", label: "TCP" },
        { id: "udp", label: "UDP" },
        { id: "dns", label: "DNS" },
        { id: "http", label: "HTTP" },
        { id: "tls", label: "TLS" },
        { id: "websocket", label: "WebSocket" },
        { id: "clientHello", label: "Client Hello" },
        { id: "serverHello", label: "Server Hello" },
        { id: "errors", label: "Errors" }
    ]

    function toggleChip(id) {
        if (id === "all") {
            selectedIDs = []
        } else {
            var next = selectedIDs.slice()
            var index = next.indexOf(id)
            if (index >= 0)
                next.splice(index, 1)
            else
                next.push(id)
            selectedIDs = next
        }
        session.setQuickFilters(selectedIDs)
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 16
        anchors.rightMargin: 16
        spacing: 8

        Flickable {
            Layout.fillWidth: true
            Layout.preferredHeight: parent.height
            contentWidth: chipRow.width
            clip: true
            flickableDirection: Flickable.HorizontalFlick
            boundsBehavior: Flickable.StopAtBounds

            Row {
                id: chipRow
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8

                Repeater {
                    model: root.chips

                    delegate: Rectangle {
                        id: chip

                        required property var modelData

                        readonly property bool active: modelData.id === "all"
                            ? root.selectedIDs.length === 0
                            : root.selectedIDs.indexOf(modelData.id) >= 0

                        width: chipLabel.implicitWidth + 24
                        height: Theme.quickFilterButtonHeight
                        radius: 6
                        color: active
                            ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.16)
                            : (chipMouse.containsMouse
                                ? Qt.rgba(Theme.label.r, Theme.label.g, Theme.label.b, 0.06)
                                : "transparent")

                        Text {
                            id: chipLabel
                            anchors.centerIn: parent
                            text: chip.modelData.label
                            font.family: Theme.uiFont
                            font.pixelSize: Theme.uiSmall
                            font.weight: Font.Medium
                            color: chip.active ? Theme.accent : Theme.label
                        }

                        MouseArea {
                            id: chipMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: root.toggleChip(chip.modelData.id)
                        }
                    }
                }
            }
        }

        Rectangle {
            id: builderButton
            Layout.preferredWidth: builderButtonLabel.implicitWidth + 20
            Layout.preferredHeight: 24
            radius: 6
            color: filterBuilderPopup.visible
                ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.16)
                : (builderButtonMouse.containsMouse
                    ? Qt.rgba(Theme.label.r, Theme.label.g, Theme.label.b, 0.06)
                    : "transparent")
            border.width: 1
            border.color: filterBuilderPopup.visible ? Theme.accent : Theme.separator

            Text {
                id: builderButtonLabel
                anchors.centerIn: parent
                text: "Builder"
                font.family: Theme.uiFont
                font.pixelSize: Theme.uiSmall
                color: filterBuilderPopup.visible ? Theme.accent : Theme.label
            }

            ToolTip.visible: builderButtonMouse.containsMouse
            ToolTip.text: "Build a filter from conditions"
            ToolTip.delay: 500

            MouseArea {
                id: builderButtonMouse
                anchors.fill: parent
                hoverEnabled: true
                onClicked: root.openFilterBuilder()
            }
        }

        Rectangle {
            id: filterCell
            Layout.preferredWidth: 270
            Layout.preferredHeight: 24
            radius: 6
            color: Theme.windowBackground
            border.width: 1
            border.color: session.filterErrorText.length > 0
                ? Theme.systemRed
                : (filterField.activeFocus ? Theme.accent : Theme.separator)

            TextField {
                id: filterField
                anchors.fill: parent
                anchors.leftMargin: 8
                // Leave room for the save, pin and clear affordances.
                anchors.rightMargin: filterField.text.length > 0 ? 54 : 8
                background: null
                padding: 0
                verticalAlignment: TextInput.AlignVCenter
                placeholderText: "Display filter"
                placeholderTextColor: Theme.secondaryLabel
                color: session.filterErrorText.length > 0 ? Theme.systemRed : Theme.label
                selectionColor: Theme.systemRed
                selectedTextColor: "white"
                font.family: Theme.monoFont
                font.pixelSize: Theme.uiSmall
                selectByMouse: true
                onAccepted: root.session.applyFilter(text)

                // Invalid expressions select the offending span (upstream
                // selects the DisplayFilterDiagnostic range); the revert in
                // the controller keeps the group working while the field
                // keeps the draft text.
                function applyErrorSpan() {
                    const span = session.filterErrorSpan
                    if (!span || span.start === undefined)
                        return
                    const start = span.start
                    if (start < 0 || start > text.length)
                        return
                    const length = span.length !== undefined ? span.length : 0
                    filterField.cursorPosition = start
                    if (length > 0)
                        select(start, Math.min(start + length, text.length))
                }

                ToolTip {
                    id: filterErrorTip
                    visible: false
                    timeout: 6000
                    font.family: Theme.uiFont
                    font.pixelSize: Theme.uiSmall
                    background: Rectangle {
                        color: Theme.windowBackground
                        border.width: 1
                        border.color: Theme.systemRed
                        radius: 6
                    }
                    contentItem: Text {
                        text: root.session.filterErrorText
                        font.family: Theme.uiFont
                        font.pixelSize: Theme.uiSmall
                        color: Theme.systemRed
                        elide: Text.ElideRight
                    }
                }

                Connections {
                    target: session

                    function onFilterErrorChanged() {
                        if (root.session.filterErrorText.length > 0) {
                            filterField.applyErrorSpan()
                            filterErrorTip.visible = true
                        } else {
                            filterErrorTip.visible = false
                        }
                    }
                }

                Connections {
                    target: root.session
                    function onFilterTextChanged() {
                        if (!filterField.activeFocus) {
                            filterField.text = root.session.filterText
                            // Show the start of externally applied expressions
                            // (builder, pinned/saved filters) instead of the tail.
                            filterField.cursorPosition = 0
                        }
                    }
                }
            }

            // Pin the current expression into the sidebar Favorites group
            // (upstream PacketCustomFilter group handling).
            Text {
                id: pinGlyph
                anchors.right: parent.right
                anchors.rightMargin: 22
                anchors.verticalCenter: parent.verticalCenter
                visible: filterField.text.trim().length > 0
                readonly property bool pinned:
                    root.session.pinnedFilters.indexOf(filterField.text.trim()) >= 0
                text: pinned ? "★" : "☆"
                font.pixelSize: 12
                color: pinned ? Theme.systemOrange : Theme.secondaryLabel

                ToolTip.visible: pinMouse.containsMouse
                ToolTip.text: pinned ? "Unpin filter" : "Pin filter"
                ToolTip.delay: 500

                MouseArea {
                    id: pinMouse
                    anchors.fill: parent
                    anchors.margins: -4
                    hoverEnabled: true
                    onClicked: {
                        const expression = filterField.text.trim()
                        if (expression.length === 0)
                            return
                        if (root.session.pinnedFilters.indexOf(expression) >= 0)
                            root.session.unpinFilter(expression)
                        else
                            root.session.pinFilter(expression)
                    }
                }
            }

            // Save the current expression under a name in the sidebar Favorites.
            Text {
                id: saveGlyph
                anchors.right: parent.right
                anchors.rightMargin: 38
                anchors.verticalCenter: parent.verticalCenter
                visible: filterField.text.trim().length > 0
                text: "⊕"
                font.pixelSize: 12
                color: saveMouse.containsMouse ? Theme.accent : Theme.secondaryLabel

                ToolTip.visible: saveMouse.containsMouse
                ToolTip.text: "Save filter…"
                ToolTip.delay: 500

                MouseArea {
                    id: saveMouse
                    anchors.fill: parent
                    anchors.margins: -4
                    hoverEnabled: true
                    onClicked: {
                        const expression = filterField.text.trim()
                        if (expression.length === 0)
                            return
                        root.pendingSaveQuery = expression
                        saveFilterPopup.open()
                    }
                }
            }

            Text {
                anchors.right: parent.right
                anchors.rightMargin: 7
                anchors.verticalCenter: parent.verticalCenter
                visible: filterField.text.length > 0
                text: "×"
                font.pixelSize: 12
                color: Theme.secondaryLabel

                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        filterField.text = ""
                        root.session.applyFilter("")
                    }
                }
            }
        }
    }

    // Named-filter dialog (upstream saveCustomFilter): Enter saves, Escape
    // cancels, and validation errors surface inline.
    Popup {
        id: saveFilterPopup
        parent: root
        x: root.width - width - 16
        y: root.height + 6
        width: 280
        padding: 12
        modal: true
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        background: Rectangle {
            color: Theme.contentBackground
            border.width: 1
            border.color: Theme.separator
            radius: 8
        }

        onOpened: {
            nameField.text = ""
            errorLabel.text = ""
            // Title reflects what gets saved (display filter vs preset).
            titleLabel.text = root.pendingSaveMode === "builder"
                ? "Save builder preset" : "Save display filter"
            nameField.forceActiveFocus()
        }

        contentItem: ColumnLayout {
            spacing: 8

            Text {
                id: titleLabel
                text: "Save display filter"
                font.family: Theme.uiFont
                font.pixelSize: Theme.uiSmall
                font.weight: Font.DemiBold
                color: Theme.secondaryLabel
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 26
                radius: 6
                color: Theme.windowBackground
                border.width: 1
                border.color: nameField.activeFocus ? Theme.accent : Theme.separator

                TextField {
                    id: nameField
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    background: null
                    padding: 0
                    verticalAlignment: TextInput.AlignVCenter
                    placeholderText: "Filter name"
                    placeholderTextColor: Theme.secondaryLabel
                    color: Theme.label
                    selectionColor: Theme.accent
                    selectedTextColor: "white"
                    font.family: Theme.uiFont
                    font.pixelSize: Theme.uiSmall
                    selectByMouse: true
                    onAccepted: root.commitSaveFilter()
                }
            }

            Text {
                id: errorLabel
                visible: text.length > 0
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                font.family: Theme.uiFont
                font.pixelSize: Theme.uiSmall
                color: Theme.systemRed
            }

            RowLayout {
                Layout.alignment: Qt.AlignRight
                spacing: 8

                DialogButton {
                    text: "Cancel"
                    onClicked: saveFilterPopup.close()
                }
                DialogButton {
                    text: "Save"
                    primary: true
                    onClicked: root.commitSaveFilter()
                }
            }
        }
    }

    ListModel {
        id: builderModel
    }

    // Up to five field/condition/value rows joined with AND or OR. The
    // generated Wireshark expression is previewed before it is applied.
    Popup {
        id: filterBuilderPopup
        parent: root
        x: Math.max(8, root.width - width - 16)
        y: root.height + 6
        width: Math.min(660, root.width - 32)
        padding: 14
        modal: true
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        background: Rectangle {
            color: Theme.contentBackground
            border.width: 1
            border.color: Theme.separator
            radius: 8
        }

        onOpened: {
            root.restoreBuilderFromSession()
            root.refreshBuilder()
        }

        contentItem: ColumnLayout {
            spacing: 10

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Text {
                    text: "Build filter"
                    font.family: Theme.uiFont
                    font.pixelSize: Theme.uiSize
                    font.weight: Font.DemiBold
                    color: Theme.label
                }

                Item { Layout.fillWidth: true }

                Text {
                    text: "Match"
                    font.family: Theme.uiFont
                    font.pixelSize: Theme.uiSmall
                    color: Theme.secondaryLabel
                }
                BuilderToggle {
                    text: "All"
                    active: !root.builderMatchAny
                    onClicked: {
                        root.builderMatchAny = false
                        root.refreshBuilder()
                    }
                }
                BuilderToggle {
                    text: "Any"
                    active: root.builderMatchAny
                    onClicked: {
                        root.builderMatchAny = true
                        root.refreshBuilder()
                    }
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 6

                Repeater {
                    model: builderModel

                    delegate: RowLayout {
                        id: builderRow

                        required property int index
                        required property string fieldId
                        required property string condId
                        required property string rowValue
                        required property bool rowEnabled

                        Layout.fillWidth: true
                        spacing: 6

                        // Upstream leading isEnabled toggle: disabled rows
                        // stay in the builder (values preserved) but stop
                        // contributing to the applied group.
                        RowCheck {
                            checked: builderRow.rowEnabled
                            hoverText: builderRow.rowEnabled
                                ? "Condition enabled" : "Condition disabled"
                            onToggled: {
                                builderModel.setProperty(builderRow.index, "rowEnabled",
                                                         !builderRow.rowEnabled)
                                root.refreshBuilder()
                            }
                        }

                        FilterCombo {
                            id: fieldCombo
                            Layout.preferredWidth: 164
                            opacity: builderRow.rowEnabled ? 1 : 0.5
                            options: root.builderFields
                            selectedId: builderRow.fieldId
                            onSelected: function(id) {
                                builderModel.setProperty(builderRow.index, "fieldId", id)
                                var conditions = root.builderConditionsFor(id)
                                builderModel.setProperty(builderRow.index, "condId",
                                    conditions.length > 0 ? conditions[0].id : "")
                                condCombo.syncSelection()
                                root.refreshBuilder()
                            }
                            Component.onCompleted: syncSelection()
                        }

                        FilterCombo {
                            id: condCombo
                            Layout.preferredWidth: 140
                            opacity: builderRow.rowEnabled ? 1 : 0.5
                            options: root.builderConditionsFor(builderRow.fieldId)
                            selectedId: builderRow.condId
                            onSelected: function(id) {
                                builderModel.setProperty(builderRow.index, "condId", id)
                                root.refreshBuilder()
                            }
                            Component.onCompleted: syncSelection()
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 26
                            radius: 6
                            opacity: builderRow.rowEnabled ? 1 : 0.5
                            color: Theme.windowBackground
                            border.width: 1
                            border.color: valueField.activeFocus ? Theme.accent : Theme.separator

                            TextField {
                                id: valueField
                                anchors.fill: parent
                                anchors.leftMargin: 8
                                anchors.rightMargin: 8
                                background: null
                                padding: 0
                                verticalAlignment: TextInput.AlignVCenter
                                placeholderText: root.builderFieldById(builderRow.fieldId).hint
                                placeholderTextColor: Theme.secondaryLabel
                                color: Theme.label
                                selectionColor: Theme.accent
                                selectedTextColor: "white"
                                font.family: Theme.monoFont
                                font.pixelSize: Theme.uiSmall
                                selectByMouse: true
                                text: builderRow.rowValue
                                onTextEdited: {
                                    builderModel.setProperty(builderRow.index, "rowValue", text)
                                    root.refreshBuilder()
                                }
                                onAccepted: root.applyBuilder()
                            }
                        }

                        Text {
                            Layout.preferredWidth: 18
                            Layout.preferredHeight: 26
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                            text: "×"
                            font.pixelSize: 13
                            color: removeMouse.containsMouse && builderModel.count > 1
                                ? Theme.systemRed : Theme.secondaryLabel
                            opacity: builderModel.count > 1 ? 1 : 0.35

                            MouseArea {
                                id: removeMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                enabled: builderModel.count > 1
                                onClicked: {
                                    builderModel.remove(builderRow.index)
                                    root.refreshBuilder()
                                }
                            }
                        }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Text {
                    text: "+ Add condition"
                    font.family: Theme.uiFont
                    font.pixelSize: Theme.uiSmall
                    font.weight: Font.Medium
                    color: builderModel.count >= 5 ? Theme.secondaryLabel : Theme.accent
                    opacity: builderModel.count >= 5 ? 0.5 : 1

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -4
                        enabled: builderModel.count < 5
                        onClicked: root.addBuilderRow()
                    }
                }

                Item { Layout.fillWidth: true }

                Text {
                    visible: builderModel.count >= 5
                    text: "Maximum 5 conditions"
                    font.family: Theme.uiFont
                    font.pixelSize: Theme.uiSmall
                    color: Theme.secondaryLabel
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 34
                radius: 6
                color: Theme.windowBackground
                border.width: 1
                border.color: Theme.separator

                Text {
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                    text: root.builderPreview.length > 0
                        ? root.builderPreview
                        : "The filter summary appears here"
                    font.family: Theme.monoFont
                    font.pixelSize: Theme.uiSmall
                    color: root.builderPreview.length > 0 ? Theme.label : Theme.secondaryLabel
                }
            }

            Text {
                visible: root.builderError.length > 0
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: root.builderError
                font.family: Theme.uiFont
                font.pixelSize: Theme.uiSmall
                color: Theme.systemRed
            }

            RowLayout {
                Layout.alignment: Qt.AlignRight
                spacing: 8

                DialogButton {
                    text: "Save preset…"
                    onClicked: {
                        //Validation still happens at commit time
                        root.pendingSaveMode = "builder"
                        root.pendingSaveQuery = ""
                        saveFilterPopup.open()
                    }
                }
                DialogButton {
                    text: "Cancel"
                    onClicked: filterBuilderPopup.close()
                }
                DialogButton {
                    text: "Apply"
                    primary: true
                    onClicked: root.applyBuilder()
                }
            }
        }
    }

    component DialogButton: Rectangle {
        id: button

        property string text
        property bool primary: false
        signal clicked

        implicitWidth: label.implicitWidth + 24
        implicitHeight: 24
        radius: 6
        color: button.primary
            ? (buttonMouse.containsMouse
                ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.85)
                : Theme.accent)
            : (buttonMouse.containsMouse
                ? Qt.rgba(Theme.label.r, Theme.label.g, Theme.label.b, 0.08)
                : "transparent")
        border.width: button.primary ? 0 : 1
        border.color: Theme.separator

        Text {
            id: label
            anchors.centerIn: parent
            text: button.text
            font.family: Theme.uiFont
            font.pixelSize: Theme.uiSmall
            color: button.primary ? "white" : Theme.label
        }

        MouseArea {
            id: buttonMouse
            anchors.fill: parent
            hoverEnabled: true
            onClicked: button.clicked()
        }
    }

    // Small per-row enable checkbox for the builder (upstream isEnabled).
    component RowCheck: Rectangle {
        id: rowCheck

        property bool checked: true
        property string hoverText: ""
        signal toggled

        implicitWidth: 18
        implicitHeight: 26
        radius: 4
        color: "transparent"
        border.width: 1
        border.color: rowCheck.checked ? Theme.accent : Theme.separator

        Text {
            anchors.centerIn: parent
            text: "✓"
            font.pixelSize: 12
            font.weight: Font.DemiBold
            color: Theme.accent
            visible: rowCheck.checked
        }

        ToolTip.visible: rowCheckMouse.containsMouse && rowCheck.hoverText.length > 0
        ToolTip.text: rowCheck.hoverText
        ToolTip.delay: 500

        MouseArea {
            id: rowCheckMouse
            anchors.fill: parent
            anchors.margins: -3
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: rowCheck.toggled()
        }
    }

    component BuilderToggle: Rectangle {
        id: toggle

        property string text
        property bool active: false
        signal clicked

        implicitWidth: toggleLabel.implicitWidth + 20
        implicitHeight: 22
        radius: 6
        color: toggle.active
            ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.16)
            : (toggleMouse.containsMouse
                ? Qt.rgba(Theme.label.r, Theme.label.g, Theme.label.b, 0.06)
                : "transparent")

        Text {
            id: toggleLabel
            anchors.centerIn: parent
            text: toggle.text
            font.family: Theme.uiFont
            font.pixelSize: Theme.uiSmall
            font.weight: Font.Medium
            color: toggle.active ? Theme.accent : Theme.label
        }

        MouseArea {
            id: toggleMouse
            anchors.fill: parent
            hoverEnabled: true
            onClicked: toggle.clicked()
        }
    }

    // Compact combo box matching the toolbar interface picker.
    component FilterCombo: ComboBox {
        id: combo

        property var options: []
        property string selectedId: ""
        signal selected(string id)

        model: combo.options
        textRole: "label"
        font.family: Theme.uiFont
        font.pixelSize: Theme.uiSmall
        implicitHeight: 26
        focusPolicy: Qt.StrongFocus

        function syncSelection() {
            for (var i = 0; i < combo.options.length; ++i) {
                if (combo.options[i].id === combo.selectedId) {
                    combo.currentIndex = i
                    return
                }
            }
            combo.currentIndex = combo.options.length > 0 ? 0 : -1
        }

        onActivated: {
            if (index >= 0 && index < combo.options.length)
                combo.selected(combo.options[index].id)
        }

        background: Rectangle {
            radius: 6
            color: Theme.windowBackground
            border.width: 1
            border.color: combo.activeFocus ? Theme.accent : Theme.separator
        }

        contentItem: Text {
            leftPadding: 8
            rightPadding: 20
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
            text: combo.displayText
            font.family: Theme.uiFont
            font.pixelSize: Theme.uiSmall
            color: Theme.label
        }

        indicator: Text {
            x: combo.width - 15
            y: (combo.height - implicitHeight) / 2
            text: "⌄"
            font.pixelSize: 10
            color: Theme.secondaryLabel
        }

        delegate: Item {
            required property var modelData
            required property int index

            width: combo.width
            height: 24

            Rectangle {
                anchors.fill: parent
                radius: 4
                color: index === combo.highlightedIndex
                    ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.16)
                    : (optionMouse.containsMouse
                        ? Qt.rgba(Theme.label.r, Theme.label.g, Theme.label.b, 0.06)
                        : "transparent")
            }

            Text {
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.label
                elide: Text.ElideRight
                font.family: Theme.uiFont
                font.pixelSize: Theme.uiSmall
                color: Theme.label
            }

            MouseArea {
                id: optionMouse
                anchors.fill: parent
                hoverEnabled: true
                onClicked: {
                    combo.currentIndex = index
                    combo.selected(modelData.id)
                    combo.popup.close()
                }
            }
        }

        popup: Popup {
            y: combo.height + 4
            width: combo.width
            padding: 4

            background: Rectangle {
                radius: 8
                color: Theme.contentBackground
                border.width: 1
                border.color: Theme.separator
            }

            contentItem: ListView {
                implicitHeight: contentHeight
                model: combo.popup.visible ? combo.delegateModel : null
                currentIndex: combo.highlightedIndex
                clip: true
            }
        }
    }

    // CI hook: capture the save-filter dialog without a mouse click. The timer
    // waits for the startup display filter (TCPVIEWER_FILTER) to arrive. Each
    // tab/layout pane owns a bar, including the hidden split pane, so only the
    // visible bar may open the dialog.
    Timer {
        interval: 1500
        repeat: false
        running: root.visible && root.width > 0
            && session.envValue("TCPVIEWER_SHOW_SAVE_DIALOG") === "1"
            && !saveFilterPopup.visible
            && filterField.text.trim().length > 0
        onTriggered: {
            root.pendingSaveQuery = filterField.text.trim()
            saveFilterPopup.open()
        }
    }

    // CI hook: render the structured filter builder for visual review.
    // "demo" seeds two representative conditions.
    Timer {
        interval: 1800
        repeat: false
        running: root.visible && root.width > 0
            && !root.builderHookDone
            && session.envValue("TCPVIEWER_SHOW_FILTER_BUILDER").length > 0
        onTriggered: {
            root.builderHookDone = true
            root.openFilterBuilder()
            const mode = session.envValue("TCPVIEWER_SHOW_FILTER_BUILDER")
            if (mode === "demo" || mode === "apply") {
                root.seedBuilderDemo()
                if (mode === "apply")
                    builderApplyTimer.start()
            }
        }
    }

    // Companion to the builder hook: proves Apply reaches the daemon.
    Timer {
        id: builderApplyTimer
        interval: 1200
        repeat: false
        onTriggered: root.applyBuilder()
    }

    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 1
        color: Theme.separator
    }
}
