/// --- The Kairo Project ---------------------- AST/Serialize/Archive.k --- ///
///
///   ASTArchive: the one object both directions of the AST serializer run
///   through. It is a writer or a reader (`reading`), and every field of
///   every node passes through one of its primitives, which either appends
///   the field to the stream or assigns it from the stream. A node class
///   therefore has ONE `io_` function (DeclIO.k, ExprIO.k, ...) and the two
///   directions cannot disagree about order or encoding.
///
///   What the archive owns:
///     - the encodings (bits, varints, ranges, tokens, strings);
///     - the tables a file is made of: strings, files, token payloads, nodes;
///     - node identity: a node is written inline the first time any field
///       reaches it and gets the next NODE ID; every later field writes that
///       id. The tree is a DAG in places (a record's members are in its
///       field list AND in a visibility group), so this is what writes a
///       node once.
///
///   What it must never do is write a process-local number. There is no
///   primitive that takes a SourceLocation, a fid or an imm index as an
///   integer: `range` stores offsets relative to a file, `tok` and `ident`
///   store spellings and payload records, `file_ref` stores a module path
///   and a content hash. `num*` are for numbers that mean the same thing in
///   every process (a count, a bit set, a position in a list).
///
///   The archive knows no node class. The family dispatchers reach it
///   through three hooks the serializer installs, which keeps this file
///   below the node files instead of in an import cycle with them.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "cstring"
ffi "c++" import "Native/KObjCache.hh"
ffi "c++" import "Native/KPlacement.hh"
ffi "c++" import "Native/Types.hh"

import AST::ASTSupport::FrozenList
import AST::Context::ASTContext::ASTContext
import AST::Context::DeclContext::DeclContext
import AST::Context::GlobalDisambigTable::GlobalDisambigTable
import AST::Context::TranslationUnit::TranslationUnit
import AST::Kind::DeclKind::DeclKind
import AST::Kind::ExprKind::ExprKind
import AST::Kind::PatternKind::PatternKind
import AST::Kind::StmtKind::StmtKind
import AST::Kind::TypeKind::TypeKind
import AST::Node::Base::{
    Decl,
    Expr,
    Pattern,
    Stmt,
    Type,
}
import AST::Node::Casting::isa
import AST::Serialize::ByteBuffer::{
    ByteReader,
    ByteWriter,
}
import AST::Serialize::Format::{
    CAT_DECL,
    CAT_EXPR,
    CAT_PATTERN,
    CAT_STMT,
    CAT_TYPE,
    PAY_CHAR,
    PAY_EXPANSION,
    PAY_FLOAT,
    PAY_INT,
    PAY_STRING,
    TOK_EXPANDED,
    TOK_IDENT,
    TOK_LITERAL,
    TOK_NONE,
    TOK_NUMBER,
    TOK_SENTINEL,
}
import AST::Serialize::StringTable::StringTable
import Lexer::ImmBig::{
    ImmBigFloat,
    ImmBigInt,
}
import Lexer::Immediate::{
    Immediate,
    ImmediateTable,
}
import Location::SourceLocation::SourceLocation
import Location::SourceManager::SourceManager
import Location::SourceRange::SourceRange
import Macro::Sentinel::MacroSentinel
import Memory::ArenaList::ArenaList
import Preprocessor::PreprocessorSymbolTable::PreprocessorSymbolTable
import Support::FileIO::Path::Path
import Token::Token::Token
import Token::TokenBuffer::TokenBuffer
import Token::TokenCacheManager::TokenCacheManager
import Token::TokenKind::TokenKind

/// One node of the tree, by id: its family and its family base pointer.
pub struct NodeSlot {
    pub var cat: u8           = 0
    pub var ptr: unsafe *void = &null
}

/// Another file a tree names (a macro's definition site, an import's
/// target). Identified by what is the same on every machine: its module
/// path, its file name and its bytes.
pub struct FileEntry {
    pub var name: string ///< module path, `::`-joined; empty for a pathless file.
    pub var base: string ///< file name, no directories.
    pub var size: u64    = 0
    pub var hash: string ///< xxh3-128 of its bytes, 32 hex digits.
    pub var fid:  u32    = u32::MAX ///< this process's fid; never written.
}

/// Which way an archive runs. Set once, by the writer's or the reader's
/// entry (ASTBinWriter::write, ASTBinReader::read), before any primitive:
/// every node function branches on it, so it can never change half way.
/// An archive is single-use; a second write would append to streams and
/// tables the first one filled.
///
/// Failure is NOT a mode: it is the sticky `failed` beside it. A failed
/// read keeps reading (the primitives yield zeros) so the node code needs
/// no error paths, and it must keep going the same way it started.
pub enum ArchiveMode derives u8 {
    Unbound, ///< constructed; neither entry has run.
    Writing,
    Reading,
}

pub class ASTArchive {
    //  mode and environment

    priv var _mode: ArchiveMode = ArchiveMode::Unbound
    pub var ctx:     unsafe *ASTContext               = &null
    pub var tu:      unsafe *TranslationUnit          = &null
    pub var sm:      unsafe *SourceManager            = &null
    pub var tcm:     unsafe *TokenCacheManager        = &null
    pub var psym:    unsafe *PreprocessorSymbolTable  = &null
    pub var gs:      unsafe *GlobalDisambigTable      = &null
    pub var fid:     u32                              = 0

    /// Raw id of this file's offset 0, and its size: a location inside
    /// [base, base + size] is this file's without asking the SourceManager.
    var self_base: u32 = 0
    var self_size: u64 = 0

    //  failure

    /// Set once, never cleared: the first thing that went wrong. Primitives
    /// keep running after it (a reader yields zeros), so node code has no
    /// error paths of its own; the serializer checks it at the end.
    pub var failed: bool   = false
    pub var error:  string

    //  streams

    /// ws[0] is the tree stream. A token payload met while writing it is
    /// written into ws[1..] and moved to `payload_w` when complete, so a
    /// payload's own payloads (the tokens of an f-string hole) are complete
    /// before it and every payload reference points backward.
    var ws:        [ByteWriter]
    var wtop:      usize        = 0
    var off_stack: [i64]

    pub var r: ByteReader

    pub var payload_w:     ByteWriter
    pub var payload_count: u32        = 0

    /// Start offset of the last range written to (read from) the current
    /// stream: ranges are deltas from it, since a node's ranges sit next to
    /// its parent's.
    var last_off: i64 = 0

    /// Bools are packed eight to a byte; any other primitive ends the byte.
    var wbit_acc: u8 = 0
    var wbit_n:   u8 = 0
    var rbit_acc: u8 = 0
    var rbit_n:   u8 = 0

    //  tables

    pub var strings: StringTable

    pub var files:    [FileEntry]
    var     file_ids: {u32: u32}

    pub var nodes:    [NodeSlot]
    var     node_ids: {u64: u32}

    var payload_ids:  {u64: u32}
    var payload_imm:  [u32]
    var payload_cls:  [u8]

