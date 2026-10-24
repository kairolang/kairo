/// --- The Kairo Project ------------------ Interop/Clang/KairoInclude.k --- ///
///
///   `#include "foo.k"` in a C++ or Objective-C++ input. Clang's preprocessor
///   enters foo.k like any header; the fork's FileTokenizer hook
///   (Preprocessor::setFileTokenizer, PPLexerChange.cpp) asks this file for
///   the tokens instead of letting clang lex Kairo source as C++. The tokens
///   are foo.k's interface, emitted by Kairo's own InterfaceEmitter into a
///   TokenSink bound to the HOST's preprocessor, so every identifier is the
///   host's IdentifierInfo and every location is a span in foo.k.
///
///     main.cc --clang cc1 (ClangJobs)--> main.o
///        #include "foo.k" -> hook -> KairoIncludeSource::tokens_for
///     foo.k   --Kairo pipeline-----------> foo.o
///     main.o + foo.o --Link--> app
///
///   The prebuilt-token lexer hands each token to the parser as it is: no
///   macro expansion (a host `#define add` cannot rewrite a Kairo name) and
///   no re-kinding (TokenSink sets keyword kinds itself), and the include
///   pops when the array runs out. An engaged EMPTY array means "no hook"
///   to the fork (Lexer::isPrebuiltTokenLexer), so an include with nothing
///   to declare, or one that failed, yields the sentinel
///   `static_assert(true);` (lexed from a buffer of that text) -- valid at
///   namespace, class and block scope,
///   and silent under -Wextra-semi and -pedantic (a C host, always an
///   error, gets `;`). A trailing tok::eof would
///   end the WHOLE host TU, so a stream never carries one.
///
///   Where the hook is installed: clang's actions pick their output by
///   SUBCLASS, and Kairo cannot pass a base constructor argument (the same
///   reason as Codegen/Backend/CodegenAction.k), so there is one host action
///   per cc1 action a C/C++ input runs: object, assembly, IR, bitcode,
///   -fsyntax-only, -E and a header's PCH. Each installs the hook in
///   BeginSourceFileAction, after its base made the preprocessor and before
///   any file is entered. Anything else, and every wrapped action
///   (CreateFrontendAction's HLSL, fix-it, symbol-graph and AST-merge
///   adaptors), runs through ExecuteCompilerInvocation without the hook.
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
ffi "c++" import "clang/Basic/Diagnostic.h";
ffi "c++" import "clang/Basic/DiagnosticIDs.h";
ffi "c++" import "clang/Basic/SourceManager.h";
ffi "c++" import "clang/Basic/TokenKinds.h";
ffi "c++" import "clang/CodeGen/CodeGenAction.h";
ffi "c++" import "clang/Frontend/CompilerInstance.h";
ffi "c++" import "clang/Frontend/FrontendActions.h";
ffi "c++" import "clang/Frontend/FrontendOptions.h";
ffi "c++" import "clang/FrontendTool/Utils.h";
ffi "c++" import "clang/Lex/HeaderSearch.h";
ffi "c++" import "clang/Lex/Preprocessor.h";
ffi "c++" import "clang/Lex/Token.h";
ffi "c++" import "llvm/ADT/ArrayRef.h";
ffi "c++" import "llvm/Support/CommandLine.h";

/// \class KairoIncludeSource
/// \brief Where a hook gets a .k file's tokens: the driver, which owns the
///        Kairo build the file is part of (Driver/KairoIncludes.k). Here so
///        Interop never imports Driver or Codegen.
class KairoIncludeSource {
    /// Why the last tokens_for failed, for the error at the include.
    pub var error: string;
    /// The `#include` lines the last tokens_for's stream needs (`<new>`,
    /// the modules' ffi headers), which the hook enters ahead of it.
    pub var include_lines: vec::<string>;

    /// \brief appends to \p out the interface of the Kairo file at \p path,
    ///        which clang entered as \p cfid in \p ci, located in that file.
    ///        Called once per file per host TU (the hook marks it
    ///        include-once). \return false with `error` set.
    virtual fn tokens_for(self, ci: *clang::CompilerInstance, cfid: clang::FileID,
                          path: string, out: *libcxx::vector::<clang::Token>) -> bool {
        self.error = "no Kairo build to take it from";
        return false;
    }

    /// The host TU is done: everything kept alive for its tokens may go.
    virtual fn end_tu(self) {}
}

/// \class KairoIncludeHook
/// \brief One host TU's hook: answers the preprocessor for each .k it enters
///        and owns the token arrays, which the lexer reads through an
///        ArrayRef until the include pops.
class KairoIncludeHook {
    pub var source: obs::<KairoIncludeSource> = &null;
    priv var _ci: obs::<clang::CompilerInstance> = &null;
    priv var _streams: vec::<*libcxx::vector::<clang::Token>>;   ///< owned
    /// Streams made on a file's first entry and held for its second, from
    /// the header buffer (_enter_headers); by FileEntry UID, parallel. A
    /// taken slot's stream goes null.
    priv var _held_uids: vec::<u32>;
    priv var _held: vec::<*libcxx::vector::<clang::Token>>;

