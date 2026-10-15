.pragma library
// JS port of the parts of gkeepapi (https://github.com/kiwiz/gkeepapi) we need
// to sync notes. gkeepapi is the unofficial Keep client.
//
// Ported: APIAuth.refresh (gpsoauth.perform_oauth), gpsoauth.exchange_token,
// KeepAPI.changes and its retries, Keep._sync_notes / _parseNodes, and the node
// format for Note / List / ListItem.
// Skipped: password login (needs RSA and Google blocks it anyway), reminders,
// media, editing labels, collaborators, drawings.
//
// No QML or Node specific code. Requests go through the `transport` function
// you pass in, which is how tests/gkeep.test.js runs it under Node.
//
// Portions derived from gkeepapi:
//   The MIT License (MIT) - Copyright 2017 Kai Zhong
//   See services/keep/LICENSE.gkeepapi.txt for the full notice.

var AUTH_URL = "https://android.clients.google.com/auth";
var AUTH_USER_AGENT = "GoogleAuth/1.4";
var API_URL = "https://www.googleapis.com/notes/v1/";
var SCOPES = "oauth2:https://www.googleapis.com/auth/memento https://www.googleapis.com/auth/reminders";
var KEEP_APP = "com.google.android.keep";
var CLIENT_SIG = "38918a453d07199354f8b19af05ec6562ced5788";
var ROOT_ID = "root";
var RETRY_CNT = 2;
var EPOCH = "1970-01-01T00:00:00.000Z";

var COLORS = ["DEFAULT", "RED", "ORANGE", "YELLOW", "GREEN", "TEAL", "BLUE", "CERULEAN", "PURPLE", "PINK", "BROWN", "GRAY"];

// ------------------------------------------------------------------ helpers

function _randInt(min, max) {
    return min + Math.floor(Math.random() * (max - min + 1));
}

function _randHex(len) {
    var s = "";
    for (var i = 0; i < len; i++) s += Math.floor(Math.random() * 16).toString(16);
    return s;
}

function _pad(n, w) {
    var s = String(n);
    while (s.length < w) s = "0" + s;
    return s;
}

// NodeTimestamps.int_to_str: "%Y-%m-%dT%H:%M:%S.%fZ" (microseconds)
function tsToStr(ms) {
    var d = new Date(ms);
    return d.getUTCFullYear() + "-" + _pad(d.getUTCMonth() + 1, 2) + "-" + _pad(d.getUTCDate(), 2)
        + "T" + _pad(d.getUTCHours(), 2) + ":" + _pad(d.getUTCMinutes(), 2) + ":" + _pad(d.getUTCSeconds(), 2)
        + "." + _pad(d.getUTCMilliseconds(), 3) + "000Z";
}

// NodeTimestamps.str_to_dt, returning epoch milliseconds (0 for missing).
function strToMs(s) {
    if (!s) return 0;
    var m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?Z$/.exec(s);
    if (!m) return 0;
    var frac = m[7] ? parseInt((m[7] + "000").substring(0, 3), 10) : 0;
    return Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6], frac);
}

// Node._generateId: "<hex ms>.<16 hex random>"
function generateId(nowMs) {
    return Math.floor(nowMs).toString(16) + "." + _randHex(16);
}

// KeepAPI._generateId: "s--<ms>--<10 digit random>"
function generateSessionId(nowMs) {
    return "s--" + Math.floor(nowMs) + "--" + _randInt(1000000000, 9999999999);
}

// fake Android ID (16 hex chars), made once and saved
function generateAndroidId() {
    return _randHex(16);
}

function _formEncode(data) {
    var parts = [];
    for (var k in data) parts.push(encodeURIComponent(k) + "=" + encodeURIComponent(String(data[k])));
    return parts.join("&");
}

// gpsoauth.google.parse_auth_response: "Key=value" lines.
function parseAuthResponse(text) {
    var out = {};
    String(text || "").split("\n").forEach(function (line) {
        var i = line.indexOf("=");
        if (i > 0) out[line.substring(0, i)] = line.substring(i + 1);
    });
    return out;
}

// ------------------------------------------------------------------ gpsoauth

var _deviceDefaults = {
    "device_country": "us",
    "operatorCountry": "us",
    "lang": "en",
    "sdk_version": 17,
    "google_play_services_version": 240913000
};

