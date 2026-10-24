/// --- The Kairo Project -------------- Interop/Clang/KairoIncludeScan.k --- ///
///
///   Which Kairo files a C/C++ input will `#include` (KairoInclude.k), found
///   before anything compiles: a .k reached only through an include is a
///   Kairo file of the build all the same -- its interface is emitted from
///   its analysed tree and its object joins the link -- so the driver adds
///   it to the build's inputs ahead of the Kairo TUs (CompilerInstance::
///   _discover_includes).
///
///   clang's dependency-directives scanner, no preprocessor: comments,
///   line splices and string literals are handled, macros and conditions
///   are not. So it over-approximates -- a .k behind `#if 0` is built and
///   linked anyway -- and an include spelled through a macro is missed (the
///   include then fails with "not part of this build", as before). Quoted
///   includes of other headers are followed, so a .k a project header
///   includes is found too; angled ones are system headers and are not.
///
///   Resolution is the host's quoted search, minus what a scan cannot know:
///   the including file's directory, then the -iquote and -I directories
///   in order. No framework or header-map lookup.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "clang/Lex/DependencyDirectivesScanner.h";
ffi "c++" import "clang/Basic/TokenKinds.h";
ffi "c++" import "llvm/ADT/SmallVector.h";
ffi "c++" import "llvm/Support/MemoryBuffer.h";

import Support::FileIO::Path::*;

/// \class KairoIncludeScan
/// \brief Every `#include "*.k"` reachable from the files scan() is given,
///        through their quoted includes. One per build: a header two inputs
///        share is scanned once.
class KairoIncludeScan {
    /// The .k files found, absolute, in first-seen order, each once.
    pub var found: vec::<string>;
    /// Every file scanned, absolute: the include graph may have cycles
    /// (`#pragma once` headers including each other).
    priv var _seen: vec::<string>;
    /// The quoted search directories after the includer's own.
    priv var _dirs: vec::<string>;

    fn KairoIncludeScan(self, dirs: vec::<string>) { self._dirs = dirs; }

    /// \brief scans \p path and every quoted header it reaches.
    fn scan(self, path: string) {
        var abs = Path::absolute_if_exists(path);
        for var i: usize = 0; i < self._seen.size(); ++i { if self._seen[i] == abs { return; } }
        self._seen.push_back(abs);

        var r = llvm::MemoryBuffer::getFile(llvm::Twine(sref(abs)));
        if !r { return; }
        var text = r.get()->getBuffer();
        var toks: llvm::SmallVector::<clang::dependency_directives_scan::Token, 64>;
        var dirs: llvm::SmallVector::<clang::dependency_directives_scan::Directive, 32>;
        // True on a scan error (an unterminated directive): clang reports it
        // when it compiles the file, so this only stops looking.
        if clang::scanSourceForDependencyDirectives(text, toks, dirs) { return; }

        var here = Path::parent_of(abs);
        for var i: usize = 0; i < dirs.size(); ++i {
            var k = dirs[i].Kind;
            var is_inc = (k == clang::dependency_directives_scan::pp_include)
                      || (k == clang::dependency_directives_scan::pp_import)
                      || (k == clang::dependency_directives_scan::pp_include_next);
            if !is_inc { continue; }
            var name = self._quoted_name(text, &(dirs[i]));
            if name.empty() { continue; }
            var hit = self._resolve(here, name);
            if hit.empty() { continue; }
            if Path::extension_of(hit) == ".k" {
                var dup = false;
                for var j: usize = 0; j < self.found.size(); ++j { if self.found[j] == hit { dup = true; break; } }
                if !dup { self.found.push_back(hit); }
                continue;
            }
            self.scan(hit);
        }
    }

    /// The file a directive names between quotes, or "" for an angled or
    /// macro-spelled one.
    priv fn _quoted_name(self, text: llvm::StringRef,
                         d: *clang::dependency_directives_scan::Directive) -> string {
        for var t: usize = 0; t < d->Tokens.size(); ++t {
            var tk = d->Tokens[t];
            if tk.Kind != clang::tok::header_name { continue; }
            if tk.Length < 2 { return ""; }
            var spelled = text.substr(static_cast::<usize>(tk.Offset), static_cast::<usize>(tk.Length));
            if spelled.front() != '\x22' { return ""; }
            return string(spelled.data() + 1, spelled.size() - 2);
        }
        return "";
    }

    /// The includer's directory, then the search directories; "" when none
    /// holds it. An absolute name is itself or nothing.
    priv fn _resolve(self, here: string, name: string) -> string {
        var first = Path::absolute_if_exists(Path::join_str(here, name));
        if Path::exists_at(first) { return first; }
        for var i: usize = 0; i < self._dirs.size(); ++i {
            var cand = Path::absolute_if_exists(Path::join_str(self._dirs[i], name));
            if Path::exists_at(cand) { return cand; }
        }
        return "";
    }
}
