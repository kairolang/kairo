/// --- The Kairo Project ----------------------------- Analyzer/Tuning.k --- ///
///
///   The server's tunables, one place. Each says what it trades off; none is a
///   protocol value (those are Protocol.k).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///


/// Quiet time after the last edit before an entry's index run starts. Lower:
/// fresher hovers and tokens, but more runs thrown away mid-typing.
/// Overridden by initializationOptions.debounceMs.
pub const DEBOUNCE_MS: i64 = 150

/// The same, for an entry whose runs are slow (SLOW_RUN_MS): a run of a wide
/// graph is seconds of every core, and one started in a 150 ms gap between
/// two words is killed by the next keystroke (see Server::touch). Higher:
/// fewer runs thrown away; lower: results sooner after the last keystroke.
/// Never below the editor's own debounceMs.
pub const SLOW_ENTRY_DEBOUNCE_MS: i64 = 400

/// Quiet time before a buffer's syntax-only pass ON THE FALLBACK PATH (a
/// process per pass, when the persistent syntax worker cannot run: no pipes
/// on the platform, or it keeps dying). The persistent worker has no
/// debounce: a pass starts on every change. initializationOptions.syntaxDebounceMs.
pub const SYNTAX_DEBOUNCE_MS: i64 = 100

/// The persistent syntax worker is restarted, between requests, after this
/// many passes or above this resident size: something a CompilerInstance
/// allocates outlives it (about 0.4 MB a pass, P829), and a restart costs
/// one process start (about 50 ms, overlapped with typing) per few hundred
/// keystrokes. Higher: fewer restarts, more memory.
pub const SYNTAX_SERVER_MAX_PASSES: u64 = 400
pub const SYNTAX_SERVER_MAX_RSS_MB: i64 = 400

/// A syntax pass that has not answered in this long is taken as hung: the
/// worker is restarted and that pass runs as a process.
pub const SYNTAX_SERVER_TIMEOUT_MS: i64 = 5000

/// Deaths or timeouts of the syntax worker after which the server stops
/// restarting it and uses a process per pass for the rest of the session.
pub const SYNTAX_SERVER_MAX_RESTARTS: u64 = 8

/// The largest debounce an editor may ask for: a typo in the option must not
/// switch analysis off.
pub const MAX_DEBOUNCE_OPTION_MS: i64 = 5000

/// Index workers at once. More: a multi-entry project settles sooner, at about
/// 200 MB (debug) per worker. initializationOptions.maxWorkers.
pub const MAX_INDEX_WORKERS: usize = 2

/// The most index workers the maxWorkers option may ask for.
pub const MAX_WORKERS_OPTION: i64 = 8

/// Syntax passes at once, over all buffers: each is a compiler process, and a
/// change touching many buffers (a rename) must not start one per buffer.
pub const MAX_SYNTAX_PASSES: usize = 2

/// A run longer than this marks its entry slow: what is parked on it is
/// answered from the old snapshot instead of waiting, and progress is shown.
pub const SLOW_RUN_MS: i64 = 1000

/// How long a request may wait for a fresh snapshot before it is answered
/// from what there is. Wall time, not loop turns: a turn is as short as the
/// next debounce deadline. Longer: fewer answers from stale text; shorter: a
/// snappier editor during long runs.
pub const PARK_LIMIT_MS: i64 = 3000

/// How long a request waits for an entry's FIRST index before that is taken
/// as not coming (a crashing or hung worker).
pub const FIRST_INDEX_LIMIT_MS: i64 = 120000

/// Above this many files in the import graph, only the editor's open buffers
/// are indexed. References and rename then cover the open files only: the
/// alternative is a snapshot of every file of a large tree on every pause in
/// typing, most of it never asked about.
pub const WIDE_INDEX_LIMIT: usize = 96

/// A worker that could not be started (its binary gone, no processes left)
/// leaves its work due, and the next launch of any worker is tried after
/// LAUNCH_RETRY_MS, doubling per refusal in a row up to LAUNCH_RETRY_MAX_MS:
/// soon enough that a passing failure costs a fraction of a second, rare
/// enough that a binary that cannot start is not spawned every loop turn.
pub const LAUNCH_RETRY_MS:     i64 = 250
pub const LAUNCH_RETRY_MAX_MS: i64 = 8000

/// After this many refusals in a row an entry's run is taken as not coming
/// (about 16 s of retries at the backoff above): a request waiting for its
/// first index is answered from nothing, and the failure is shown once,
/// rather than the request waiting out FIRST_INDEX_LIMIT_MS.
pub const LAUNCH_GIVE_UP: u32 = 6

/// The trace buffer ($/kals/text and --trace) is cut back to TRACE_KEEP_BYTES
/// once it passes TRACE_CAP_BYTES: memory against how much history a bug
/// report carries.
pub const TRACE_CAP_BYTES:  usize = 262144
pub const TRACE_KEEP_BYTES: usize = 131072

/// The longest the loop waits for a message when nothing is due: the
/// latency of noticing a finished worker, against idle wake-ups.
pub const IDLE_WAIT_MS: i64 = 40