function _withDefaults(data) {
    for (var k in _deviceDefaults) data[k] = _deviceDefaults[k];
    return data;
}

// gpsoauth.perform_oauth like APIAuth.refresh calls it. service/app default to
// Keep, gtasks.js passes its own.
function oauthRequest(email, masterToken, androidId, service, app) {
    return {
        method: "POST",
        url: AUTH_URL,
        headers: {
            "Accept-Encoding": "identity",
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": AUTH_USER_AGENT
        },
        body: _formEncode(_withDefaults({
            "accountType": "HOSTED_OR_GOOGLE",
            "Email": email,
            "has_permission": 1,
            "EncryptedPasswd": masterToken,
            "service": service || SCOPES,
            "source": "android",
            "androidId": androidId,
            "app": app || KEEP_APP,
            "client_sig": CLIENT_SIG
        }))
    };
}

// gpsoauth.exchange_token: browser oauth_token cookie -> master token.
function exchangeTokenRequest(email, oauthToken, androidId) {
    return {
        method: "POST",
        url: AUTH_URL,
        headers: {
            "Accept-Encoding": "identity",
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": AUTH_USER_AGENT
        },
        body: _formEncode(_withDefaults({
            "accountType": "HOSTED_OR_GOOGLE",
            "Email": email,
            "has_permission": 1,
            "add_account": 1,
            "ACCESS_TOKEN": 1,
            "Token": oauthToken,
            "service": "ac2dm",
            "source": "android",
            "androidId": androidId,
            "client_sig": CLIENT_SIG,
            "callerSig": CLIENT_SIG,
            "droidguard_results": "dummy123"
        }))
    };
}

// ------------------------------------------------------------------ changes request

var CAPABILITIES = ["NC", "PI", "LB", "AN", "SH", "DR", "TR", "IN", "SNB", "MI", "CO"];

function changesRequest(authToken, sessionId, targetVersion, nodes, labels, nowMs) {
    var params = {
        "nodes": nodes || [],
        "clientTimestamp": tsToStr(nowMs),
        "requestHeader": {
            "clientSessionId": sessionId,
            "clientPlatform": "ANDROID",
            "clientVersion": { "major": "9", "minor": "9", "build": "9", "revision": "9" },
            "capabilities": CAPABILITIES.map(function (t) { return { "type": t }; })
        }
    };
    if (targetVersion) params["targetVersion"] = targetVersion;
    if (labels && labels.length) params["userInfo"] = { "labels": labels };
    return {
        method: "POST",
        url: API_URL + "changes",
        headers: {
            "Authorization": "OAuth " + authToken,
            "Content-Type": "application/json"
        },
        body: JSON.stringify(params)
    };
}

// ------------------------------------------------------------------ state / node tree

// state is plain JSON so KeepSync can just write it to disk:
//   { version: "<toVersion>", nodes: { id: rawNode }, labels: [rawLabel] }
function emptyState() {
    return { version: null, nodes: {}, labels: [] };
}

function isTopLevel(node) {
    return node && node.parentId === ROOT_ID && (node.type === "NOTE" || node.type === "LIST");
}

function isTrashed(node) {
    return !!(node && node.timestamps && strToMs(node.timestamps.trashed) > 0);
}

function isDeleted(node) {
    return !!(node && node.timestamps && strToMs(node.timestamps.deleted) > 0);
}

// Keep._parseNodes + _parseUserInfo. Returns ids of top-level nodes touched.
function applyChanges(state, changes) {
    var touched = {};
    if (changes.userInfo && changes.userInfo.labels) state.labels = changes.userInfo.labels;
    (changes.nodes || []).forEach(function (raw) {
        if (!raw || !raw.id) return;
        var existing = state.nodes[raw.id];
        if (!("parentId" in raw)) {
            // no parentId means it was deleted on the server
            if (existing) {
                touched[existing.parentId === ROOT_ID ? existing.id : existing.parentId] = true;
                delete state.nodes[raw.id];
            }
            return;
        }
        if (raw.kind && raw.kind !== "notes#node") return;
        if (raw.mergeConflict) {
            // gkeepapi throws MergeException here, we just take the server's copy
            delete raw.mergeConflict;
        }
        state.nodes[raw.id] = existing ? Object.assign({}, existing, raw) : raw;
        touched[raw.parentId === ROOT_ID ? raw.id : raw.parentId] = true;
    });
    if (changes.toVersion) state.version = changes.toVersion;
    // clean up list items whose note is gone
    for (var id in state.nodes) {
        var n = state.nodes[id];
        if (n.parentId !== ROOT_ID && !state.nodes[n.parentId]) delete state.nodes[id];
    }
    return Object.keys(touched);
}

