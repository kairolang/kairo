/// --- The Kairo Project ------------------ Preprocessor/ScopeTracker.k --- ///
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Preprocessor::PreprocessorSymbolTable::*;
import Resolution::ModulePath::*;
import Location::SourceManager::*;
import Lexer::Immediate::*;
import Token::TokenText::*;
import Token::TokenCacheManager::*;
import Preprocessor::TokenSource::*;

enum ModuleVisibility derives u8 {
    Public,     ///< pub module or no modifier - exported
    Private,    ///< priv module - not exported outside file
    Protected,  ///< prot module - not accessible outside current folder
}

class ScopeTracker {
    struct Frame { // 38 bytes before padding - total size 48 bytes after padding
        var path:        ModulePath;        ///< full module path at this frame
        var brace_depth: i32;               ///< brace depth when frame was pushed
        var visibility:  ModuleVisibility;  ///< visibility of this module block
        var is_global:   bool;              ///< true if `module :: { }`
    }

    /// total size of members: 116 bytes or 928 bits (after padding its 128 bytes)
    priv var _file_base:   ModulePath;               ///< base path from filename (e.g., Baz from baz.k)
    priv var _current:     ModulePath;               ///< cached current scope
    priv var _stack:       vec::<Frame>;             ///< scope stack
    priv var _sym_table:   obs::<PreprocessorSymbolTable>; ///< for interning identifiers
    priv var _sm:          obs::<SourceManager>;            ///< source manager for error reporting
    priv var _tcm:         obs::<TokenCacheManager>;        ///< token cache manager for token text
    priv var _imm_table:   obs::<ImmediateTable>;    ///< imm table of the file being scanned, for spelling
    priv var _brace_depth: i32;                      ///< current brace nesting level

    /// \brief constructs tracker with file's base module path
    /// \param sym_table symbol table for interning identifiers
    /// \param file_base module path derived from filename
    fn ScopeTracker(self, sym_table: *PreprocessorSymbolTable, sm: *SourceManager, imm_table: *ImmediateTable, tcm: *TokenCacheManager, file_base: ModulePath) {
        self._stack       = vec::<Frame>();
        self._sym_table   = sym_table;
        self._file_base   = file_base;
        self._current     = file_base;
        self._sm          = sm;
        self._tcm         = tcm;
        self._imm_table   = imm_table;
        self._brace_depth = 0;

        // push initial frame for file-level scope
        var initial = Frame();
        initial.path        = file_base;
        initial.brace_depth = 0;
        initial.visibility  = ModuleVisibility::Public;
        initial.is_global   = false;
        self._stack.push_back(initial);
    }

    /// \brief returns current module scope as ModulePath
    fn current_scope(self) -> ModulePath {
        return self._current;
    }

    /// \brief returns current visibility
    fn current_visibility(self) -> ModuleVisibility {
        if self._stack.size() == 0 {
            return ModuleVisibility::Public;
        }
        return self._stack.back().visibility;
    }

    /// \brief returns true if currently in global scope (module :: { })
    fn is_global_scope(self) -> bool {
        if self._stack.size() == 0 {
            return false;
        }
        return self._stack.back().is_global;
    }

    /// \brief returns current brace depth
    fn brace_depth(self) -> i32 {
        return self._brace_depth;
    }


    // ======================================================================
    //  Streaming driver (PP single-pass walk). Pulls from TokenSource; emits
    //  consumed tokens through `emit` because module headers are real decls
    //  the parser needs downstream. Mirrors update()+parse_module_decl but
    //  forward-only, UNBOUNDED path length (no window).
    // ======================================================================

