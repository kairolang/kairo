/// --- The Kairo Project ------------------- AST/Serialize/Serializer.k --- ///
///
///   ASTBinWriter / ASTBinReader: one file's parsed AST to bytes and back.
///   The format is Compiler/Spec/Serialization.md; this file is its
///   container (header, sections) and the translation unit's own fields.
///   Node classes are in DeclIO / ExprIO / StmtIO / TypeIO / PatternIO, and
///   every encoding is the archive's (Archive.k).
///
///   The writer takes a tree as the parser left it: BEFORE Sema. Sema's
///   facts are not written, and the writer checks (debug builds) that the
///   slots it skips are still unset. The reader builds the same tree in a
///   context that has no tree yet, then restores what the parser derives
///   from the tree rather than parses: scope links into the hoisted table,
///   the per-scope symbol tables and the file's own module declaration
///   (ASTParse::rebuild_derived).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/Support/FileSystem.h"
ffi "c++" import "llvm/Support/raw_ostream.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "system_error"

import AST::Context::ASTContext::ASTContext
import AST::Context::DeclContext::DeclContext
import AST::Context::GlobalDisambigTable::GlobalDisambigTable
import AST::Context::TranslationUnit::{
    ImportEdge,
    TranslationUnit,
}
import AST::Node::Base::{
    Decl,
    Expr,
    Pattern,
    Stmt,
    Type,
}
import AST::Node::Declarations::ImportDecl
import AST::Node::Program::{
    Program,
    TopLevelItem,
    TopLevelKind,
}
import AST::Serialize::Archive::{
    ASTArchive,
    FileEntry,
}
import AST::Serialize::ByteBuffer::{
    ByteReader,
    ByteWriter,
}
import AST::Serialize::DeclIO::{
    decl_alloc,
    decl_dc,
    decl_io,
}
import AST::Serialize::ExprIO::{
    expr_alloc,
    expr_io,
}
import AST::Serialize::Format::{
    AST_FORMAT_VERSION,
    AST_MAGIC,
    CAT_DECL,
    CAT_EXPR,
    CAT_PATTERN,
    CAT_STMT,
    CAT_TYPE,
    SEC_END,
    SEC_FILES,
    SEC_PAYLOADS,
    SEC_STRINGS,
    SEC_TREE,
}
import AST::Serialize::PatternIO::{
    pattern_alloc,
    pattern_io,
}
import AST::Serialize::StmtIO::{
    stmt_alloc,
    stmt_io,
}
import AST::Serialize::TypeIO::{
    type_alloc,
    type_io,
}
import Driver::TUStage::TUStage
import Parser::ASTParse::ASTParse
import Preprocessor::PreprocessorSymbolTable::PreprocessorSymbolTable
import Token::Token::Token
import std::c_char
import Support::Ascii::hex_value

//  the archive's hooks

fn hook_alloc(ar: unsafe *ASTArchive, cat: u8) -> unsafe *void {
    if cat == CAT_DECL {
        return unsafe (decl_alloc(ar) as unsafe *void)
    }

    if cat == CAT_EXPR {
        return unsafe (expr_alloc(ar) as unsafe *void)
    }

    if cat == CAT_STMT {
        return unsafe (stmt_alloc(ar) as unsafe *void)
    }

    if cat == CAT_TYPE {
        return unsafe (type_alloc(ar) as unsafe *void)
    }

    if cat == CAT_PATTERN {
        return unsafe (pattern_alloc(ar) as unsafe *void)
    }

    return &null
}

fn hook_io(ar: unsafe *ASTArchive, cat: u8, p: unsafe *void) {
    if cat == CAT_DECL {
        decl_io(ar, unsafe (p as unsafe *Decl))
    } else if cat == CAT_EXPR {
        expr_io(ar, unsafe (p as unsafe *Expr))
    } else if cat == CAT_STMT {
        stmt_io(ar, unsafe (p as unsafe *Stmt))
    } else if cat == CAT_TYPE {
        type_io(ar, unsafe (p as unsafe *Type))
    } else if cat == CAT_PATTERN {
        pattern_io(ar, unsafe (p as unsafe *Pattern))
    }
}

fn hook_dc(d: unsafe *Decl) -> unsafe *DeclContext {
    return decl_dc(d)
}

fn install_hooks(ar: unsafe *ASTArchive) {
    ar->alloc_hook = hook_alloc
    ar->io_hook    = hook_io
    ar->dc_hook    = hook_dc
}

//  the translation unit