    fn install(self, ci: ref!(clang::CompilerInstance)) {
        // An LLVM IR input (.ll/.bc) runs the same codegen actions with no
        // preprocessor at all, and so nothing it could #include.
        if !ci.hasPreprocessor() { return; }
        self._ci = &ci;
        var me = &self;
        ci.getPreprocessor().setFileTokenizer(fn (fid: clang::FileID) |me| -> libcxx::optional::<llvm::ArrayRef::<clang::Token>> {
            return me->tokens(fid);
        });
    }

    fn tokens(self, fid: clang::FileID) -> libcxx::optional::<llvm::ArrayRef::<clang::Token>> {
        var csm = &(self._ci->getSourceManager());
        // The main file is never ours: `kairo x.k` is a Kairo TU, and a
        // .k given to clang as its input (-x c++ x.k) is the user's call.
        if fid == csm->getMainFileID() { return libcxx::nullopt; }
        var fe = csm->getFileEntryRefForID(fid);
        if !fe { return libcxx::nullopt; }
        var name = fe->getName();
        if !name.ends_with(r".k") { return libcxx::nullopt; }

        var path = string(name.data(), name.size());

        // The second entry, from the header buffer: the stream is ready.
        var uid = static_cast::<u32>(fe->getUID());
        for var i: usize = 0; i < self._held_uids.size(); ++i {
            if (self._held_uids[i] != uid) || (self._held[i] == &null) { continue; }
            var held = self._held[i];
            self._held[i] = &null;
            self._ci->getPreprocessor().getHeaderSearchInfo().MarkFileIncludeOnce(*fe);
            return llvm::ArrayRef::<clang::Token>(held->data(), held->size());
        }

        var toks = std::create::<libcxx::vector::<clang::Token>>();
        self._streams.push_back(toks);

        var why = "";
        if !self._ci->getLangOpts().CPlusPlus {
            why = "a Kairo file can only be included from C++ or Objective-C++";
        } else if !self._ci->getLangOpts().CPlusPlus20 {
            why = "including a Kairo file needs C++20 or later (kairo defaults to --cxx-std=c++23)";
        } else if self.source == &null {
            why = "no Kairo build to take it from";
        } else if !self.source->tokens_for(self._ci, fid, path, toks) {
            why = self.source->error;
            toks->clear();
        }
        if !why.empty() { self._error_at(csm->getIncludeLoc(fid), f"cannot include '{path}\x27: {why}"); }

        // A stream that needs headers cannot carry them (a token stream has
        // no line for an #include), so this entry stands down to the
        // sentinel and the headers come from a buffer entered beneath it,
        // which includes them and then this file again.
        if why.empty() && (!self.source->include_lines.empty()) {
            self._held_uids.push_back(uid);
            self._held.push_back(toks);
            // Absolute: a quoted include from a buffer has no directory of
            // its own to be relative to.
            var real = fe->getFileEntry().tryGetRealPathName();
            var again = (string(real.data(), real.size())) if (!real.empty()) else (path);
            self._enter_headers(fid, again, &(self.source->include_lines));
            var stand_in = std::create::<libcxx::vector::<clang::Token>>();
            self._streams.push_back(stand_in);
            self._sentinel(stand_in, fid);
            return llvm::ArrayRef::<clang::Token>(stand_in->data(), stand_in->size());
        }

        // Entered once per TU however often it is included: the stream is
        // declarations and the helpers, which C++ rejects twice.
        self._ci->getPreprocessor().getHeaderSearchInfo().MarkFileIncludeOnce(*fe);

        if toks->empty() { self._sentinel(toks, fid); }
        return llvm::ArrayRef::<clang::Token>(toks->data(), toks->size());
    }

    /// \brief enters each of \p lines, then `#include "<path>"`, as a
    ///        buffer included where \p fid was.
    ///
    /// The hook runs inside EnterSourceFile before \p fid's lexer is
    /// pushed, so a buffer entered here sits UNDER it: the sentinel this
    /// entry returns is lexed first, then the buffer, whose last include is
    /// this file's second entry. The include-once mark waits for that one.
    priv fn _enter_headers(self, fid: clang::FileID, path: string, lines: *vec::<string>) {
        var csm = &(self._ci->getSourceManager());
        var text = "";
        for var i: usize = 0; i < lines->size(); ++i { text += (*lines)[i] + "\n"; }
        text += "#include \x22" + path + "\x22\n";
        var buf = llvm::MemoryBuffer::getMemBufferCopy(sref(text), r"<kairo-include>");
        var at  = csm->getIncludeLoc(fid);
        var bfid = csm->createFileID(libcxx::move(buf), clang::SrcMgr::C_User, 0, 0, at);
        self._ci->getPreprocessor().EnterSourceFile(bfid, clang::ConstSearchDirIterator(&null), at);
    }

