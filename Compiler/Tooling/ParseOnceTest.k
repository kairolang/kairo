/// --- The Kairo Project ---------------------- Tooling/ParseOnceTest.k --- ///
///
///   The kparse driver: parses one file through the argv-free tooling path.
///
///   \par What it proves
///     Nothing in this file constructs an argv array, a `char*`, or a flag
///     string. Options are set as typed fields on a CompilerInvocation, the
///     invocation is handed to parse_once(), and an AST comes back. That was
///     impossible before CompilerInvocation::from_args was split out of the
///     CompilerInstance constructor   the only way to pass `-I Compiler` was
///     to synthesise argv and keep the backing buffers alive past the call.
///
///   \par Usage
///     kparse <file.k> [include-dir ...]
///
///     Include dirs are positional and plain: they go straight into
///     inv.include_dirs. There is no flag parser here, which is the point.
///
///     $KPARSE_VIA_ARGV=1 switches to the delegating overload, which DOES take
///     an argv   ours, forwarded verbatim   so the two entry points can be
///     diffed against each other on the same input:
///
///       kparse file.k Compiler                    # invocation path
///       KPARSE_VIA_ARGV=1 kparse file.k -I Compiler   # argv path
///
///   \par Build target
///     Registered in build.py as 'kparse'. It is a verification driver, not a
///     shipped tool: nothing imports it.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/Support/TargetSelect.h"
ffi "c++" import "cstdlib"
ffi "c++" import "Native/KLog.hh"
ffi "c++" import "cstring"

import AST::Printer::PrintCore::PrintOptions
import AST::Printer::Printers::ASTPrinter
import Config::Invocation::CompilerInvocation
import Driver::TUStage::TUStage
import Support::FileIO::Path::Path
import Tooling::ParseAPI::{
    OwnedUnit,
    parse_once,
}
import std::c_char
import std::io

pub fn main(argc: i32, argv: unsafe *(unsafe *c_char)) -> i32 {
    llvm::InitializeAllTargetInfos()
    llvm::InitializeAllTargets()
    llvm::InitializeAllTargetMCs()
    llvm::InitializeAllAsmParsers()
    llvm::InitializeAllAsmPrinters()

    kairo::Logger::init(kairo::Logger::Level::Warn)

    if argc < 2 {
        io::println("Usage: kparse <file.k> [include-dir ...]")
        return 1
    }

    // argv is read HERE, by this program, into ordinary strings. It is never
    // handed to the compiler, which would parse it as its own command line.
    var target = string(
        unsafe ((argv[1] as unsafe *const u8) as *const u8),
        cxx::std::strlen(argv[1]),
    )

    var inv = CompilerInvocation()
    for var i: i32 = 2; i < argc; ++i {
        inv.include_dirs.push_back(
            string(unsafe ((argv[i] as unsafe *const u8) as *const u8), cxx::std::strlen(argv[i])),
        )
    }

    // Typed option, not a flag string. This is the whole point of the split.
    inv.frontend.thread_count = 0

    // $KPARSE_VIA_ARGV exercises the delegating overload instead: it hands our
    // own argv straight to CompilerInvocation::from_args. Same result, and it
    // proves the two entry points agree.
    var via_argv: bool = cxx::std::getenv(r"KPARSE_VIA_ARGV") != &null

    var owned = OwnedUnit()
    if via_argv {
        owned = parse_once(Path(target), argc, argv, TUStage::Parsing)
    } else {
        owned = parse_once(Path(target), &inv, TUStage::Parsing)
    }

    io::println(f"== kparse {target}")
    var stage_n = ((owned.unit.stage as u8) as i32)
    io::println(
        f"== fids={owned.unit.fids.size()} stage={stage_n} errors={owned.unit.errors} warnings={owned.unit.warnings} ok={owned.ok()} clean={owned.clean()}",
    )

    for var i: usize = 0; i < owned.unit.diags.size(); ++i {
        io::println(f"   {owned.unit.diags[i].format()}")
    }

    if !owned.ok() {
        io::println("== no translation unit")
        return 1
    }

    var opts = PrintOptions::dump()
    opts.color = false
    ASTPrinter::print(owned.unit.tu, opts)

    // owned's destructor runs here: release_all(Lexing), clear_retained(),
    // destroy(ci). Everything reached through owned.unit dangles past this
    // point, which is exactly the contract OwnedUnit documents.
    return 0
}
