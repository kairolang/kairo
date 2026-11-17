/// --- The Kairo Project ---------------------------- Driver/Progress.k --- ///
///
///   Build progress: a pinned status line on a terminal, `@progress` event
///   lines for a program reading stderr. Kairo surface over the engine in
///   Native/Progress.hh (see there for why it is native); the flag and the
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

ffi "c++" import "Native/Progress.hh"

/// The phases, in the order a run reaches them. The numbers are the native
/// enum's (Progress.hh, ProgressMeter::Phase).
pub
const PROGRESS_PARSE: i32 = 0
pub
const PROGRESS_SEMA: i32 = 1
pub
const PROGRESS_CODEGEN: i32 = 2

/// Resolves --progress. False for a value that is none of auto, always,
/// never, lines; the meter is then off. `auto` is on whenever stderr is a
/// terminal, --verbose included.
pub fn progress_configure(const flag: string) -> bool {
    var f = flag.copy()
    return kairo::ProgressMeter::configure(f.c_str(), false)
}

/// Whether the meter writes anything; callers building a file name for a tick
/// ask first, so a run with --progress=never pays nothing.
pub fn progress_on() -> bool {
    return kairo::ProgressMeter::mode() != 0
}

/// A phase of \p total units begins; counters restart at zero.
pub fn progress_begin(phase: i32, total: usize) {
    kairo::ProgressMeter::begin(phase, total)
}

/// \p n units finished, \p file the one that did. Any thread.
pub fn progress_tick(phase: i32, const file: string, n: usize = 1) {
    if kairo::ProgressMeter::mode() == 0 {
        return
    }

    var f = file.copy()
    kairo::ProgressMeter::tick(phase, f.c_str(), n)
}

/// \p n units need no work (codegen: the object cache held them); they count
/// as done and as reused.
pub fn progress_reuse(phase: i32, n: usize) {
    kairo::ProgressMeter::reuse(phase, n)
}

pub fn progress_end(phase: i32) {
    kairo::ProgressMeter::end(phase)
}

/// Erase the pinned line and keep it off until progress_release(): bracket
/// every write to stderr that can run while a phase is active.
pub fn progress_hold() {
    kairo::ProgressMeter::hold()
}

pub fn progress_release() {
    kairo::ProgressMeter::release()
}

/// The run is over: erase the line and stop drawing. Idempotent.
pub fn progress_finish() {
    kairo::ProgressMeter::finish()
}
