/// --- The Kairo Project ----------------------- Analyzer/Index/LiveWorker.k --- ///
///
///   The live index worker: `kals --worker --index-server`. One process per
///   entry that STAYS UP, holding the checked graph (Tooling::LiveCheck), so
///   an edit re-checks the edited file and the files that import it instead
///   of the whole graph (Compiler/Spec/IncrementalSema.md phase 5,
///   LanguageServer.md section 10).
///
///   Requests and answers are LSP-framed JSON on stdin and stdout (the
///   Transport the server speaks to the editor). They are small on purpose:
///   buffer texts and snapshots travel as FILES, so neither side can fill a
///   pipe while the other is writing to it.
///
///     in:  { "id": n, "out": <path>, "changed": [path...],
///            "open": [ { "path": real, "file": tmp }... ],
///            "order": [path...], "progress": <path> }
///     out: { "id": n, "ok": true, "mode": "full" | "refresh", "why": str,
///            "rechecked": k, "pending": m, "files": N, "out": <path> }
///          { "id": n, "superseded": true }
///          { "id": n, "ok": false, "error": str }
///
///   `open` is every buffer the editor holds for this entry, each as a file
///   holding its text; `changed` names files whose text on DISK changed.
///   The worker compares each buffer with the text it holds, so a server
///   that is ahead of it (a run it did by other means) needs no bookkeeping.
///   `out` is where the answer's snapshot is written: the document the
///   per-run worker writes (Worker.k), with every row of every file the
///   editor asked about, re-checked or not.
///
///   Requests that arrive while one is being answered are COALESCED: the
///   newest buffers win, the changed lists are joined, and the older ids are
///   answered `superseded`.
///
///   TWO TIERS (LiveCheck::two_tier). The answer to a request is its FIRST
///   tier: each edited file re-checked, with the queued files it imports;
///   `pending` says how many files that import them are queued. The worker
///   then re-checks those LIVE_SLICE_FILES at a time, in Sema's order (an
///   import cycle is one step, whatever its size), looking at its stdin
///   between slices, and sends one more message per slice under the same
///   id, with `"bg": true`, a snapshot of its own and the new `pending`. A
///   request that arrives meanwhile is answered first (its first tier
///   joins the queue), and the id that was draining is answered
///   `superseded`. A queued file's rows and diagnostics in a snapshot are
///   the ones from before the edit until its turn comes.
///
///   The worker keeps each walked file's rows (IndexObserver::keep) and each
///   file's diagnostics as rendered JSON, and replaces those of the files a
///   step re-checked. A file under the project root is walked whether a
///   buffer is open for it or not, so opening it later costs no check.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "string"
ffi "c++" import "vector"
ffi "c++" import "chrono"
ffi "c++" import "cstdlib"
ffi "c++" import "thread"

import API::FS::LinkFS
import Diagnostic::FileDiagnostics::FileDiagConsumer
import Index::Snapshot::{
    SK_DEPS,
    SK_DIAGNOSTICS,
    SK_FILES,
    SK_OK,
    SK_RUN_US,
    SK_TIMING,
    SK_UNIT_FIDS,
    SK_WALK_US,
    SK_WIDE,
    SK_WRITE_US,
}
import Index::Worker::{
    DiagCollector,
    IndexObserver,
}
import Index::WorkerKeys::*
import Json::{
    JSON_NONE,
    JsonDoc,
    JsonWriter,
}
import JsonRpc::Transport
import Support::FileIO::Path::Path
import Tooling::LiveCheck::LiveCheck
import Tuning::{
    LIVE_PREFER_OPEN,
    LIVE_SLICE_FILES,
    WIDE_INDEX_LIMIT,
}
import WorkerArgs::*

fn live_us() -> i64 {
    var t = cxx::std::chrono::steady_clock::now()
    var d = cxx::std::chrono::duration_cast<cxx::std::chrono::microseconds>(t.time_since_epoch())
    return d.count() as i64
}

