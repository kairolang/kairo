/// --- The Kairo Project -------------------- AST/Serialize/RoundTrip.k --- ///
///
///   ASTRoundTrip: the two ways the driver exercises the serializer on a
///   tree it has just parsed (--ast-roundtrip, --verify-ast-roundtrip).
///
///   replace  writes the tree, reads it back into the same context and
///            leaves the RELOADED tree as the context's, so everything
///            after parsing runs on what the reader built.
///   verify   writes the tree, reads it into a second context of its own
///            and compares the two trees four ways; the parsed tree stays.
///
///   verify's four comparisons, weakest oracle first:
///     1. the `--print-ast=tree` rendering, line by line;
///     2. the bytes of the reloaded tree written again: every stored field
///        the printer does not show (ranges, flags, annotations, tokens);
///     3. what the reader REBUILDS instead of storing (dc_scope, dc_symbols,
///        out_of_line, module_self), node by node: the writer's and the
///        reader's node tables are index-aligned;
///     4. nothing else: a field that is neither stored nor rebuilt is one
///        the writer's debug checks hold at its default.
///   It then damages the bytes three ways (another version, another source
///   hash, cut short) and checks the reader refuses each.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import AST::Context::ASTContext::ASTContext
import AST::Context::DeclContext::DeclContext
import AST::Context::GlobalDisambigTable::GlobalDisambigTable
import AST::Context::SymbolTable::SymbolTable
import AST::Context::TranslationUnit::TranslationUnit
import AST::Node::Base::Decl
import AST::Printer::PrintCore::PrintOptions
import AST::Printer::Printers::ASTPrinter
import AST::Serialize::Archive::ASTArchive
import AST::Serialize::ByteBuffer::ByteWriter
import AST::Serialize::DeclIO::decl_dc
import AST::Serialize::Format::CAT_DECL
import AST::Serialize::Serializer::{
    ASTBinReader,
    ASTBinWriter,
}
import Preprocessor::PreprocessorSymbolTable::PreprocessorSymbolTable
import Support::TimeReport::TimeRegion

/// Totals over the files one run round-tripped (the gate's numbers).
pub struct RoundTripStats {
    pub var files:    u64 = 0
    pub var bytes:    u64 = 0 ///< serialized
    pub var source:   u64 = 0 ///< source text of the same files
    pub var nodes:    u64 = 0
    pub var tokens:   u64 = 0
    pub var payloads: u64 = 0
    pub var strings:  u64 = 0
}

/// The first line two renderings differ at, for the error message.
fn first_difference(const a: string, const b: string) -> string {
    var line: usize = 1
    var ia: usize   = 0
    var ib: usize   = 0
    while ia < a.size() || ib < b.size() {
        var ea = ia
        while ea < a.size() && a[ea] != ('\n' as u8) {
            ea += 1
        }

        var eb = ib
        while eb < b.size() && b[eb] != ('\n' as u8) {
            eb += 1
        }

        var la = string(unsafe ((a.raw() + ia) as *const u8), ea - ia)
        var lb = string(unsafe ((b.raw() + ib) as *const u8), eb - ib)
        if la != lb {
            return f"line {line}: parsed `{la}`, reloaded `{lb}`"
        }

        ia = ea + 1
        ib = eb + 1
        line += 1
    }

    return "no differing line (lengths differ)"
}

/// Index of the node at family base pointer \p p in \p ar's node table.
fn node_index(ar: unsafe *ASTArchive, @inout ids: {u64: u32}, p: unsafe *Decl) -> u32 {
    if p == &null {
        return u32::MAX - 1
    }

    var hit = ids.get((p as usize) as u64)
    if hit == null {
        return u32::MAX
    }

    return *hit
}