    //  hooks into the node files (set by the serializer)

    /// Reads a node's kind from the stream and allocates its class.
    pub var alloc_hook: fn(unsafe *ASTArchive, u8) -> unsafe *void
    /// Runs the node's `io_` function, in either direction.
    pub var io_hook: fn(unsafe *ASTArchive, u8, unsafe *void)
    /// The DeclContext of a scope declaration.
    pub var dc_hook: fn(unsafe *Decl) -> unsafe *DeclContext

    //  statistics (reported by --print-stats and the round-trip gate)

    pub var stat_tokens:   u64 = 0
    pub var stat_payloads: u64 = 0

    pub fn ASTArchive(self) {
        self.ws.push_back(ByteWriter())
        var me = FileEntry{}
        self.files.push_back(me)
    }

    pub fn me(self) -> unsafe *ASTArchive {
        return unsafe ((&self) as unsafe *ASTArchive)
    }

    /// The direction every primitive takes. False while Unbound too, which
    /// is what the field this replaced read before either entry set it.
    pub fn reading(self) -> bool {
        return self._mode == ArchiveMode::Reading
    }

    /// The writer's entry: the only transition to Writing.
    pub fn begin_writing(self) {
        self._begin(ArchiveMode::Writing)
    }

    /// The reader's entry: the only transition to Reading. First thing in
    /// read(), before the payload section (read before the tree) and
    /// before its early failures, which already report through fail().
    pub fn begin_reading(self) {
        self._begin(ArchiveMode::Reading)
    }

    priv fn _begin(self, to: ArchiveMode) {
        eval if defined!(DEBUG) {
            if self._mode != ArchiveMode::Unbound {
                kairo::std::ice_fail(r"ASTArchive: an archive is single-use; this one already ran")
            }
        }

        self._mode = to
    }

    /// Binds the archive to one file's context. Both directions call it
    /// before anything else.
    pub fn bind(self,
                ctx:  unsafe *ASTContext,
                psym: unsafe *PreprocessorSymbolTable,
                gs:   unsafe *GlobalDisambigTable) {
        self.ctx  = ctx
        self.sm   = ctx->sm
        self.tcm  = ctx->tcm
        self.psym = psym
        self.gs   = gs
        self.fid  = ctx->fid
        self.self_base = self.sm->get_loc(self.fid, 0).raw()
        self.self_size = self.sm->get_file_size(self.fid) as u64
        self.files[0].fid = self.fid
    }

    pub fn fail(self, const msg: string) {
        if !self.failed {
            self.failed = true
            self.error  = msg
        }
    }

    pub fn ok(self) -> bool {
        if self.reading() && self.r.failed {
            self.fail("serialized AST is truncated or damaged")
        }

        return !self.failed
    }

    //  raw stream access

    fn flush_bits(self) {
        if self.wbit_n > 0 {
            self.ws[self.wtop].put_u8(self.wbit_acc)
            self.wbit_acc = 0
            self.wbit_n   = 0
        }
    }

    fn put(self, v: u64) {
        self.flush_bits()
        self.ws[self.wtop].put_varint(v)
    }

    fn put_s(self, v: i64) {
        self.flush_bits()
        self.ws[self.wtop].put_svarint(v)
    }

    fn get(self) -> u64 {
        self.rbit_n = 0
        return self.r.get_varint()
    }

    fn get_s(self) -> i64 {
        self.rbit_n = 0
        return self.r.get_svarint()
    }

    /// The tree stream, once the tree is written.
    pub fn tree_bytes(self) -> unsafe *ByteWriter {
        // Every payload stream pushed for a token was popped into payload_w:
        // one still open would be cut off here, with its bytes lost from
        // both sections.
        eval if defined!(DEBUG) {
            if self.wtop != 0 {
                kairo::std::ice_fail(r"ASTArchive: tree_bytes with a payload stream still open")
            }
        }

        self.flush_bits()
        return unsafe &self.ws[0]
    }

    /// Points the reader at one section's bytes.
    pub fn begin_read(self, data: unsafe *const u8, len: usize) {
        self.r        = ByteReader(data, len)
        self.rbit_n   = 0
        self.last_off = 0
    }

    priv fn _push_stream(self) {
        self.flush_bits()
        self.off_stack.push_back(self.last_off)
        self.wtop += 1
        if self.ws.size() <= self.wtop {
            self.ws.push_back(ByteWriter())
        } else {
            self.ws[self.wtop].clear()
        }

        self.last_off = 0
    }

    priv fn _pop_stream(self) {
        self.flush_bits()
        self.payload_w.put_writer(self.ws[self.wtop])
        self.wtop -= 1
        self.last_off = self.off_stack[self.off_stack.size() - 1]
        self.off_stack.pop_back()
    }

    //  numbers that mean the same in every process

    pub fn flag(self, @inout v: bool) {
        if self.reading() {
            if self.rbit_n == 0 {
                self.rbit_acc = self.r.get_u8()
                self.rbit_n   = 8
            }

            v = (self.rbit_acc & 1) != 0
            self.rbit_acc = self.rbit_acc >> 1
            self.rbit_n -= 1
            return
        }

        if v {
            self.wbit_acc = self.wbit_acc | ((1 as u8) << self.wbit_n)
        }

        self.wbit_n += 1
        if self.wbit_n == 8 {
            self.flush_bits()
        }
    }

    pub fn num8(self, @inout v: u8) {
        if self.reading() {
            v = self.get() as u8
        } else {
            self.put(v as u64)
        }
    }

    pub fn num16(self, @inout v: u16) {
        if self.reading() {
            v = self.get() as u16
        } else {
            self.put(v as u64)
        }
    }

    pub fn num32(self, @inout v: u32) {
        if self.reading() {
            v = self.get() as u32
        } else {
            self.put(v as u64)
        }
    }

    pub fn num64(self, @inout v: u64) {
        if self.reading() {
            v = self.get()
        } else {
            self.put(v)
        }
    }

    pub fn size_(self, @inout v: usize) {
        if self.reading() {
            v = self.get() as usize
        } else {
            self.put(v as u64)
        }
    }

    pub fn snum8(self, @inout v: i8) {
        if self.reading() {
            v = self.get_s() as i8
        } else {
            self.put_s(v as i64)
        }
    }

    pub fn snum32(self, @inout v: i32) {
        if self.reading() {
            v = self.get_s() as i32
        } else {
            self.put_s(v as i64)
        }
    }

    pub fn snum64(self, @inout v: i64) {
        if self.reading() {
            v = self.get_s()
        } else {
            self.put_s(v)
        }
    }

