pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Caelestia.Config
import qs.modules.dashboard.notes
import "keep/gkeep.js" as GKeep
import "keep/mapping.js" as Mapping

// Google Keep sync. The actual Keep protocol lives in keep/gkeep.js (ported from
// gkeepapi), this file just does the curl calls, timers and token storage.
//
// keep-sync.json in ~/.local/state/caelestia has the email, android id and cached
// Keep state. The master token goes in the keyring via secret-tool, or in
// keep-token (chmod 600) if secret-tool isn't installed.
Singleton {
    id: root

    readonly property string stateDir: `${Quickshell.env("HOME")}/.local/state/caelestia`
    readonly property string tokenFile: `${stateDir}/keep-token`

    property string email: ""
    property string androidId: ""
    property bool enabled: false
    property bool signedIn: enabled && email.length > 0 && hasToken
    property bool hasToken: false
    property bool busy: false
    property string status: ""
    property string lastError: ""
    property real lastSync: 0
    property int intervalMinutes: 5

    // Own window instead of a popup in the dashboard, because the dashboard
    // closes as soon as you click into the browser to copy the cookie.
    property bool windowOpen: false
    property string draftEmail: ""
    property string draftToken: "" // never saved, cleared after sign-in

    // "Sign in with browser" runs login.qml in qml6 and we poll its cookies.
    property bool browserBusy: false
    readonly property string loginProfileDir: `${stateDir}/keep-login`
    // needs a plain path, qml6 can't open the qs: url Qt.resolvedUrl gives us
    readonly property string loginQml: `${Quickshell.shellDir}/services/keep/login.qml`

    function openWindow() {
        if (!root.draftEmail)
            root.draftEmail = root.email;
        root.windowOpen = true;
    }

    // qs ipc -c caelestia call keepsync open   (handy for a keybind)
    IpcHandler {
        target: "keepsync"
        function open(): void { root.openWindow(); }
        function close(): void { root.windowOpen = false; }
        function sync(): void { root.sync(); }
    }

    LazyLoader {
        active: root.windowOpen

        FloatingWindow {
            title: qsTr("Google Keep sync")
            implicitWidth: 460
            implicitHeight: 560
            color: Colours.palette.m3surface
            onVisibleChanged: if (!visible) root.windowOpen = false

            KeepSyncPanel {
                anchors.fill: parent
                anchors.margins: Tokens.padding.medium
                onClose: root.windowOpen = false
            }
        }
    }

    property var keepState: GKeep.emptyState()
    property var linked: []
    property bool loaded: false

    property var _client: null
    property string _masterToken: ""
    property bool _resyncQueued: false
    property string _syncedFingerprint: ""

    function notesFingerprint() {
        return JSON.stringify((NotesStore.notes || []).map(n => n ? [n.id, Mapping.localSig(n)] : null));
    }

    readonly property FileView stateFile: FileView {
        path: `${root.stateDir}/keep-sync.json`
        printErrors: false
        onLoaded: root.loadState(text())
        onLoadFailed: root.loaded = true
    }

    Timer {
        id: periodic
        interval: Math.max(1, root.intervalMinutes) * 60000
        running: root.signedIn
        repeat: true
        onTriggered: root.sync()
    }

    // sync a few seconds after an edit
    Timer {
        id: debounce
        interval: 4000
        onTriggered: root.sync()
    }

    Connections {
        target: NotesStore
        function onLoadedChanged() {
            if (NotesStore.loaded)
                root.sync();
        }

        function onVersionChanged() {
            // version also bumps on to-do changes, so check the notes actually changed
            if (root.signedIn && !root.busy && root.notesFingerprint() !== root._syncedFingerprint)
                debounce.restart();
        }
    }

    function loadState(raw) {
        try {
            const d = raw && raw.trim().length ? JSON.parse(raw) : {};
            root.email = d.email || "";
            root.androidId = d.androidId || "";
            root.enabled = !!d.enabled;
            root.lastSync = d.lastSync || 0;
            root.intervalMinutes = d.intervalMinutes || 5;
            root.keepState = d.keepState || GKeep.emptyState();
            root.linked = d.linked || [];
        } catch (e) {
            console.warn("[KeepSync] keep-sync.json is unreadable, starting fresh:", e);
        }
        root.loaded = true;
        if (root.enabled && root.email)
            loadToken();
    }

    function saveState() {
        stateFile.setText(JSON.stringify({
            "email": root.email,
            "androidId": root.androidId,
            "enabled": root.enabled,
            "lastSync": root.lastSync,
            "intervalMinutes": root.intervalMinutes,
            "linked": root.linked,
            "keepState": root.keepState
        }));
    }

    // ---------------------------------------------------------------- transport (curl)

    // Everything goes to curl as a config file on stdin so tokens don't end up in ps.
    function _curlQuote(s) {
        return "\"" + String(s).replace(/\\/g, "\\\\").replace(/"/g, "\\\"").replace(/\n/g, "\\n").replace(/\r/g, "\\r") + "\"";
    }

    function curl(req) {
        return new Promise((resolve, reject) => {
            const lines = [
                "url = " + _curlQuote(req.url),
                "request = " + _curlQuote(req.method || "GET"),
                "silent", "show-error", "http1.1", "compressed",
                "max-time = 60",
                "write-out = " + _curlQuote("\n@@KEEPSTATUS@@%{http_code}")
            ];
            for (const k in req.headers || {})
                lines.push("header = " + _curlQuote(k + ": " + req.headers[k]));
            if (req.body !== undefined)
                lines.push("data-binary = " + _curlQuote(req.body));
            const proc = curlComponent.createObject(root, { config: lines.join("\n") + "\n" });
            proc.done.connect((out, code) => {
                proc.destroy();
                const i = out.lastIndexOf("\n@@KEEPSTATUS@@");
                if (i < 0) {
                    reject(new Error("Network error (curl exit " + code + ")"));
                    return;
                }
                resolve({ "status": parseInt(out.substring(i + 15), 10) || 0, "text": out.substring(0, i) });
            });
            proc.running = true;
        });
    }

    Component {
        id: curlComponent

        Process {
            id: proc

            property string config
            property string output
            property int exitCode: -1
            property int pending: 2
            signal done(string out, int code)

            function step() {
                if (--pending === 0)
                    done(output, exitCode);
            }

            command: ["curl", "--config", "-"]
            stdinEnabled: true
            onStarted: {
                write(config);
                stdinEnabled = false;
            }
            onExited: code => {
                exitCode = code;
                step();
            }
            stdout: StdioCollector {
                onStreamFinished: {
                    proc.output = text;
                    proc.step();
                }
            }
        }
    }

    function sleep(ms) {
        return new Promise(resolve => {
            const t = Qt.createQmlObject("import QtQuick; Timer { repeat: false }", root);
            t.interval = ms;
            t.triggered.connect(() => {
                t.destroy();
                resolve();
            });
            t.start();
        });
    }

    // ---------------------------------------------------------------- secret storage

    Process {
        id: tokenStore
        property string secret
        command: ["sh", "-c", "if command -v secret-tool >/dev/null 2>&1; then secret-tool store --label='Caelestia Notes: Google Keep' service caelestia-notes-keep account \"$1\" && rm -f \"$2\"; else umask 077; cat > \"$2\"; fi", "sh", root.email, root.tokenFile]
        stdinEnabled: true
        onStarted: {
            write(secret);
            secret = "";
            stdinEnabled = false;
        }
        onExited: code => {
            if (code !== 0)
                root.fail(qsTr("Could not store the Keep token"));
        }
    }

    Process {
        id: tokenLoad
        command: ["sh", "-c", "secret-tool lookup service caelestia-notes-keep account \"$1\" 2>/dev/null || cat \"$2\" 2>/dev/null", "sh", root.email, root.tokenFile]
        stdout: StdioCollector {
            onStreamFinished: {
                root._masterToken = text.trim();
                root.hasToken = root._masterToken.length > 0;
                if (root.hasToken)
                    root.sync();
                else
                    root.status = qsTr("Signed out: token missing");
            }
        }
    }

    Process {
        id: tokenClear
        command: ["sh", "-c", "secret-tool clear service caelestia-notes-keep account \"$1\" 2>/dev/null; rm -f \"$2\"", "sh", root.email, root.tokenFile]
    }

    function loadToken() {
        tokenLoad.running = true;
    }

    // ---------------------------------------------------------------- account

    function makeClient() {
        if (!root.androidId)
            root.androidId = GKeep.generateAndroidId();
        root._client = new GKeep.Client({
            "email": root.email,
            "masterToken": root._masterToken || null,
            "androidId": root.androidId,
            "transport": req => root.curl(req),
            "sleep": ms => root.sleep(ms)
        });
        return root._client;
    }

    // ---------------------------------------------------------------- embedded-browser sign-in

    // Opens login.qml and polls for the oauth_token cookie. Once it's there we
    // close the window and do the same exchange as a pasted token.
    function signInWithBrowser() {
        if (root.busy || root.browserBusy)
            return;
        root.lastError = "";
        root.browserBusy = true;
        root.status = qsTr("Opening sign-in window…");
        // start from an empty profile every time
        loginReset.command = ["sh", "-c", "rm -rf \"$1\" && mkdir -p \"$1\" && chmod 700 \"$1\"", "sh", root.loginProfileDir];
        loginReset.running = true;
    }

    function cancelBrowserLogin() {
        loginPoll.stop();
        if (loginBrowser.running)
            loginBrowser.signal(15); // SIGTERM
        root.browserBusy = false;
        if (!root.lastError.length)
            root.status = qsTr("Sign-in cancelled");
        loginWipe.running = true;
    }

    // the profile has a logged in Google session in it, don't leave it lying around
    Process {
        id: loginWipe
        command: ["sh", "-c", "rm -rf \"$1\"", "sh", root.loginProfileDir]
    }

    Process {
        id: loginReset
        onExited: code => {
            if (code !== 0 || !root.browserBusy) {
                root.browserBusy = false;
                if (code !== 0)
                    root.fail(qsTr("Could not prepare the sign-in window"));
                return;
            }
            loginBrowser.running = true;
            root.status = qsTr("Sign in to Google in the window that opened…");
            loginPoll.start();
        }
    }

    Process {
        id: loginBrowser
        // Go through sh to set the env var. Process.environment replaces the whole
        // env instead of adding to it, so qml6 lost WAYLAND_DISPLAY and crashed.
        // --password-store=basic keeps the cookies unencrypted so we can read them.
        command: ["sh", "-c",
            "QTWEBENGINE_CHROMIUM_FLAGS=--password-store=basic QML_XHR_ALLOW_FILE_WRITE=1 exec qml6 \"$1\" -- \"$2\" \"$3\" >\"$4\" 2>&1",
            "sh", root.loginQml, root.loginProfileDir, "https://accounts.google.com/EmbeddedSetup",
            `${root.stateDir}/keep-login.log`]
        onExited: code => {
            // user closed the window before we got a token
            if (root.browserBusy && loginPoll.running) {
                loginPoll.stop();
                root.browserBusy = false;
                if (!root.lastError.length && !root.busy)
                    root.status = qsTr("Sign-in window closed");
                loginWipe.running = true;
            }
        }
    }

    Timer {
        id: loginPoll
        interval: 1500
        repeat: true
        onTriggered: {
            const probe = cookieProbe.createObject(root);
            probe.done.connect(tok => {
                probe.destroy();
                if (!root.browserBusy || !tok)
                    return;
                // "<oauth_token>\t<email>", email is often empty
                const parts = String(tok).split("\t");
                const oauth = (parts[0] || "").trim();
                const mail = (parts[1] || "").trim();
                if (!oauth)
                    return;
                loginPoll.stop();
                root.browserBusy = false;
                if (loginBrowser.running)
                    loginBrowser.signal(15);
                loginWipe.running = true;
                const addr = mail || (root.draftEmail || "").trim();
                if (!addr) {
                    // no email, let the user type it and hit Connect
                    root.draftToken = oauth;
                    root.status = qsTr("Token captured. Enter your email above and click Connect.");
                    return;
                }
                root.signIn(addr, oauth);
            });
            probe.running = true;
        }
    }

    // Cookies is a sqlite db. Using python's sqlite3 so we don't need the sqlite3
    // cli installed. -I so it doesn't import anything from the cwd.
    // Prints "<oauth_token>\t<email>", email comes from email.txt (see login.qml).
    readonly property string cookieReader:
        "import sqlite3,sys,os,urllib.request\n" +
        "d=sys.argv[1]\n" +
        "uri='file:'+urllib.request.pathname2url(d+'/Cookies')+'?mode=ro'\n" +
        "tok=''\n" +
        "try:\n" +
        "    c=sqlite3.connect(uri,uri=True,timeout=1)\n" +
        "    r=c.execute(\"select value from cookies where name='oauth_token' and value<>'' order by length(value) desc limit 1\").fetchone()\n" +
        "    tok=r[0] if r else ''\n" +
        "except Exception:\n" +
        "    pass\n" +
        "email=''\n" +
        "try:\n" +
        "    email=open(os.path.join(d,'email.txt')).read().strip()\n" +
        "except Exception:\n" +
        "    pass\n" +
        "sys.stdout.write(tok+'\\t'+email)\n"

    Component {
        id: cookieProbe
        Process {
            id: p
            signal done(string token)
            command: ["python3", "-I", "-c", root.cookieReader, root.loginProfileDir]
            stdout: StdioCollector {
                onStreamFinished: p.done(text)
            }
        }
    }

    // token can be a master token (aas_et/...) or the oauth_token cookie, which
    // we swap for a master token first
    function signIn(newEmail, token) {
        newEmail = (newEmail || "").trim();
        token = (token || "").trim();
        if (!newEmail || !token) {
            fail(qsTr("Email and token are required"));
            return;
        }
        if (root.busy)
            return;
        root.busy = true;
        root.lastError = "";
        root.status = qsTr("Signing in…");
        if (newEmail !== root.email) {
            root.keepState = GKeep.emptyState();
            root.linked = [];
        }
        root.email = newEmail;
        root._masterToken = token.startsWith("aas_et/") ? token : "";
        const client = makeClient();
        const ready = root._masterToken ? Promise.resolve(token) : client.exchangeToken(token);
        ready.then(master => {
            root._masterToken = master;
            return client.refresh();
        }).then(() => {
            tokenStore.secret = root._masterToken;
            tokenStore.running = true;
            root.hasToken = true;
            root.enabled = true;
            saveState();
            root.busy = false;
            sync();
        }).catch(e => {
            root.busy = false;
            root._masterToken = "";
            root._client = null;
            fail(String(e && e.message ? e.message : e));
        });
    }

    function signOut() {
        tokenClear.running = true;
        root._masterToken = "";
        root._client = null;
        root.hasToken = false;
        root.enabled = false;
        root.keepState = GKeep.emptyState();
        root.linked = [];
        root.status = qsTr("Signed out");
        // keep the notes, just unlink them
        NotesStore.notes = (NotesStore.notes || []).map(n => {
            if (!n || !n.keepId)
                return n;
            const c = Object.assign({}, n);
            delete c.keepId;
            delete c.keepSig;
            return c;
        });
        NotesStore.flushSave();
        saveState();
    }

    function fail(msg) {
        root.lastError = msg;
        root.status = msg;
        console.warn("[KeepSync]", msg);
    }

    // ---------------------------------------------------------------- sync

    function sync() {
        if (!root.signedIn || !root._masterToken)
            return;
        // never sync against an empty board that has not loaded from notes.json yet
        if (!NotesStore.loaded)
            return;
        if (root.busy) {
            root._resyncQueued = true;
            return;
        }
        root.busy = true;
        root.status = qsTr("Syncing…");
        debounce.stop();
        const client = root._client || makeClient();
        // copy, so if the sync fails halfway the saved state is still fine
        const state = JSON.parse(JSON.stringify(root.keepState));
        let snapshot = null;
        let plan = null;

        client.sync(state, []).then(() => {
            snapshot = (NotesStore.notes || []).slice();
            plan = Mapping.reconcile(state, snapshot, root.linked, Date.now());
            return plan.dirty.length ? client.sync(state, plan.dirty) : null;
        }).then(() => {
            const merged = Mapping.mergeConcurrent(snapshot, NotesStore.notes || [], plan.notes);
            NotesStore.notes = Mapping.finalize(state, merged, plan.pushed, Date.now());
            NotesStore.flushSave();
            root._syncedFingerprint = root.notesFingerprint();
            root.keepState = state;
            root.linked = plan.linked;
            root.lastSync = Date.now();
            root.lastError = "";
            root.status = plan.dirty.length ? qsTr("Synced, %1 change(s) sent").arg(plan.dirty.length) : qsTr("Synced");
            saveState();
        }).catch(e => {
            if (e && e.resync) {
                root.keepState = GKeep.emptyState();
                root._resyncQueued = true;
            }
            if (e && e.code === 401)
                root._client = null;
            fail(String(e && e.message ? e.message : e));
        }).then(() => {
            root.busy = false;
            debounce.stop(); // that was our own write, not an edit
            if (root._resyncQueued) {
                root._resyncQueued = false;
                sync();
            }
        });
    }
}