function childrenOf(state, parentId) {
    var out = [];
    for (var id in state.nodes) {
        var n = state.nodes[id];
        if (n.parentId === parentId && n.type === "LIST_ITEM" && !isDeleted(n)) out.push(n);
    }
    return out;
}

// simpler List.sorted_items: highest sortValue first, subitems right after their parent
function sortedItems(state, listId) {
    var items = childrenOf(state, listId);
    var bySort = function (a, b) { return Number(b.sortValue || 0) - Number(a.sortValue || 0); };
    var top = items.filter(function (i) { return !i.superListItemId; }).sort(bySort);
    var out = [];
    top.forEach(function (t) {
        out.push({ node: t, indent: 0 });
        items.filter(function (i) { return i.superListItemId === t.id; }).sort(bySort)
            .forEach(function (s) { out.push({ node: s, indent: 1 }); });
    });
    // subitems without a parent go last
    items.forEach(function (i) {
        if (i.superListItemId && !out.some(function (o) { return o.node === i; })) out.push({ node: i, indent: 0 });
    });
    return out;
}

function noteText(state, node) {
    if (node.type === "LIST") {
        return sortedItems(state, node.id).map(function (e) {
            return (e.indent ? "  " : "") + "- [" + (e.node.checked ? "x" : " ") + "] " + (e.node.text || "");
        }).join("\n");
    }
    var kids = childrenOf(state, node.id);
    return kids.length ? (kids[0].text || "") : (node.text || "");
}

// every note that isn't trashed or deleted, as simple objects
function topLevelNotes(state, includeArchived) {
    var out = [];
    for (var id in state.nodes) {
        var n = state.nodes[id];
        if (!isTopLevel(n) || isTrashed(n) || isDeleted(n)) continue;
        if (n.isArchived && !includeArchived) continue;
        out.push({
            id: n.id,
            serverId: n.serverId || null,
            type: n.type,
            title: n.title || "",
            text: noteText(state, n),
            color: n.color || "DEFAULT",
            pinned: !!n.isPinned,
            archived: !!n.isArchived,
            created: strToMs(n.timestamps && n.timestamps.created),
            updated: strToMs(n.timestamps && n.timestamps.updated)
        });
    }
    return out;
}

// ------------------------------------------------------------------ building local edits

function _baseNode(id, type, parentId, nowMs) {
    var ts = tsToStr(nowMs);
    return {
        "id": id,
        "kind": "notes#node",
        "type": type,
        "parentId": parentId,
        "sortValue": _randInt(1000000000, 9999999999),
        "text": "",
        "timestamps": { "kind": "notes#timestamps", "created": ts, "updated": ts, "userEdited": ts },
        "nodeSettings": { "newListItemPlacement": "BOTTOM", "graveyardState": "COLLAPSED", "checkedListItemsPolicy": "GRAVEYARD" },
        "annotationsGroup": { "kind": "notes#annotationsGroup" }
    };
}

function _topNode(type, fields, nowMs) {
    var n = _baseNode(generateId(nowMs), type, ROOT_ID, nowMs);
    n["color"] = fields.color && COLORS.indexOf(fields.color) >= 0 ? fields.color : "DEFAULT";
    n["isArchived"] = false;
    n["isPinned"] = !!fields.pinned;
    n["title"] = fields.title || "";
    n["collaborators"] = [];
    return n;
}

function _listItem(parent, text, checked, sortValue, nowMs) {
    var n = _baseNode(generateId(nowMs), "LIST_ITEM", parent.id, nowMs);
    n["parentServerId"] = parent.serverId || null;
    n["superListItemId"] = null;
    n["checked"] = !!checked;
    n["text"] = text || "";
    if (sortValue !== undefined) n["sortValue"] = sortValue;
    return n;
}

function _touch(node, nowMs, edited) {
    node.timestamps = Object.assign({}, node.timestamps || { "kind": "notes#timestamps" });
    node.timestamps.updated = tsToStr(nowMs);
    if (edited) node.timestamps.userEdited = tsToStr(nowMs);
    return node;
}

