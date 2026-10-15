.pragma library
.import "gkeep.js" as G

// Google Tasks sync logic for the to-do list, using the normal Tasks REST API
// (https://tasks.googleapis.com/tasks/v1).
//
// TasksSync.qml logs in with your own OAuth client (opts.oauth). The older route
// that borrows the Keep master token is still here but nothing uses it right now.
//
// Everything goes into one list, LIST_TITLE, which we create if it's missing.
// Linked to-dos get three extra fields:
//   taskId         the Google task id
//   taskLocalSig   sig of the to-do at the last sync
//   taskRemoteSig  sig of the Google task at the last sync
// If both sides changed, ours wins. No I/O in here, see tests/gtasks.test.js.

var API = "https://tasks.googleapis.com/tasks/v1";
var SCOPE = "oauth2:https://www.googleapis.com/auth/tasks";
var TASKS_APP = "com.google.android.apps.tasks";
// Only some Google apps are allowed the Tasks scope (you get
// UNREGISTERED_ON_API_CONSOLE otherwise), so we just try these one by one.
var TASKS_APPS = [TASKS_APP, "com.google.android.calendar", "com.google.android.gm", "com.google.android.gms"];
var LIST_TITLE = "Caelestia";

function _pad(n) { return (n < 10 ? "0" : "") + n; }

function dateStr(d) {
    return d.getFullYear() + "-" + _pad(d.getMonth() + 1) + "-" + _pad(d.getDate());
}

// our due values can be "YYYY-MM-DD", "today", "tomorrow", "" or "none"; turn them into "YYYY-MM-DD" or ""
function normalizeDue(due, nowMs) {
    if (!due || typeof due !== "string") return "";
    var s = due.trim().toLowerCase();
    if (!s || s === "none") return "";
    var d = new Date(nowMs);
    if (s === "today") return dateStr(d);
    if (s === "tomorrow") { d.setDate(d.getDate() + 1); return dateStr(d); }
    var m = /^(\d{4})-(\d{2})-(\d{2})/.exec(s);
    return m ? m[1] + "-" + m[2] + "-" + m[3] : "";
}

function sig(title, done, due) { return JSON.stringify([title || "", !!done, due || ""]); }
function localSig(t) { return sig(t.title, t.done, t.due && t.due !== "none" ? t.due : ""); }
function remoteSig(task) { return sig(task.title, task.status === "completed", task.due ? task.due.substring(0, 10) : ""); }

// request body for creating/patching a task
function taskBody(t, nowMs) {
    var due = normalizeDue(t.due, nowMs);
    var body = {
        "title": String(t.title || ""),
        "status": t.done ? "completed" : "needsAction",
        "due": due ? due + "T00:00:00.000Z" : null
    };
    if (!t.done) body.completed = null;
    return body;
}

function _today(nowMs) { return dateStr(new Date(nowMs)); }

// copy a remote change into the to-do (streaks work like NotesStore.toggleTodo)
function todoFromTask(t, task, nowMs) {
    var c = Object.assign({}, t);
    c.title = String(task.title || "").slice(0, 300);
    var done = task.status === "completed";
    if (done !== !!t.done) {
        c.done = done;
        if (c.repeating && done && c.lastCompletedDate !== _today(nowMs)) {
            c.streak = (c.streak || 0) + 1;
            c.lastCompletedDate = _today(nowMs);
        }
    }
    var remoteDue = task.due ? task.due.substring(0, 10) : "";
    if (remoteDue !== normalizeDue(t.due, nowMs)) c.due = remoteDue;
    c.taskId = task.id;
    c.taskLocalSig = localSig(c);
    c.taskRemoteSig = remoteSig(task);
    return c;
}

function newTodoFromTask(task, nowMs) {
    return todoFromTask({
        "id": "todo_gtask_" + task.id,
        "title": "",
        "done": false,
        "due": "",
        "repeating": false,
        "streak": 0,
        "lastCompletedDate": "",
        "type": "task",
        "createdAt": nowMs,
        "shapeIndex": Math.floor(Math.random() * 1000)
    }, task, nowMs);
}