/// Two symbol tables hold the same names, in the same order, each naming
/// the same declarations (by node id). The empty string when they do, else
/// what differs.
fn symbols_differ(a:   unsafe *SymbolTable,
                  b:   unsafe *SymbolTable,
                  wa:  unsafe *ASTArchive,
                  @inout ia: {u64: u32},
                  wb:  unsafe *ASTArchive,
                  @inout ib: {u64: u32}) -> string {
    if a == &null || b == &null {
        if a == &null && b == &null {
            return ""
        }

        return "one tree has no table"
    }

    if a->is_frozen() != b->is_frozen() {
        return "one table is not frozen"
    }

    var ea = cxx::std::vector<SymbolTable::Entry>()
    var eb = cxx::std::vector<SymbolTable::Entry>()
    a->collect_entries(&ea)
    b->collect_entries(&eb)
    if ea.size() != eb.size() {
        return f"{ea.size()} names parsed, {eb.size()} reloaded"
    }

    for var i: usize = 0; i < ea.size(); ++i {
        if ea[i].name.as_key() != eb[i].name.as_key() {
            var ka = ea[i].name.as_key()
            var kb = eb[i].name.as_key()
            return f"name {i} is keyed {ka} parsed, {kb} reloaded"
        }

        if ea[i].cell->size() != eb[i].cell->size() {
            return f"name {i} has {ea[i].cell->size()} declarations parsed, {eb[i].cell->size()} reloaded"
        }

        for var j: usize = 0; j < ea[i].cell->size(); ++j {
            var x = node_index(wa, &ia, ea[i].cell->get(j))
            var y = node_index(wb, &ib, eb[i].cell->get(j))
            if x != y || x == u32::MAX {
                return f"name {i}, declaration {j}: node {x} parsed, node {y} reloaded"
            }
        }
    }

    return ""
}

pub class ASTRoundTrip {
    /// Serializes \p ctx's tree and replaces it with the tree read back.
    /// On failure the parsed tree is still the context's and \p err says
    /// what went wrong.
    pub static fn replace(ctx:   unsafe *ASTContext,
                          psym:  unsafe *PreprocessorSymbolTable,
                          gs:    unsafe *GlobalDisambigTable,
                          @inout stats: RoundTripStats,
                          @inout err:   string) -> bool {
        var unsafe *old = ctx->tu
        if old == &null {
            return true
        }

        var w = ASTBinWriter()
        {
            var _tw = TimeRegion("Write")
            if !w.write(old, psym, gs) {
                err = w.error()
                return false
            }
        }

        // The parsed tree is abandoned in its arena, not freed: the macro
        // table still names the old MacroDecls, whose parameter lists live
        // there. Nothing the pipeline reaches through ctx->tu points at it.
        ctx->tu = &null

        var r = ASTBinReader()
        var tu: unsafe *TranslationUnit = &null
        {
            var _tr = TimeRegion("Read")
            tu = r.read(w.out.bytes(), w.out.size(), ctx, psym, gs)
        }

        if tu == &null {
            ctx->tu = old
            err     = r.error()
            return false
        }

        // What on a TU belongs to the build, not to the tree: the clang
        // header set the preprocessor requested for this file's ffi imports.
        tu->header_set = old->header_set

        ASTRoundTrip::_count(unsafe &w, &stats)
        return true
    }

    /// Serializes \p tu, reads it into a context of its own and compares.
    /// The parsed tree is untouched. False with \p err naming the first
    /// difference.
    pub static fn verify(tu:    unsafe *TranslationUnit,
                         psym:  unsafe *PreprocessorSymbolTable,
                         gs:    unsafe *GlobalDisambigTable,
                         @inout stats: RoundTripStats,
                         @inout err:   string) -> bool {
        if tu == &null {
            return true
        }

        var w = ASTBinWriter()
        {
            var _tw = TimeRegion("Write")
            if !w.write(tu, psym, gs) {
                err = w.error()
                return false
            }
        }

        var unsafe *c2 = ASTRoundTrip::_fresh_context(tu->ctx)
        var ok = ASTRoundTrip::_verify_in(tu, c2, unsafe &w, psym, gs, &err)
        ASTRoundTrip::_drop_context(c2)

        // 5. a reader refuses what is not its own: another version, another
        // source text, a file cut short. Checked here, on every tree the
        // gate runs, because nothing else reads a damaged file.
        if ok {
            ok = ASTRoundTrip::_refuses_damage(tu->ctx, unsafe &w, psym, gs, &err)
        }

        if ok {
            ASTRoundTrip::_count(unsafe &w, &stats)
        }

        return ok
    }

