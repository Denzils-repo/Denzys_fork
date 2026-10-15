.pragma library
.import "gkeep.js" as G

// Converts between Keep notes (gkeep.js state) and our notes (NotesStore.notes)
// and decides what changed where. Tests are in tests/gkeep.test.js.
//
// Linked notes get two extra fields:
//   keepId   id of the note in Keep
//   keepSig  title/body/color/pinned as they were at the last sync
// If our note no longer matches keepSig we changed it, if the Keep note doesn't
// match it they changed it. If both did, ours wins.

var LOCAL_TO_KEEP = { "none": "DEFAULT", "primary": "BLUE", "secondary": "GREEN", "tertiary": "YELLOW", "pink": "PINK" };
var KEEP_TO_LOCAL = {
    "DEFAULT": "none", "GRAY": "none",
    "BLUE": "primary", "CERULEAN": "primary", "PURPLE": "primary",
    "GREEN": "secondary", "TEAL": "secondary",
    "YELLOW": "tertiary", "ORANGE": "tertiary", "BROWN": "tertiary",
    "RED": "pink", "PINK": "pink"
};

function colorToKeep(c) { return LOCAL_TO_KEEP[c] || "DEFAULT"; }
function colorToLocal(c) { return KEEP_TO_LOCAL[c] || "none"; }

function sig(title, body, color, pinned) {
    return JSON.stringify([title || "", body || "", color || "none", !!pinned]);
}

function localSig(n) { return sig(n.title, n.body, n.color, n.pinned); }
function keepSig(k) { return sig(k.title, k.text, colorToLocal(k.color), k.pinned); }

function localFromKeep(k, existing, nowMs) {
    var n = Object.assign({}, existing || {
        "id": "note_keep_" + k.id,
        "listShapes": {},
        "type": "note",
        "createdAt": k.created || nowMs
    });
    n.title = k.title;
    n.body = k.text;
    n.color = colorToLocal(k.color);
    n.pinned = k.pinned;
    n.updatedAt = k.updated || nowMs;
    n.keepId = k.id;
    n.keepSig = keepSig(k);
    return n;
}

// Called after a pull. Writes our edits into `state` and returns
// { notes, dirty, linked, pushed }. `pushed` is local id -> sig of what we sent,
// finalize() needs it.
function reconcile(state, localNotes, linkedIds, nowMs) {
    var live = {};
    G.topLevelNotes(state, false).forEach(function (k) { live[k.id] = k; });
    var linkedBefore = {};
    (linkedIds || []).forEach(function (id) { linkedBefore[id] = true; });

    var dirty = [];
    var pushed = {};
    var seen = {};
    var notes = [];

    (localNotes || []).forEach(function (n) {
        if (!n) return;
        var isDirty = !n.keepId || localSig(n) !== n.keepSig;
        var k = n.keepId ? live[n.keepId] : null;

        if (n.keepId && !k) {
            // trashed/deleted/archived in Keep
            if (!isDirty) return; // so drop it here too
            n = Object.assign({}, n);
            delete n.keepId; // but we edited it, so upload it again as a new note
        }

        if (!n.keepId && !(n.title || "").trim() && !(n.body || "").trim()) {
            notes.push(n); // empty, wait until there's something in it
            return;
        }

        if (!n.keepId) {
            var created = G.createNote(state, {
                title: n.title, text: n.body, color: colorToKeep(n.color), pinned: n.pinned
            }, nowMs);
            dirty = dirty.concat(created);
            n = Object.assign({}, n, { keepId: created[0].id });
            pushed[n.id] = localSig(n);
        } else if (isDirty) {
            var fields = {};
            if (n.title !== k.title) fields.title = n.title;
            if (n.body !== k.text) fields.text = n.body;
            if (n.color !== colorToLocal(k.color)) fields.color = colorToKeep(n.color);
            if (!!n.pinned !== !!k.pinned) fields.pinned = !!n.pinned;
            dirty = dirty.concat(G.updateNote(state, n.keepId, fields, nowMs));
            pushed[n.id] = localSig(n);
        } else if (keepSig(k) !== n.keepSig) {
            n = localFromKeep(k, n, nowMs);
        }
        seen[n.keepId] = true;
        notes.push(n);
    });

    Object.keys(live).forEach(function (id) {
        if (seen[id]) return;
        if (linkedBefore[id]) {
            // we deleted it, so trash it in Keep
            dirty = dirty.concat(G.trashNote(state, id, nowMs));
        } else {
            var n = localFromKeep(live[id], null, nowMs);
            seen[id] = true;
            if (n.pinned) notes.unshift(n); else notes.push(n);
        }
    });

    return { notes: notes, dirty: dirty, linked: Object.keys(seen), pushed: pushed };
}

// After the push, take the server's version of what we sent and save the sigs.
// `currentNotes` is NotesStore.notes right now, so edits made while the request
// was running are left alone and go out next sync.
function finalize(state, currentNotes, pushed, nowMs) {
    var live = {};
    G.topLevelNotes(state, false).forEach(function (k) { live[k.id] = k; });
    return (currentNotes || []).map(function (n) {
        if (!n || !n.keepId || !(n.id in pushed)) return n;
        if (localSig(n) !== pushed[n.id]) return n; // edited mid-sync
        var k = live[n.keepId];
        if (!k) return n;
        return localFromKeep(k, n, nowMs);
    });
}

// Merges the sync result with whatever the user did while it was running.
// snapshot = notes when reconcile() ran, current = notes now.
function mergeConcurrent(snapshot, current, planned) {
    var snap = {}, cur = {};
    (snapshot || []).forEach(function (n) { if (n) snap[n.id] = n; });
    (current || []).forEach(function (n) { if (n) cur[n.id] = n; });
    var out = [];
    (planned || []).forEach(function (p) {
        if (!(p.id in snap)) { out.push(p); return; } // new from Keep
        var c = cur[p.id];
        if (!c) return; // deleted mid-sync, gets trashed in Keep next time
        if (localSig(c) !== localSig(snap[p.id])) {
            out.push(Object.assign({}, c, { keepId: p.keepId, keepSig: p.keepSig }));
        } else {
            out.push(p);
        }
    });
    (current || []).forEach(function (n) { if (n && !(n.id in snap)) out.unshift(n); }); // created mid-sync
    return out;
}

