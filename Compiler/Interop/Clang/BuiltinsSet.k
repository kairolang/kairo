/// --- The Kairo Project ---------------- Interop/Clang/BuiltinsSet.k --- ///
///
///   \brief A parse-free clang instance whose one job is to say what a clang
///          builtin is: its ID, its prototype, its attributes.
///
///   \detail
///     No ClangBackend or HeaderSet instance can answer this for a TU with no
///     ffi imports. The backend's CompilerInstance has no Preprocessor or
///     ASTContext, and the ones ExecuteAction creates are per action. A
///     HeaderSet exists only when there is a header. And neither
///     createPreprocessor nor createASTContext populates the builtin IDs:
///     FrontendAction::BeginSourceFile calls initializeBuiltins, so an
///     instance that never begins a source file has to call it itself.
///
///     The invocation is a COPY of the backend's: C++26 LangOptions are what
///     register the COR_LANG builtins (`__builtin_coro_*`), and the target is
///     what registers the target ones.
///
///   \par Threading
///     build() runs once, on whichever thread runs ClangBackend::startup, under
///     its lock. The name map is frozen after that and read from any thread.
///     ast() and builtins() have exactly one caller, BuiltinImport, which
///     serializes every call under its own lock: GetBuiltinType creates types.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh";
ffi "c++" import "clang/AST/ASTContext.h";
ffi "c++" import "clang/Basic/Builtins.h";
ffi "c++" import "clang/Basic/IdentifierTable.h";
ffi "c++" import "clang/Basic/TargetInfo.h";
ffi "c++" import "clang/Frontend/CompilerInstance.h";
ffi "c++" import "clang/Frontend/CompilerInvocation.h";
ffi "c++" import "clang/Frontend/TextDiagnosticPrinter.h";
ffi "c++" import "clang/Lex/PreprocessorOptions.h";
ffi "c++" import "clang/Lex/Preprocessor.h";
ffi "c++" import "llvm/ADT/IntrusiveRefCntPtr.h";
ffi "c++" import "llvm/ADT/STLExtras.h";
ffi "c++" import "llvm/ADT/StringMap.h";
ffi "c++" import "llvm/Support/VirtualFileSystem.h";

class BuiltinsSet {
    priv var _ci:     opt::<clang::CompilerInstance> = &null;
    /// name -> builtin ID. The ONE owner of the name bytes: a StringMap
    /// entry stores its key inline and never moves, so _sorted views into it
    /// instead of holding a second copy, and id_of probes with a StringRef
    /// rather than building a std::string per lookup.
    priv var _ids:    llvm::StringMap::<u32>;
    /// The target's predefined macros (`__linux__`, `__x86_64__`), by name:
    /// what `defined!` answers in a file with no ffi header (EVAL.md §4.3).
    priv var _predef: llvm::StringMap::<u32>;
    /// Every builtin the target and language register, sorted by name;
    /// keys view _ids' entries.
    priv var _sorted: libcxx::vector::<libcxx::pair::<llvm::StringRef, u32>>;
    priv var _ready:  bool = false;

    fn BuiltinsSet(self) { }

    fn op delete (self) { self.release(); }

    /// Destroy the instance. Called by ClangBackend BEFORE its printer dies:
    /// this instance's engine borrows it.
    fn release(self) {
        if self._ci != &null { std::destroy(self._ci); self._ci = &null; }
        self._ready = false;
    }

    fn ready(self) -> bool { return self._ready; }