    /// \brief called by the walk when the current token is scope-relevant
    ///        (`{`, `}`, or `module` visibility keywords are pre-stripped by
    ///        the walk, which passes the resolved visibility in). Consumes and
    ///        emits exactly the scope syntax; returns nothing (state updated).
    ///
    /// \note the walk owns pub/priv/prot routing (it must, to split
    ///       `<vis> import`/`<vis> macro` from `<vis> module`). So by the time
    ///       feed_stream sees a `module`, any visibility keyword is already
    ///       consumed+emitted by the walk and its value handed in via `vis`.
    fn feed_stream(self, src: *TokenSource, vis: ModuleVisibility, emit: fn(Token)) {
        var k = src->peek(0).kind;

        if k == TokenKind::OpLBrace {
            ++self._brace_depth;
            emit(src->next());
            return;
        }

        if k == TokenKind::OpRBrace {
            --self._brace_depth;
            emit(src->next());
            self.maybe_pop_scope();
            return;
        }

        if k != TokenKind::KwModule { return; } // defensive; walk shouldn't call otherwise
        emit(src->next()); // `module`

        // case: `module :: ...`
        if src->peek(0).kind == TokenKind::OpColonColon {
            emit(src->next()); // `::`

            // `module :: {` global scope
            if src->peek(0).kind == TokenKind::OpLBrace {
                self.push_global_scope(vis);
                return; // `{` consumed by the next _track_scope call
            }

            // `module ::Path {` absolute
            var path = self._consume_module_path_stream(src, emit);
            if (path.segments.size() > 0) && (src->peek(0).kind == TokenKind::OpLBrace) {
                self.push_absolute_scope(path, vis);
            }
            return;
        }

        // case: `module {` anonymous visibility block
        if src->peek(0).kind == TokenKind::OpLBrace {
            self.push_visibility_scope(vis);
            return;
        }

        // case: `module Path {` relative
        if src->peek(0).kind != TokenKind::LitIdentifier { return; }
        var path = self._consume_module_path_stream(src, emit);
        if (path.segments.size() > 0) && (src->peek(0).kind == TokenKind::OpLBrace) {
            self.push_scope(path, vis);
        }
    }

    /// \brief stream twin of parse_module_path: ident (:: ident)*, UNBOUNDED.
    ///        Consumes and emits each token. Stops before the trailing `{`.
    priv fn _consume_module_path_stream(self, src: *TokenSource, emit: fn(Token)) -> ModulePath {
        var path = ModulePath();

        while src->peek(0).kind == TokenKind::LitIdentifier {
            var t = src->peek(0);
            var ident = IdentifierToken();
            ident.token = &null; // stream token is a copy; spelling is what's used
            ident.name  = self._sym_table->intern(TokenText::spelling(t, self._tcm));
            path.segments.push_back(ident);
            emit(src->next());

            if src->peek(0).kind != TokenKind::OpColonColon { break; }
            emit(src->next()); // `::`
        }
        return path;
    }

    /// \brief pushes a new relative scope
    priv fn push_scope(self, path: ModulePath, visibility: ModuleVisibility) {
        var frame = Frame();

        // extend current scope with new path
        frame.path = self._current;
        for seg in path.segments {
            frame.path.segments.push_back(seg);
        }

        frame.brace_depth = self._brace_depth + 1;
        frame.visibility  = visibility;
        frame.is_global   = false;

        self._stack.push_back(frame);
        self.update_current();
    }

    /// \brief pushes global scope (module :: { })
    priv fn push_global_scope(self, visibility: ModuleVisibility) {
        var frame = Frame();
        frame.path        = ModulePath(); // empty = global
        frame.brace_depth = self._brace_depth + 1;
        frame.visibility  = visibility;
        frame.is_global   = true;

        self._stack.push_back(frame);
        self.update_current();
    }

    /// \brief pushes absolute scope (module ::Foo::Bar { })
    priv fn push_absolute_scope(self, path: ModulePath, visibility: ModuleVisibility) {
        var frame = Frame();
        frame.path        = path; // absolute path, replaces current
        frame.brace_depth = self._brace_depth + 1;
        frame.visibility  = visibility;
        frame.is_global   = false;

        self._stack.push_back(frame);
        self.update_current();
    }

    /// \brief pushes visibility-only scope (priv module { })
    priv fn push_visibility_scope(self, visibility: ModuleVisibility) {
        var frame = Frame();
        frame.path        = self._current;
        frame.brace_depth = self._brace_depth + 1;
        frame.visibility  = visibility;
        frame.is_global   = false;

        self._stack.push_back(frame);
        // current scope doesn't change, just visibility
    }

    /// \brief pops scope if brace depth drops below frame's depth
    priv fn maybe_pop_scope(self) {
        // never pop the file-level scope
        while self._stack.size() > 1 {
            var top = self._stack.back();
            if self._brace_depth >= top.brace_depth {
                break;
            }
            self._stack.pop_back();
        }
        self.update_current();
    }

    /// \brief updates cached current scope from stack top
    priv fn update_current(self) {
        if self._stack.size() == 0 {
            self._current = self._file_base;
            return;
        }

        var top = self._stack.back();
        if top.is_global {
            self._current = ModulePath(); // empty = global
        } else {
            self._current = top.path;
        }
    }

    /// \brief resets tracker to initial state
    fn reset(self) {
        self._stack.clear();
        self._brace_depth = 0;
        self._current     = self._file_base;

        var initial = Frame();
        initial.path        = self._file_base;
        initial.brace_depth = 0;
        initial.visibility  = ModuleVisibility::Public;
        initial.is_global   = false;
        self._stack.push_back(initial);
    }
}
