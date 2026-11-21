/// --- The Kairo Project ---------------------------- Driver/Progress.k --- ///
///
///   Build progress: a pinned status line on a terminal, `@progress` event
///   lines for a program reading stderr. Kairo surface over the engine in
///   Native/Progress.k (see there for why it is native); the flag and the
///   line format are documented in Spec/Driver.md#progress.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Native::Progress::ProgressMeter

/// The phases, in the order a run reaches them. The numbers are
/// ProgressMeter's (Native/Progress.k, ProgressMeter::Parse ..).
pub
const PROGRESS_PARSE: i32 = 0
pub
const PROGRESS_SEMA: i32 = 1
pub
const PROGRESS_CODEGEN: i32 = 2

/// Codegen's stages (fed by clang's timing, Native/ClangTime.k) and the link.
pub
const PROGRESS_IRGEN: i32 = 3
pub
const PROGRESS_OPT: i32 = 4
pub
const PROGRESS_EMIT: i32 = 5
pub
const PROGRESS_LINK: i32 = 6

/// Resolves --progress. False for a value that is none of auto, always,
/// never, lines; the meter is then off. `auto` is on whenever stderr is a
/// terminal, --verbose included.
pub fn progress_configure(const flag: string) -> bool {
    var f = flag.copy()
    return ProgressMeter::configure(f.c_str(), false)
}

/// Whether the meter writes anything; callers building a file name for a tick
/// ask first, so a run with --progress=never pays nothing.
pub fn progress_on() -> bool {
    return ProgressMeter::mode() != 0
}

/// A phase of `total` units begins; counters restart at zero.
pub fn progress_begin(phase: i32, total: usize) {
    ProgressMeter::begin(phase, total)
}

/// `n` units finished, `file` the one that did. Any thread.
pub fn progress_tick(phase: i32, const file: string, n: usize = 1) {
    if ProgressMeter::mode() == 0 {
        return
    }

    var f = file.copy()
    ProgressMeter::tick(phase, f.c_str(), n)
}

/// `n` units need no work (codegen: the object cache held them); they count
/// as done and as reused.
pub fn progress_reuse(phase: i32, n: usize) {
    ProgressMeter::reuse(phase, n)
}

pub fn progress_end(phase: i32) {
    ProgressMeter::end(phase)
}

/// Erase the pinned line and keep it off until progress_release(): bracket
/// every write to stderr that can run while a phase is active.
pub fn progress_hold() {
    ProgressMeter::hold()
}

pub fn progress_release() {
    ProgressMeter::release()
}

/// The run is over: erase the line and stop drawing. Idempotent.
pub fn progress_finish() {
    ProgressMeter::finish()
}
