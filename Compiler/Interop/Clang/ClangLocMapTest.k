/// --- The Kairo Project ------------- Interop/Clang/ClangLocMapTest.k --- ///
///
///   \brief Round-trip verification for ClangLocMap.
///
///   \par Why this is its own file
///     The test needs a live clang SourceManager, and the only thing that
///     builds one standalone is ClangBackend   which IMPORTS ClangLocMap. A
///     Test block inside ClangLocMap.k would close that cycle. The test
///     therefore sits ABOVE both: it imports the backend and the map, and
///     nothing imports it.
///
///     That is the general shape for interop tests here. The subject of the
///     test is a leaf; the scaffolding that makes it observable is not.
///
///   \par No pipeline required, and that is the point
///     rebind() needs a live FileManager + SourceManager and nothing else
///     no Preprocessor, no parse, no driver. ClangBackend::startup() builds
///     exactly that, so this test never touches the driver and the
///     circular-import problem never arises.
///
///     What the codegen action window actually contributes is ONE call:
///     SourceManager::clearIDTables(). It is public, so the regression that
///     motivated the rewrite is directly constructible here rather than
///     something you hope a real compile happens to exercise.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "clang/Basic/SourceManager.h";
ffi "c++" import "llvm/Support/MemoryBufferRef.h";
ffi "c++" import "llvm/TargetParser/Triple.h";
ffi "c++" import "llvm/TargetParser/Host.h";

import Location::SourceLocation::*;
import Location::SourceManager::*;
import Support::FileIO::Path::*;
import Support::FileIO::VirtualFileManager::*;
import Threading::ThreadPool::*;
import Diagnostic::Engine::*;
import Interop::Clang::ClangLocMap::*;
import Interop::Clang::ClangBackend::*;

/// Failure count. A test whose only output is an exit code cannot distinguish
/// "every check passed" from "no check ran"   which is exactly what a release
/// build does to assert(). Nothing here uses assert; every check reports.
var _fails: u32 = 0;
var _ran:   u32 = 0;

priv fn _check(cond: bool, what: string) {
    _ran += 1;
    if cond {
        std::print(f"  pass  {what}");
    } else {
        _fails += 1;
        std::print(f"  FAIL  {what}");
    }
}

/// Host triple, same normalization the driver applies. Duplicated rather than
/// reached for through CompilerInstance, which would drag the driver in and
/// re-create the cycle this file exists to avoid.
priv fn _host_triple() -> string {
    var t = llvm::Triple(llvm::Triple::normalize(llvm::sys::getProcessTriple()));
    if (t.getVendor()) == (llvm::Triple::UnknownVendor) && (t.isOSLinux()) {
        t.setVendor(llvm::Triple::PC);
    }
    return std::nstring_to_string(t.getTriple());
}

/// \param argv[1] optional directory holding the fixtures. Fixture paths are
///        resolved against it, NOT against cwd   a relative path that silently
///        fails to load leaves file_count() at 0, and every downstream check
///        then passes vacuously. Defaults to the in-tree location.
fn main(argc: i32, argv: *(*kairo::std::Legacy::char)) -> i32 {
    var root: string = "Tests/Clang/Inputs";
    if argc > 1 { root = std::nstring_to_string(nstring(argv[1])); }

    std::print("=== ClangLocMap round-trip test ===");
    std::print(f"fixtures: {root}");

    var pool = ThreadPool(1);
    var diag = DiagEngine();
    var vfm  = VirtualFileManager(&diag);
    var ksm  = SourceManager(&pool, &vfm, &diag);

    // Three files is the minimum that proves anything: fid 0 fixes the base,
    // fid 1 proves the stride, fid 2 proves the stride is not an accident of
    // two. Sizes MUST differ   uniform files hide a stride bug, because every
    // wrong answer is then also a consistent one. loc_c is >4 KB so it spans a
    // page boundary and exercises the alignment gap.
    ksm.load_file(Path(f"{root}/loc_a.k"), true);
    ksm.load_file(Path(f"{root}/loc_b.k"), true);
    ksm.load_file(Path(f"{root}/loc_c.k"), true);

    // HARD stop, not a soft check: everything below is vacuous without files,
    // and a vacuous pass is worse than a failure.
    if ksm.file_count() != 3 {
        std::print(f"ABORT: loaded {ksm.file_count()} fixture(s), expected 3.");
        std::print("       Pass the fixture directory as argv[1].");
        return 2;
    }

    var cfg = ClangBackendConfig{};
    (cfg.triple) = _host_triple();

    var be = ClangBackend(&ksm, cfg);
    be.startup();
    if !be.ready() {
        std::print(f"ABORT: clang backend failed to start (triple={cfg.triple})");
        return 2;
    }

    var ci  = be.ci();
    var lm  = be.locmap();
    var csm = &ci->getSourceManager();

    // 1. The bijection holds on a fresh SM.
    _check(lm->rebind(ci), "rebind on fresh SM");
    _check(lm->verify(),   "bijection on fresh SM");
    lm->dump();

    var base_before = lm->block_base();

    // 2. THE REGRESSION. Exactly what FrontendAction::BeginSourceFile does on
    //    the SM-reuse path, and what silently invalidated every FileID the old
    //    preload() handed out.
    csm->clearIDTables();

    _check(lm->rebind(ci), "rebind after clearIDTables");
    _check(lm->verify(),   "bijection after clearIDTables");

    // The base is REPORTED, not asserted equal or unequal. Whether clang
    // restarts its counter at the same value is clang's business; the point is
    // that nothing here depends on it. A cached clang::FileID did.
    std::print(f"  info  block base: {base_before} -> {lm->block_base()}");

    // 3. Post-block FileIDs are what headers, predefines, and
    //    Preprocessor::CreateString scratch buffers actually occupy. Accepting
    //    one is the silent-wrong-caret failure: a diagnostic in <vector>
    //    rendered against a Kairo file at a bogus offset.
    var hdr = csm->createFileID(
        llvm::MemoryBufferRef(llvm::StringRef(r"#include <x>", 12), r"<hdr>"),
        clang::SrcMgr::C_User);
    _check(lm->kairo_fid(hdr) == static_cast::<FileID>(u32(-1)),
           "post-block FileID rejected");

    // 4. Invalid in, invalid out   never fid 0. An unsigned underflow in
    //    kairo_fid() surfaces right here.
    _check(lm->kairo_fid(clang::FileID()) == static_cast::<FileID>(u32(-1)),
           "invalid clang FileID rejected");
    _check(!lm->to_clang(SourceLocation::invalid()).isValid(),
           "invalid Kairo loc rejected");

    // 5. A fid loaded AFTER the last rebind must be rejected, not guessed at.
    ksm.load_file(Path(f"{root}/loc_d.k"), true);
    var late = static_cast::<FileID>(ksm.file_count() - 1);
    _check(!lm->to_clang(ksm.get_loc(late, 0)).isValid(),
           "fid loaded after rebind rejected");

    // ...and correct once rebuilt, which is how per-action rebind replaces the
    // old tail-tracking preload.
    _check(lm->rebind(ci), "rebind picks up late fid");
    _check(lm->verify(),   "bijection after late load_file");
    _check(lm->to_clang(ksm.get_loc(late, 0)).isValid(),
           "late fid translates after rebind");

    std::print(f"=== {_ran - _fails}/{_ran} passed ===");
    if _fails > 0 { return 1; }
    return 0;
}
