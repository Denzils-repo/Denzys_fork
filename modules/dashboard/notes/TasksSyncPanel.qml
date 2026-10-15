pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services

// Contents of the Google Tasks sync window (button is in the to-do header).
StyledRect {
    id: root

    signal close

    radius: Tokens.rounding.large
    color: Colours.palette.m3surfaceContainerHigh

    function relativeTime(ms) {
        if (!ms)
            return qsTr("never");
        const mins = Math.round((Date.now() - ms) / 60000);
        if (mins < 1)
            return qsTr("just now");
        if (mins < 60)
            return qsTr("%1 min ago").arg(mins);
        return new Date(ms).toLocaleString(Qt.locale(), Locale.ShortFormat);
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Tokens.padding.large
        spacing: Tokens.spacing.medium

        RowLayout {
            Layout.fillWidth: true
            spacing: Tokens.spacing.small

            MaterialIcon {
                text: "task_alt"
                color: Colours.palette.m3primary
                fontStyle: Tokens.font.icon.medium
            }

            StyledText {
                Layout.fillWidth: true
                text: qsTr("Google Tasks")
                font: Tokens.font.title.medium
                color: Colours.palette.m3onSurface
            }

            IconButton {
                icon: "close"
                type: ButtonBase.Tonal
                onClicked: root.close()
            }
        }

        // signed in
        ColumnLayout {
            Layout.fillWidth: true
            spacing: Tokens.spacing.small
            visible: TasksSync.hasLogin

            StyledText {
                Layout.fillWidth: true
                text: qsTr("Syncing your to-dos with the \"Caelestia\" list in Google Tasks.\nLast sync: %1").arg(root.relativeTime(TasksSync.lastSync)) + (NotesStore.minuteTick, "")
                font: Tokens.font.body.medium
                color: Colours.palette.m3onSurface
                wrapMode: Text.WordWrap
            }

            StyledText {
                Layout.fillWidth: true
                text: qsTr("Titles, ticks and due dates sync both ways every %1 minutes and a few seconds after you edit. Repeat settings and streaks stay in Caelestia.").arg(KeepSync.intervalMinutes)
                font: Tokens.font.body.small
                color: Colours.palette.m3onSurfaceVariant
                wrapMode: Text.WordWrap
            }

            RowLayout {
                Layout.topMargin: Tokens.spacing.small
                spacing: Tokens.spacing.small

                TextButton {
                    text: TasksSync.busy ? qsTr("Syncing…") : qsTr("Sync now")
                    type: TextButton.Filled
                    disabled: TasksSync.busy
                    onClicked: TasksSync.sync()
                }

                TextButton {
                    text: qsTr("Sign out")
                    type: TextButton.Tonal
                    disabled: TasksSync.busy
                    onClicked: TasksSync.signOut()
                }
            }
        }

        // signed out
        ColumnLayout {
            Layout.fillWidth: true
            spacing: Tokens.spacing.small
            visible: !TasksSync.hasLogin

            StyledText {
                Layout.fillWidth: true
                text: qsTr("Uses your own free Google Cloud login (one-time setup):\n1. console.cloud.google.com: enable \"Google Tasks API\".\n2. Google Auth Platform: External app, add yourself as a test user (or publish it).\n3. Clients → Create client → Desktop app.\n4. Paste its Client ID and Client secret below and click Sign in with Google.")
                font: Tokens.font.body.small
                color: Colours.palette.m3onSurfaceVariant
                wrapMode: Text.WordWrap
            }

            Repeater {
                model: [
                    { "key": "id", "hint": qsTr("Client ID (….apps.googleusercontent.com)"), "secret": false },
                    { "key": "secret", "hint": qsTr("Client secret"), "secret": true }
                ]

                StyledRect {
                    id: field

                    required property var modelData

                    Layout.fillWidth: true
                    implicitHeight: input.implicitHeight + Tokens.padding.medium * 2
                    radius: Tokens.rounding.small
                    color: Colours.palette.m3surfaceContainerHighest

                    TextField {
                        id: input

                        anchors.fill: parent
                        anchors.leftMargin: Tokens.padding.medium
                        anchors.rightMargin: Tokens.padding.medium
                        verticalAlignment: TextInput.AlignVCenter
                        text: field.modelData.key === "id" ? TasksSync.draftClientId : TasksSync.draftClientSecret
                        echoMode: field.modelData.secret ? TextInput.Password : TextInput.Normal
                        placeholderText: field.modelData.hint
                        placeholderTextColor: Colours.palette.m3onSurfaceVariant
                        font: Tokens.font.body.medium
                        color: Colours.palette.m3onSurface
                        background: null
                        padding: 0
                        selectByMouse: true
                        onTextChanged: {
                            if (field.modelData.key === "id")
                                TasksSync.draftClientId = text;
                            else
                                TasksSync.draftClientSecret = text;
                        }
                    }
                }
            }

            RowLayout {
                Layout.topMargin: Tokens.spacing.small
                spacing: Tokens.spacing.small

                TextButton {
                    text: TasksSync.signingIn ? qsTr("Waiting for browser…") : qsTr("Sign in with Google")
                    type: TextButton.Filled
                    disabled: TasksSync.signingIn || TasksSync.draftClientId.trim().length === 0 || TasksSync.draftClientSecret.trim().length === 0
                    onClicked: TasksSync.signIn(TasksSync.draftClientId, TasksSync.draftClientSecret)
                }

                TextButton {
                    visible: TasksSync.signingIn
                    text: qsTr("Cancel")
                    type: TextButton.Tonal
                    onClicked: TasksSync.cancelSignIn()
                }

                TextButton {
                    visible: !TasksSync.signingIn
                    text: qsTr("Open Cloud Console")
                    type: TextButton.Tonal
                    onClicked: Qt.openUrlExternally("https://console.cloud.google.com/apis/library/tasks.googleapis.com")
                }
            }
        }

        StyledText {
            Layout.fillWidth: true
            visible: text.length > 0
            text: TasksSync.lastError.length ? TasksSync.lastError : TasksSync.status
            font: Tokens.font.body.small
            color: TasksSync.lastError.length ? Colours.palette.m3error : Colours.palette.m3onSurfaceVariant
            wrapMode: Text.WordWrap
        }

        Item {
            Layout.fillHeight: true
        }
    }
}