// Works out what to send and what to change locally. `tasks` is everything in
// the list, completed/hidden ones too. Returns { todos, trashTodos, ops, linked }.
// ops: { kind: "create", todoId, body } | { kind: "patch", todoId, taskId, body } | { kind: "delete", taskId }
function reconcile(todos, trashTodos, tasks, linkedIds, nowMs) {
    var remote = {};
    (tasks || []).forEach(function (k) { if (k && k.id && !k.deleted) remote[k.id] = k; });
    var linkedBefore = {};
    (linkedIds || []).forEach(function (id) { linkedBefore[id] = true; });

    var ops = [];
    var seen = {};
    var outTodos = [];
    var outTrash = (trashTodos || []).slice();

    // go oldest first so new tasks end up in the same order as our list (newest on top)
    (todos || []).filter(function (t) { return !!t; }).slice().reverse().forEach(function (t) {
        var task = t.taskId ? remote[t.taskId] : null;
        var localDirty = !t.taskId || localSig(t) !== t.taskLocalSig;

        if (t.taskId && !task) {
            if (!localDirty) {
                // deleted on the Google side, put it in our trash
                outTrash.unshift(Object.assign({}, t, { done: true, deletedAt: nowMs }));
                return;
            }
            t = Object.assign({}, t);
            delete t.taskId;
        }

        if (!t.taskId) {
            if (!String(t.title || "").trim()) { outTodos.push(t); return; }
            ops.push({ kind: "create", todoId: t.id, body: taskBody(t, nowMs) });
        } else if (localDirty) {
            ops.push({ kind: "patch", todoId: t.id, taskId: t.taskId, body: taskBody(t, nowMs) });
            seen[t.taskId] = true;
        } else if (remoteSig(task) !== t.taskRemoteSig) {
            t = todoFromTask(t, task, nowMs);
            seen[t.taskId] = true;
        } else {
            seen[t.taskId] = true;
        }
        outTodos.push(t);
    });
    outTodos.reverse();

    Object.keys(remote).forEach(function (id) {
        if (seen[id]) return;
        if (linkedBefore[id]) {
            ops.push({ kind: "delete", taskId: id }); // we deleted it since last sync
        } else if (String(remote[id].title || "").trim()) {
            seen[id] = true;
            outTodos.unshift(newTodoFromTask(remote[id], nowMs));
        }
    });

    return { todos: outTodos, trashTodos: outTrash, ops: ops, linked: Object.keys(seen) };
}

// Runs after the ops. `results` is todoId -> task that came back from create/patch.
// `current` is NotesStore.todos right now, so anything edited mid-sync isn't lost.
function finalize(snapshot, current, planned, results) {
    var snap = {}, cur = {};
    (snapshot || []).forEach(function (t) { if (t) snap[t.id] = t; });
    (current || []).forEach(function (t) { if (t) cur[t.id] = t; });
    var out = [];
    var linked = [];
    (planned || []).forEach(function (p) {
        var c = p;
        if (p.id in snap) {
            c = cur[p.id];
            if (!c) return; // deleted mid-sync, next sync removes it from Tasks
            var editedMeanwhile = localSig(c) !== localSig(snap[p.id]);
            if (!editedMeanwhile) c = p;
            else c = Object.assign({}, c, { taskId: p.taskId, taskLocalSig: p.taskLocalSig, taskRemoteSig: p.taskRemoteSig });
            var task = results[p.id];
            if (task) {
                c = Object.assign({}, c, { taskId: task.id, taskRemoteSig: remoteSig(task) });
                // store the sig of what we sent, so a mid-sync edit still counts as changed
                c.taskLocalSig = localSig(snap[p.id]);
            }
        }
        if (c.taskId) linked.push(c.taskId);
        out.push(c);
    });
    (current || []).forEach(function (t) { if (t && !(t.id in snap)) out.unshift(t); });
    return { todos: out, linked: linked };
}

// ---------------------------------------------------------------- OAuth
//
// Standard "Desktop app" flow: redirect to 127.0.0.1, plain PKCE, and
// access_type=offline so we get a refresh token.

var AUTH_ENDPOINT = "https://accounts.google.com/o/oauth2/v2/auth";
var TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token";
var OAUTH_SCOPE = "https://www.googleapis.com/auth/tasks";

function _form(data) {
    var parts = [];
    for (var k in data) parts.push(encodeURIComponent(k) + "=" + encodeURIComponent(String(data[k])));
    return parts.join("&");
}

function randomString(len) {
    var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~";
    var s = "";
    for (var i = 0; i < len; i++) s += chars.charAt(Math.floor(Math.random() * chars.length));
    return s;
}

function authUrl(clientId, redirectUri, verifier, state) {
    return AUTH_ENDPOINT + "?" + _form({
        "client_id": clientId,
        "redirect_uri": redirectUri,
        "response_type": "code",
        "scope": OAUTH_SCOPE,
        "access_type": "offline",
        "prompt": "consent",
        "code_challenge": verifier,
        "code_challenge_method": "plain",
        "state": state
    });
}

function _tokenPost(data) {
    return {
        method: "POST",
        url: TOKEN_ENDPOINT,
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: _form(data)
    };
}

function codeExchangeRequest(clientId, clientSecret, code, verifier, redirectUri) {
    return _tokenPost({
        "client_id": clientId,
        "client_secret": clientSecret,
        "code": code,
        "code_verifier": verifier,
        "grant_type": "authorization_code",
        "redirect_uri": redirectUri
    });
}

function refreshTokenRequest(clientId, clientSecret, refreshToken) {
    return _tokenPost({
        "client_id": clientId,
        "client_secret": clientSecret,
        "refresh_token": refreshToken,
        "grant_type": "refresh_token"
    });
}