fn live_has(list: *const [string], const s: string) -> bool {
    for var i: usize = 0; i < list->size(); ++i {
        if (*list)[i] == s {
            return true
        }
    }

    return false
}

/// One request, or several joined (LiveReq::join).
class LiveReq {
    pub var id:         i64    = -1
    pub var out:        string = ""
    pub var open_paths: [string]
    pub var open_files: [string]
    pub var changed:    [string]
    pub var order:      [string]
    pub var progress:   string = ""

    pub fn LiveReq(self) = default
}

/// What the process holds between requests.
class LiveState {
    pub var root:    string = ""
    pub var checked: bool   = false

    /// The buffers the editor holds, as last sent, and their texts.
    pub var held_paths: [string]
    pub var held_texts: [string]

    /// The files of the graph, as the last step left it.
    pub var deps: [string]

    /// Each owner's diagnostics as rendered rows, comma-joined (an owner is
    /// the file whose check delivered them; "" is the driver). Rendered
    /// when the owner is checked and never again: a kept row's positions
    /// are in text that a later edit of ANOTHER file may have replaced.
    pub var d_owner: [string]
    pub var d_rows:  [string]
    pub var d_count: [usize]

    pub fn LiveState(self) = default
}

/// Renders the diagnostics of \p owners (all of them when \p all) into the
/// state's per-owner rows.
///
/// \return whether any row of those owners is another than it was.
fn live_render(st: *LiveState, live: *LiveCheck, all: bool, owners: *const [string]) -> bool {
    var unsafe *fd = live->file_diags()
    var before: string = ""
    for var i: usize = 0; i < st->d_owner.size(); ++i {
        if all || st->d_owner[i].empty() || live_has(owners, st->d_owner[i]) {
            before += st->d_owner[i] + "\n" + st->d_rows[i] + "\n"
        }
    }

    if all {
        st->d_owner.clear()
        st->d_rows.clear()
        st->d_count.clear()
    } else {
        var ko: [string]
        var kr: [string]
        var kc: [usize]
        for var i: usize = 0; i < st->d_owner.size(); ++i {
            // The driver's own are few and located outside every re-checked
            // file (LiveCheck refuses a refresh otherwise): rendered again.
            if st->d_owner[i].empty() || live_has(owners, st->d_owner[i]) {
                continue
            }

            ko.push_back(st->d_owner[i])
            kr.push_back(st->d_rows[i])
            kc.push_back(st->d_count[i])
        }

        st->d_owner = ko
        st->d_rows  = kr
        st->d_count = kc
    }

    if fd == &null || live->ci() == &null {
        return true
    }

    // A collector per step: it caches each file's text for its line map,
    // and a text may have changed since the last step.
    var unsafe *col = kairo::std::create<DiagCollector>(live->ci()->sm())
    finally {
        kairo::std::destroy(col)
    }

    for var i: usize = 0; i < fd->diags.size(); ++i {
        var owner: string = fd->owners[i]
        if (!all) && (!owner.empty()) && (!live_has(owners, owner)) {
            continue
        }

        col->out   = ""
        col->count = 0
        col->handle(fd->diags[i])
        if col->count == 0 {
            continue
        }

        var slot = usize::MAX
        for var k: usize = 0; k < st->d_owner.size(); ++k {
            if st->d_owner[k] == owner {
                slot = k
                break
            }
        }

        if slot == usize::MAX {
            st->d_owner.push_back(owner)
            st->d_rows.push_back(col->out)
            st->d_count.push_back(1)
        } else {
            st->d_rows[slot] += ","
            st->d_rows[slot] += col->out
            st->d_count[slot] += 1
        }
    }

    // The kept owners come first and in their old order, so the owners
    // asked for are compared in the order they were rendered in both times.
    var after: string = ""
    for var i: usize = 0; i < st->d_owner.size(); ++i {
        if all || st->d_owner[i].empty() || live_has(owners, st->d_owner[i]) {
            after += st->d_owner[i] + "\n" + st->d_rows[i] + "\n"
        }
    }

    return before != after
}