    /// A second context for the same file: same source, tokens, immediate
    /// table and index, no tree.
    priv static fn _fresh_context(octx: unsafe *ASTContext) -> unsafe *ASTContext {
        var unsafe *c = kairo::std::create<ASTContext>(
            octx->fid,
            octx->sm,
            octx->tcm,
            octx->diags,
            octx->resolver,
            octx->ci,
        )

        c->source_path     = octx->source_path
        c->module_base     = octx->module_base
        c->module_leaf_imm = octx->module_leaf_imm
        c->hoisted         = octx->hoisted
        return c
    }

    priv static fn _drop_context(c: unsafe *ASTContext) {
        // The index is the original context's; this one only borrowed it.
        c->hoisted = &null
        kairo::std::destroy(c)
    }

    /// True when a reader given \p bytes builds no tree.
    priv static fn _refused(octx:  unsafe *ASTContext,
                            const bytes: ByteWriter,
                            len:   usize,
                            psym:  unsafe *PreprocessorSymbolTable,
                            gs:    unsafe *GlobalDisambigTable) -> bool {
        var unsafe *c = ASTRoundTrip::_fresh_context(octx)
        var r         = ASTBinReader()
        var unsafe *t = r.read(bytes.bytes(), len, c, psym, gs)
        var refused   = t == &null && c->tu == &null
        ASTRoundTrip::_drop_context(c)
        return refused
    }

    priv static fn _refuses_damage(octx: unsafe *ASTContext,
                                   w:    unsafe *ASTBinWriter,
                                   psym: unsafe *PreprocessorSymbolTable,
                                   gs:   unsafe *GlobalDisambigTable,
                                   @inout err: string) -> bool {
        var _td = TimeRegion("Refuse")
        var len = w->out.size()

        // Byte 4 is the low byte of the format version; bytes 8..23 the
        // source hash.
        var other_version = w->out
        other_version.buf[4] = other_version.buf[4] + 1
        if !ASTRoundTrip::_refused(octx, other_version, len, psym, gs) {
            err = "a serialized AST of another format version was accepted"
            return false
        }

        var other_source = w->out
        other_source.buf[8] = other_source.buf[8] ^ 0x5A
        if !ASTRoundTrip::_refused(octx, other_source, len, psym, gs) {
            err = "a serialized AST of another source text was accepted"
            return false
        }

        if !ASTRoundTrip::_refused(octx, w->out, len - len / 3, psym, gs) {
            err = "a truncated serialized AST was accepted"
            return false
        }

        if !ASTRoundTrip::_refused(octx, w->out, len - 1, psym, gs) {
            err = "a serialized AST missing its last byte was accepted"
            return false
        }

        return true
    }

    priv static fn _count(w: unsafe *ASTBinWriter, @inout stats: RoundTripStats) {
        stats.files += 1
        stats.bytes += w->out.size() as u64
        stats.source += w->ar.sm->get_file_size(w->ar.fid) as u64
        stats.nodes += w->ar.nodes.size() as u64
        stats.tokens += w->ar.stat_tokens
        stats.payloads += w->ar.stat_payloads
        stats.strings += w->ar.strings.size() as u64
    }