    /// An enum, by its numeric value. The format version covers the
    /// numbering: renumbering an enum that is written is a version bump.
    ///
    /// E is not known to be an integer here (a generic parameter converts
    /// to nothing), so the value moves through a same-sized integer: by
    /// width, never by address arithmetic, which keeps the bytes the same
    /// on either byte order.
    pub fn <E: type> en(self, @inout e: E) {
        var v: u32 = 0
        if !self.reading() {
            if sizeof(E) == 1 {
                var b: u8 = 0
                cxx::std::memcpy(unsafe ((unsafe &b) as unsafe *void), unsafe ((unsafe &e) as unsafe *const void), 1)
                v = b as u32
            } else if sizeof(E) == 2 {
                var h: u16 = 0
                cxx::std::memcpy(unsafe ((unsafe &h) as unsafe *void), unsafe ((unsafe &e) as unsafe *const void), 2)
                v = h as u32
            } else {
                cxx::std::memcpy(unsafe ((unsafe &v) as unsafe *void), unsafe ((unsafe &e) as unsafe *const void), 4)
            }

            self.put(v as u64)
            return
        }

        v = self.get() as u32
        if sizeof(E) == 1 {
            var b = v as u8
            cxx::std::memcpy(unsafe ((unsafe &e) as unsafe *void), unsafe ((unsafe &b) as unsafe *const void), 1)
        } else if sizeof(E) == 2 {
            var h = v as u16
            cxx::std::memcpy(unsafe ((unsafe &e) as unsafe *void), unsafe ((unsafe &h) as unsafe *const void), 2)
        } else {
            cxx::std::memcpy(unsafe ((unsafe &e) as unsafe *void), unsafe ((unsafe &v) as unsafe *const void), 4)
        }
    }

    /// A list's length: written from \p have, or read (bounded by what the
    /// stream could still hold).
    pub fn len_(self, have: usize) -> usize {
        if self.reading() {
            self.rbit_n = 0
            return self.r.get_count()
        }

        self.put(have as u64)
        return have
    }

    pub fn str(self, @inout s: string) {
        if self.reading() {
            var id = self.get() as u32
            if !self.strings.has(id) {
                self.fail("string index out of range")
                return
            }

            s = self.strings.get(id)
        } else {
            self.put(self.strings.intern(s) as u64)
        }
    }

    //  files

    priv fn _module_name(self, f: u32) -> string {
        var out: string = ""
        if self.gs == &null || self.psym == &null {
            return out
        }

        var unsafe *fctx = self.gs->get_context(f)
        if fctx == &null {
            return out
        }

        for var i: usize = 0; i < fctx->module_base.segments.size(); ++i {
            var unsafe *seg = self.psym->resolve(fctx->module_base.segments[i].name)
            if i > 0 {
                out += "::"
            }

            if seg != &null {
                out += *seg
            }
        }

        return out
    }

    priv fn _file_hash(self, f: u32) -> string {
        var buf? = self.sm->get_buffer(f)
        if buf != null && buf.is_valid() {
            return kairo::std::from_std_string<string>(
                kairo::objcache_hash128_bytes(buf.data(), buf.size()),
            )
        }

        return ""
    }

    /// Hash of this archive's own source file: the header's content hash.
    pub fn source_hash(self) -> string {
        return self._file_hash(self.fid)
    }

    /// Index of fid \p f in the file table (0 is this file), adding it on
    /// first use.
    pub fn file_ref(self, f: u32) -> u32 {
        if f == self.fid {
            return 0
        }

        var hit = self.file_ids.get(f)
        if hit != null {
            return *hit
        }

        var e = FileEntry{}
        e.name = self._module_name(f)
        e.base = Path::filename_of(self.sm->get_filename(f))
        e.size = self.sm->get_file_size(f) as u64
        e.hash = self._file_hash(f)
        e.fid  = f

        var idx = self.files.size() as u32
        self.files.push_back(e)
        self.file_ids[f] = idx
        return idx
    }

    /// The fid a file-table index names in THIS process: the loaded file
    /// with that module path, name, size and content. A file that is not
    /// loaded, or whose bytes changed, fails the read: the tree was built
    /// against text that is no longer there.
    pub fn file_fid(self, idx: u32) -> u32 {
        if (idx as usize) >= self.files.size() {
            self.fail("file index out of range")
            return self.fid
        }

        if self.files[idx as usize].fid != u32::MAX {
            return self.files[idx as usize].fid
        }

        var n = self.sm->file_count()
        for var f: usize = 0; f < n; ++f {
            var cand = f as u32
            if (self.sm->get_file_size(cand) as u64) != self.files[idx as usize].size {
                continue
            }

            if Path::filename_of(self.sm->get_filename(cand)) != self.files[idx as usize].base {
                continue
            }

            if self._module_name(cand) != self.files[idx as usize].name {
                continue
            }

            if self._file_hash(cand) != self.files[idx as usize].hash {
                continue
            }

            self.files[idx as usize].fid = cand
            return cand
        }

        var want = self.files[idx as usize].base
        self.fail(f"a file the serialized AST depends on is not loaded or has changed: {want}")
        return self.fid
    }

    /// The fid a location is in, or this file's for one in no file (a
    /// synthesized token keeps an invalid range and this file's table).
    priv fn _home_of(self, loc: SourceLocation) -> u32 {
        var id = loc.raw()
        if self._in_self(id) {
            return self.fid
        }

        var res = self.sm->resolve(loc)
        if res.fid == usize::MAX {
            return self.fid
        }

        return res.fid as u32
    }

    priv fn _in_self(self, id: u32) -> bool {
        return id >= self.self_base && ((id - self.self_base) as u64) <= self.self_size && id != 0
    }

    //  locations

    priv fn _write_loc(self, loc: SourceLocation) {
        var id = loc.raw()
        if id == 0 {
            self.put(0)
            return
        }

        if id == 0xFFFFFFFF {
            self.put(1)
            return
        }

        if !self._in_self(id) {
            var res = self.sm->resolve(loc)
            if res.fid != usize::MAX && (res.fid as u32) != self.fid {
                self.put(3)
                self.put(self.file_ref(res.fid as u32) as u64)
                self.put(res.offset as u64)
                return
            }
        }

        // In this file, or in no file at all (the alignment gap past a
        // file's end): kept relative to this file either way, so the
        // reloaded location is the same distance from the same text.
        self.put(2)
        self.put_s((id as i64) - (self.self_base as i64))
    }

    priv fn _read_loc(self) -> SourceLocation {
        var cls = self.get()
        if cls == 0 {
            return SourceLocation::from_raw(0)
        }

        if cls == 1 {
            return SourceLocation::from_raw(0xFFFFFFFF)
        }

        if cls == 2 {
            var rel = self.get_s()
            return SourceLocation::from_raw(((self.self_base as i64) + rel) as u32)
        }

        if cls == 3 {
            var f   = self.file_fid(self.get() as u32)
            var off = self.get() as usize
            if self.failed || off > self.sm->get_file_size(f) {
                self.fail("location outside its file")
                return SourceLocation::from_raw(0)
            }

            return self.sm->get_loc(f, off)
        }

        self.fail("unknown location class")
        return SourceLocation::from_raw(0)
    }