/// The snapshot as the per-run worker writes it (Worker.k, worker_main),
/// from what is kept: the rows of every open buffer, and on a narrow graph
/// of every file under the root.
fn live_snapshot(st:    *LiveState,
                 obs:   unsafe *IndexObserver,
                 live:  *LiveCheck,
                 names: *const [string],
                 took:  i64) -> string {
    var narrow = st->deps.size() <= WIDE_INDEX_LIMIT
    var files: string = ""
    var nfiles: usize = 0
    for var pass: usize = 0; pass < 2; ++pass {
        for var i: usize = 0; i < obs->k_paths.size(); ++i {
            var named = live_has(names, obs->k_paths[i])
            // Buffers first, as a run's observer writes them.
            if (pass == 0) != named {
                continue
            }

            if (!named) && ((!narrow) || st->root.empty() || (!obs->k_paths[i].starts_with(st->root))) {
                continue
            }

            if nfiles > 0 {
                files += ","
            }

            files += obs->k_blocks[i]
            nfiles += 1
        }
    }

    var diags: string = ""
    var nd: usize = 0
    for var i: usize = 0; i < st->d_owner.size(); ++i {
        if st->d_count[i] == 0 {
            continue
        }

        if nd > 0 {
            diags += ","
        }

        diags += st->d_rows[i]
        nd += st->d_count[i]
    }

    var w = JsonWriter()
    w.begin_object()
    w.field_bool(SK_OK, true)
    w.field_raw(SK_FILES, "[" + files + "]")
    w.field_bool(SK_WIDE, narrow)
    w.field_raw(SK_DIAGNOSTICS, "[" + diags + "]")
    w.key(SK_DEPS)
    w.begin_array()
    for var k: usize = 0; k < st->deps.size(); ++k {
        w.str(st->deps[k])
    }

    w.end_array()
    w.key(SK_TIMING)
    w.begin_object()
    w.field_int(SK_RUN_US, took)
    w.field_int(SK_WALK_US, obs->walk_us)
    w.field_int(SK_WRITE_US, obs->write_us)
    w.field_uint(SK_UNIT_FIDS, st->deps.size())
    w.end_object()
    w.end_object()
    return w.out
}

/// Takes every buffered request into \p r: the newest buffers and output
/// path, the changed lists joined; each older id is answered `superseded`.
fn live_take(t: *Transport, r: *LiveReq) {
    while t->wait(0) {
        var d = JsonDoc()
        if !d.parse(t->take()) {
            continue
        }

        if r->id >= 0 {
            var sw = JsonWriter()
            sw.begin_object()
            sw.field_int(RP_ID, r->id)
            sw.field_bool(RP_SUPERSEDED, true)
            sw.end_object()
            t->send(sw.out)
        }

        r->id       = d.get_int(d.root, RQ_ID)
        r->out      = d.get_str(d.root, RQ_OUT)
        r->progress = d.get_str(d.root, RQ_PROGRESS)
        r->open_paths.clear()
        r->open_files.clear()
        var o = d.first(d.get(d.root, RQ_OPEN))
        while o != JSON_NONE() {
            r->open_paths.push_back(d.get_str(o, RQ_PATH))
            r->open_files.push_back(d.get_str(o, RQ_FILE))
            o = d.next(o)
        }

        var c = d.first(d.get(d.root, RQ_CHANGED))
        while c != JSON_NONE() {
            var p = d.str(c)
            if !live_has(&r->changed, p) {
                r->changed.push_back(p)
            }

            c = d.next(c)
        }

        r->order.clear()
        var q = d.first(d.get(d.root, RQ_ORDER))
        while q != JSON_NONE() {
            r->order.push_back(d.str(q))
            q = d.next(q)
        }
    }
}

fn live_fail(t: *Transport, id: i64, const why: string) {
    var w = JsonWriter()
    w.begin_object()
    w.field_int(RP_ID, id)
    w.field_bool(RP_OK, false)
    w.field(RP_ERROR, why)
    w.end_object()
    t->send(w.out)
}