    /// Build once. False leaves the oracle unready, and every builtin then
    /// misses into R020E, which is what the build did without it.
    fn build(self, inv: *clang::CompilerInvocation,
             vfs: llvm::IntrusiveRefCntPtr::<llvm::vfs::FileSystem>,
             printer: *clang::TextDiagnosticPrinter) -> bool {
        if self._ready { return true; }
        if inv == &null { return false; }

        var copy = libcxx::make_shared::<clang::CompilerInvocation>(*inv);
        copy->getPreprocessorOpts().Includes.clear();     // no main file is ever entered.

        self._ci = std::create::<clang::CompilerInstance>(copy);
        self._ci->setVirtualFileSystem(vfs);
        self._ci->createDiagnostics(printer, false);
        if !self._ci->hasDiagnostics() { self.release(); return false; }
        self._ci->setTarget(clang::TargetInfo::CreateTargetInfo(
            self._ci->getDiagnostics(), self._ci->getInvocation().getTargetOpts()));
        if !self._ci->hasTarget() { self.release(); return false; }
        self._ci->getTarget().adjust(self._ci->getDiagnostics(), self._ci->getLangOpts(), &null);

        self._ci->createFileManager();
        self._ci->createSourceManager();
        self._ci->createPreprocessor(clang::TU_Complete);   // PP::Initialize -> BuiltinInfo.InitializeTarget.
        self._ci->createASTContext();                       // InitBuiltinTypes.

        // The step BeginSourceFile would have taken: give every supported
        // builtin's identifier its ID.
        var pp = &(self._ci->getPreprocessor());
        pp->getBuiltinInfo().initializeBuiltins(pp->getIdentifierTable(), self._ci->getLangOpts());

        // createPreprocessor wrote the predefines buffer (`#define __linux__
        // 1` ...) but no main file is entered, so none is defined in the
        // preprocessor: read the names off the buffer instead.
        var pd   = pp->getPredefines();
        var all  = llvm::StringRef(pd.data(), pd.size());
        // The spellings outlive their views: sref of a temporary dangles.
        var def_s  = string("#define ");
        var nl_s   = string("\n");
        var stop_s = string(" (");
        var def  = sref(def_s);
        var nl   = sref(nl_s);
        var stop = sref(stop_s);
        while !all.empty() {
            var pr = all.split(nl);
            var line = pr.first;
            all = pr.second;
            if !line.starts_with(def) { continue; }
            var rest = line.drop_front(def.size());
            self._predef.try_emplace(rest.substr(0, rest.find_first_of(stop)), u32(1));
        }

        // Read back what got an ID. Iterating the table rather than the ID
        // space keeps this independent of how a clang version shards its
        // builtin tables: only supported builtins were stamped.
        var idt = &(pp->getIdentifierTable());
        for var it = idt->begin(); it != idt->end(); ++it {
            var id = it->getValue()->getBuiltinID();
            if id == 0 { continue; }
            self._ids.try_emplace(it->getKey(), static_cast::<u32>(id));
        }
        self._sorted.reserve(self._ids.size());
        for var e = self._ids.begin(); e != self._ids.end(); ++e {
            self._sorted.push_back(libcxx::make_pair(e->getKey(), e->getValue()));
        }
        // Sorted: the pseudo-header BuiltinImport writes from this is then the
        // same bytes every build, whatever order the StringMap hashed into.
        llvm::sort(self._sorted);

        self._ready = true;
        Logger::info(Logger::Stage::Driver, f"BuiltinsSet: {self._sorted.size()} builtin(s) for this target");
        return true;
    }

    /// Is \p name one of the target's predefined macros. Read-only; any thread.
    fn predefined(self, name: string) -> bool {
        if !self._ready { return false; }
        return self._predef.find(sref(name)) != self._predef.end();
    }

    /// The builtin ID \p name has here, or 0. Read-only; any thread.
    fn id_of(self, name: string) -> u32 {
        if !self._ready { return 0; }
        var it = self._ids.find(sref(name));
        if it == self._ids.end() { return 0; }
        return it->second;
    }

    fn count(self) -> usize { return self._sorted.size(); }
    fn name_at(self, i: usize) -> string {
        var k = self._sorted[i].first;
        return string(k.data(), k.size());
    }
    fn id_at(self, i: usize) -> u32 { return self._sorted[i].second; }

    /// BuiltinImport only, under its lock.
    fn ast(self) -> *clang::ASTContext { return &(self._ci->getASTContext()); }
    fn builtins(self) -> *clang::Builtin::Context { return &(self._ci->getPreprocessor().getBuiltinInfo()); }
}