// throws with Google's error message if there's no access token
function parseTokenResponse(res) {
    var r = null;
    try { r = JSON.parse(res.text); } catch (e) { r = null; }
    if (!r || !r.access_token) {
        var msg = r ? (r.error_description || r.error) : ("HTTP " + res.status);
        throw new Error("Google sign-in failed: " + msg);
    }
    return r;
}

// ---------------------------------------------------------------- client

// opts: { oauth, transport } or the old { email, masterToken, androidId, transport }
function Client(opts) {
    this.email = opts.email;
    this.masterToken = opts.masterToken;
    this.androidId = opts.androidId;
    this.transport = opts.transport;
    this.authTransport = opts.authTransport || opts.transport;
    this.token = null;
    this.app = opts.app || null; // whichever app worked last time
    this.oauth = opts.oauth || null; // { clientId, clientSecret, refreshToken }
}

Client.prototype.refresh = function () {
    var self = this;
    if (self.oauth) {
        return self.authTransport(refreshTokenRequest(self.oauth.clientId, self.oauth.clientSecret, self.oauth.refreshToken)).then(function (res) {
            self.token = parseTokenResponse(res).access_token;
            return self.token;
        });
    }
    var apps = self.app ? [self.app] : TASKS_APPS;
    var errors = [];
    function attempt(i) {
        if (i >= apps.length)
            return Promise.reject(new Error("Google Tasks login failed: " + errors.join(", ")));
        return self.authTransport(G.oauthRequest(self.email, self.masterToken, self.androidId, SCOPE, apps[i])).then(function (res) {
            var r = G.parseAuthResponse(res.text);
            if (r.Auth) {
                self.app = apps[i];
                self.token = r.Auth;
                return r.Auth;
            }
            var e = r.Error || ("HTTP " + res.status);
            errors.push(apps[i].replace("com.google.android.", "") + ": " + e);
            // these are about the account, trying another app won't help
            if (e === "BadAuthentication" || e === "NeedsBrowser") return Promise.reject(new Error("Google Tasks login failed: " + e));
            return attempt(i + 1);
        });
    }
    return attempt(0);
};

// single API call, gets a new token and retries once on a 401
Client.prototype.call = function (method, path, body) {
    var self = this;
    var retried = false;
    function attempt() {
        var ready = self.token ? Promise.resolve() : self.refresh();
        return ready.then(function () {
            var req = { method: method, url: API + path, headers: { "Authorization": "Bearer " + self.token } };
            if (body !== undefined) {
                req.headers["Content-Type"] = "application/json";
                req.body = JSON.stringify(body);
            }
            return self.transport(req);
        }).then(function (res) {
            if (res.status === 401 && !retried) {
                retried = true;
                self.token = null;
                return attempt();
            }
            if (res.status === 404 && method === "DELETE") return null; // already gone
            if (res.status < 200 || res.status >= 300) {
                var msg = "HTTP " + res.status;
                try { msg = JSON.parse(res.text).error.message || msg; } catch (e) {}
                var err = new Error("Google Tasks error: " + msg);
                err.code = res.status;
                throw err;
            }
            return res.text ? JSON.parse(res.text) : null;
        });
    }
    return attempt();
};

// find our list (by saved id, then by name) or make it
Client.prototype.ensureList = function (knownId) {
    var self = this;
    return self.call("GET", "/users/@me/lists?maxResults=100").then(function (r) {
        var lists = (r && r.items) || [];
        var hit = lists.filter(function (l) { return l.id === knownId; })[0]
            || lists.filter(function (l) { return l.title === LIST_TITLE; })[0];
        if (hit) return hit.id;
        return self.call("POST", "/users/@me/lists", { "title": LIST_TITLE }).then(function (l) { return l.id; });
    });
};

Client.prototype.listTasks = function (listId) {
    var self = this;
    var all = [];
    function page(token) {
        var q = "?showCompleted=true&showHidden=true&maxResults=100" + (token ? "&pageToken=" + encodeURIComponent(token) : "");
        return self.call("GET", "/lists/" + encodeURIComponent(listId) + "/tasks" + q).then(function (r) {
            all = all.concat((r && r.items) || []);
            return r && r.nextPageToken ? page(r.nextPageToken) : all;
        });
    }
    return page(null);
};

// runs the ops one after another, resolves to { todoId: task } for creates/patches
Client.prototype.apply = function (listId, ops) {
    var self = this;
    var results = {};
    var base = "/lists/" + encodeURIComponent(listId) + "/tasks";
    return ops.reduce(function (p, op) {
        return p.then(function () {
            if (op.kind === "create")
                return self.call("POST", base, op.body).then(function (t) { results[op.todoId] = t; });
            if (op.kind === "patch")
                return self.call("PATCH", base + "/" + encodeURIComponent(op.taskId), op.body).then(function (t) { results[op.todoId] = t; });
            return self.call("DELETE", base + "/" + encodeURIComponent(op.taskId));
        });
    }, Promise.resolve()).then(function () { return results; });
};