/// One request: the buffers brought up to date, the check or the
/// re-checks, the snapshot written, the answer sent.
fn live_step(st: *LiveState, live: *LiveCheck, obs: unsafe *IndexObserver, r: *LiveReq, t: *Transport) {
    var t0 = live_us()

    // The buffers: one whose text is not the one held is a change, whether
    // the server said so or not.
    var changed: [string]
    for var k: usize = 0; k < r->changed.size(); ++k {
        changed.push_back(r->changed[k])
    }

    for var k: usize = 0; k < r->open_paths.size(); ++k {
        var text: string = ""
        if !LinkFS::read(r->open_files[k], &text) {
            continue
        }

        var at = usize::MAX
        for var h: usize = 0; h < st->held_paths.size(); ++h {
            if st->held_paths[h] == r->open_paths[k] {
                at = h
                break
            }
        }

        if at != usize::MAX && st->held_texts[at] == text {
            continue
        }

        if at == usize::MAX {
            // A buffer opened with the text the disk has changes nothing.
            var disk: string = ""
            var same = st->checked && LinkFS::read(r->open_paths[k], &disk) && (disk == text)
            st->held_paths.push_back(r->open_paths[k])
            st->held_texts.push_back(text)
            live->set_overlay(r->open_paths[k], text)
            if same {
                continue
            }
        } else {
            st->held_texts[at] = text
            live->set_overlay(r->open_paths[k], text)
        }

        if !live_has(&changed, r->open_paths[k]) {
            changed.push_back(r->open_paths[k])
        }
    }

    // A buffer the editor closed: the disk's text again, which is a change
    // only when it is another text.
    var hp: [string]
    var ht: [string]
    for var h: usize = 0; h < st->held_paths.size(); ++h {
        if live_has(&r->open_paths, st->held_paths[h]) {
            hp.push_back(st->held_paths[h])
            ht.push_back(st->held_texts[h])
            continue
        }

        live->clear_overlay(st->held_paths[h])
        var disk: string = ""
        if (!LinkFS::read(st->held_paths[h], &disk)) || (disk != st->held_texts[h]) {
            if !live_has(&changed, st->held_paths[h]) {
                changed.push_back(st->held_paths[h])
            }
        }
    }

    st->held_paths = hp
    st->held_texts = ht
    obs->named     = r->open_paths
    obs->progress  = r->progress
    obs->checked   = 0

    var full = false
    var mode: string = "refresh"
    var why:  string = "nothing changed"
    var rechecked: [string]
    if !st->checked {
        if (!live->check()) || (live->ci() == &null) {
            live_fail(t, r->id, "the compile command was rejected: check its flags in kairo_compile.json")
            return
        }

        st->checked = true
        full = true
        mode = live->mode
        why  = live->why
    } else {
        // A buffer of the graph that has no rows (it is outside the root
        // and was not open when its file was last checked) is checked
        // again to be walked.
        for var k: usize = 0; k < r->open_paths.size(); ++k {
            if live_has(&st->deps, r->open_paths[k]) && (!live_has(&obs->k_paths, r->open_paths[k]))
                && (!live_has(&changed, r->open_paths[k])) {
                changed.push_back(r->open_paths[k])
            }
        }

        for var k: usize = 0; k < changed.size(); ++k {
            // A file the graph does not hold: nothing of the result reads
            // it (a file that an import now FINDS is found by that
            // importer's own edit, or by the entry's next full check).
            if (!live_has(&st->deps, changed[k])) && (live->errors == 0) {
                continue
            }

            if !live->replace_file(changed[k]) {
                live_fail(t, r->id, "the compile command was rejected: check its flags in kairo_compile.json")
                st->checked = false
                return
            }

            mode = live->mode
            why  = live->why
            if live->mode == "full" {
                // Everything was read again, the other changes with it.
                full = true
                break
            }

            for var q: usize = 0; q < live->rechecked.size(); ++q {
                var name: string = live->rechecked[q]
                if !live_has(&rechecked, name) {
                    rechecked.push_back(name)
                }
            }
        }
    }

    live_finish(st, live, obs, r, t, full, mode, why, &rechecked, false, r->out, t0)
}