    /// A source range, file-relative. Four shapes, the first varint's low
    /// two bits saying which:
    ///   0  invalid (both ends zero)
    ///   1  starts in this file: start as a delta from the previous range's
    ///      start, then the length
    ///   2  starts in another file: file index, offset, length
    ///   3  anything else: each end as a location
    pub fn range(self, @inout r: SourceRange) {
        if self.reading() {
            var v   = self.get()
            var tag = v & 3
            if tag == 0 {
                r = SourceRange(SourceLocation::from_raw(0), SourceLocation::from_raw(0))
                return
            }

            if tag == 1 {
                var zz    = v >> 2
                var delta = ((zz >> 1) as i64) ^ (-((zz & 1) as i64))
                var rel   = self.last_off + delta
                var len   = self.get()
                self.last_off = rel
                var s = ((self.self_base as i64) + rel) as u32
                r = SourceRange(
                    SourceLocation::from_raw(s),
                    SourceLocation::from_raw(s + (len as u32)),
                )

                return
            }

            if tag == 2 {
                var f   = self.file_fid((v >> 2) as u32)
                var off = self.get() as usize
                var len = self.get()
                if self.failed || off > self.sm->get_file_size(f) {
                    self.fail("range outside its file")
                    r = SourceRange(SourceLocation::from_raw(0), SourceLocation::from_raw(0))
                    return
                }

                var s = self.sm->get_loc(f, off).raw()
                r = SourceRange(
                    SourceLocation::from_raw(s),
                    SourceLocation::from_raw(s + (len as u32)),
                )

                return
            }

            var a = self._read_loc()
            var b = self._read_loc()
            r = SourceRange(a, b)
            return
        }

        var s = r.start.raw()
        var e = r.end.raw()
        if s == 0 && e == 0 {
            self.put(0)
            return
        }

        if s != 0 && s != 0xFFFFFFFF && e != 0xFFFFFFFF && e >= s {
            var len    = (e - s) as u64
            var mine   = self._in_self(s)
            var other  = u32::MAX
            var offset: usize = 0
            if !mine {
                var res = self.sm->resolve(r.start)
                if res.fid != usize::MAX && (res.fid as u32) != self.fid {
                    other  = res.fid as u32
                    offset = res.offset
                }
            }

            if other == u32::MAX {
                var rel   = (s as i64) - (self.self_base as i64)
                var delta = rel - self.last_off
                self.last_off = rel
                var zz = ((delta as u64) << 1) ^ ((delta >> 63) as u64)
                self.put((zz << 2) | 1)
                self.put(len)
                return
            }

            self.put(((self.file_ref(other) as u64) << 2) | 2)
            self.put(offset as u64)
            self.put(len)
            return
        }

        self.put(3)
        self._write_loc(r.start)
        self._write_loc(r.end)
    }

    //  tokens

    pub fn table_of(self, f: u32) -> unsafe *ImmediateTable {
        return self.tcm->get_imm_table_for_fid(f)
    }

    priv fn _intern_in(self, f: u32, const s: string) -> u32 {
        var unsafe *tbl = self.table_of(f)
        if tbl == &null {
            self.fail("no immediate table for a file the serialized AST names")
            return u32::MAX
        }

        // A spelling with a byte past ASCII can be in the table twice, under
        // two hashes: the lexer mixes one value per decoded code point,
        // find_ident and intern_ident_copy one per byte, and the two agree
        // only on ASCII. The token this spelling came from held the
        // lexer's index, which is the first one interned, so such a name
        // is found by its bytes, lowest index first; find_ident would
        // answer the copy another pass interned by spelling.
        var raw  = s.raw()
        var wide = false
        for var i: usize = 0; i < s.size(); ++i {
            var c: u8 = raw[i]
            if c >= 128 {
                wide = true
                break
            }
        }

        if wide {
            var at: u32 = 0
            while true {
                var unsafe *d = tbl->get<Immediate::IdentData>(at)
                if d == &null {
                    break
                }

                if (d->len as usize) == s.size() && cxx::std::memcmp(
                    unsafe (d->ptr as unsafe *const void),
                    unsafe (raw as unsafe *const void),
                    s.size(),
                ) == 0 {
                    return at
                }

                at += 1
            }
        }

        var idx = tbl->find_ident(s)
        if idx != u32::MAX {
            return idx
        }

        // Table-owned bytes, never this context's: a context read for
        // verification is thrown away, and the table is not.
        return tbl->intern_ident_copy(s)
    }

    priv static fn _literal_class(k: TokenKind) -> u8 {
        if k == TokenKind::LitInt {
            return PAY_INT
        }

        if k == TokenKind::LitFloat {
            return PAY_FLOAT
        }

        if k == TokenKind::LitString {
            return PAY_STRING
        }

        if k == TokenKind::LitChar {
            return PAY_CHAR
        }

        return 0
    }

    /// A token: kind, range, and what its `imm` stands for. `imm` itself is
    /// an index into a per-process table and is never written: an
    /// identifier is its spelling, a literal is a payload record, a
    /// macro-expanded token is its chain of expansion records.
    pub fn tok(self, @inout t: Token) {
        self._tok_in(&t, u32::MAX)
    }

