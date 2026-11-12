/// --- The Kairo Project ----------------------------- Support/Assert.k --- ///
///
///   Assert: a small test-assertion harness that times the code under test.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/KShims.hh" // volatile_i64
ffi "c++" import "chrono"

import std::io

pub class Assert {
    var passes:      usize  = 0
    var fails:       usize  = 0
    var overhead_ns: i64
    var name:        string

    /// we can count the number of tests run by checking passes + fails
    pub fn Assert(self, const n: string) {
        self.name        = n
        self.overhead_ns = self.measure_timer_overhead()
    }

    // (libcxx::wcout) << f"  \033[90m({(self.passes) + (self.fails) + 1}) ●\033[0m {m}".raw_string() << (libcxx::endl);

    fn summary(self) {
        var total = self.passes + self.fails
        io::println(f"\n=== Test Summary: {self.name} ===")
        io::println(f"  Passed: \x1b[32m{self.passes}\x1b[0m")
        io::println(f"  Failed: \x1b[31m{self.fails}\x1b[0m")
        io::println(f"  Total:  {total}")
    }

    priv fn test_success(self, const m: string, const time: string) {
        ++self.passes
        io::println(
            f"\x1b[32m({(self.passes) + (self.fails)})\t[PASS]\x1b[0m\t\x1b[90m({time})\x1b[0m\t{m}",
        )
    }

    priv fn <T> test_failure(self, m: string, e: T, v: T, time: string) {
        ++self.fails
        io::println(
            f"\x1b[31m({(self.passes) + (self.fails)}) \t[FAIL]\x1b[0m \t\x1b[90m({time})\x1b[0m \t{m}",
        )

        io::println(f"    \x1b[90m|>>>\x1b[0m expected: \x1b[33m{e}\x1b[0m")
        io::println(f"    \x1b[90m|>>>\x1b[0m actual:   \x1b[31m{v}\x1b[0m")
    }

    fn measure_timer_overhead(self) -> i64 {
        const iterations                     = 1000
        var   total                          = cxx::std::chrono::nanoseconds(0)
        var   dummy:     kairo::volatile_i64 = 0

        for var i = 0; i < iterations; ++i {
            const s = cxx::std::chrono::steady_clock::now()
            dummy = s.time_since_epoch().count() // force materialization
            const e = cxx::std::chrono::steady_clock::now()
            total += cxx::std::chrono::duration_cast<cxx::std::chrono::nanoseconds>(
                e - s,
            )
        }

        return total.count() / iterations
    }

    priv fn <T> time_and_run(self, c: fn () -> T, iters: usize) -> (T, string) {
        const start = cxx::std::chrono::steady_clock::now()

        var v: T
        for var i: usize = 0; i < iters; ++i {
            v = c()
        }

        const end = cxx::std::chrono::steady_clock::now()
        const dur = cxx::std::chrono::duration_cast<cxx::std::chrono::nanoseconds>(
            end - start,
        )

        const ns = (dur.count() as u64) / (iters as u64) - (self.overhead_ns as u64)
        const us = (ns as f64) / 1000.0
        const ms = (ns as f64) / 1000000.0
        const s  = (ns as f64) / 1000000000.0

        if us < 10.0 {
            if iters > 1 {
                return (v, f"mean: {ns}ns,\titers: {iters}")
            }

            return (v, f"{ns}ns")
        }

        if ms < 10.0 {
            if iters > 1 {
                return (v, f"mean: {us}us,\titers: {iters}")
            }

            return (v, f"{us}us")
        }

        if s < 10.0 {
            if iters > 1 {
                return (v, f"mean: {ms}ms,\titers: {iters}")
            }

            return (v, f"{ms}ms")
        }

        if iters > 1 {
            return (v, f"mean: {s}s,\titers: {iters}")
        }

        return (v, f"{s}s")
    }

    // TODO(DUCK-GENERIC): T uses op ==. Stage 0 was duck-typed; bound it or keep `: type`.
    pub fn <T: type> equal(self, m: string, e: T, c: fn () -> T, iters: usize = 1) {
        var res      = self.time_and_run<T>(c, iters)
        var v        = res.0
        var time_str = res.1

        if e == v {
            self.test_success(m, time_str)
        } else {
            self.test_failure(m, e, v, time_str)
        }
    }

    // TODO(DUCK-GENERIC): T uses op !=. Stage 0 was duck-typed; bound it or keep `: type`.
    fn <T: type> not_equal(self, m: string, e: T, c: fn () -> T, iters: usize = 1) {
        var res      = self.time_and_run<T>(c, iters)
        var v        = res.0
        var time_str = res.1

        if e != v {
            self.test_success(m, time_str)
        } else {
            self.test_failure(m, e, v, time_str)
        }
    }

    // Not transferable: the destructor prints the summary, so a copy would print it twice.
    @copy fn Assert(self, const other: Self) = delete

    fn op finally (self) {
        self.summary()
    }

    fn reset(self) {
        self.passes = 0
        self.fails  = 0
    }
}
