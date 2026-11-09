/// --- The Kairo Project ------------------------------ Support/Timer.k --- ///
///
///   Timer: a scoped steady-clock timer that prints its elapsed time.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

///
/// \file Timer.k
/// \brief lightweight scoped timer for profiling and benchmarking.
///
/// \details
/// `Timer` measures elapsed execution time using `steady_clock`, printing the
/// result automatically on destruction. intended for quick profiling of hot paths
/// or scoped operations (e.g., parsing, compilation stages, i/o).
///
/// measurements are taken in microseconds, with both µs and ms values printed
/// for convenience. the timer is resettable and uses steady clock to ensure
/// monotonic time progression even across system clock adjustments.
///
/// example:
/// ```kairo
/// { // for some reason stage(0) doesn't work with scopes
///     var t = Timer("lex phase");
///     lexer.run();
/// } // automatically prints: "lex phase elapsed: 213 µs (0.213 ms)"
/// ```
///
/// \note
/// meant for short-lived scopes, not for long-term scheduling or wall-clock use.
///
/// \see libcxx::chrono::steady_clock
///

ffi "c++" import "chrono"

import std::io

pub class Timer {
    priv var _start: cxx::std::chrono::steady_clock::time_point ///< start timestamp.
    priv var _label: string                                     ///< label printed on stop.

    ///
    /// \brief constructs and starts a new timer.
    ///
    /// \param label optional descriptive name (default: `"Timer"`).
    ///
    inline fn Timer(self) {
        var label: string = "Timer"
        self._start = cxx::std::chrono::steady_clock::now()
        self._label = label
    }

    pub inline fn Timer(self, const label: string) {
        self._start = cxx::std::chrono::steady_clock::now()
        self._label = label
    }

    // Not transferable: the destructor stops and prints it, so a copy would report the same region twice.
    @copy fn Timer(self, const other: Self) = delete

    ///
    /// \brief destructor; automatically stops and prints elapsed time.
    ///
    inline fn op finally (self) {
        self.stop()
    }


    pub inline fn elapsed_ns(self) -> i64 {
        var end = cxx::std::chrono::steady_clock::now()
        var dur = cxx::std::chrono::duration_cast<cxx::std::chrono::nanoseconds>(end - self._start)
        return dur.count()
    }

    inline fn elapsed_us(self) -> f64 {
        return (self.elapsed_ns() as f64) / 1000.0
    }

    inline fn elapsed_ms(self) -> f64 {
        return (self.elapsed_ns() as f64) / 1000000.0
    }

    ///
    /// \brief prints elapsed time since start.
    ///
    /// \details
    /// stops the timer and prints a formatted line with both µs and ms precision.
    ///
    pub inline fn stop(self) {
        var ns = self.elapsed_ns()
        var us = (ns as f64) / 1000.0
        var ms = (ns as f64) / 1000000.0

        io::println(f"{self._label} elapsed: {ns} ns ({us} µs / {ms} ms)\n")
    }

    ///
    /// \brief resets the timer's start point to the current time.
    ///
    inline fn reset(self) {
        self._start = cxx::std::chrono::steady_clock::now()
    }
}
