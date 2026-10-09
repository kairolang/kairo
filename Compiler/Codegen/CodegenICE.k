/// --- The Kairo Project ----------------------- Codegen/CodegenICE.k ----- ///
///
///   \brief An ICE that names the Kairo source it was emitting.
///
///   \detail
///     A bare ICE_IF/ICE_FAIL reports where in the COMPILER it fired. To
///     reduce it, what is needed is where in the PROGRAM: the node codegen
///     was emitting. Every codegen site that holds a node or a range ICEs
///     through codegen_ice instead, which
///
///       1. reports an internal diagnostic at that range (I003E by default)
///          with the ICE text as its message,
///       2. drains the context's buffered sink into the engine and renders
///          it to stderr, since the abort skips the driver's end-of-run
///          flush and a buffered diagnostic would die with the process,
///       3. ICEs with the range's path:line:col appended, so the location
///          survives even if rendering itself is what broke.
///
///     A null context (a sink not yet bound to one) or an invalid range
///     degrades to a plain ICE_FAIL with the same text.
///
///   Phase: CODEGEN (shared by all emitters and sinks)
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::Context::ASTContext::*;
import Location::SourceLocation::*;
import Location::SourceRange::*;
import Location::SourceManager::*;
import Location::FullSourceLocation::*;
import Diagnostic::Registry::*;

/// `path:line:col` of \p loc, or empty when it maps to nothing.
fn codegen_ice_loc(ctx: *ASTContext, loc: SourceLocation) -> string {
    if (ctx == &null) || (ctx->sm == &null) { return ""; }
    if !loc.is_valid() { return ""; }
    var sm = ctx->sm;
    var full: FullSourceLocation = sm->get_line_col(loc);
    if full.line == 0 { return ""; }   // not is_valid(): that rejects fid 0, the main file.
    return f"{full.path.full_path()}:{full.line}:{full.column}";
}

/// ICE at \p at, reported as \p id. Never returns.
fn codegen_ice(ctx: *ASTContext, id: DiagID, at: SourceRange, msg: string) {
    var where_ = codegen_ice_loc(ctx, at.start);
    if where_.size() == 0 { ICE_FAIL(msg); }

    var b = ctx->diag_sink.report(DiagCode(id), at.start, f"internal compiler error: {msg}");
    b.first(at);
    b.emit();
    if ctx->diags != &null {
        ctx->diag_sink.drain_into(ctx->diags, ctx->sm);
        ctx->diags->flush_consumers_for_ice();
    }
    ICE_FAIL(f"{msg}, at {where_}");
}

/// ICE at \p at, reported as I003E (internal invariant violation).
fn codegen_ice(ctx: *ASTContext, at: SourceRange, msg: string) {
    codegen_ice(ctx, DiagID::I003E, at, msg);
}