    /// \p rec_fid: the file whose table holds the expansion records of a
    /// chain being walked (unwrap_expansion pins it for the whole chain);
    /// u32::MAX for a token met in the tree, whose own range decides.
    priv fn _tok_in(self, @inout t: Token, rec_fid: u32) {
        self.stat_tokens += 1
        self.en<TokenKind>(&t.kind)
        self.range(&t.range)

        if self.reading() {
            // The tag has to be the one this kind is written with: a kind
            // that indexes a table must come back with an index INTO that
            // table, or the first reader of the token walks off its end.
            var tag     = self.get() as u8
            var lit_cls = ASTArchive::_literal_class(t.kind)
            var is_exp  = t.kind == TokenKind::TkMacroExpand
            var is_id   = t.kind == TokenKind::LitIdentifier
            if tag == TOK_NONE {
                t.imm = u32::MAX
            } else if tag == TOK_SENTINEL && is_exp {
                var n = self.get() as u32
                t.imm = u32::MAX - n
                if t.imm < (MacroSentinel::Threshold as u32) {
                    self.fail("macro sentinel out of range")
                    t.imm = u32::MAX
                }
            } else if tag == TOK_IDENT && is_id {
                var id = self.get() as u32
                if !self.strings.has(id) {
                    self.fail("string index out of range")
                    t.imm = u32::MAX
                    return
                }

                t.imm = self._intern_in(self._home_of(t.range.start), self.strings.get(id))
            } else if (tag == TOK_EXPANDED && is_exp) || (tag == TOK_LITERAL && lit_cls != 0) {
                var p    = self.get() as usize
                var want = if (is_exp) => PAY_EXPANSION else => lit_cls
                if p >= self.payload_imm.size() || self.payload_cls[p] != want {
                    self.fail("token payload index out of range or of the wrong class")
                    t.imm = u32::MAX
                    return
                }

                t.imm = self.payload_imm[p]
            } else if tag == TOK_NUMBER && (!is_exp) && (!is_id) && lit_cls == 0 {
                t.imm = self.get() as u32
            } else {
                self.fail("token payload tag does not match the token's kind")
                t.imm = u32::MAX
            }

            return
        }

        if t.imm == u32::MAX {
            self.put(TOK_NONE as u64)
            return
        }

        if t.kind == TokenKind::TkMacroExpand {
            if t.imm >= (MacroSentinel::Threshold as u32) {
                self.put(TOK_SENTINEL as u64)
                self.put((u32::MAX - t.imm) as u64)
                return
            }

            var home = rec_fid
            if home == u32::MAX {
                home = self._home_of(t.range.start)
            }

            self.put(TOK_EXPANDED as u64)
            self.put(self._payload_ref(PAY_EXPANSION, home, t.imm) as u64)
            return
        }

        var home = self._home_of(t.range.start)
        if t.kind == TokenKind::LitIdentifier {
            var unsafe *tbl = self.table_of(home)
            if tbl == &null {
                self.fail("identifier token in a file with no immediate table")
                self.put(TOK_NONE as u64)
                return
            }

            self.put(TOK_IDENT as u64)
            self.put(self.strings.intern(tbl->get_ident(t.imm)) as u64)
            return
        }

        var cls = ASTArchive::_literal_class(t.kind)
        if cls != 0 {
            self.put(TOK_LITERAL as u64)
            self.put(self._payload_ref(cls, home, t.imm) as u64)
            return
        }

        // Every other kind indexes no table: its imm is a number (the kind an
        // error token expected, the 0 of a token nothing ever wrote).
        self.put(TOK_NUMBER as u64)
        self.put(t.imm as u64)
    }

    /// An identifier index of THIS file's table that is stored outside a
    /// token (an attribute's name): its spelling. u32::MAX stays u32::MAX.
    pub fn ident(self, @inout imm: u32) {
        if self.reading() {
            var has = false
            self.flag(&has)
            if !has {
                imm = u32::MAX
                return
            }

            var s: string
            self.str(&s)
            imm = self._intern_in(self.fid, s)
            return
        }

        var has = imm != u32::MAX
        self.flag(&has)
        if has {
            var s = self.ctx->get_imm_table()->get_ident(imm)
            self.str(&s)
        }
    }

    //  token payloads

    priv fn _io_big_int(self, b: unsafe *ImmBigInt) {
        var n = self.len_(b->limbs.size() as usize)
        if self.reading() {
            b->limbs.clear()
            for var i: usize = 0; i < n; ++i {
                b->limbs.push_back(0)
            }
        }

        for var i: usize = 0; i < n; ++i {
            self.num64(&b->limbs[i])
        }

        self.size_(&b->bits)
        self.snum8(&b->sign)
    }

    priv fn _io_int(self, d: unsafe *Immediate::IntData) {
        self.range(&d->body)
        self.range(&d->prefix)
        self.range(&d->suffix)
        self.num64(&d->value_lo)
        self.num64(&d->value_hi)
        self.num16(&d->bits)
        self.num8(&d->base)
        self.num8(&d->flags)

        var has_big = d->big != &null
        self.flag(&has_big)
        if has_big {
            if self.reading() {
                d->big = kairo::std::create<ImmBigInt>(0 as usize)
            }

            self._io_big_int(d->big)
        }
    }

    priv fn _io_float(self, d: unsafe *Immediate::FloatData) {
        self.range(&d->body)
        self.range(&d->prefix)
        self.range(&d->suffix)
        self.num32(&d->bits)
        self.num8(&d->base)
        self.num8(&d->flags)

        // The value as its IEEE binary128 bits, low word first: exact, and
        // the same bytes on every host.
        var lo: u64 = 0
        var hi: u64 = 0
        if !self.reading() {
            var unsafe *src = unsafe ((unsafe &d->value_ieee) as unsafe *const u8)
            cxx::std::memcpy(unsafe ((unsafe &lo) as unsafe *void), unsafe (src as unsafe *const void), 8)
            cxx::std::memcpy(
                unsafe ((unsafe &hi) as unsafe *void),
                unsafe ((src + 8) as unsafe *const void),
                8,
            )
        }

        self.num64(&lo)
        self.num64(&hi)
        if self.reading() {
            var unsafe *dst = unsafe ((unsafe &d->value_ieee) as unsafe *u8)
            cxx::std::memcpy(unsafe (dst as unsafe *void), unsafe ((unsafe &lo) as unsafe *const void), 8)
            cxx::std::memcpy(
                unsafe ((dst + 8) as unsafe *void),
                unsafe ((unsafe &hi) as unsafe *const void),
                8,
            )
        }

        var has_big = d->big_float != &null
        self.flag(&has_big)
        if has_big {
            if self.reading() {
                d->big_float = kairo::std::create<ImmBigFloat>()
            }

            self._io_big_int(unsafe &d->big_float->mantissa)
            self.size_(&d->big_float->precision)
            self.snum64(&d->big_float->exponent)
            self.snum8(&d->big_float->sign)
            self.flag(&d->big_float->is_hex)
        }
    }

    /// The token run of one f-string hole: its tokens and the range of the
    /// braces around it.
    priv fn _io_hole_runs(self,
                          @inout exprs: llvm::SmallVector<(unsafe *TokenBuffer<16>, SourceRange), 4>,
                          @inout holes: llvm::SmallVector<Immediate::HoleSpec, 4>) {
        var n = self.len_(exprs.size() as usize)
        for var i: usize = 0; i < n; ++i {
            var rng: SourceRange
            var buf: unsafe *TokenBuffer<16> = &null
            if !self.reading() {
                buf = exprs[i].0
                rng = exprs[i].1
            } else {
                buf = kairo::std::create<TokenBuffer<16>>()
            }

            self.range(&rng)
            var have: usize = 0
            if buf != &null && !self.reading() {
                have = buf->size()
            }

            var m = self.len_(have)
            for var j: usize = 0; j < m; ++j {
                var t: Token
                if !self.reading() {
                    t = *buf->get(j)
                }

                self._tok_in(&t, u32::MAX)
                if self.reading() {
                    buf->append(t)
                }
            }

            if self.reading() {
                exprs.push_back((buf, rng))
            }
        }

        var h = self.len_(holes.size() as usize)
        for var i: usize = 0; i < h; ++i {
            var spec: Immediate::HoleSpec
            if !self.reading() {
                spec = holes[i]
            }

            self.range(&spec.spec)
            self.range(&spec.doc)
            if self.reading() {
                holes.push_back(spec)
            }
        }
    }