/// The TU's own fields, in both directions. What is here is what the
/// preprocessor and the parser wrote; everything Sema, the driver or a
/// later stage writes on a TU is listed in the checks at the end (`_stage`
/// is not stored: the writer requires a parsed tree and the reader sets
/// Parsing on what it built), and the
/// fields the reader REBUILDS (scope, dc_scope, dc_symbols, out_of_line,
/// module_self) are restored by ASTParse::rebuild_derived, not stored.
fn io_tu(ar: unsafe *ASTArchive, tu: unsafe *TranslationUnit) {
    ar->flag(&tu->has_eval_if)
    ar->flag(&tu->has_eval_for)
    ar->flag(&tu->has_prim_member)
    ar->flag(&tu->has_alloc_sugar)
    ar->num32(&tu->error_count)
    ar->num32(&tu->warn_count)

    // The `module a::b` pin.
    var pins = ar->len_(tu->pin_segments.size())
    for var i: usize = 0; i < pins; ++i {
        var t: Token
        if !ar->reading() {
            t = *tu->pin_segments.get(i)
        }

        ar->tok(&t)
        if ar->reading() {
            tu->pin_segments.push(t)
        }
    }

    ar->range(&tu->pin_range)
    ar->range(&tu->pin_extra_range)

    // What the preprocessor took out of the token stream.
    ar->decl_arena_list(&tu->imports)
    ar->decl_arena_list(&tu->macros)

    // Import edges: the file each resolved import names. A fid is this
    // process's; the file table names the file itself.
    var edges = ar->len_(tu->import_edges.size())
    for var i: usize = 0; i < edges; ++i {
        var e = ImportEdge{}
        if !ar->reading() {
            e = *tu->import_edges.get(i)
        }

        var resolved = e.target_fid != u32::MAX
        ar->flag(&resolved)
        if resolved {
            var fref: u32 = 0
            if !ar->reading() {
                fref = ar->file_ref(e.target_fid)
            }

            ar->num32(&fref)
            if ar->reading() {
                e.target_fid = ar->file_fid(fref)
            }
        } else {
            e.target_fid = u32::MAX
        }

        ar->decl<ImportDecl>(&e.decl)
        if ar->reading() {
            tu->import_edges.push(e)
        }
    }

    ar->decl<Decl>(&tu->global_alloc)
    ar->range(&tu->global_alloc_at)

    ar->decl_arena_list(&tu->dc_decls)

    // The program: its top-level items, in source order.
    var unsafe *prog = tu->program
    var have: usize = 0
    if prog != &null {
        have = prog->items.size()
    }

    var has_prog = prog != &null
    ar->flag(&has_prog)
    if has_prog {
        if ar->reading() {
            prog        = ar->ctx->alloc_init<Program>(ar->ctx->fid, ar->ctx)
            tu->program = prog
        }

        var items = ar->len_(have)
        for var i: usize = 0; i < items; ++i {
            var kind = TopLevelKind::Decl
            if !ar->reading() {
                kind = prog->items.get(i)->get_kind()
            }

            ar->en<TopLevelKind>(&kind)
            if kind == TopLevelKind::Decl {
                var d: unsafe *Decl = &null
                if !ar->reading() {
                    d = prog->items.get(i)->as_decl()
                }

                ar->decl<Decl>(&d)
                if ar->reading() {
                    prog->add_item(TopLevelItem::from_decl(d))
                }
            } else if kind == TopLevelKind::Stmt {
                var s: unsafe *Stmt = &null
                if !ar->reading() {
                    s = prog->items.get(i)->as_stmt()
                }

                ar->stmt<Stmt>(&s)
                if ar->reading() {
                    prog->add_item(TopLevelItem::from_stmt(s))
                }
            } else {
                var e: unsafe *Expr = &null
                if !ar->reading() {
                    e = prog->items.get(i)->as_expr()
                }

                ar->expr<Expr>(&e)
                if ar->reading() {
                    prog->add_item(TopLevelItem::from_expr(unsafe (e as *Expr)))
                }
            }
        }
    }

    eval if defined!(DEBUG) {
        ar->sema_zero(tu->tu_attrs.size() as u64, "TranslationUnit::tu_attrs")
        ar->sema_zero(tu->body_ranges.size() as u64, "TranslationUnit::body_ranges")
        ar->sema_null<void>(unsafe (tu->import_overlay as unsafe *void), "TranslationUnit::import_overlay")
        ar->sema_null<Decl>(tu->cxx_module, "TranslationUnit::cxx_module")
        ar->sema_false(tu->is_foreign, "TranslationUnit::is_foreign")
        ar->sema_false(tu->has_eval_string, "TranslationUnit::has_eval_string")
        ar->sema_false(tu->no_extensions, "TranslationUnit::no_extensions")
        ar->sema_zero(tu->cxx_escaping.size() as u64, "TranslationUnit::cxx_escaping")
        ar->sema_false(tu->cxx_escaping_done, "TranslationUnit::cxx_escaping_done")
        ar->sema_zero(tu->panic_sites.size() as u64, "TranslationUnit::panic_sites")
        ar->sema_zero(tu->module_path.segments.size() as u64, "TranslationUnit::module_path")
    }
}