    /// `static_assert(true);`: see the file header. Lexed from a buffer of
    /// its own text, included where \p fid was, so each token has the bytes
    /// it spells: `-E` prints a token's bytes, and a zero-length one printed
    /// as nothing (`static_asserttrue`).
    priv fn _sentinel(self, toks: *libcxx::vector::<clang::Token>, fid: clang::FileID) {
        // A C or ObjC host only gets here with the include already an
        // error, and before C23 `static_assert(true)` parses there as an
        // implicit-int declaration, burying that error under two bogus
        // ones. An empty declaration is valid C at every scope it can be.
        var cxx = self._ci->getLangOpts().CPlusPlus;
        var text = (" static_assert(true);") if (cxx) else (" ;");
        var csm = &(self._ci->getSourceManager());
        var buf = llvm::MemoryBuffer::getMemBufferCopy(sref(text), r"<kairo-include>");
        var sfid = csm->createFileID(libcxx::move(buf), clang::SrcMgr::C_User, 0, 0, csm->getIncludeLoc(fid));
        var at = csm->getLocForStartOfFile(sfid);
        if !cxx {
            self._push_punct(toks, clang::tok::semi, at.getLocWithOffset(1), 1);
            return;
        }
        var pp = &(self._ci->getPreprocessor());
        self._push_kw(toks, pp, r"static_assert", at.getLocWithOffset(1), 13);
        self._push_punct(toks, clang::tok::l_paren, at.getLocWithOffset(14), 1);
        self._push_kw(toks, pp, r"true", at.getLocWithOffset(15), 4);
        self._push_punct(toks, clang::tok::r_paren, at.getLocWithOffset(19), 1);
        self._push_punct(toks, clang::tok::semi, at.getLocWithOffset(20), 1);
    }

    priv fn _push_kw(self, toks: *libcxx::vector::<clang::Token>, pp: *clang::Preprocessor,
                     spelling: string, at: clang::SourceLocation, len: u32) {
        var t: clang::Token;
        t.startToken();
        var ii = pp->getIdentifierInfo(sref(spelling));
        t.setIdentifierInfo(ii);
        t.setKind(ii->getTokenID());
        t.setLocation(at);
        t.setLength(len);
        t.setFlag(clang::Token::LeadingSpace);
        toks->push_back(t);
    }

    priv fn _push_punct(self, toks: *libcxx::vector::<clang::Token>, k: clang::tok::TokenKind,
                        at: clang::SourceLocation, len: u32) {
        var t: clang::Token;
        t.startToken();
        t.setKind(k);
        t.setLocation(at);
        t.setLength(len);
        toks->push_back(t);
    }

    /// An error in the HOST's engine, so the cc1 fails by its own count.
    priv fn _error_at(self, loc: clang::SourceLocation, msg: string) {
        var de = &(self._ci->getDiagnostics());
        var id = de->getDiagnosticIDs()->getCustomDiagID(clang::DiagnosticIDs::Level::Error, r"%0");
        var db = de->Report(loc, id);
        db.AddString(sref(msg));
    }

    fn op delete (self) {
        for var i: usize = 0; i < self._streams.size(); ++i { std::destroy(self._streams[i]); }
        self._streams.clear();
    }
}

// --- Host actions: one per cc1 action a C/C++ input runs (see header) -------

class KairoHostObj derives clang::EmitObjAction {
    pub var hook: KairoIncludeHook;
    override fn BeginSourceFileAction(self, ci: ref!(clang::CompilerInstance)) -> bool {
        if !clang::EmitObjAction::BeginSourceFileAction(ci) { return false; }
        self.hook.install(ci);
        return true;
    }
}

class KairoHostAsm derives clang::EmitAssemblyAction {
    pub var hook: KairoIncludeHook;
    override fn BeginSourceFileAction(self, ci: ref!(clang::CompilerInstance)) -> bool {
        if !clang::EmitAssemblyAction::BeginSourceFileAction(ci) { return false; }
        self.hook.install(ci);
        return true;
    }
}

class KairoHostLLVM derives clang::EmitLLVMAction {
    pub var hook: KairoIncludeHook;
    override fn BeginSourceFileAction(self, ci: ref!(clang::CompilerInstance)) -> bool {
        if !clang::EmitLLVMAction::BeginSourceFileAction(ci) { return false; }
        self.hook.install(ci);
        return true;
    }
}