    /// A chained literal's next slot (`"a" "b"`): a payload of the same
    /// sheet and table, or none.
    priv fn _io_next(self, @inout next: u32, cls: u8, home: u32) {
        var has = next != u32::MAX
        self.flag(&has)
        if !has {
            if self.reading() {
                next = u32::MAX
            }

            return
        }

        if self.reading() {
            var p = self.get() as usize
            if p >= self.payload_imm.size() || self.payload_cls[p] != cls {
                self.fail("payload index out of range or of the wrong class")
                next = u32::MAX
                return
            }

            next = self.payload_imm[p]
        } else {
            self.put(self._payload_ref(cls, home, next) as u64)
        }
    }

    priv fn _io_string(self, d: unsafe *Immediate::StringData, home: u32) {
        self.range(&d->body)
        self.tok(&d->prefix)
        self.tok(&d->suffix)
        self.num8(&d->prefix_kind.bits)
        self._io_next(&d->next, PAY_STRING, home)
        self._io_hole_runs(&d->exprs, &d->holes)
    }

    priv fn _io_char(self, d: unsafe *Immediate::CharData, home: u32) {
        self.range(&d->body)
        self.tok(&d->prefix)
        self.tok(&d->suffix)
        self.num8(&d->prefix_kind.bits)
        self._io_next(&d->next, PAY_CHAR, home)
        self._io_hole_runs(&d->exprs, &d->holes)
    }

    /// One macro expansion record. Its `original_*` and `def_range` are a
    /// token (the one this hop wrapped), so they are written as one: an
    /// inner record of the same chain, or the original token, whose
    /// payload lives in the table of the file `def_range` is in.
    priv fn _io_expansion(self, d: unsafe *Immediate::MacroExpansionInfo, home: u32) {
        self.range(&d->invoke_range)

        var inner = Token(d->def_range, d->original_kind, d->original_imm)
        self._tok_in(&inner, home)
        if self.reading() {
            d->def_range     = inner.range
            d->original_kind = inner.kind
            d->original_imm  = inner.imm
        }

        var has_parent = d->parent_idx != u32::MAX
        self.flag(&has_parent)
        if has_parent {
            if self.reading() {
                var p = self.get() as usize
                if p >= self.payload_imm.size() || self.payload_cls[p] != PAY_EXPANSION {
                    self.fail("payload index out of range or of the wrong class")
                    d->parent_idx = u32::MAX
                } else {
                    d->parent_idx = self.payload_imm[p]
                }
            } else {
                self.put(self._payload_ref(PAY_EXPANSION, home, d->parent_idx) as u64)
            }
        } else if self.reading() {
            d->parent_idx = u32::MAX
        }

        // macro_name is a preprocessor SymbolID: another per-process table.
        // 0 and u32::MAX both mean "none" to its readers and are kept apart.
        var name_cls: u8 = 0
        var name: string
        if !self.reading() {
            if d->macro_name == u32::MAX {
                name_cls = 1
            } else if d->macro_name != 0 {
                var sp: unsafe *string = &null
                if self.psym != &null {
                    sp = self.psym->resolve(d->macro_name)
                }

                if sp == &null {
                    self.fail("macro expansion names a symbol the preprocessor table does not have")
                } else {
                    name_cls = 2
                    name     = *sp
                }
            }
        }

        self.num8(&name_cls)
        if name_cls == 2 {
            self.str(&name)
        }

        if self.reading() {
            if name_cls == 0 {
                d->macro_name = 0
            } else if name_cls == 1 {
                d->macro_name = u32::MAX
            } else if self.psym != &null {
                d->macro_name = self.psym->intern(name)
            } else {
                self.fail("no preprocessor symbol table to restore a macro name into")
            }
        }
    }

    /// Payload index of slot \p imm of sheet \p cls in file \p home's
    /// table, writing its record the first time it is met.
    priv fn _payload_ref(self, cls: u8, home: u32, imm: u32) -> u32 {
        var key = ((home as u64) << 36) | ((cls as u64) << 32) | (imm as u64)
        var hit = self.payload_ids.get(key)
        if hit != null {
            if *hit == u32::MAX {
                self.fail("token payload refers to itself")
                return 0
            }

            return *hit
        }

        var unsafe *tbl = self.table_of(home)
        if tbl == &null {
            self.fail("literal token in a file with no immediate table")
            return 0
        }

        self.payload_ids[key] = u32::MAX
        self._push_stream()
        self.put(cls as u64)
        self.put(self.file_ref(home) as u64)

        if cls == PAY_INT {
            var unsafe *d = tbl->get<Immediate::IntData>(imm)
            if d == &null {
                self.fail("integer literal slot out of range")
            } else {
                self._io_int(d)
            }
        } else if cls == PAY_FLOAT {
            var unsafe *d = tbl->get<Immediate::FloatData>(imm)
            if d == &null {
                self.fail("float literal slot out of range")
            } else {
                self._io_float(d)
            }
        } else if cls == PAY_STRING {
            var unsafe *d = tbl->get<Immediate::StringData>(imm)
            if d == &null {
                self.fail("string literal slot out of range")
            } else {
                // Owned text (stringify!, file!) has no source range to
                // re-read: the bytes themselves are the payload.
                var owned = d->owned_ptr != &null
                self.flag(&owned)
                if owned {
                    self.put(d->owned_len as u64)
                    self.flush_bits()
                    self.ws[self.wtop].put_bytes(
                        unsafe (d->owned_ptr as unsafe *const u8),
                        d->owned_len as usize,
                    )
                }

                self._io_string(d, home)
            }
        } else if cls == PAY_CHAR {
            var unsafe *d = tbl->get<Immediate::CharData>(imm)
            if d == &null {
                self.fail("char literal slot out of range")
            } else {
                self._io_char(d, home)
            }
        } else {
            var unsafe *d = tbl->get<Immediate::MacroExpansionInfo>(imm)
            if d == &null {
                self.fail("macro expansion record out of range")
            } else {
                self._io_expansion(d, home)
            }
        }

        self._pop_stream()
        var idx = self.payload_count
        self.payload_count += 1
        self.payload_ids[key] = idx
        self.stat_payloads += 1
        return idx
    }