/// The end of a step, first tier or slice: the rows and diagnostics of
/// what was re-checked replace the kept ones, the snapshot is written to
/// \p out and the answer sent.
fn live_finish(st:        *LiveState,
               live:      *LiveCheck,
               obs:       unsafe *IndexObserver,
               r:         *LiveReq,
               t:         *Transport,
               full_in:   bool,
               const mode: string,
               const why:  string,
               rechecked: *const [string],
               bg:        bool,
               const out: string,
               t0:        i64) {
    var full = full_in
    obs->flush()
    if live->ci() == &null {
        live_fail(t, r->id, "the compile command was rejected: check its flags in kairo_compile.json")
        st->checked = false
        return
    }

    if full {
        st->deps.clear()
        for var f: string in live->graph_files() {
            st->deps.push_back(f)
        }

        // Rows of a file the graph no longer holds.
        var kp: [string]
        var kb: [string]
        for var i: usize = 0; i < obs->k_paths.size(); ++i {
            if live_has(&st->deps, obs->k_paths[i]) {
                kp.push_back(obs->k_paths[i])
                kb.push_back(obs->k_blocks[i])
            }
        }

        obs->k_paths  = kp
        obs->k_blocks = kb
    }

    var diags_moved = live_render(st, live, full, rechecked)
    var took = live_us() - t0

    // Did this step re-check a buffer the editor holds? Its rows changed
    // with no edit of its own: the server asks the editor to draw it again.
    var touched = false
    for var k: usize = 0; k < rechecked->size(); ++k {
        if live_has(&r->open_paths, (*rechecked)[k]) {
            touched = true
        }
    }

    // A background slice that changed nothing the snapshot holds (no open
    // buffer among its files, no diagnostic that moved; on a wide graph the
    // other files' rows are not in it) sends its count alone: a core file
    // has hundreds of importers, which is dozens of slices.
    var narrow = st->deps.size() <= WIDE_INDEX_LIMIT
    var wrote  = out
    if bg && (!full) && (!touched) && (!diags_moved) && (!narrow) && (live->pending > 0) {
        wrote = ""
    } else {
        var snap = live_snapshot(st, obs, live, &r->open_paths, took)
        if !LinkFS::write(out, snap) {
            live_fail(t, r->id, "cannot write " + out)
            return
        }
    }

    var w = JsonWriter()
    w.begin_object()
    w.field_int(RP_ID, r->id)
    w.field_bool(RP_OK, true)
    if bg {
        w.field_bool(RP_BG, true)
    }

    w.field(RP_MODE, mode)
    w.field(RP_WHY, why)
    w.field_uint(RP_RECHECKED, if (full) => (st->deps.size()) else => (rechecked->size()))
    w.field_uint(RP_PENDING, live->pending)
    w.field_bool(RP_TOUCHED, touched || full)
    w.field_uint(RP_FILES, st->deps.size())
    w.field(RP_OUT, wrote)
    w.field_int(RP_US, took)
    // What the re-checks since the last whole check replaced and hold.
    w.field_uint(RP_RETIRED_FILES, live->retired_files())
    w.field_uint(RP_RETIRED_MB, live->retired_bytes() / 1048576)
    w.end_object()
    t->send(w.out)
}

/// One slice of the second tier: up to LIVE_SLICE_FILES queued files, in
/// the order Sema runs them (with LIVE_PREFER_OPEN, the editor's buffers
/// and what they import first).
fn live_slice(st: *LiveState, live: *LiveCheck, obs: unsafe *IndexObserver, r: *LiveReq, t: *Transport, seq: u64) {
    var t0 = live_us()
    var prefer: cxx::std::vector<string>
    if LIVE_PREFER_OPEN {
        for var k: usize = 0; k < r->open_paths.size(); ++k {
            prefer.push_back(r->open_paths[k])
        }
    }

    obs->named    = r->open_paths
    obs->progress = ""
    live->drain(LIVE_SLICE_FILES, prefer)
    var rechecked: [string]
    for var q: usize = 0; q < live->rechecked.size(); ++q {
        var name: string = live->rechecked[q]
        rechecked.push_back(name)
    }

    // A slice that could not be re-checked in place re-checked everything.
    var full = live->mode == "full"
    live_finish(st, live, obs, r, t, full, live->mode, live->why, &rechecked, true, r->out + f".{seq}", t0)
}