// "- [ ] item" / "- [x] item" lines -> items, or null if any line isn't one
function parseChecklist(text) {
    var lines = String(text || "").split("\n").filter(function (l) { return l.trim().length > 0; });
    if (!lines.length) return null;
    var items = [];
    for (var i = 0; i < lines.length; i++) {
        var m = /^\s*[-*]\s+\[([ xX])\]\s?(.*)$/.exec(lines[i]);
        if (!m) return null;
        items.push({ text: m[2], checked: m[1] !== " " });
    }
    return items;
}

// New note, or a list if the text is all checkboxes. Adds the nodes to state
// and returns them so they can be sent.
function createNote(state, fields, nowMs) {
    var items = parseChecklist(fields.text);
    var top = _topNode(items ? "LIST" : "NOTE", fields, nowMs);
    var out = [top];
    if (items) {
        var sort = 1000000000 + items.length * 10000;
        items.forEach(function (it, i) { out.push(_listItem(top, it.text, it.checked, sort - i * 10000, nowMs)); });
    } else {
        out.push(_listItem(top, fields.text, false, undefined, nowMs));
    }
    out.forEach(function (n) { state.nodes[n.id] = n; });
    return out;
}

// fields: any of title, text, color, pinned, archived. Returns the nodes that changed.
function updateNote(state, id, fields, nowMs) {
    var top = state.nodes[id];
    if (!top) return [];
    var changed = [];
    var t = Object.assign({}, top);
    var topDirty = false;
    if (fields.title !== undefined && fields.title !== t.title) { t.title = fields.title; topDirty = true; }
    if (fields.color !== undefined && fields.color !== t.color && COLORS.indexOf(fields.color) >= 0) { t.color = fields.color; topDirty = true; }
    if (fields.pinned !== undefined && !!fields.pinned !== !!t.isPinned) { t.isPinned = !!fields.pinned; topDirty = true; }
    if (fields.archived !== undefined && !!fields.archived !== !!t.isArchived) { t.isArchived = !!fields.archived; topDirty = true; }

    if (fields.text !== undefined && fields.text !== noteText(state, top)) {
        topDirty = true;
        if (top.type === "LIST") {
            var wanted = parseChecklist(fields.text) || String(fields.text).split("\n")
                .filter(function (l) { return l.trim().length; })
                .map(function (l) { return { text: l.replace(/^\s*[-*]\s+/, ""), checked: false }; });
            var existing = sortedItems(state, id).map(function (e) { return e.node; });
            var sort = 1000000000 + wanted.length * 10000;
            wanted.forEach(function (w, i) {
                var sv = sort - i * 10000;
                if (i < existing.length) {
                    var e = existing[i];
                    if (e.text !== w.text || !!e.checked !== w.checked || e.superListItemId || Number(e.sortValue) !== sv) {
                        var c = Object.assign({}, e, { text: w.text, checked: w.checked, superListItemId: null, sortValue: sv });
                        changed.push(_touch(c, nowMs, true));
                    }
                } else {
                    changed.push(_listItem(top, w.text, w.checked, sv, nowMs));
                }
            });
            existing.slice(wanted.length).forEach(function (e) {
                var c = _touch(Object.assign({}, e), nowMs, true);
                c.timestamps.deleted = tsToStr(nowMs);
                changed.push(c);
            });
        } else {
            var kids = childrenOf(state, id);
            if (kids.length) {
                changed.push(_touch(Object.assign({}, kids[0], { text: fields.text }), nowMs, true));
            } else {
                changed.push(_listItem(top, fields.text, false, undefined, nowMs));
            }
        }
    }
    if (topDirty || changed.length) changed.unshift(_touch(t, nowMs, true));
    changed.forEach(function (n) { state.nodes[n.id] = n; });
    return changed;
}

// TopLevelNode.trash()
function trashNote(state, id, nowMs) {
    var top = state.nodes[id];
    if (!top) return [];
    var t = _touch(Object.assign({}, top), nowMs, false);
    t.timestamps.trashed = tsToStr(nowMs);
    state.nodes[id] = t;
    return [t];
}

// ------------------------------------------------------------------ client

