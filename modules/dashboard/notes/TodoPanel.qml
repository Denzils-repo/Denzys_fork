pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import M3Shapes
import Caelestia.Components
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services

StyledRect {
    id: root

    radius: Tokens.rounding.large
    color: Colours.tPalette.m3surfaceContainer
    implicitHeight: 480
    clip: true

    readonly property list<int> morphShapeList: [
        MaterialShape.Cookie4Sided,
        MaterialShape.Cookie6Sided,
        MaterialShape.Cookie9Sided,
        MaterialShape.Cookie12Sided,
        MaterialShape.Clover4Leaf,
        MaterialShape.Sunny,
        MaterialShape.VerySunny,
        MaterialShape.SoftBurst,
        MaterialShape.Ghostish,
        MaterialShape.Gem,
        MaterialShape.Pentagon,
        MaterialShape.Diamond,
        MaterialShape.Oval,
        MaterialShape.Pill,
        MaterialShape.Slanted
    ]

    function getTaskShape(task): int {
        if (!task) return morphShapeList[0];
        let idx = 0;
        if (task.shapeIndex !== undefined && typeof task.shapeIndex === "number") {
            idx = Math.abs(task.shapeIndex);
        } else {
            const str = String(task.id || task.title || "todo");
            let hash = 0;
            for (let i = 0; i < str.length; i++) {
                hash = ((hash << 5) - hash) + str.charCodeAt(i);
                hash |= 0;
            }
            idx = Math.abs(hash);
        }
        return morphShapeList[idx % morphShapeList.length];
    }

    readonly property var activeTodos: NotesStore.getTodos()
    readonly property var trashTodosList: NotesStore.getCompletedAndTrashTodos()
    readonly property int remainingCount: NotesStore.getRemainingTodosCount()
    readonly property int trashCount: NotesStore.getTrashCount()

    property bool showTrash: false
    property bool confirmEmptyTrash: false
    property bool isAdding: false
    property bool calendarPickerOpen: false
    property string selectedNewDue: ""
    readonly property bool isDatePicking: root.calendarPickerOpen || (detailView && detailView.calendarOpen)

    Timer {
        id: confirmEmptyTimer
        interval: 3000
        repeat: false
        onTriggered: root.confirmEmptyTrash = false
    }

    StackLayout {
        anchors.fill: parent
        currentIndex: NotesStore.isEditingTodo ? 1 : 0

        // ==========================================
        // INDEX 0: MAIN TODO LIST VIEW
        // ==========================================
        Item {
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Tokens.padding.large
                spacing: Tokens.spacing.small

                // Header Row
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Tokens.spacing.small

                    StyledText {
                        text: root.showTrash ? qsTr("Trash") : qsTr("To-do")
                        font: Tokens.font.title.medium
                        color: Colours.palette.m3onSurface
                        Layout.maximumWidth: 100
                        elide: Text.ElideRight
                    }

                    StyledRect {
                        radius: Tokens.rounding.full
                        color: Colours.palette.m3surfaceContainerHigh
                        implicitHeight: 20
                        implicitWidth: countBadgeText.implicitWidth + 12

                        StyledText {
                            id: countBadgeText
                            anchors.centerIn: parent
                            text: root.showTrash
                                  ? qsTr(`${root.trashCount}`)
                                  : (root.remainingCount === 0 ? qsTr("All done") : qsTr(`${root.remainingCount} left`))
                            font: Tokens.font.label.small
                            color: root.showTrash
                                   ? Colours.palette.m3onSurfaceVariant
                                   : (root.remainingCount === 0 ? Colours.palette.m3primary : Colours.palette.m3onSurfaceVariant)
                        }
                    }

                    Item { Layout.fillWidth: true }

                    // Empty Trash button (matches other buttons: ButtonBase.Tonal with 2-step confirm)
                    IconButton {
                        visible: root.showTrash && root.trashCount > 0
                        icon: root.confirmEmptyTrash ? "check" : "delete_sweep"
                        type: root.confirmEmptyTrash ? ButtonBase.Filled : ButtonBase.Tonal
                        inactiveColour: root.confirmEmptyTrash ? Colours.palette.m3error : Colours.palette.m3secondaryContainer
                        inactiveOnColour: root.confirmEmptyTrash ? Colours.palette.m3onError : Colours.palette.m3onSecondaryContainer
                        onClicked: {
                            if (!root.confirmEmptyTrash) {
                                root.confirmEmptyTrash = true;
                                confirmEmptyTimer.restart();
                            } else {
                                confirmEmptyTimer.stop();
                                root.confirmEmptyTrash = false;
                                NotesStore.emptyAllTrash();
                            }
                        }
                    }

                    // Trashcan toggle button (switches between active to-dos and cross-marked completed/removed)
                    IconButton {
                        icon: root.showTrash ? "checklist" : "delete_outline"
                        type: root.showTrash ? ButtonBase.Filled : ButtonBase.Tonal
                        onClicked: {
                            root.flushPendingActions();
                            root.confirmEmptyTrash = false;
                            confirmEmptyTimer.stop();
                            root.showTrash = !root.showTrash;
                            if (root.showTrash) {
                                root.isAdding = false;
                                root.calendarPickerOpen = false;
                            }
                        }
                    }

                    // Add button (visible in active to-do mode)
                    IconButton {
                        visible: !root.showTrash
                        icon: root.isAdding ? "close" : "add"
                        type: root.isAdding ? ButtonBase.Text : ButtonBase.Filled
                        onClicked: {
                            root.flushPendingActions();
                            root.isAdding = !root.isAdding;
                            if (root.isAdding) {
                                root.selectedNewDue = "";
                                root.calendarPickerOpen = false;
                                Qt.callLater(() => {
                                    newTodoInput.text = "";
                                    newTodoInput.forceActiveFocus();
                                });
                            } else {
                                root.calendarPickerOpen = false;
                            }
                        }
                    }
                }

                // Inline Add Row (visible when isAdding is true)
                StyledRect {
                    id: inlineAddBox
                    Layout.fillWidth: true
                    Layout.fillHeight: root.isAdding && root.calendarPickerOpen
                    implicitHeight: root.isAdding ? (root.calendarPickerOpen ? 368 : 44) : 0
                    visible: root.isAdding
                    radius: Tokens.rounding.medium
                    color: Colours.tPalette.m3surfaceContainerHigh
                    clip: true

                    Behavior on implicitHeight {
                        Anim {
                            type: Anim.DefaultSpatial
                        }
                    }

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 6
                        spacing: 4

                        // Row 1: Checkbox icon + Input text + Date button + Add button
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 4

                            MaterialShape {
                                Layout.alignment: Qt.AlignVCenter
                                implicitSize: 18
                                shape: MaterialShape.Square
                                color: "transparent"
                                strokeColor: Colours.palette.m3primary
                                strokeWidth: 1.5
                            }

                            TextField {
                                id: newTodoInput
                                Layout.fillWidth: true
                                enabled: !root.calendarPickerOpen
                                placeholderText: qsTr("Add a new to-do…")
                                placeholderTextColor: Colours.palette.m3onSurfaceVariant
                                font: Tokens.font.body.medium
                                color: Colours.palette.m3onSurface
                                background: null
                                padding: 0
                                selectByMouse: true

                                Keys.onReturnPressed: root.commitNewTodo()
                                Keys.onEnterPressed: root.commitNewTodo()
                                Keys.onEscapePressed: {
                                    if (root.calendarPickerOpen) {
                                        root.calendarPickerOpen = false;
                                    } else {
                                        root.isAdding = false;
                                        text = "";
                                        root.selectedNewDue = "";
                                    }
                                }
                            }

                            // Calendar Date Button / Pill
                            CustomMouseArea {
                                id: datePickerTrigger
                                Layout.alignment: Qt.AlignVCenter
                                implicitHeight: 26
                                implicitWidth: dateBtnContent.implicitWidth + 14
                                cursorShape: Qt.PointingHandCursor

                                readonly property var dueInfo: NotesStore.formatDuePill(root.selectedNewDue)

                                StyledRect {
                                    anchors.fill: parent
                                    radius: Tokens.rounding.full
                                    color: root.calendarPickerOpen
                                           ? Colours.palette.m3primary
                                           : (root.selectedNewDue.length > 0 ? Colours.palette.m3surfaceContainerHighest : "transparent")
                                    border.width: 1
                                    border.color: root.calendarPickerOpen
                                                  ? Colours.palette.m3primary
                                                  : (root.selectedNewDue.length > 0 ? Qt.alpha(Colours.palette.m3primary, 0.5) : Qt.alpha(Colours.palette.m3outlineVariant, 0.5))

                                    Behavior on color {
                                        CAnim {}
                                    }

                                    RowLayout {
                                        id: dateBtnContent
                                        anchors.centerIn: parent
                                        spacing: 4

                                        MaterialIcon {
                                            text: root.selectedNewDue.length > 0 ? "event" : "calendar_today"
                                            fontStyle: Tokens.font.icon.small
                                            color: root.calendarPickerOpen
                                                   ? Colours.palette.m3onPrimary
                                                   : (root.selectedNewDue.length > 0 ? Colours.palette.m3primary : Colours.palette.m3onSurfaceVariant)
                                        }

                                        StyledText {
                                            text: datePickerTrigger.dueInfo ? datePickerTrigger.dueInfo.label : qsTr("Date")
                                            font: Tokens.font.label.small
                                            color: root.calendarPickerOpen
                                                   ? Colours.palette.m3onPrimary
                                                   : (root.selectedNewDue.length > 0 ? Colours.palette.m3primary : Colours.palette.m3onSurfaceVariant)
                                        }
                                    }
                                }

                                onClicked: {
                                    root.calendarPickerOpen = !root.calendarPickerOpen;
                                }
                            }

                            IconButton {
                                icon: "check"
                                type: ButtonBase.Text
                                Layout.preferredWidth: 28
                                Layout.preferredHeight: 28
                                onClicked: root.commitNewTodo()
                            }
                        }

                        // Row 2: Embedded Calendar Picker (visible when calendarPickerOpen is true)
                        TodoDatePicker {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: root.calendarPickerOpen
                            currentDateStr: root.selectedNewDue
                            onDateSelected: (dateStr) => {
                                root.selectedNewDue = dateStr;
                                root.calendarPickerOpen = false;
                                Qt.callLater(() => {
                                    newTodoInput.forceActiveFocus();
                                });
                            }
                            onCancelled: {
                                root.calendarPickerOpen = false;
                                Qt.callLater(() => {
                                    newTodoInput.forceActiveFocus();
                                });
                            }
                        }
                    }
                }

                // Scrollable List of Todos (hidden when picking date)
                ScrollView {
                    id: todoScrollView
                    Layout.fillWidth: true
                    Layout.fillHeight: !root.calendarPickerOpen
                    visible: !root.calendarPickerOpen
                    clip: true

                    ColumnLayout {
                        width: todoScrollView.availableWidth
                        spacing: 2

                        // Empty State
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: 40
                            visible: (root.showTrash ? root.trashTodosList.length : root.activeTodos.length) === 0
                            spacing: Tokens.spacing.small

                            MaterialIcon {
                                Layout.alignment: Qt.AlignHCenter
                                text: root.showTrash ? "auto_delete" : "check_circle"
                                fontStyle: Tokens.font.icon.extraLarge
                                color: Colours.palette.m3primary
                                opacity: 0.8
                            }

                            StyledText {
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                                text: root.showTrash ? qsTr("Trash is empty") : qsTr("All clear for today")
                                font: Tokens.font.body.medium
                                color: Colours.palette.m3onSurface
                                wrapMode: Text.Wrap
                            }

                            StyledText {
                                Layout.fillWidth: true
                                Layout.leftMargin: Tokens.padding.medium
                                Layout.rightMargin: Tokens.padding.medium
                                horizontalAlignment: Text.AlignHCenter
                                text: root.showTrash
                                      ? qsTr("Completed and removed tasks will appear here")
                                      : qsTr("Tap + to add your first task")
                                font: Tokens.font.body.small
                                color: Colours.palette.m3onSurfaceVariant
                                wrapMode: Text.Wrap
                            }
                        }

                        // Todo Rows
                        Repeater {
                            id: todoRepeater
                            model: root.showTrash ? root.trashTodosList : root.activeTodos

                            delegate: Item {
                                id: todoRow
                                required property var modelData

                                readonly property string todoId: modelData ? (modelData.id || "") : ""
                                property bool actionCommitted: false
                                readonly property int taskShape: root.getTaskShape(modelData)

                                function commitCompletion() {
                                    if (!actionCommitted && todoId.length > 0) {
                                        actionCommitted = true;
                                        scratchDoneAnimation.stop();
                                        NotesStore.toggleTodo(todoId);
                                    }
                                }

                                function commitDeletion() {
                                    if (!actionCommitted && todoId.length > 0) {
                                        actionCommitted = true;
                                        scratchDeleteAnimation.stop();
                                        NotesStore.deleteTodo(todoId);
                                    }
                                }

                                Component.onDestruction: {
                                    if (isScratching && !actionCommitted) {
                                        commitCompletion();
                                    } else if (isDeleting && !actionCommitted) {
                                        commitDeletion();
                                    }
                                }

                                Layout.fillWidth: true
                                implicitHeight: 38

                                readonly property bool isDone: !!(modelData && modelData.done)
                                readonly property var duePillInfo: NotesStore.formatDuePill(modelData ? modelData.due : null)

                                property bool isScratching: false
                                property bool isDeleting: false
                                property real scratchProgress: 0.0
                                property real rowOpacity: 1.0

                                readonly property bool isRowHovered: rowHoverHandler.hovered || (rowActionBtn && (rowActionBtn.hovered || rowActionBtn.pressed)) || hoverGraceTimer.running

                                HoverHandler {
                                    id: rowHoverHandler
                                    onHoveredChanged: {
                                        if (!hovered) {
                                            hoverGraceTimer.restart();
                                        } else {
                                            hoverGraceTimer.stop();
                                        }
                                    }
                                }

                                Timer {
                                    id: hoverGraceTimer
                                    interval: 200
                                    repeat: false
                                }

                                clip: true
                                opacity: rowOpacity

                                // 1-Second Scratching-Off & Fade-Out Animation for Completion
                                SequentialAnimation {
                                    id: scratchDoneAnimation

                                    ScriptAction {
                                        script: {
                                            todoRow.isScratching = true;
                                        }
                                    }

                                    // Phase 1: Strike line animates across the text (400ms)
                                    ParallelAnimation {
                                        NumberAnimation {
                                            target: todoRow
                                            property: "scratchProgress"
                                            from: 0.0
                                            to: 1.0
                                            duration: 400
                                            easing.type: Easing.OutCubic
                                        }
                                        NumberAnimation {
                                            target: todoLabel
                                            property: "opacity"
                                            to: 0.5
                                            duration: 400
                                        }
                                    }

                                    // Phase 2: Fade out & collapse row height to move rest of tasks up (600ms)
                                    ParallelAnimation {
                                        NumberAnimation {
                                            target: todoRow
                                            property: "rowOpacity"
                                            to: 0.0
                                            duration: 350
                                            easing.type: Easing.InQuad
                                        }
                                        NumberAnimation {
                                            target: todoRow
                                            property: "implicitHeight"
                                            to: 0
                                            duration: 550
                                            easing.type: Easing.InOutQuad
                                        }
                                    }

                                    // Phase 3: Update model state at ~1000ms
                                    ScriptAction {
                                        script: {
                                            todoRow.commitCompletion();
                                        }
                                    }
                                }

                                // 1-Second Scratching-Off & Fade-Out Animation for Deletion
                                SequentialAnimation {
                                    id: scratchDeleteAnimation

                                    ScriptAction {
                                        script: {
                                            todoRow.isDeleting = true;
                                        }
                                    }

                                    // Phase 1: Red scratch line draws across text (400ms)
                                    ParallelAnimation {
                                        NumberAnimation {
                                            target: todoRow
                                            property: "scratchProgress"
                                            from: 0.0
                                            to: 1.0
                                            duration: 400
                                            easing.type: Easing.OutCubic
                                        }
                                        NumberAnimation {
                                            target: todoLabel
                                            property: "opacity"
                                            to: 0.4
                                            duration: 400
                                        }
                                    }

                                    // Phase 2: Fade out & collapse row height (600ms)
                                    ParallelAnimation {
                                        NumberAnimation {
                                            target: todoRow
                                            property: "rowOpacity"
                                            to: 0.0
                                            duration: 350
                                            easing.type: Easing.InQuad
                                        }
                                        NumberAnimation {
                                            target: todoRow
                                            property: "implicitHeight"
                                            to: 0
                                            duration: 550
                                            easing.type: Easing.InOutQuad
                                        }
                                    }

                                    ScriptAction {
                                        script: {
                                            todoRow.commitDeletion();
                                        }
                                    }
                                }

                                // Background highlight on hover
                                StyledRect {
                                    anchors.fill: parent
                                    radius: Tokens.rounding.small
                                    color: Colours.palette.m3onSurface
                                    opacity: todoRow.isRowHovered ? 0.06 : 0

                                    Behavior on opacity {
                                        Anim { type: Anim.FastEffects }
                                    }
                                }

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 6
                                    anchors.rightMargin: 4
                                    spacing: Tokens.spacing.small

                                    // Custom Checkbox with M3Shapes Morphing Animation
                                    CustomMouseArea {
                                        id: checkMouseArea
                                        Layout.alignment: Qt.AlignVCenter
                                        implicitWidth: 22
                                        implicitHeight: 22
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            if (root.showTrash) {
                                                NotesStore.restoreTodo(todoRow.todoId);
                                            } else {
                                                if (!todoRow.isScratching && !todoRow.isDeleting && !todoRow.actionCommitted) {
                                                    scratchDoneAnimation.start();
                                                }
                                            }
                                        }

                                        MaterialShape {
                                            id: checkShape
                                            anchors.centerIn: parent
                                            implicitSize: 18

                                            readonly property bool isChecked: todoRow.isDone || root.showTrash || todoRow.isScratching

                                            shape: isChecked ? todoRow.taskShape : MaterialShape.Square

                                            color: isChecked ? Colours.palette.m3primary : "transparent"
                                            strokeColor: isChecked ? Colours.palette.m3primary : (checkMouseArea.containsMouse || todoRow.isRowHovered ? Colours.palette.m3primary : Colours.palette.m3outline)
                                            strokeWidth: isChecked ? 0 : 1.5

                                            scale: checkMouseArea.pressed ? 0.88 : (checkMouseArea.containsMouse ? 1.08 : 1.0)

                                            animationEasing: Tokens.anim.expressiveDefaultSpatial
                                            animationDuration: Tokens.anim.durations.expressiveDefaultSpatial * Tokens.anim.durations.scale

                                            Behavior on color {
                                                CAnim {}
                                            }

                                            Behavior on strokeColor {
                                                CAnim {}
                                            }

                                            Behavior on scale {
                                                Anim { type: Anim.FastSpatial }
                                            }

                                            MaterialIcon {
                                                anchors.centerIn: parent
                                                text: "check"
                                                fontStyle: Tokens.font.icon.small
                                                color: Colours.palette.m3onPrimary
                                                visible: opacity > 0
                                                opacity: checkShape.isChecked ? 1 : 0
                                                scale: checkShape.isChecked ? 1.0 : 0.4

                                                Behavior on opacity {
                                                    Anim { type: Anim.FastEffects }
                                                }

                                                Behavior on scale {
                                                    Anim { type: Anim.DefaultSpatial }
                                                }
                                            }
                                        }
                                    }

                                    // Label text with click to open view mode & strikethrough / scratching overlay
                                    CustomMouseArea {
                                        Layout.fillWidth: true
                                        Layout.alignment: Qt.AlignVCenter
                                        implicitHeight: Math.max(22, todoLabel.implicitHeight)
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            if (root.showTrash) {
                                                NotesStore.restoreTodo(todoRow.todoId);
                                            } else {
                                                if (!todoRow.isScratching && !todoRow.isDeleting && !todoRow.actionCommitted) {
                                                    NotesStore.openTodo(todoRow.modelData);
                                                }
                                            }
                                        }

                                        Item {
                                            anchors.fill: parent
                                            clip: true

                                            StyledText {
                                                id: todoLabel
                                                anchors.left: parent.left
                                                anchors.right: parent.right
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: todoRow.modelData ? (todoRow.modelData.title || "") : ""
                                                font: Tokens.font.body.medium
                                                color: (todoRow.isDone || root.showTrash || todoRow.isScratching) ? Colours.palette.m3onSurfaceVariant : Colours.palette.m3onSurface
                                                opacity: (todoRow.isDone || root.showTrash) ? 0.7 : 1.0
                                                elide: Text.ElideRight
                                                maximumLineCount: 1

                                                Behavior on opacity {
                                                    Anim {}
                                                }
                                            }

                                            // Subtle Wavy Strike-through & Living Worm Scratch Animation
                                            WavyLine {
                                                id: scratchWavyLine

                                                readonly property bool isActionActive: todoRow.isScratching || todoRow.isDeleting
                                                readonly property bool isResting: (todoRow.isDone || root.showTrash) && !isActionActive

                                                visible: isActionActive || isResting
                                                anchors.left: todoLabel.left
                                                anchors.verticalCenter: todoLabel.verticalCenter
                                                width: Math.max(1, Math.min(todoLabel.implicitWidth, todoLabel.width))
                                                height: 12

                                                lineWidth: 2
                                                amplitudeMultiplier: isActionActive ? 0.75 : 0.55
                                                frequency: Math.max(2, Math.round(width / 24))
                                                fullLength: width
                                                value: isActionActive ? todoRow.scratchProgress : 1.0
                                                color: todoRow.isDeleting ? Colours.palette.m3error : (isActionActive ? Colours.palette.m3primary : Colours.palette.m3onSurfaceVariant)
                                                opacity: isActionActive ? 1.0 : 0.7

                                                Anim on waveProgress {
                                                    running: scratchWavyLine.isActionActive
                                                    from: 0
                                                    to: 1
                                                    duration: 500
                                                    easing.type: Easing.Linear
                                                    loops: Animation.Infinite
                                                }
                                            }
                                        }
                                    }

                                    // Smart Due Pill (Today, Tomorrow, in X days, Overdue)
                                    StyledRect {
                                        visible: !root.showTrash && todoRow.duePillInfo !== null
                                        Layout.alignment: Qt.AlignVCenter
                                        radius: Tokens.rounding.full
                                        implicitHeight: 18
                                        implicitWidth: dueText.implicitWidth + 10
                                        color: {
                                            if (!todoRow.duePillInfo) return Colours.palette.m3surfaceContainerHigh;
                                            switch (todoRow.duePillInfo.status) {
                                                case "overdue": return Colours.palette.m3error;
                                                case "today": return Colours.palette.m3tertiary;
                                                case "tomorrow": return Colours.palette.m3secondaryContainer;
                                                default: return Colours.palette.m3surfaceContainerHigh;
                                            }
                                        }

                                        StyledText {
                                            id: dueText
                                            anchors.centerIn: parent
                                            text: todoRow.duePillInfo ? todoRow.duePillInfo.label : ""
                                            font: Tokens.font.label.small
                                            color: {
                                                if (!todoRow.duePillInfo) return Colours.palette.m3onSurfaceVariant;
                                                switch (todoRow.duePillInfo.status) {
                                                    case "overdue": return Colours.palette.m3onError;
                                                    case "today": return Colours.palette.m3onTertiary;
                                                    case "tomorrow": return Colours.palette.m3onSecondaryContainer;
                                                    default: return Colours.palette.m3onSurfaceVariant;
                                                }
                                            }
                                        }
                                    }

                                    // Fixed-slot action button (NEVER resizes row layout!)
                                    Item {
                                        Layout.preferredWidth: 28
                                        Layout.preferredHeight: 28
                                        Layout.alignment: Qt.AlignVCenter

                                        IconButton {
                                            id: rowActionBtn
                                            anchors.fill: parent
                                            opacity: todoRow.isRowHovered ? 1 : 0
                                            enabled: todoRow.isRowHovered
                                            icon: root.showTrash ? "restore" : "close"
                                            type: ButtonBase.Text
                                            onHoveredChanged: {
                                                if (!hovered && !rowHoverHandler.hovered) {
                                                    hoverGraceTimer.restart();
                                                }
                                            }
                                            onClicked: {
                                                if (root.showTrash) {
                                                    NotesStore.restoreTodo(todoRow.todoId);
                                                } else {
                                                    if (!todoRow.isScratching && !todoRow.isDeleting && !todoRow.actionCommitted) {
                                                        scratchDeleteAnimation.start();
                                                    }
                                                }
                                            }

                                            Behavior on opacity {
                                                Anim { type: Anim.FastEffects }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // ==========================================
        // INDEX 1: TODO DETAIL VIEW (FULL TEXT TAKEOVER)
        // ==========================================
        Item {
            TodoDetailView {
                id: detailView
                anchors.fill: parent
                anchors.margins: Tokens.padding.large
            }
        }
    }

    function flushPendingActions() {
        if (todoRepeater) {
            for (let i = 0; i < todoRepeater.count; ++i) {
                const item = todoRepeater.itemAt(i);
                if (item) {
                    if (item.isScratching && !item.actionCommitted) {
                        item.commitCompletion();
                    } else if (item.isDeleting && !item.actionCommitted) {
                        item.commitDeletion();
                    }
                }
            }
        }
    }

    function commitNewTodo() {
        const text = newTodoInput.text.trim();
        if (text.length > 0) {
            NotesStore.addTodo(text, root.selectedNewDue);
            newTodoInput.text = "";
            root.selectedNewDue = "";
            root.calendarPickerOpen = false;
            root.isAdding = false;
        }
    }
}
