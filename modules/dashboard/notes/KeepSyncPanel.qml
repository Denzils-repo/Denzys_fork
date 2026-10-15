pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services

// Contents of the Google Keep sync window (KeepSync.qml opens it).
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

    MouseArea {
        anchors.fill: parent // eat clicks on the background
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Tokens.padding.large
        spacing: Tokens.spacing.medium

        RowLayout {
            Layout.fillWidth: true
            spacing: Tokens.spacing.small

            MaterialIcon {
                text: "cloud_sync"
                color: Colours.palette.m3primary
                fontStyle: Tokens.font.icon.medium
            }

            StyledText {
                Layout.fillWidth: true
                text: qsTr("Google Keep")
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
            visible: KeepSync.signedIn

            StyledText {
                Layout.fillWidth: true
                text: qsTr("Signed in as %1").arg(KeepSync.email)
                font: Tokens.font.body.medium
                color: Colours.palette.m3onSurface
                elide: Text.ElideRight
            }

            StyledText {
                Layout.fillWidth: true
                text: qsTr("Last sync: %1").arg(root.relativeTime(KeepSync.lastSync)) + (NotesStore.minuteTick, "")
                font: Tokens.font.body.small
                color: Colours.palette.m3onSurfaceVariant
            }

            StyledText {
                Layout.fillWidth: true
                text: qsTr("Notes sync both ways every %1 minutes and a few seconds after you edit. Checklists use \"- [ ] item\" lines. Archived and trashed Keep notes are not shown.").arg(KeepSync.intervalMinutes)
                font: Tokens.font.body.small
                color: Colours.palette.m3onSurfaceVariant
                wrapMode: Text.WordWrap
            }

            RowLayout {
                Layout.topMargin: Tokens.spacing.small
                spacing: Tokens.spacing.small

                TextButton {
                    text: KeepSync.busy ? qsTr("Syncing…") : qsTr("Sync now")
                    type: TextButton.Filled
                    disabled: KeepSync.busy
                    onClicked: KeepSync.sync()
                }

                TextButton {
                    text: qsTr("Sign out")
                    type: TextButton.Tonal
                    disabled: KeepSync.busy
                    onClicked: KeepSync.signOut()
                }
            }
        }

        // signed out
        ColumnLayout {
            Layout.fillWidth: true
            spacing: Tokens.spacing.small
            visible: !KeepSync.signedIn

            StyledText {
                Layout.fillWidth: true
                text: qsTr("1. Enter your Google account email below.\n2. Click \"Sign in with browser\" — a sign-in window opens.\n3. Log in to Google and tap \"I agree\". The token is captured automatically and exchanged for a master token, stored in your keyring.\n\nManual fallback: paste an oauth_token cookie (from accounts.google.com) or a master token (aas_et/…) into the token field, then click Connect.")
                font: Tokens.font.body.small
                color: Colours.palette.m3onSurfaceVariant
                wrapMode: Text.WordWrap
            }

            Repeater {
                model: [
                    { "key": "email", "hint": qsTr("Google account email"), "secret": false },
                    { "key": "token", "hint": qsTr("oauth_token or master token"), "secret": true }
                ]

                StyledRect {
                    id: field

                    required property var modelData
                    readonly property alias text: input.text

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
                        text: field.modelData.key === "email" ? KeepSync.draftEmail : KeepSync.draftToken
                        echoMode: field.modelData.secret ? TextInput.Password : TextInput.Normal
                        placeholderText: field.modelData.hint
                        placeholderTextColor: Colours.palette.m3onSurfaceVariant
                        font: Tokens.font.body.medium
                        color: Colours.palette.m3onSurface
                        background: null
                        padding: 0
                        selectByMouse: true
                        onTextChanged: {
                            if (field.modelData.key === "email")
                                KeepSync.draftEmail = text;
                            else
                                KeepSync.draftToken = text;
                        }
                        Keys.onReturnPressed: root.submit()
                        Keys.onEnterPressed: root.submit()
                    }
                }
            }

            RowLayout {
                Layout.topMargin: Tokens.spacing.small
                spacing: Tokens.spacing.small

                TextButton {
                    text: KeepSync.browserBusy ? qsTr("Waiting for sign-in…") : qsTr("Sign in with browser")
                    type: TextButton.Filled
                    disabled: KeepSync.busy || KeepSync.browserBusy
                    onClicked: KeepSync.signInWithBrowser()
                }

                TextButton {
                    text: qsTr("Cancel")
                    type: TextButton.Tonal
                    visible: KeepSync.browserBusy
                    onClicked: KeepSync.cancelBrowserLogin()
                }

                TextButton {
                    text: KeepSync.busy ? qsTr("Connecting…") : qsTr("Connect")
                    type: TextButton.Tonal
                    visible: !KeepSync.browserBusy
                    disabled: KeepSync.busy || KeepSync.draftEmail.trim().length === 0 || KeepSync.draftToken.trim().length === 0
                    onClicked: root.submit()
                }
            }
        }

        StyledText {
            Layout.fillWidth: true
            visible: text.length > 0
            text: KeepSync.lastError.length ? KeepSync.lastError : KeepSync.status
            font: Tokens.font.body.small
            color: KeepSync.lastError.length ? Colours.palette.m3error : Colours.palette.m3onSurfaceVariant
            wrapMode: Text.WordWrap
        }

        Item {
            Layout.fillHeight: true
        }
    }

    function submit() {
        if (KeepSync.busy)
            return;
        KeepSync.signIn(KeepSync.draftEmail, KeepSync.draftToken);
        KeepSync.draftToken = "";
    }
}