//  the container

/// A 128-bit hash, 32 hex digits, as its 16 bytes. An unreadable file has
/// the empty string for a hash and is written as zeros.
priv fn put_hash(@inout w: ByteWriter, const hex: string) {
    for var i: usize = 0; i < 16; ++i {
        var b: u8 = 0
        if hex.size() == 32 {
            b = (hex_value(hex[i * 2]) << 4) | hex_value(hex[i * 2 + 1])
        }

        w.put_u8(b)
    }
}

priv fn get_hash(@inout r: ByteReader) -> string {
    var digits      = "0123456789abcdef"
    var out: string = ""
    for var i: usize = 0; i < 16; ++i {
        var b = r.get_u8()
        out += string(unsafe ((digits.raw() + ((b >> 4) as usize)) as *const u8), 1)
        out += string(unsafe ((digits.raw() + ((b & 15) as usize)) as *const u8), 1)
    }

    return out
}

priv fn put_section(@inout out: ByteWriter, id: u8, const body: ByteWriter) {
    out.put_u8(id)
    out.put_u32le(body.size() as u32)
    out.put_writer(body)
}

/// Writes \p w's bytes to \p path, truncating. False on failure.
pub fn write_ast_file(const path: string, const w: ByteWriter) -> bool {
    var ec: cxx::std::error_code
    var os = llvm::raw_fd_ostream(kairo::sref(path), &ec, llvm::sys::fs::OF_None)
    if ec.value() != 0 {
        return false
    }

    if w.size() > 0 {
        os.write(unsafe (w.bytes() as unsafe *const c_char), w.size())
    }

    os.close()
    return !os.has_error()
}

pub class ASTBinWriter {
    pub var ar:  ASTArchive
    pub var out: ByteWriter

    pub fn ASTBinWriter(self) { }

    pub fn error(self) -> string {
        return self.ar.error
    }

    /// Serializes \p tu into `out`. False (with error()) when the tree is
    /// not one the format can hold: a Sema slot is set, a canonical type is
    /// reachable, a token's payload cannot be found.
    pub fn write(self,
                 tu:   unsafe *TranslationUnit,
                 psym: unsafe *PreprocessorSymbolTable,
                 gs:   unsafe *GlobalDisambigTable) -> bool {
        if tu == &null || tu->ctx == &null {
            self.ar.fail("no translation unit to serialize")
            return false
        }

        var unsafe *ar = self.ar.me()
        ar->begin_writing()

        // Only a parsed tree: the stage says so for the whole TU, and the
        // per-slot checks in each io_ function stay as the cross-check for a
        // Sema write into this tree from another TU's Sema (an instance
        // homed here), which does not move this TU's stage. Debug-only, as
        // they are: a release build does not pay for either.
        eval if defined!(DEBUG) {
            if (tu->stage() as u8) > (TUStage::Parsing as u8) {
                self.ar.fail("the translation unit has been through Sema; only a parsed tree can be serialized")
                return false
            }
        }

        ar->bind(tu->ctx, psym, gs)
        ar->tu = tu
        install_hooks(ar)

        io_tu(ar, tu)
        if !ar->ok() {
            return false
        }

        var unsafe *tree = ar->tree_bytes()

        self.out.clear()
        self.out.put_u32le(AST_MAGIC)
        self.out.put_u32le(AST_FORMAT_VERSION)
        put_hash(&self.out, ar->source_hash())
        self.out.put_u32le(0) // flags: none defined in version 1

        // Files. Entry 0 is the file itself and has nothing to say.
        var files = ByteWriter()
        files.put_varint((ar->files.size() - 1) as u64)
        for var i: usize = 1; i < ar->files.size(); ++i {
            var id_name = ar->strings.intern(ar->files[i].name)
            var id_base = ar->strings.intern(ar->files[i].base)
            files.put_varint(id_name as u64)
            files.put_varint(id_base as u64)
            files.put_varint(ar->files[i].size)
            put_hash(&files, ar->files[i].hash)
        }

        var strings = ByteWriter()
        ar->strings.write(&strings)

        var payloads = ByteWriter()
        payloads.put_varint(ar->payload_count as u64)
        payloads.put_writer(ar->payload_w)

        var tree_sec = ByteWriter()
        tree_sec.put_varint(ar->nodes.size() as u64)
        tree_sec.put_writer(*tree)

        // Strings first: the file table names its files through it.
        put_section(&self.out, SEC_STRINGS, strings)
        put_section(&self.out, SEC_FILES, files)
        put_section(&self.out, SEC_PAYLOADS, payloads)
        put_section(&self.out, SEC_TREE, tree_sec)
        self.out.put_u8(SEC_END)
        self.out.put_u32le(0)
        return true
    }
}