/// Signature help lists at most this many overloads.
pub const MAX_SIGNATURES: usize = 8

/// workspace/symbol answers at most this many: an empty query must not send
/// every symbol of a large tree.
pub const WORKSPACE_SYMBOL_CAP: usize = 512

/// The C/C++ source scan of the clangd bridge stops this deep and at this many
/// files: a workspace holding a vendored tree must not stall the first turn.
pub const SOURCE_WALK_DEPTH:     u32   = 8
pub const SOURCE_WALK_MAX_FILES: usize = 4000

/// How often kals looks at overlay.yaml's mtime for a write by another kals
/// on the same root (a second editor), and merges its own entries back into
/// it: how long such a race can hide a header from clangd, against a stat
/// per interval.
pub const BRIDGE_OVERLAY_CHECK_MS: i64 = 2000

/// The C/C++ sources most recently reported changed whose included .k files
/// get their headers first (after the open ones): longer remembers more of
/// what the user has been editing, at a scan-time cost per source.
pub const BRIDGE_RECENT_SOURCES: usize = 16

/// The clangd bridge follows a source's quoted includes this many headers
/// deep, and reads at most this many headers per scan, to find the sources
/// that reach a .k through a header (P861): deeper and more cover more
/// indirect includers, at a read per header on every scan after a C/C++
/// change. A source past either bound gets the overlay but not kcc's flags.
pub const BRIDGE_INCLUDE_DEPTH:     u32   = 8
pub const BRIDGE_INCLUDE_MAX_READS: usize = 4000

/// --- the live index worker (initializationOptions.liveCheck) -------------

/// Entries that may hold a live index worker at once. Each is a whole
/// checked graph kept resident (about 4 GB for a 400-file graph), where a
/// per-run worker gives its memory back when it exits. An entry past the
/// cap is analysed by a process per run, as with the option off. Higher:
/// more entries answer an edit in place; lower: less resident memory.
pub const LIVE_MAX_CHILDREN: usize = 2

/// A live worker is restarted, between requests, once its resident size
/// passes its size after the first check by this factor plus this slack.
/// A re-check frees the trees it replaced once its queue is empty, so
/// what still grows is small per edit of a leaf (under 1 MB) and about
/// 170 MB per edit of a core file, whose dropped C++ template instances
/// are filled again into the header files' trees (Compiler/Spec/
/// IncrementalSema.md, "Memory"); a whole check inside the worker leaves
/// about 0.57 GB. A
/// restart costs one whole check of the graph, in the background of the
/// next edit. Higher: fewer restarts, more memory. Relative, not absolute:
/// a large graph is large from its first check on.
pub const LIVE_RSS_FACTOR_PCT: i64 = 175
pub const LIVE_RSS_SLACK_MB:   i64 = 256

/// A live request not answered in this long is a hung worker: it is
/// killed, and that revision is analysed by a process. Above the longest
/// first check of a large graph by a debug build.
pub const LIVE_TIMEOUT_MS: i64 = 300000

/// Deaths or timeouts of an entry's live worker after which the entry is
/// analysed by a process per run for the rest of the session.
pub const LIVE_MAX_RESTARTS: u64 = 4

/// How long a live request waits for the syntax pass's verdict on a changed
/// buffer. A buffer that does not parse cannot be re-checked in place (the
/// live worker would fall back to a whole check and grow by one), so that
/// revision goes to a process per run instead and the live worker keeps the
/// last text that parsed. Past this the request is sent without a verdict.
pub const LIVE_SYNTAX_WAIT_MS: i64 = 500

/// Files the live worker re-checks in the background between two looks at
/// its requests (a file is about 25 ms in a release build). An edit that
/// arrives during a slice waits for the slice to end before its own file
/// is re-checked. Higher: fewer snapshots installed while importers are
/// re-checked; lower: an edit pre-empts sooner.
pub const LIVE_SLICE_FILES: usize = 4

/// Below LIVE_RSS_FACTOR_PCT a live worker that has grown this much is
/// restarted too, but only once the editor has been quiet for
/// LIVE_IDLE_RECYCLE_MS: the restart's whole check then runs while nobody
/// is typing, and the next edit finds a worker that is already warm. Lower
/// percentage: less memory held, a restart at more pauses.
pub const LIVE_RSS_IDLE_PCT:    i64 = 130
pub const LIVE_IDLE_RECYCLE_MS: i64 = 4000

/// Whether the live worker re-checks the editor's open buffers (and what
/// they import) before the rest of the queue. Off: the queue is drained in
/// the order Sema runs files. On, an open importer deep in the graph gets
/// its results sooner. A generic instance's once-only reports belong to
/// its first use in Sema's order, so the queued files that were first to
/// use an instance the buffer names go before it, and when that cannot be
/// arranged the queue's order stands for that step
/// (FrontendAction::prefer_first_users; IncrementalSema.md, "Preferred
/// order"): no whole check is taken for the preference.
pub const LIVE_PREFER_OPEN: bool = true