// transport(req) -> Promise<{ status: number, text: string }>
// authTransport is the same unless you pass one. android.clients.google.com is
// picky about the TLS client, which is why we use curl for it.
function Client(opts) {
    this.email = opts.email;
    this.masterToken = opts.masterToken || null;
    this.androidId = opts.androidId;
    this.transport = opts.transport;
    this.authTransport = opts.authTransport || opts.transport;
    this.sleep = opts.sleep || function (ms) { return new Promise(function (r) { setTimeout(r, ms); }); };
    this.now = opts.now || function () { return Date.now(); };
    this.authToken = null;
    this.sessionId = generateSessionId(this.now());
}

// oauth_token cookie -> master token (aas_et/...)
Client.prototype.exchangeToken = function (oauthToken) {
    var self = this;
    return self.authTransport(exchangeTokenRequest(self.email, oauthToken, self.androidId)).then(function (res) {
        var r = parseAuthResponse(res.text);
        if (!r.Token) throw new Error("Token exchange failed: " + (r.Error || ("HTTP " + res.status)));
        self.masterToken = r.Token;
        return r.Token;
    });
};

// APIAuth.refresh
Client.prototype.refresh = function () {
    var self = this;
    if (!self.masterToken) return Promise.reject(new Error("Not logged in"));
    return self.authTransport(oauthRequest(self.email, self.masterToken, self.androidId)).then(function (res) {
        var r = parseAuthResponse(res.text);
        if (!r.Auth) throw new Error("Login failed: " + (r.Error || ("HTTP " + res.status)));
        self.authToken = r.Auth;
        return r.Auth;
    });
};

// same retries as API.send: new token on 401 (up to RETRY_CNT times), wait and retry on 429
Client.prototype.changes = function (targetVersion, nodes, labels) {
    var self = this;
    var tries = 0;
    var delay = 2000;
    function attempt() {
        var ready = self.authToken ? Promise.resolve() : self.refresh();
        return ready.then(function () {
            return self.transport(changesRequest(self.authToken, self.sessionId, targetVersion, nodes, labels, self.now()));
        }).then(function (res) {
            var body = null;
            try { body = JSON.parse(res.text); } catch (e) { body = null; }
            var code = body && body.error ? body.error.code : (res.status >= 400 ? res.status : 0);
            if (!code && body) return body;
            if (code === 429) {
                var d = delay;
                delay = Math.min(delay * 2, 60000);
                return self.sleep(d).then(attempt);
            }
            if (code === 401 && tries < RETRY_CNT) {
                tries++;
                self.authToken = null;
                return attempt();
            }
            var msg = body && body.error && body.error.message ? body.error.message : ("HTTP " + res.status);
            var err = new Error("Keep API error " + code + ": " + msg);
            err.code = code;
            throw err;
        });
    }
    return attempt();
};

// Keep._sync_notes: send `dirty`, keep pulling until it's not truncated.
// Updates `state` in place, resolves to the ids of notes that changed.
Client.prototype.sync = function (state, dirty) {
    var self = this;
    var touched = {};
    var first = true;
    function loop() {
        var nodes = first ? (dirty || []) : [];
        first = false;
        return self.changes(state.version, nodes, null).then(function (changes) {
            if (changes.forceFullResync) {
                var e = new Error("Full resync required");
                e.resync = true;
                throw e;
            }
            applyChanges(state, changes).forEach(function (id) { touched[id] = true; });
            if (changes.truncated) return loop();
            return Object.keys(touched);
        });
    }
    return loop();
};

if (typeof module !== "undefined") {
    module.exports = {
        AUTH_URL: AUTH_URL, API_URL: API_URL, SCOPES: SCOPES, COLORS: COLORS, ROOT_ID: ROOT_ID,
        tsToStr: tsToStr, strToMs: strToMs, generateId: generateId, generateSessionId: generateSessionId,
        generateAndroidId: generateAndroidId, parseAuthResponse: parseAuthResponse,
        oauthRequest: oauthRequest, exchangeTokenRequest: exchangeTokenRequest, changesRequest: changesRequest,
        emptyState: emptyState, applyChanges: applyChanges, topLevelNotes: topLevelNotes, noteText: noteText,
        sortedItems: sortedItems, parseChecklist: parseChecklist, isTrashed: isTrashed, isDeleted: isDeleted,
        createNote: createNote, updateNote: updateNote, trashNote: trashNote, Client: Client
    };
}