/// \brief `kals --worker --index-server [--cwd <dir>] [--root <dir>] --
///        <kairo args> <entry>`. Exits at EOF.
pub fn index_server_main(@inout args: [string]) -> i32 {
    var st = LiveState()
    var words: cxx::std::vector<string>
    var i: usize = 1
    while i < args.size() {
        var a = args[i]
        if a == WA_END {
            i += 1
            break
        }

        if (a == WA_CWD) && ((i + 1) < args.size()) {
            Path::set_cwd(args[i + 1])
            i += 2
            continue
        }

        if (a == WA_ROOT) && ((i + 1) < args.size()) {
            st.root = args[i + 1]
            i += 2
            continue
        }

        return 2
    }

    while i < args.size() {
        words.push_back(args[i])
        i += 1
    }

    // A refresh re-renders nothing it kept, which the pretty renderer's
    // coalescing across files does not allow (LiveCheck refuses it). The
    // worker reads Diagnostic objects: the format changes nothing it sends.
    words.push_back(CF_ERROR_FORMAT_BASIC)

    var unsafe *obs = kairo::std::create<IndexObserver>()
    finally {
        kairo::std::destroy(obs)
    }

    obs->keep = true
    obs->root = st.root

    var live = LiveCheck(words)
    live.as_module = false
    live.in_place  = true
    live.two_tier  = true
    live.observer  = unsafe (obs as unsafe *void)

    // The test knob of the per-run worker (Worker.k): each request takes
    // at least this long, so a test can order a change inside it.
    var delay_ms: i32 = 0
    var unsafe *delay = cxx::std::getenv(r"KALS_DEBUG_INDEX_DELAY_MS")
    if delay != &null {
        delay_ms = cxx::std::atoi(delay)
    }

    // Another: each background slice waits this long first, so a test can
    // send an edit while files are still queued.
    var slice_delay_ms: i32 = 0
    var unsafe *sdelay = cxx::std::getenv(r"KALS_DEBUG_LIVE_SLICE_DELAY_MS")
    if sdelay != &null {
        slice_delay_ms = cxx::std::atoi(sdelay)
    }

    var t = Transport()
    var draining = LiveReq() // the request whose importers are queued (id < 0: none)
    var slices: u64 = 0
    while !t.closed {
        if (draining.id >= 0) && st.checked && (live.pending > 0) {
            // Between slices: a request pre-empts what is queued.
            if !t.wait(if (slice_delay_ms > 0) => (slice_delay_ms) else => (0 as i32)) {
                slices += 1
                live_slice(&st, &live, obs, &draining, &t, slices)
                continue
            }
        } else if !t.wait(1000) {
            continue
        }

        var r = LiveReq()
        live_take(&t, &r)
        if r.id < 0 {
            continue
        }

        if delay_ms > 0 {
            cxx::std::this_thread::sleep_for(cxx::std::chrono::milliseconds(delay_ms))
            // What arrived meanwhile replaces it, as a change during a
            // per-run worker's run kills that run.
            live_take(&t, &r)
        }

        // The request that was draining gets no more slices under its id:
        // what it left queued is this one's now.
        if (draining.id >= 0) && (live.pending > 0) {
            var sw = JsonWriter()
            sw.begin_object()
            sw.field_int(RP_ID, draining.id)
            sw.field_bool(RP_SUPERSEDED, true)
            sw.end_object()
            t.send(sw.out)
        }

        live_step(&st, &live, obs, &r, &t)
        draining = r
    }

    return 0
}
