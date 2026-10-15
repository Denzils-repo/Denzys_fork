// Browser window for the Google Keep sign-in.
//
// This runs in qml6, not in Quickshell (Quickshell doesn't set up QtWebEngine):
//
//   QTWEBENGINE_CHROMIUM_FLAGS=--password-store=basic \
//       qml6 login.qml -- <profileDir> [startUrl]
//
// Opens accounts.google.com/EmbeddedSetup with a temporary profile in
// <profileDir>. After you sign in and hit "I agree", Google sets an oauth_token
// cookie. KeepSync.qml keeps checking the Cookies db, and when the cookie is
// there it kills this window and trades the cookie for a master token.
//
// --password-store=basic is there so the cookies aren't encrypted on disk.

import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtWebEngine

Window {
    id: win

    // args after "--": [profileDir, startUrl?]
    readonly property var _args: Qt.application.arguments
    readonly property int _sep: _args.indexOf("--")
    readonly property string profileDir: _sep >= 0 && _args.length > _sep + 1 ? _args[_sep + 1] : ""
    readonly property string startUrl: _sep >= 0 && _args.length > _sep + 2 ? _args[_sep + 2] : "https://accounts.google.com/EmbeddedSetup"

    width: 520
    height: 680
    visible: true
    title: qsTr("Sign in to Google Keep")
    color: "#202124"

    WebEngineProfile {
        id: profile
        storageName: "keep-login"
        persistentStoragePath: win.profileDir
        offTheRecord: false
        persistentCookiesPolicy: WebEngineProfile.ForcePersistentCookies
    }

    Column {
        anchors.fill: parent
        spacing: 0

        Rectangle {
            width: parent.width
            height: 40
            color: "#2d2e30"

            Row {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                spacing: 8

                Label {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    elide: Text.ElideRight
                    color: "#e8eaed"
                    font.pixelSize: 13
                    text: view.loading
                        ? qsTr("Loading…")
                        : qsTr("Sign in and tap “I agree”. This window closes automatically.")
                }
            }
        }

        WebEngineView {
            id: view
            width: parent.width
            height: parent.height - 40
            profile: profile
            url: win.startUrl

            onCertificateError: error => error.rejectCertificate()
        }
    }

    // Try to grab the email off the page and save it to email.txt so you don't
    // have to type it. If it doesn't find one you just enter it yourself.
    property bool _emailWritten: false

    function _writeEmail(addr) {
        if (win._emailWritten || !addr)
            return;
        win._emailWritten = true;
        try {
            const xhr = new XMLHttpRequest();
            xhr.open("PUT", "file://" + win.profileDir + "/email.txt");
            xhr.send(addr);
        } catch (e) {
            win._emailWritten = false;
        }
    }

    Timer {
        interval: 1500
        repeat: true
        running: !win._emailWritten
        onTriggered: {
            view.runJavaScript(
                "(function(){try{" +
                "var t=(document.body&&document.body.innerText)||'';" +
                "var m=t.match(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}/g);" +
                "if(!m)return '';" +
                "for(var i=0;i<m.length;i++){var e=m[i],lo=e.toLowerCase();" +
                "if(lo.indexOf('@google.com')>=0)continue;" +
                "if(lo.indexOf('@gstatic.')>=0)continue;" +
                "return e;}return '';" +
                "}catch(e){return '';}})()",
                function (res) { if (res) win._writeEmail(String(res).trim()); });
        }
    }
}