    /// Reads the payload section: every record becomes a slot in its home
    /// file's immediate table, in order, so each reference a later record
    /// or the tree makes is to a slot that already exists.
    pub fn read_payloads(self) {
        var count = self.r.get_count()
        for var i: usize = 0; i < count; ++i {
            if self.failed || self.r.failed {
                return
            }

            self.last_off = 0
            var cls  = self.get() as u8
            var home = self.file_fid(self.get() as u32)
            var unsafe *tbl = self.table_of(home)
            if tbl == &null {
                self.fail("no immediate table for a payload's file")
                return
            }

            var imm = u32::MAX
            if cls == PAY_INT {
                imm = tbl->create<Immediate::IntData>()
                self._io_int(tbl->get<Immediate::IntData>(imm))
            } else if cls == PAY_FLOAT {
                imm = tbl->create<Immediate::FloatData>()
                self._io_float(tbl->get<Immediate::FloatData>(imm))
            } else if cls == PAY_STRING {
                var owned = false
                self.flag(&owned)
                if owned {
                    var n = self.len_(0)
                    var p = self.r.get_bytes(n)
                    if self.r.failed {
                        return
                    }

                    imm = tbl->intern_bytes_copy(unsafe (p as kairo::std::ConstPtr<u8>), n)
                } else {
                    imm = tbl->create<Immediate::StringData>()
                }

                self._io_string(tbl->get<Immediate::StringData>(imm), home)
            } else if cls == PAY_CHAR {
                imm = tbl->create<Immediate::CharData>()
                self._io_char(tbl->get<Immediate::CharData>(imm), home)
            } else if cls == PAY_EXPANSION {
                imm = tbl->create<Immediate::MacroExpansionInfo>()
                self._io_expansion(tbl->get<Immediate::MacroExpansionInfo>(imm), home)
            } else {
                self.fail("unknown payload class")
                return
            }

            self.payload_imm.push_back(imm)
            self.payload_cls.push_back(cls)
            self.stat_payloads += 1
        }
    }

    //  nodes

    /// The first half of writing a reference to the node at family base
    /// pointer \p p: 0 for null, id + 2 for a node already written, and 1
    /// the first time, when the node gets its id and the caller must write
    /// the node itself next (true).
    priv fn _begin_write(self, cat: u8, p: unsafe *void) -> bool {
        if p == &null {
            self.put(0)
            return false
        }

        var key = (p as usize) as u64
        var hit = self.node_ids.get(key)
        if hit != null {
            self.put((*hit as u64) + 2)
            return false
        }

        var id = self.nodes.size() as u32
        self.node_ids[key] = id
        var slot = NodeSlot{}
        slot.cat = cat
        slot.ptr = p
        self.nodes.push_back(slot)

        self.put(1)
        return true
    }

    /// The first half of reading one: \p out is null, the node the id
    /// names, or a newly allocated node whose fields the caller must read
    /// next (true).
    priv fn _begin_read(self, cat: u8, @inout out: unsafe *void) -> bool {
        out = &null
        var v = self.get()
        if v == 0 || self.failed || self.r.failed {
            return false
        }

        if v >= 2 {
            var id = (v - 2) as usize
            if id >= self.nodes.size() || self.nodes[id].cat != cat {
                self.fail("node reference to the wrong kind of node")
                return false
            }

            out = self.nodes[id].ptr
            return false
        }

        var unsafe *p = self.alloc_hook(self.me(), cat)
        if p == &null {
            self.fail("unknown node kind")
            return false
        }

        // Registered before its fields are read: a child's back-pointer to
        // this node (a generic parameter's owner, a scope's parent) is a
        // reference to an id that must already resolve.
        var slot = NodeSlot{}
        slot.cat = cat
        slot.ptr = p
        self.nodes.push_back(slot)

        out = p
        return true
    }

    priv fn _write_ref(self, cat: u8, p: unsafe *void) {
        if self._begin_write(cat, p) {
            self.io_hook(self.me(), cat, p)
        }
    }

    priv fn _read_ref(self, cat: u8) -> unsafe *void {
        var p: unsafe *void = &null
        if self._begin_read(cat, &p) {
            self.io_hook(self.me(), cat, p)
        }

        return p
    }

    /// An expression reference whose node, when it is met for the first
    /// time (true), the CALLER writes or reads. For a caller that walks a
    /// chain of nodes in a loop instead of recursing down it: the left
    /// spine of `a + b + c + ...` is as deep as the expression is long,
    /// and the parser builds it without recursion.
    pub fn expr_begin(self, @inout p: unsafe *Expr) -> bool {
        if self.reading() {
            var q: unsafe *void = &null
            var fresh = self._begin_read(CAT_EXPR, &q)
            p = unsafe (q as unsafe *Expr)
            return fresh
        }

        return self._begin_write(CAT_EXPR, unsafe (p as unsafe *void))
    }

    /// A recovery node is an object of the class its `recovery_kind` names
    /// with `kind` set to the family's Recovery kind, so `isa` (which
    /// compares `kind`) is asked with the class's own kind in place.
    priv fn <T: type> _decl_is(self, d: unsafe *Decl) -> bool {
        if d->kind != DeclKind::RecoveryDecl {
            return isa<T>(d)
        }

        d->kind = d->recovery_kind
        var ok = isa<T>(d)
        d->kind = DeclKind::RecoveryDecl
        return ok
    }

    priv fn <T: type> _expr_is(self, e: unsafe *Expr) -> bool {
        if e->kind != ExprKind::RecoveryExpr {
            return isa<T>(e)
        }

        e->kind = e->recovery_kind
        var ok = isa<T>(e)
        e->kind = ExprKind::RecoveryExpr
        return ok
    }

    priv fn <T: type> _stmt_is(self, s: unsafe *Stmt) -> bool {
        if s->kind != StmtKind::RecoveryStmt {
            return isa<T>(s)
        }

        s->kind = s->recovery_kind
        var ok = isa<T>(s)
        s->kind = StmtKind::RecoveryStmt
        return ok
    }

    priv fn <T: type> _type_is(self, t: unsafe *Type) -> bool {
        if t->kind != TypeKind::RecoveryType {
            return isa<T>(t)
        }

        t->kind = t->recovery_kind
        var ok = isa<T>(t)
        t->kind = TypeKind::RecoveryType
        return ok
    }

    priv fn <T: type> _pattern_is(self, p: unsafe *Pattern) -> bool {
        if p->kind != PatternKind::RecoveryPattern {
            return isa<T>(p)
        }

        p->kind = p->recovery_kind
        var ok = isa<T>(p)
        p->kind = PatternKind::RecoveryPattern
        return ok
    }

    /// A pointer to a declaration, whatever the field's static class: the
    /// base classes and every node class go through here. A reader checks
    /// that the node it got IS a T before the field holds it.
    pub fn <T: type> decl(self, @inout p: unsafe *T) {
        if self.reading() {
            var unsafe *d = unsafe (self._read_ref(CAT_DECL) as unsafe *Decl)
            if d != &null && !self._decl_is<T>(d) {
                self.fail("declaration of the wrong class for its field")
                p = &null
                return
            }

            p = unsafe (d as unsafe *T)
            return
        }

        var d: unsafe *Decl = unsafe (p as unsafe *Decl)
        self._write_ref(CAT_DECL, unsafe (d as unsafe *void))
    }

    pub fn <T: type> expr(self, @inout p: unsafe *T) {
        if self.reading() {
            var unsafe *e = unsafe (self._read_ref(CAT_EXPR) as unsafe *Expr)
            if e != &null && !self._expr_is<T>(e) {
                self.fail("expression of the wrong class for its field")
                p = &null
                return
            }

            p = unsafe (e as unsafe *T)
            return
        }

        var e: unsafe *Expr = unsafe (p as unsafe *Expr)
        self._write_ref(CAT_EXPR, unsafe (e as unsafe *void))
    }