pub class ASTBinReader {
    pub var ar: ASTArchive

    pub fn ASTBinReader(self) { }

    pub fn error(self) -> string {
        return self.ar.error
    }

    /// Builds the tree \p data holds in \p ctx, which must have its tokens'
    /// immediate table and its hoisted (Index) table but no tree: `ctx->tu`
    /// is null on entry and the new TU on success. Null (with error()) for
    /// bytes of another version, of another source text, or damaged.
    pub fn read(self,
                data: unsafe *const u8,
                len:  usize,
                ctx:  unsafe *ASTContext,
                psym: unsafe *PreprocessorSymbolTable,
                gs:   unsafe *GlobalDisambigTable) -> unsafe *TranslationUnit {
        var unsafe *ar = self.ar.me()
        ar->begin_reading()
        install_hooks(ar)

        if ctx == &null || ctx->tu != &null {
            ar->fail("the context to deserialize into already has a tree")
            return &null
        }

        if ctx->hoisted == &null {
            ar->fail("the context to deserialize into has no index (Parse.Index has not run)")
            return &null
        }

        ar->bind(ctx, psym, gs)

        var hdr = ByteReader(data, len)
        if hdr.get_u32le() != AST_MAGIC {
            ar->fail("not a serialized Kairo AST")
            return &null
        }

        var version = hdr.get_u32le()
        if version != AST_FORMAT_VERSION {
            ar->fail(f"serialized AST is format version {version}, this compiler reads {AST_FORMAT_VERSION}")
            return &null
        }

        // Every range in the file is an offset into one exact text.
        var want = get_hash(&hdr)
        if want != ar->source_hash() {
            ar->fail("serialized AST was written from different source text")
            return &null
        }

        hdr.get_u32le() // flags
        if hdr.failed {
            ar->fail("serialized AST header is truncated")
            return &null
        }

        // Sections, in file order. One this version does not know is
        // skipped by its length.
        var tree_at:  usize = 0
        var tree_len: usize = 0
        var have_tree       = false
        while !hdr.at_end() {
            var id  = hdr.get_u8()
            var n   = hdr.get_u32le() as usize
            var at  = hdr.pos
            var sec = hdr.get_bytes(n)
            if hdr.failed {
                ar->fail("serialized AST section is truncated")
                return &null
            }

            if id == SEC_END {
                break
            }

            if id == SEC_STRINGS {
                var r = ByteReader(sec, n)
                ar->strings.read(&r)
                if r.failed {
                    ar->fail("serialized AST string table is damaged")
                    return &null
                }
            } else if id == SEC_FILES {
                var r     = ByteReader(sec, n)
                var count = r.get_count()
                for var i: usize = 0; i < count; ++i {
                    var e = FileEntry{}
                    e.name = ar->strings.get(r.get_varint() as u32)
                    e.base = ar->strings.get(r.get_varint() as u32)
                    e.size = r.get_varint()
                    e.hash = get_hash(&r)
                    ar->files.push_back(e)
                }

                if r.failed {
                    ar->fail("serialized AST file table is damaged")
                    return &null
                }
            } else if id == SEC_PAYLOADS {
                ar->begin_read(sec, n)
                ar->read_payloads()
                if !ar->ok() {
                    return &null
                }
            } else if id == SEC_TREE {
                tree_at   = at
                tree_len  = n
                have_tree = true
            }
        }

        if !have_tree {
            ar->fail("serialized AST has no tree section")
            return &null
        }

        var unsafe *tu = ctx->alloc_init_pp<TranslationUnit>(ctx, ctx->fid, ctx->hoisted, gs)
        ar->tu = tu

        ar->begin_read(unsafe (data + tree_at), tree_len)
        var node_count = ar->r.get_count()
        io_tu(ar, tu)
        if !ar->ok() {
            return &null
        }

        if ar->nodes.size() != node_count {
            ar->fail("serialized AST node count does not match its tree")
            return &null
        }

        // Only now is the tree the context's: a failed read leaves it as it
        // was found.
        ctx->tu = tu

        // What the parser derives from the finished tree rather than parses.
        var rebuild = ASTParse(ctx, &null, gs, ASTParse::ParseMode::Full)
        rebuild.rebuild_derived()
        // What the reader built is a parsed tree, as the parser's is.
        tu->advance(TUStage::Parsing)
        return tu
    }
}
