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