    pub fn <T: type> stmt(self, @inout p: unsafe *T) {
        if self.reading() {
            var unsafe *s = unsafe (self._read_ref(CAT_STMT) as unsafe *Stmt)
            if s != &null && !self._stmt_is<T>(s) {
                self.fail("statement of the wrong class for its field")
                p = &null
                return
            }

            p = unsafe (s as unsafe *T)
            return
        }

        var s: unsafe *Stmt = unsafe (p as unsafe *Stmt)
        self._write_ref(CAT_STMT, unsafe (s as unsafe *void))
    }

    pub fn <T: type> type_(self, @inout p: unsafe *T) {
        if self.reading() {
            var unsafe *t = unsafe (self._read_ref(CAT_TYPE) as unsafe *Type)
            if t != &null && !self._type_is<T>(t) {
                self.fail("type of the wrong class for its field")
                p = &null
                return
            }

            p = unsafe (t as unsafe *T)
            return
        }

        var t: unsafe *Type = unsafe (p as unsafe *Type)
        self._write_ref(CAT_TYPE, unsafe (t as unsafe *void))
    }

    pub fn <T: type> pattern(self, @inout p: unsafe *T) {
        if self.reading() {
            var unsafe *q = unsafe (self._read_ref(CAT_PATTERN) as unsafe *Pattern)
            if q != &null && !self._pattern_is<T>(q) {
                self.fail("pattern of the wrong class for its field")
                p = &null
                return
            }

            p = unsafe (q as unsafe *T)
            return
        }

        var q: unsafe *Pattern = unsafe (p as unsafe *Pattern)
        self._write_ref(CAT_PATTERN, unsafe (q as unsafe *void))
    }

    /// A pointer to a DeclContext: the TU's, or a scope declaration's (by
    /// the declaration that owns it). No other DeclContext exists in a
    /// parsed tree.
    pub fn dc(self, @inout p: unsafe *DeclContext) {
        var unsafe *tu_dc = unsafe (self.tu as unsafe *DeclContext)
        if self.reading() {
            var tag = self.get()
            if tag == 0 {
                p = &null
            } else if tag == 1 {
                p = tu_dc
            } else {
                var owner: unsafe *Decl = &null
                self.decl<Decl>(&owner)
                if owner == &null {
                    self.fail("scope reference without its declaration")
                    p = &null
                    return
                }

                p = self.dc_hook(owner)
                if p == &null {
                    self.fail("scope reference to a declaration that is not a scope")
                }
            }

            return
        }

        if p == &null {
            self.put(0)
            return
        }

        if p == tu_dc {
            self.put(1)
            return
        }

        var unsafe *owner = p->dc_owner
        if owner == &null {
            self.fail("a DeclContext of another translation unit is reachable from the tree")
            self.put(0)
            return
        }

        self.put(2)
        self.decl<Decl>(&owner)
    }

    //  lists

    /// Storage for a list read from the stream: \p n default-constructed
    /// elements in the AST arena.
    pub fn <T: type> alloc_list(self, @inout l: FrozenList<T>, n: usize) {
        if n == 0 {
            l.items = &null
            l.count = 0
            return
        }

        l.items = self.ctx->alloc_array<T>(n)
        l.count = n
        cxx::std::memset(unsafe (l.items as unsafe *void), 0, sizeof(T) * n)
        for var i: usize = 0; i < n; ++i {
            kairo::construct_at<T>(unsafe ((l.items + i) as unsafe *void))
        }
    }

    /// A list of plain structs: its length, with storage made on read. The
    /// caller then runs each element through its own `io_` function.
    pub fn <T: type> list(self, @inout l: FrozenList<T>) -> usize {
        var n = self.len_(l.count)
        if self.reading() {
            self.alloc_list<T>(&l, n)
        }

        return n
    }

    pub fn <T: type> decl_list(self, @inout l: FrozenList<unsafe *T>) {
        var n = self.list<unsafe *T>(&l)
        for var i: usize = 0; i < n; ++i {
            self.decl<T>(&l.items[i])
        }
    }

    pub fn <T: type> expr_list(self, @inout l: FrozenList<unsafe *T>) {
        var n = self.list<unsafe *T>(&l)
        for var i: usize = 0; i < n; ++i {
            self.expr<T>(&l.items[i])
        }
    }

    pub fn <T: type> stmt_list(self, @inout l: FrozenList<unsafe *T>) {
        var n = self.list<unsafe *T>(&l)
        for var i: usize = 0; i < n; ++i {
            self.stmt<T>(&l.items[i])
        }
    }

    pub fn <T: type> type_list(self, @inout l: FrozenList<unsafe *T>) {
        var n = self.list<unsafe *T>(&l)
        for var i: usize = 0; i < n; ++i {
            self.type_<T>(&l.items[i])
        }
    }

    pub fn <T: type> pattern_list(self, @inout l: FrozenList<unsafe *T>) {
        var n = self.list<unsafe *T>(&l)
        for var i: usize = 0; i < n; ++i {
            self.pattern<T>(&l.items[i])
        }
    }

    pub fn tok_list(self, @inout l: FrozenList<Token>) {
        var n = self.list<Token>(&l)
        for var i: usize = 0; i < n; ++i {
            self.tok(&l.items[i])
        }
    }

    /// A scope's declaration list (ArenaList: appended, never frozen).
    pub fn decl_arena_list(self, @inout l: ArenaList<unsafe *Decl>) {
        var n = self.len_(l.size())
        for var i: usize = 0; i < n; ++i {
            var d: unsafe *Decl = &null
            if !self.reading() {
                d = *l.get(i)
            }

            self.decl<Decl>(&d)
            if self.reading() {
                l.push(d)
            }
        }
    }

    //  slots the format does not store

    /// The debug half of "Sema slots are not serialized": a slot the writer
    /// skips must be in the state a freshly allocated node has, or the tree
    /// is not a parsed tree (or the slot is the parser's after all) and the
    /// reloaded tree would differ from it. A failed write, never a silent
    /// difference.
    pub fn <T: type> sema_null(self, p: unsafe *T, const what: string) {
        if self.reading() {
            return
        }

        if p != &null {
            self.fail(f"slot the serializer skips is set on a parsed tree: {what}")
        }
    }

    pub fn sema_zero(self, v: u64, const what: string) {
        if self.reading() {
            return
        }

        if v != 0 {
            self.fail(f"slot the serializer skips is set on a parsed tree: {what}")
        }
    }

    pub fn sema_false(self, v: bool, const what: string) {
        if self.reading() {
            return
        }

        if v {
            self.fail(f"slot the serializer skips is set on a parsed tree: {what}")
        }
    }

    /// The general form: \p ok says the slot still holds its default.
    pub fn sema_is(self, ok: bool, const what: string) {
        if self.reading() {
            return
        }

        if !ok {
            self.fail(f"slot the serializer skips is set on a parsed tree: {what}")
        }
    }
}
