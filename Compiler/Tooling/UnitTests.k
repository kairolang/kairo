/// --- The Kairo Project ------------------------- Tooling/UnitTests.k --- ///
///
///   The kunit driver: runs the in-module `Test()` functions.
///
///   \par Usage
///     kunit [--bench] [--list] [name ...]
///
///     With no name every test runs, in the order below. A name runs only
///     that test (`kunit TermRenderer`); an unknown name is an error.
///     `--bench` also runs the throughput benchmarks a test carries (the
///     lexer's hot loop lexes two 1 GiB buffers).
///
///     Each test prints its own output, then one line: `ok <name>` or
///     `FAIL <name>`. The exit code is 1 when any test failed. A test that
///     crashes ends the run, so a crash is a failure too.
///
///   \par Build target
///     Registered in build.py as 'kunit'. It is a verification driver, not a
///     shipped tool: it is not staged into the release tree, and nothing
///     imports it. Tests/unit runs it when it is built beside kairo.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "cstring"
ffi "c++" import "vector"
ffi "c++" import "Native/Log.hh"

import Command::FlagRegistry::Test as command_test
import DocComment::Test as doc_comment_test
import Lexer::Lexer::Test as lexer_test
import Location::SourceManager::Test as source_manager_test
import Memory::MappedFileBuffer::Test as mapped_file_buffer_test
import Support::FileIO::AtomicFile::Test as atomic_file_test
import Support::TermRenderer::Test as term_renderer_test
import Threading::ThreadPool::Test as thread_pool_test
import std::c_char
import std::io

/// Runs the selected tests and counts the failures. `only` empty selects
/// every test.
class UnitRunner {
    var only:   cxx::std::vector<string>
    var known:  cxx::std::vector<string>
    var list:   bool                     = false
    var failed: usize                    = 0

    fn UnitRunner(self, only: cxx::std::vector<string>, list: bool) {
        self.only = only
        self.list = list
    }

    fn _selected(self, const name: string) -> bool {
        if self.only.empty() {
            return true
        }

        for var i: usize = 0; i < self.only.size(); ++i {
            if self.only[i] == name {
                return true
            }
        }

        return false
    }

    fn run(self, const name: string, body: fn () -> i32) {
        self.known.push_back(name.copy())
        if self.list {
            io::println(name)
            return
        }

        if !self._selected(name) {
            return
        }

        if body() == 0 {
            io::println(f"ok {name}")
        } else {
            ++self.failed
            io::println(f"FAIL {name}")
        }
    }

    /// The exit code: 2 for a name no test has, 1 for a failure, else 0.
    fn finish(self) -> i32 {
        var unknown = false
        for var i: usize = 0; i < self.only.size(); ++i {
            var found = false
            for var j: usize = 0; j < self.known.size(); ++j {
                if self.known[j] == self.only[i] {
                    found = true
                }
            }

            if !found {
                io::eprintln(
                    f"kunit: no test named '{self.only[i]}' (kunit --list)",
                )

                unknown = true
            }
        }

        if unknown {
            return 2
        }

        if self.failed != 0 {
            io::println(f"kunit: {self.failed} test(s) failed")
            return 1
        }

        return 0
    }
}

pub fn main(argc: i32, argv: unsafe *(unsafe *c_char)) -> i32 {
    kairo::Logger::init(kairo::Logger::Level::Warn)

    var bench = false
    var list  = false
    var only  = cxx::std::vector<string>()
    for var i: i32 = 1; i < argc; ++i {
        var arg = string(
            unsafe ((argv[i] as unsafe *const u8) as *const u8),
            cxx::std::strlen(argv[i]),
        )

        if arg == "--bench" {
            bench = true
        } else if arg == "--list" {
            list = true
        } else {
            only.push_back(arg)
        }
    }

    var runner = UnitRunner(only, list)
    runner.run("ThreadPool", thread_pool_test)
    runner.run("MappedFileBuffer", mapped_file_buffer_test)
    runner.run("SourceManager", source_manager_test)
    runner.run("Lexer", fn () -> i32 { return lexer_test(bench) })
    runner.run("FlagRegistry", command_test)
    runner.run("TermRenderer", term_renderer_test)
    runner.run("AtomicFile", atomic_file_test)
    runner.run("DocComment", doc_comment_test)
    return runner.finish()
}