class KairoHostBC derives clang::EmitBCAction {
    pub var hook: KairoIncludeHook;
    override fn BeginSourceFileAction(self, ci: ref!(clang::CompilerInstance)) -> bool {
        if !clang::EmitBCAction::BeginSourceFileAction(ci) { return false; }
        self.hook.install(ci);
        return true;
    }
}

class KairoHostSyntax derives clang::SyntaxOnlyAction {
    pub var hook: KairoIncludeHook;
    override fn BeginSourceFileAction(self, ci: ref!(clang::CompilerInstance)) -> bool {
        if !clang::SyntaxOnlyAction::BeginSourceFileAction(ci) { return false; }
        self.hook.install(ci);
        return true;
    }
}

class KairoHostPreprocess derives clang::PrintPreprocessedAction {
    pub var hook: KairoIncludeHook;
    override fn BeginSourceFileAction(self, ci: ref!(clang::CompilerInstance)) -> bool {
        if !clang::PrintPreprocessedAction::BeginSourceFileAction(ci) { return false; }
        self.hook.install(ci);
        return true;
    }
}

class KairoHostPCH derives clang::GeneratePCHAction {
    pub var hook: KairoIncludeHook;
    override fn BeginSourceFileAction(self, ci: ref!(clang::CompilerInstance)) -> bool {
        if !clang::GeneratePCHAction::BeginSourceFileAction(ci) { return false; }
        self.hook.install(ci);
        return true;
    }
}

/// \brief runs one cc1 job like clang::ExecuteCompilerInvocation, with the
///        include hook installed when its action is one of the above.
///
/// \details The prologue is ExecuteCompilerInvocation's, minus what a
///          driver-planned job never carries (-help, -version, the
///          analyzer's listings): plugins, then -mllvm, which the driver
///          puts on this line and nowhere else (-masm=intel becomes
///          `-mllvm -x86-asm-syntax=intel`).
fn execute_with_kairo_includes(ci: *clang::CompilerInstance, source: *KairoIncludeSource) -> bool {
    var fo = &(ci->getFrontendOpts());
    var wrapped = ci->getLangOpts().HLSL || fo->FixAndRecompile || fo->EmitSymbolGraph
               || (!fo->ASTMergeFiles.empty()) || fo->ShowHelp || fo->ShowVersion;
    var pa = fo->ProgramAction;
    var hooked = (pa == clang::frontend::EmitObj) || (pa == clang::frontend::EmitAssembly)
              || (pa == clang::frontend::EmitLLVM) || (pa == clang::frontend::EmitBC)
              || (pa == clang::frontend::ParseSyntaxOnly) || (pa == clang::frontend::PrintPreprocessedInput)
              || (pa == clang::frontend::GeneratePCH);
    if wrapped || (!hooked) { return clang::ExecuteCompilerInvocation(ci); }

    var errs_before = ci->getDiagnostics().getNumErrors();
    ci->LoadRequestedPlugins();
    if !fo->LLVMArgs.empty() {
        var argv: libcxx::vector::<std::ConstPtr::<std::Legacy::char>>;
        argv.push_back(r"clang (LLVM option parsing)");
        for var i: usize = 0; i < fo->LLVMArgs.size(); ++i { argv.push_back(fo->LLVMArgs[i].c_str()); }
        argv.push_back(&null);
        llvm::cl::ParseCommandLineOptions(static_cast::<i32>(argv.size() - 1), argv.data(),
                                          r"", &null, &(ci->getVirtualFileSystem()));
    }
    if ci->getDiagnostics().getNumErrors() != errs_before { return false; }

    var ok = false;
    finally { if source != &null { source->end_tu(); } }
    if pa == clang::frontend::EmitObj {
        var act = KairoHostObj();
        act.hook.source = source;
        ok = ci->ExecuteAction(act);
    } else if pa == clang::frontend::EmitAssembly {
        var act = KairoHostAsm();
        act.hook.source = source;
        ok = ci->ExecuteAction(act);
    } else if pa == clang::frontend::EmitLLVM {
        var act = KairoHostLLVM();
        act.hook.source = source;
        ok = ci->ExecuteAction(act);
    } else if pa == clang::frontend::EmitBC {
        var act = KairoHostBC();
        act.hook.source = source;
        ok = ci->ExecuteAction(act);
    } else if pa == clang::frontend::ParseSyntaxOnly {
        var act = KairoHostSyntax();
        act.hook.source = source;
        ok = ci->ExecuteAction(act);
    } else if pa == clang::frontend::PrintPreprocessedInput {
        var act = KairoHostPreprocess();
        act.hook.source = source;
        ok = ci->ExecuteAction(act);
    } else {
        var act = KairoHostPCH();
        act.hook.source = source;
        ok = ci->ExecuteAction(act);
    }
    return ok;
}
