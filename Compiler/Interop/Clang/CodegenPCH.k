/// --- The Kairo Project ------------------- Interop/Clang/CodegenPCH.k --- ///
///
///   CodegenPCH, the one PCH over a TU's header sets, and its writer action.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/StringMap.h"
ffi "c++" import "llvm/Support/FileSystem.h"
ffi "c++" import "llvm/Support/Path.h"
ffi "c++" import "llvm/ADT/SmallString.h"
ffi "c++" import "cstring"
ffi "c++" import "llvm/ADT/STLExtras.h"
ffi "c++" import "llvm/ADT/DenseMap.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/KShims.hh" // header_set_late_uses
ffi "c++" import "clang/AST/ASTContext.h"
ffi "c++" import "clang/AST/ASTConsumer.h"
ffi "c++" import "clang/Basic/Diagnostic.h"
ffi "c++" import "clang/Basic/DiagnosticOptions.h"
ffi "c++" import "clang/Basic/FileEntry.h"
ffi "c++" import "clang/Basic/SourceManager.h"
ffi "c++" import "clang/Basic/TargetInfo.h"
ffi "c++" import "clang/Frontend/CompilerInstance.h"
ffi "c++" import "clang/Frontend/CompilerInvocation.h"
ffi "c++" import "clang/Frontend/FrontendAction.h"
ffi "c++" import "clang/Frontend/FrontendOptions.h"
ffi "c++" import "clang/Frontend/TextDiagnosticPrinter.h"
ffi "c++" import "clang/Lex/HeaderSearchOptions.h"
ffi "c++" import "clang/Lex/PPCallbacks.h"
ffi "c++" import "clang/Lex/Preprocessor.h"
ffi "c++" import "clang/Sema/Sema.h"
ffi "c++" import "clang/Serialization/ASTWriter.h"
ffi "c++" import "clang/Serialization/PCHContainerOperations.h"
ffi "c++" import "llvm/ADT/IntrusiveRefCntPtr.h"
ffi "c++" import "llvm/Support/Error.h"
ffi "c++" import "llvm/Support/MemoryBuffer.h"
ffi "c++" import "llvm/Support/VirtualFileSystem.h"
ffi "c++" import "llvm/Support/raw_ostream.h"
ffi "c++" import "Native/KLog.hh"
ffi "c++" import "Native/KTimeReport.hh"
ffi "c++" import "memory"
ffi "c++" import "vector"
ffi "c++" import "string"
ffi "c++" import "set"
ffi "c++" import "utility"
ffi "c++" import "cstdlib"

import Interop::Clang::ClangBackend::ClangBackend
import Interop::Clang::HeaderSet::HeaderSet
import Support::TimeReport::TimeRegion

///
/// \class CodegenPCHAction
/// \brief Writes CodegenPCH's bytes. A plain prefix parse: nothing walks the
///        AST afterwards, so no callbacks and no instance kept alive.
///
pub class CodegenPCHAction derives clang::ASTFrontendAction {
    pub var _buf: cxx::std::shared_ptr<clang::PCHBuffer>

    override fn CreateASTConsumer(self, @inout ci: clang::CompilerInstance, in_file: llvm::StringRef)
            -> cxx::std::unique_ptr<clang::ASTConsumer>
    override fn getTranslationUnitKind(self) -> clang::TranslationUnitKind
}

///
/// \class CodegenPCH
/// \brief Phase B's one implicit PCH: every header set a TU's emission
///        needs, in one parse.
///
/// clang loads one implicit PCH per TU, so with a PCH per set every set but
/// the first was `#include`d as text by every TU. The first was the TU's
/// own set -- for builtin's TUs the small rt/fmt.h one -- so libc++'s
/// <coroutine> (153 files, concept-heavy) was re-parsed by 22 of a
/// hello-sized program's 23 TUs: about 28 of each TU's 30 ms of backend time
/// (measured). A PCH of all of them loads in about 1.5 ms.
///
/// Built from the same text phase B's textual wrappers replay, so it parses
/// what the TUs' textual wrappers parse; a failed build leaves `ok` false and
/// the TUs fall back to the wrappers.
///
pub class CodegenPCH {
    pub var pch:  cxx::std::shared_ptr<clang::PCHBuffer>
    pub var ok:   bool                                   = false
    pub var path: string
    /// The backend's VFS holds the bytes at `path`. Driver thread only.
    pub var  mounted: bool             = false
    priv var _text:   cxx::std::string         ///< the injected buffer; must outlive the parse.

    fn CodegenPCH(self) {
        self.pch = cxx::std::make_shared<clang::PCHBuffer>()
    }

