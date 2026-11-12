/// --- The Kairo Project ------------------- Analyzer/Index/WorkerKeys.k --- ///
///
///   The JSON member names of what the server sends a worker that stays up
///   (the live index worker, LiveWorker.k; the syntax worker,
///   Worker.k syntax_server_main) and of what it answers. The server writes
///   the requests and reads the answers (Server/LiveIndex.k,
///   Server/SyntaxWorker.k); one definition here, so a member cannot be
///   written under one spelling and read under another. A snapshot an
///   answer carries or names is Snapshot.k's (SK_*).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///


// --- requests ---------------------------------------------------------------
pub const RQ_ID:       string = "id"        ///< both workers: answered under the same id
pub const RQ_OUT:      string = "out"       ///< live: where the answer's snapshot goes
pub const RQ_OPEN:     string = "open"      ///< live: every buffer of the entry, as {path, file}
pub const RQ_PATH:     string = "path"      ///< live: an `open` buffer's real path
pub const RQ_FILE:     string = "file"      ///< live: the file holding an `open` buffer's text; syntax: the buffer's path
pub const RQ_CHANGED:  string = "changed"   ///< live: files whose text on disk changed
pub const RQ_PROGRESS: string = "progress"  ///< live: where the progress count is written
pub const RQ_TEXT:     string = "text"      ///< syntax: the buffer's text
/// live: read by the worker, written by no server (P916).
pub const RQ_ORDER:    string = "order"

// --- answers ----------------------------------------------------------------
pub const RP_ID:            string = "id"
pub const RP_OK:            string = "ok"
pub const RP_ERROR:         string = "error"         ///< ok false: why
pub const RP_SUPERSEDED:    string = "superseded"    ///< a newer request took this one's place
pub const RP_BG:            string = "bg"            ///< live: a second-tier slice, not the request's first answer
pub const RP_MODE:          string = "mode"          ///< live: "full" or "refresh"
pub const RP_WHY:           string = "why"
pub const RP_RECHECKED:     string = "rechecked"
pub const RP_PENDING:       string = "pending"       ///< live: importers still queued
pub const RP_TOUCHED:       string = "touched"
pub const RP_FILES:         string = "files"         ///< live: the graph's file count
pub const RP_OUT:           string = "out"           ///< live: the snapshot written, "" for none
pub const RP_US:            string = "us"
pub const RP_RETIRED_FILES: string = "retiredFiles"
pub const RP_RETIRED_MB:    string = "retiredMb"
