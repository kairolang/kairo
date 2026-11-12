/// --- The Kairo Project ----------------------------- Analyzer/WorkerArgs.k --- ///
///
///   The worker command line: `kals --worker ...`, built by the server
///   (Server/Workers.k, Diagnostics.k, ClangdBridge.k, SyntaxWorker.k,
///   LiveIndex.k) and parsed by Driver/kals.k and the workers (Index/Worker.k,
///   Index/LiveWorker.k). One spelling per word, for builders and parsers
///   alike; the shapes are LanguageServer.md sections 1, 3 and 10.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///


// --- the worker's own words -------------------------------------------------
/// First word after the executable: the process is a worker, not the server.
pub const WA_WORKER: string = "--worker"
/// The live index worker, which stays up (Index/LiveWorker.k).
pub const WA_INDEX_SERVER: string = "--index-server"
/// The syntax worker, which stays up (Index/Worker.k syntax_server_main).
pub const WA_SYNTAX_SERVER: string = "--syntax-server"
/// `<file>`: one syntax pass of that file, as a process.
pub const WA_SYNTAX_ONLY: string = "--syntax-only"
/// The clangd bridge's header job: the entry is checked as the module it is.
pub const WA_AS_MODULE: string = "--as-module"
/// `<dir>`: the directory the entry's arguments are relative to.
pub const WA_CWD: string = "--cwd"
/// `<dir>`: index every file under the project, not only the graph's.
pub const WA_ROOT: string = "--root"
/// `<path> <file>`: the buffer for \p path is the text of \p file.
pub const WA_OVERLAY: string = "--overlay"
/// `<file>`: where the count of checked files is written as it goes.
pub const WA_PROGRESS: string = "--progress"
/// Ends the worker's words; the entry's kairo arguments follow.
pub const WA_END: string = "--"

// --- compiler flags the server and the workers add to an entry's ------------
pub const CF_TYPE_CHECK_ONLY:          string = "--type-check-only"
pub const CF_THREADS_ONE:              string = "--threads=1"
pub const CF_CHECK_PAST_SYNTAX_ERRORS: string = "--check-past-syntax-errors"
pub const CF_ERROR_FORMAT_BASIC:       string = "--error-format=basic"
pub const CF_EMIT_HEADERS:             string = "--emit-headers"
pub const CF_EMIT_HEADERS_LAYOUT:      string = "--emit-headers-layout"
