/// --- The Kairo Project -------------------- Driver/CompilerRecovery.k --- ///
///
///   CompilerInstance, part: --check-past-syntax-errors, the language
///   server's index run over a graph with syntax errors in it
///   (Compiler/Spec/LanguageServer.md section 9). Decides, between the parse
///   and Sema, whether the run may go on and which files Sema leaves
///   unchecked. An `extend` of the class in CompilerInstance.k
///   (Driver/module.k).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/DenseSet.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"
ffi "c++" import "cstdlib"

import AST::Context::ASTContext::ASTContext
import AST::Context::GlobalDisambigTable::GlobalDisambigTable
import AST::Context::TranslationUnit::TranslationUnit
import AST::LangItems::builtin_root_name
import AST::Node::Casting::dyn_cast
import AST::Node::Declarations::{
    FnBodyKind,
    FunctionDecl,
}
import Driver::CompilerInstance::CompilerInstance
import std::io

extend CompilerInstance {
    /// \brief whether an action whose parse reported errors may still run
    ///        Sema, for a tool's index; marks the files Sema must skip.
    ///
    /// \details False, and nothing marked, outside the mode: the action
    ///          fails right after the parse, as it always has. In the mode
    ///          the run goes on only when every error since \p errors_at_start
    ///          is one file's own (its parse sink counted it): an error the
    ///          dependency scan or the PP reported straight to the engine
    ///          (a lexing error, an import that did not resolve) belongs to
    ///          no file, and Sema over a graph missing a piece reports what
    ///          that piece would have declared as undeclared.
    ///
    ///          A file with a syntax error is skipped, and so is every file
    ///          that imports one, directly or through others: its uses of the
    ///          broken file's names have nothing sound to resolve to. What is
    ///          left is closed under imports (a kept file's imports are kept),
    ///          so Sema over it is Sema over a smaller, healthy graph.
    ///          A broken file under the builtin root, or with a --prelude or
    ///          --force-include in play, reaches every file without an edge
    ///          saying so: the run fails as today rather than guess.
    prot fn admit_past_syntax_errors(self,
                                     gs:              unsafe *GlobalDisambigTable,
                                     const fids:      cxx::std::vector<u32>,
                                     errors_at_start: u32) -> bool {
        if !self.invocation()->frontend.check_past_syntax {
            return false
        }

        if gs == &null {
            return false
        }

        // A live check runs Sema again in the same instance: what an earlier
        // run skipped is decided afresh.
        for var f: u32 in fids {
            var unsafe *c = gs->get_context(f)
            if c != &null {
                c->syntax_skipped = false
            }
        }

        var broken       = llvm::DenseSet<u64>()
        var in_graph     = llvm::DenseSet<u64>()
        var owned:   u32 = 0
        for var f: u32 in fids {
            if self.is_foreign_fid(f) {
                continue
            }

            var unsafe *ctx = gs->get_context(f)
            if ctx == &null || ctx->tu == &null {
                continue
            }

            in_graph.insert(f as u64)
            var n = ctx->diag_sink.error_count()
            if n > 0 {
                broken.insert(f as u64)
                owned += n
            }
        }

        // Exact, not at most: a sink that counted an error the engine never
        // got (or the reverse) means the attribution is not what this assumes.
        if (self.diag()->error_count() - errors_at_start) != owned || owned == 0 {
            return false
        }

        if (!self.invocation()->pp.prelude_path.empty())
            || self.invocation()->pp.force_includes.size() > 0 {
            return false
        }

        // The builtin subtree: every file imports its root implicitly (the
        // prelude edge is stamped in Sema, after this), so a broken file
        // there reaches every file.
        var unsafe *table = self.pp()->get_symbol_table()
        var        bsym   = table->intern(builtin_root_name())
        for var f: u32 in fids {
            if !broken.contains(f as u64) {
                continue
            }

            var unsafe *ctx  = gs->get_context(f)
            var        *segs = &ctx->module_base.segments
            if segs->size() > 0 && (*segs)[0].name == bsym {
                return false
            }
        }

        var bfid = gs->builtin_fid()
        if bfid != 0 && in_graph.contains(bfid as u64) {
            var seen  = llvm::DenseSet<u64>()
            var stack = cxx::std::vector<u32>()
            stack.push_back(bfid)
            seen.insert(bfid as u64)
            while !stack.empty() {
                var f = stack.back()
                stack.pop_back()
                if broken.contains(f as u64) {
                    return false
                }

                var unsafe *ctx = gs->get_context(f)
                if ctx == &null || ctx->tu == &null {
                    continue
                }

                for var j: usize = 0; j < ctx->tu->import_edges.size(); ++j {
                    var unsafe *e = ctx->tu->import_edges.get(j)
                    if e == &null {
                        continue
                    }

                    var t = e->target_fid as u64
                    if in_graph.contains(t) && !seen.contains(t) {
                        seen.insert(t)
                        stack.push_back(e->target_fid)
                    }
                }
            }
        }

        // A file whose every error is inside function bodies that kept them
        // (ASTParse::closes_lexically) parsed everything else as it would
        // have without them: it is checked with those bodies dropped, each
        // function its signature alone. Decided for all before any is dropped.
        var recovered = llvm::DenseSet<u64>()
        for var f: u32 in fids {
            if broken.contains(f as u64) && Self::_bodies_hold_errors(gs->get_context(f)) {
                recovered.insert(f as u64)
            }
        }

        for var f: u32 in fids {
            if recovered.contains(f as u64) {
                broken.erase(f as u64)
            }
        }

        // Importers, to a fixed point: the graph is small next to the cost
        // of the Sema it saves, and a cycle needs no special case.
        var skipped = broken
        var grew    = true
        while grew {
            grew = false
            for var f: u32 in fids {
                if !in_graph.contains(f as u64) || skipped.contains(f as u64) {
                    continue
                }

                var unsafe *ctx = gs->get_context(f)
                for var j: usize = 0; j < ctx->tu->import_edges.size(); ++j {
                    var unsafe *e = ctx->tu->import_edges.get(j)
                    if e != &null && skipped.contains(e->target_fid as u64) {
                        skipped.insert(f as u64)
                        grew = true
                        break
                    }
                }
            }
        }

        for var f: u32 in fids {
            if skipped.contains(f as u64) {
                gs->get_context(f)->syntax_skipped = true
            }
        }

        for var f: u32 in fids {
            if recovered.contains(f as u64) {
                self._drop_recovered_bodies(gs, f)
            }
        }

        // For Scripts/syntax_recovery_diff.py: whether the run checked the
        // entry (fids[0]) or only what it imports, and how much it skipped.
        if cxx::std::getenv(r"KAIRO_DEBUG_SYNTAX_RECOVERY") != &null && fids.size() > 0 {
            var entry = if skipped.contains(fids[0] as u64) => "skipped" else => "checked"
            io::eprintln(
                f"syntax-recovery: entry {entry}, {skipped.size()} of {in_graph.size()} files skipped, {recovered.size()} checked without their broken bodies",
            )
        }

        return true
    }

    /// \p f's functions whose bodies hold its syntax errors become their
    /// signatures alone.
    priv fn _drop_recovered_bodies(self, gs: unsafe *GlobalDisambigTable, f: u32) {
        var unsafe *rtu = gs->get_context(f)->tu
        for var i: usize = 0; i < rtu->recovered_bodies.size(); ++i {
            var unsafe *fd = dyn_cast<FunctionDecl>(
                *rtu->recovered_bodies.get(i),
            )

            if fd == &null {
                continue
            }

            // For Scripts/syntax_recovery_diff.py: a diagnostic inside a
            // dropped body would be a cascade; one outside it is about
            // healthy code.
            if cxx::std::getenv(r"KAIRO_DEBUG_SYNTAX_RECOVERY") != &null
                && fd->body_block != &null {
                var unsafe *sm = self.sm()
                var        a   = sm->get_line_col(fd->body_block->range.start)
                var        b   = sm->get_line_col(fd->body_block->range.end)
                io::eprintln(
                    f"syntax-recovery: dropped body {sm->get_filename(f)}:{a.line}-{b.line}",
                )
            }

            fd->body_block     = &null
            fd->body_kind      = FnBodyKind::None
            fd->body_recovered = true
        }
    }

    /// \brief admit_past_syntax_errors for a live check's re-check of \p fids
    ///        (Tooling/LiveCheck.k, LiveCheck::past_syntax): each of them
    ///        has just been parsed again, in an instance whose other files
    ///        are checked and stay as they are.
    ///
    /// \details True when every file of \p fids that has syntax errors has
    ///          them all inside function bodies that can be dropped; those
    ///          bodies are then dropped, and Sema checks the files as their
    ///          signatures. False, and nothing touched, when one has an error
    ///          anywhere else: that file, and so every file that imports it,
    ///          cannot be checked (the caller leaves them as they were).
    ///          \p broken gets the files that had errors and \p errors
    ///          their number, for the caller to match against what the
    ///          engine was handed. The builtin root and --prelude /
    ///          --force-include never get here: LiveCheck refuses both.
    pub fn admit_bodies_in_place(self,
                                 gs:         unsafe *GlobalDisambigTable,
                                 const fids: cxx::std::vector<u32>,
                                 broken:     *cxx::std::vector<u32>,
                                 errors:     *u32) -> bool {
        *errors = 0
        for var f: u32 in fids {
            var unsafe *ctx = gs->get_context(f)
            if ctx == &null || ctx->tu == &null {
                return false
            }

            var n = ctx->diag_sink.error_count()
            if n == 0 {
                continue
            }

            if !Self::_bodies_hold_errors(ctx) {
                return false
            }

            broken->push_back(f)
            *errors += n
        }

        // Decided for all before any is dropped.
        for var f: u32 in *broken {
            self._drop_recovered_bodies(gs, f)
        }

        return true
    }

    /// Every error of \p ctx's file is inside a function body the parser kept
    /// it in, and each such function can stand as its signature alone. Not:
    /// an out-of-line member definition (the class's ring expects it to be
    /// one), an `eval` / `const` function or an `inline` one (their bodies
    /// are part of their contract), or a `where` member (its guard is).
    priv static fn _bodies_hold_errors(ctx: unsafe *ASTContext) -> bool {
        if ctx == &null || ctx->tu == &null {
            return false
        }

        var unsafe *tu = ctx->tu
        if tu->recovered_bodies.size() == 0
            || tu->recovered_errors != ctx->diag_sink.error_count() {
            return false
        }

        for var i: usize = 0; i < tu->recovered_bodies.size(); ++i {
            var unsafe *fd = dyn_cast<FunctionDecl>(
                *tu->recovered_bodies.get(i),
            )

            if fd == &null
                || fd->is_out_of_line()
                || fd->is_constexpr()
                || fd->is_inline()
                || fd->has_where() {
                return false
            }
        }

        return true
    }
}