    fn build(self, be: unsafe *ClangBackend, @inout sets: cxx::std::vector<unsafe *HeaderSet>) {
        var _t = TimeRegion("CodegenPCHBuild")
        self.ok = false
        if !be->ready() {
            return
        }

        // A failed set already reported its errors; the fallback replays it.
        for var i: usize = 0; i < sets.size(); ++i {
            if !sets[i]->ok {
                return
            }
        }

        var fp_open  = cxx::std::vector<string>()
        var fp_close = cxx::std::vector<string>()
        be->header_fp_pragmas(unsafe &fp_open, unsafe &fp_close)
        var text = ""
        for *l in fp_open {
            text += *l
            text += "\n"
        }

        text += CodegenPCH::llvm_dump_prologue()
        for var i: usize = 0; i < sets.size(); ++i {
            text += sets[i]->replay_lines()
        }

        for *l in fp_close {
            text += *l
            text += "\n"
        }

        self._text = kairo::std::to_std_string(text)

        // A COPY of the backend's invocation, as for every phase-A set: the
        // PCH reader rejects one whose options differ from the TU's.
        var inv = cxx::std::make_shared<clang::CompilerInvocation>(*be->invocation())
        var buf = llvm::MemoryBuffer::getMemBuffer(
            llvm::StringRef(self._text.data(), self._text.size()),
            kairo::sref(r"<kairo-codegen-hdrs>"),
            false,
        )

        var *fe = &inv->getFrontendOpts()
        fe->Inputs.clear()
        fe->Inputs.push_back(
            clang::FrontendInputFile(
                buf->getMemBufferRef(),
                clang::InputKind(clang::Language::CXX),
            ),
        )

        fe->DisableFree = 0                         // nothing outlives the parse.
        inv->getPreprocessorOpts().Includes.clear() // the buffer IS the includes.
        // -fpch-instantiate-templates: perform the headers' pending implicit
        // instantiations HERE, once, and store them in the PCH. Without it
        // every TU loading the PCH performed them all again at its end
        // (PerformPendingInstantiations): std::format, clang's DenseMaps,
        // ... -- 659 s of the 794 s clang frontend time over the self-host
        // graph's 316 TUs. A Benign LangOpt: the TUs' own invocations
        // need not match it for the PCH to load.
        inv->getLangOpts().PCHInstantiateTemplates = 1

        var unsafe *ci = kairo::std::create<clang::CompilerInstance>(inv)
        var        ok  = self._parse(ci, be, fe->Inputs[0])
        kairo::std::destroy(ci)
        self.ok = ok
        kairo::Logger::info(
            kairo::Logger::Stage::Driver,
            f"CodegenPCH: {sets.size()} set(s), {self.pch->Data.size()} bytes, ok={self.ok}",
        )
    }

    /// Without NDEBUG, LLVM's Compiler.h makes LLVM_DUMP_METHOD `noinline
    /// used retain`, and `used` puts every dump() that clang's headers
    /// define inline into this PCH's always-emitted set: ASTReader hands
    /// them to every TU's CodeGen, which IRGens and retains a copy in each
    /// object (12.4 s of the debug self-build's codegen CPU). A build
    /// that defines the C++ macro KAIRO_LLVM_DUMP_UNUSED (build.py's debug
    /// profile) gets plain `noinline` instead, NDEBUG's spelling, without
    /// NDEBUG itself: clang's inline asserts stay on. Compiler.h's include
    /// guard keeps the headers below from restoring the macro, and a -D
    /// could not do it, as Compiler.h defines it unconditionally. The cost
    /// is that a dump() is emitted only where something calls it, so a
    /// debugger may not find it. Any other build gets nothing here.
    static fn llvm_dump_prologue() -> string {
        return "#if defined(KAIRO_LLVM_DUMP_UNUSED) && __has_include(<llvm/Support/Compiler.h>)\n" + "#include <llvm/Support/Compiler.h>\n" + "#undef LLVM_DUMP_METHOD\n" + "#define LLVM_DUMP_METHOD LLVM_ATTRIBUTE_NOINLINE\n" + "#endif\n"
    }

    /// The errors are the per-set builds' to report, and they already have:
    /// this parse only says whether the merged text holds together.
    priv fn _parse(self,
                   ci:    unsafe *clang::CompilerInstance,
                   be:    unsafe *ClangBackend,
                   input: clang::FrontendInputFile) -> bool {
        ci->setVirtualFileSystem(be->vfs())
        ci->createDiagnostics(kairo::std::create<clang::IgnoringDiagConsumer>(), true)
        if !ci->hasDiagnostics() {
            return false
        }

        ci->setTarget(
            clang::TargetInfo::CreateTargetInfo(
                &ci->getDiagnostics(),
                &ci->getInvocation().getTargetOpts(),
            ),
        )

        if !ci->hasTarget() {
            return false
        }

        ci->getTarget().adjust(&ci->getDiagnostics(), &ci->getLangOpts(), &null)

        var act = CodegenPCHAction()
        act._buf = self.pch
        if !act.BeginSourceFile(&*ci, input) {
            return false
        }

        // llvm::Error: bool(err) is TRUE ON FAILURE, and an unconsumed Error
        // asserts on destruction.
        var err    = act.Execute()
        var failed = err as bool
        if failed {
            llvm::consumeError(cxx::std::move(err))
        }

        var errors = ci->getDiagnostics().getNumErrors()
        act.EndSourceFile()
        return !failed && errors == 0 && self.pch->IsComplete
    }
}

override fn CodegenPCHAction::CreateASTConsumer(self, @inout ci: clang::CompilerInstance, in_file: llvm::StringRef)
        -> cxx::std::unique_ptr<clang::ASTConsumer> {
    // Same generator and arguments as HeaderSetAction's (ASTWriter.h:1015).
    return cxx::std::unique_ptr<clang::ASTConsumer>(
        cxx::std::make_unique<clang::PCHGenerator>(
            ci.getPreprocessor(),
            ci.getModuleCache(),
            llvm::StringRef(r"<kairo-codegen-hdrs>.pch"),
            llvm::StringRef(r""),
            self._buf,
            ci.getCodeGenOpts(),
            ci.getFrontendOpts().ModuleFileExtensions,
            false,
            false,
        ),
    )
}

override fn CodegenPCHAction::getTranslationUnitKind(self) -> clang::TranslationUnitKind {
    return clang::TU_Prefix
}
