pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Caelestia.Config
import qs.modules.dashboard.notes
import "keep/gtasks.js" as GTasks

// Syncs the to-do list with a Google Tasks list called "Caelestia".
//
// This one uses the official Tasks API, so you need your own OAuth client
// (Desktop app) from Google Cloud. Sign-in: python3 listens on 127.0.0.1 for the
// redirect, we trade the code for a refresh token and put that plus the client
// secret in the keyring (or tasks-token with chmod 600 without secret-tool).
// Requests reuse KeepSync.curl.
//
// tasks-sync.json in ~/.local/state/caelestia: enabled, client id, list id, linked ids
Singleton {
    id: root

    readonly property string stateDir: `${Quickshell.env("HOME")}/.local/state/caelestia`
    readonly property string tokenFile: `${stateDir}/tasks-token`

    property bool enabled: false
    property string clientId: ""
    property bool hasLogin: false
    readonly property bool active: enabled && hasLogin
    property bool busy: false
    property bool signingIn: false
    property string status: ""
    property string lastError: ""
    property real lastSync: 0
    property string listId: ""
    property var linked: []
    property bool windowOpen: false

    // text fields in the window, not saved
    property string draftClientId: ""
    property string draftClientSecret: ""

    property var _oauth: null // { clientId, clientSecret, refreshToken }
    property var _client: null
    property bool _queued: false
    property string _syncedFingerprint: ""
    property var _pending: null // set while signing in: { clientId, clientSecret, verifier, state, redirect }

    readonly property FileView stateFile: FileView {
        path: `${root.stateDir}/tasks-sync.json`
        printErrors: false
        onLoaded: root.loadState(text())
    }

    function loadState(raw) {
        try {
            const d = raw && raw.trim().length ? JSON.parse(raw) : {};
            root.enabled = !!d.enabled;
            root.clientId = d.clientId || "";
            root.listId = d.listId || "";
            root.linked = d.linked || [];
            root.lastSync = d.lastSync || 0;
        } catch (e) {
            console.warn("[TasksSync] tasks-sync.json is unreadable, starting fresh:", e);
        }
        if (root.enabled && root.clientId)
            secretLoad.running = true;
    }

    function saveState() {
        stateFile.setText(JSON.stringify({
            "enabled": root.enabled,
            "clientId": root.clientId,
            "listId": root.listId,
            "linked": root.linked,
            "lastSync": root.lastSync
        }));
    }

    onActiveChanged: {
        root._client = null;
        if (active)
            sync();
    }

    Timer {
        interval: Math.max(1, KeepSync.intervalMinutes) * 60000
        running: root.active
        repeat: true
        onTriggered: root.sync()
    }

    Timer {
        id: debounce
        interval: 4000
        onTriggered: root.sync()
    }

    function todosFingerprint() {
        return JSON.stringify((NotesStore.todos || []).map(t => t ? [t.id, GTasks.localSig(t)] : null));
    }

    Connections {
        target: NotesStore
        function onLoadedChanged() {
            if (NotesStore.loaded)
                root.sync();
        }

        function onVersionChanged() {
            // version also bumps on note changes, so check the to-dos actually changed
            if (root.active && !root.busy && root.todosFingerprint() !== root._syncedFingerprint)
                debounce.restart();
        }
    }

    // qs ipc -c caelestia call taskssync open
    IpcHandler {
        target: "taskssync"
        function open(): void { root.openWindow(); }
        function close(): void { root.windowOpen = false; }
        function sync(): void { root.sync(); }
    }

    function openWindow() {
        if (!root.draftClientId)
            root.draftClientId = root.clientId;
        root.windowOpen = true;
    }

    LazyLoader {
        active: root.windowOpen

        FloatingWindow {
            title: qsTr("Google Tasks sync")
            implicitWidth: 460
            implicitHeight: 560
            color: Colours.palette.m3surface
            onVisibleChanged: if (!visible) root.windowOpen = false

            TasksSyncPanel {
                anchors.fill: parent
                anchors.margins: Tokens.padding.medium
                onClose: root.windowOpen = false
            }
        }
    }

    // ---------------------------------------------------------------- secrets

    Process {
        id: secretStore
        property string secret
        command: ["sh", "-c", "if command -v secret-tool >/dev/null 2>&1; then secret-tool store --label='Caelestia Notes: Google Tasks' service caelestia-notes-tasks account \"$1\" && rm -f \"$2\"; else umask 077; cat > \"$2\"; fi", "sh", root.clientId, root.tokenFile]
        stdinEnabled: true
        onStarted: {
            write(secret);
            secret = "";
            stdinEnabled = false;
        }
        onExited: code => {
            if (code !== 0)
                root.fail(qsTr("Could not store the Google Tasks login"));
        }
    }

    Process {
        id: secretLoad
        command: ["sh", "-c", "secret-tool lookup service caelestia-notes-tasks account \"$1\" 2>/dev/null || cat \"$2\" 2>/dev/null", "sh", root.clientId, root.tokenFile]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const o = JSON.parse(text);
                    if (o && o.refreshToken && o.clientSecret) {
                        root._oauth = { "clientId": root.clientId, "clientSecret": o.clientSecret, "refreshToken": o.refreshToken };
                        root.hasLogin = true;
                        return;
                    }
                } catch (e) {}
                root.hasLogin = false;
                root.status = qsTr("Signed out: login missing");
            }
        }
    }

    Process {
        id: secretClear
        property string account
        command: ["sh", "-c", "secret-tool clear service caelestia-notes-tasks account \"$1\" 2>/dev/null; rm -f \"$2\"", "sh", account, root.tokenFile]
    }

    // ---------------------------------------------------------------- sign-in (loopback)

    // Tiny http server for the OAuth redirect. Prints "PORT <n>", waits for the
    // browser to hit /?..., prints "QUERY <...>" and quits. Gives up after 5 min.
    Process {
        id: listener
        command: ["python3", "-c", "import socket,sys\ns=socket.socket();s.bind(('127.0.0.1',0));s.listen(1);s.settimeout(300)\nprint('PORT',s.getsockname()[1],flush=True)\nwhile True:\n  c,_=s.accept();r=c.recv(65536).decode('latin-1').split(' ')\n  p=r[1] if len(r)>1 else '/'\n  if not p.startswith('/?'):\n    c.sendall(b'HTTP/1.1 404 Not Found\\r\\nContent-Length: 0\\r\\nConnection: close\\r\\n\\r\\n');c.close();continue\n  b=b'<html><body style=\"font-family:sans-serif\"><h2>Caelestia Notes</h2><p>Done. You can close this tab.</p></body></html>'\n  c.sendall(b'HTTP/1.1 200 OK\\r\\nContent-Type: text/html\\r\\nContent-Length: '+str(len(b)).encode()+b'\\r\\nConnection: close\\r\\n\\r\\n'+b);c.close()\n  print('QUERY',p[2:],flush=True);break"]
        stdout: SplitParser {
            onRead: line => root.handleListenerLine(line)
        }
        onExited: code => {
            if (root.signingIn && root._pending && !root._pending.got) {
                root.signingIn = false;
                root._pending = null;
                root.fail(code === 0 ? qsTr("Sign-in cancelled") : qsTr("Sign-in timed out or python3 is missing"));
            }
        }
    }

    function _queryParam(q, key) {
        const parts = q.split("&");
        for (let i = 0; i < parts.length; i++) {
            const kv = parts[i].split("=");
            if (decodeURIComponent(kv[0]) === key)
                return decodeURIComponent((kv[1] || "").replace(/\+/g, " "));
        }
        return "";
    }

    function signIn(clientId, clientSecret) {
        clientId = (clientId || "").trim();
        clientSecret = (clientSecret || "").trim();
        if (!clientId || !clientSecret) {
            fail(qsTr("Client ID and client secret are required"));
            return;
        }
        if (root.signingIn || root.busy)
            return;
        root.lastError = "";
        root.status = qsTr("Waiting for you to approve in the browser…");
        root.signingIn = true;
        root._pending = {
            "clientId": clientId,
            "clientSecret": clientSecret,
            "verifier": GTasks.randomString(64),
            "state": GTasks.randomString(24),
            "got": false
        };
        listener.running = true;
    }

    function cancelSignIn() {
        if (listener.running)
            listener.running = false;
        root.signingIn = false;
        root._pending = null;
        root.status = qsTr("Sign-in cancelled");
    }

    function handleListenerLine(line) {
        const p = root._pending;
        if (!p)
            return;
        if (line.startsWith("PORT ")) {
            p.redirect = "http://127.0.0.1:" + line.substring(5).trim();
            Qt.openUrlExternally(GTasks.authUrl(p.clientId, p.redirect, p.verifier, p.state));
            return;
        }
        if (!line.startsWith("QUERY "))
            return;
        p.got = true;
        const q = line.substring(6);
        const err = _queryParam(q, "error");
        const code = _queryParam(q, "code");
        if (err || !code || _queryParam(q, "state") !== p.state) {
            root.signingIn = false;
            root._pending = null;
            fail(qsTr("Sign-in failed: %1").arg(err || (code ? qsTr("the browser reply did not match this sign-in, try again") : qsTr("no code returned"))));
            return;
        }
        root.status = qsTr("Finishing sign-in…");
        KeepSync.curl(GTasks.codeExchangeRequest(p.clientId, p.clientSecret, code, p.verifier, p.redirect)).then(res => {
            const r = GTasks.parseTokenResponse(res);
            if (!r.refresh_token)
                throw new Error(qsTr("Google returned no refresh token; remove the app's access at myaccount.google.com/permissions and try again"));
            if (root.clientId && root.clientId !== p.clientId) {
                secretClear.account = root.clientId;
                secretClear.running = true;
            }
            root.clientId = p.clientId;
            root._oauth = { "clientId": p.clientId, "clientSecret": p.clientSecret, "refreshToken": r.refresh_token };
            secretStore.secret = JSON.stringify({ "clientSecret": p.clientSecret, "refreshToken": r.refresh_token });
            secretStore.running = true;
            root.draftClientSecret = "";
            root.enabled = true;
            root.hasLogin = true;
            root._client = null;
            saveState();
            root.status = qsTr("Signed in");
            sync();
        }).catch(e => {
            fail(String(e && e.message ? e.message : e));
        }).then(() => {
            root.signingIn = false;
            root._pending = null;
        });
    }

    // Forget the login. To-dos are kept (just unlinked) and nothing gets deleted on Google's side.
    function signOut() {
        if (root.clientId) {
            secretClear.account = root.clientId;
            secretClear.running = true;
        }
        root.enabled = false;
        root.hasLogin = false;
        root._oauth = null;
        root._client = null;
        root.linked = [];
        root.listId = "";
        root.status = qsTr("Signed out");
        NotesStore.todos = (NotesStore.todos || []).map(t => {
            if (!t || !t.taskId)
                return t;
            const c = Object.assign({}, t);
            delete c.taskId;
            delete c.taskLocalSig;
            delete c.taskRemoteSig;
            return c;
        });
        NotesStore.flushSave();
        saveState();
    }

    function fail(msg) {
        root.lastError = msg;
        root.status = msg;
        console.warn("[TasksSync]", msg);
    }

    // ---------------------------------------------------------------- sync

    function sync() {
        if (!root.active || !root._oauth)
            return;
        // never sync against an empty board that has not loaded from notes.json yet
        if (!NotesStore.loaded)
            return;
        if (root.busy) {
            root._queued = true;
            return;
        }
        root.busy = true;
        root.status = qsTr("Syncing…");
        debounce.stop();
        if (!root._client)
            root._client = new GTasks.Client({
                "oauth": root._oauth,
                "transport": req => KeepSync.curl(req)
            });
        const client = root._client;
        let listId = "";
        let snapshot = null;
        let plan = null;

        client.ensureList(root.listId).then(id => {
            listId = id;
            return client.listTasks(id);
        }).then(tasks => {
            snapshot = (NotesStore.todos || []).slice();
            plan = GTasks.reconcile(snapshot, NotesStore.trashTodos || [], tasks, root.linked, Date.now());
            return client.apply(listId, plan.ops);
        }).then(results => {
            const fin = GTasks.finalize(snapshot, NotesStore.todos || [], plan.todos, results);
            NotesStore.todos = fin.todos;
            // don't overwrite the trash, something might have been deleted during the sync
            const known = new Set((NotesStore.trashTodos || []).map(t => t && t.id));
            const added = plan.trashTodos.filter(t => t && !known.has(t.id));
            if (added.length)
                NotesStore.trashTodos = added.concat(NotesStore.trashTodos || []);
            NotesStore.flushSave();
            root._syncedFingerprint = root.todosFingerprint();
            root.listId = listId;
            root.linked = fin.linked;
            root.lastSync = Date.now();
            root.lastError = "";
            root.status = plan.ops.length ? qsTr("Synced, %1 change(s) sent").arg(plan.ops.length) : qsTr("Synced");
            saveState();
        }).catch(e => {
            if (e && e.code === 401)
                root._client = null;
            fail(String(e && e.message ? e.message : e));
        }).then(() => {
            root.busy = false;
            debounce.stop();
            if (root._queued) {
                root._queued = false;
                sync();
            }
        });
    }
}