    priv static fn _verify_in(tu:   unsafe *TranslationUnit,
                              c2:   unsafe *ASTContext,
                              w:    unsafe *ASTBinWriter,
                              psym: unsafe *PreprocessorSymbolTable,
                              gs:   unsafe *GlobalDisambigTable,
                              @inout err: string) -> bool {
        var r = ASTBinReader()
        var tu2: unsafe *TranslationUnit = &null
        {
            var _tr = TimeRegion("Read")
            tu2 = r.read(w->out.bytes(), w->out.size(), c2, psym, gs)
        }

        if tu2 == &null {
            err = r.error()
            return false
        }

        var _tc = TimeRegion("Compare")

        // 1. what --print-ast=tree shows
        var a = ASTPrinter::render(tu, PrintOptions::dump_plain())
        var b = ASTPrinter::render(tu2, PrintOptions::dump_plain())
        if a != b {
            var where_ = first_difference(a, b)
            err = f"reloaded AST prints differently, {where_}"
            return false
        }

        // 2. every stored field: the reloaded tree serializes to the same bytes
        var w2 = ASTBinWriter()
        if !w2.write(tu2, psym, gs) {
            var why = w2.error()
            err = f"reloaded AST does not serialize: {why}"
            return false
        }

        if w2.out.size() != w->out.size() {
            err = f"reloaded AST serializes to {w2.out.size()} bytes, the parsed one to {w->out.size()}"
            return false
        }

        for var i: usize = 0; i < w->out.size(); ++i {
            if w->out.buf[i] != w2.out.buf[i] {
                err = f"reloaded AST serializes differently from byte {i}"
                return false
            }
        }

        // 3. what the reader rebuilds
        if w->ar.nodes.size() != r.ar.nodes.size() {
            err = "reloaded AST has a different number of nodes"
            return false
        }

        var ia: {u64: u32}
        var ib: {u64: u32}
        for var i: usize = 0; i < w->ar.nodes.size(); ++i {
            if w->ar.nodes[i].cat != r.ar.nodes[i].cat {
                err = f"node {i} is of another family after reload"
                return false
            }

            if w->ar.nodes[i].cat == CAT_DECL {
                ia[(w->ar.nodes[i].ptr as usize) as u64] = i as u32
                ib[(r.ar.nodes[i].ptr as usize) as u64]  = i as u32
            }
        }

        var unsafe *wa = w->ar.me()
        var unsafe *wb = r.ar.me()

        if tu->dc_scope != tu2->dc_scope {
            err = "the reloaded TU is wired to a different hoisted scope"
            return false
        }

        var tu_diff = symbols_differ(tu->dc_symbols, tu2->dc_symbols, wa, &ia, wb, &ib)
        if !tu_diff.empty() {
            err = f"the reloaded TU's symbol table differs: {tu_diff}"
            return false
        }

        if tu->out_of_line.size() != tu2->out_of_line.size() {
            err = "the reloaded TU's out-of-line list differs in length"
            return false
        }

        for var i: usize = 0; i < tu->out_of_line.size(); ++i {
            var x = node_index(wa, &ia, *tu->out_of_line.get(i))
            var y = node_index(wb, &ib, *tu2->out_of_line.get(i))
            if x != y || x == u32::MAX {
                err = f"the reloaded TU's out-of-line list differs at {i}"
                return false
            }
        }

        if (tu->module_self == &null) != (tu2->module_self == &null) {
            err = "the reloaded TU's own module declaration differs"
            return false
        }

        if tu->module_self != &null {
            if tu->module_self->name.imm != tu2->module_self->name.imm || tu->module_self->dc_symbols != tu->dc_symbols || tu2->module_self->dc_symbols != tu2->dc_symbols {
                err = "the reloaded TU's own module declaration differs"
                return false
            }
        }

        for var i: usize = 0; i < w->ar.nodes.size(); ++i {
            if w->ar.nodes[i].cat != CAT_DECL {
                continue
            }

            var unsafe *d1 = unsafe (w->ar.nodes[i].ptr as unsafe *Decl)
            var unsafe *d2 = unsafe (r.ar.nodes[i].ptr as unsafe *Decl)
            var unsafe *s1 = decl_dc(d1)
            var unsafe *s2 = decl_dc(d2)
            if (s1 == &null) != (s2 == &null) {
                err = f"node {i} is a scope in one tree only"
                return false
            }

            if s1 == &null {
                continue
            }

            if s1->dc_scope != s2->dc_scope {
                err = f"node {i}: the reloaded scope is wired to a different hoisted scope"
                return false
            }

            var diff = symbols_differ(s1->dc_symbols, s2->dc_symbols, wa, &ia, wb, &ib)
            if !diff.empty() {
                err = f"node {i}: the reloaded scope's symbol table differs: {diff}"
                return false
            }
        }

        return true
    }
}
