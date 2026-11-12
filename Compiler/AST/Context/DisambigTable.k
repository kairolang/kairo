/// --- The Kairo Project ------------------ AST/Context/DisambigTable.k --- ///
///
///   DisambigTable: a file's hoisted scope table (name -> coarse kind) that the
///   parser consults to disambiguate, with its entries, nodes and lookup
///   result. Allocated from its ASTContext's index arena (ASTContext::hoisted).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/MapVector.h"
ffi "c++" import "Native/KPlacement.hh" // construct_at, destroy_in_place
ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"
ffi "c++" import "cstring"
ffi "c++" import "utility"

import AST::Context::ASTContext::ASTContext
import Lexer::Immediate::ImmediateTable
import Location::SourceRange::SourceRange
import Token::Token::Token
import std::io

/// Coarse declaration kind enough for parser disambiguation.
/// Sema refines these into concrete DeclKind values.
pub enum DisambigKind derives u8 {
    ClassType,     ///< class Foo
    EnumType,      ///< enum Foo
    UnionType,     ///< union Foo
    StructType,    ///< struct Foo
    InterfaceType, ///< interface Foo
    TypeAlias,     ///< type Foo = ...
    Function,      ///< fn foo
    Operator,      ///< fn op +
    Variable,      ///< var foo / const foo
    ProcMacro,     ///< @foo
    BasicMacro,    ///< foo!
    Module,        ///< namespace / module block
}

/// A single entry in the hoisted scope table.
///
/// \c decl is null for declarations originating from C++ FFI use
/// \c origin for source location in that case.
/// \c is_foreign is true for symbols introduced via import, not declared
/// locally in the file being indexed.
///
/// \c generic mirrors TemplateParams::is_generic() on the declaring node:
/// true iff the decl carries explicit `<T>` type params OR is a Primary
/// specialization form. Explicit/Partial specializations do NOT set it
/// genericness of a name is owned by the primary declaration. The zero
/// value (false) is the safe default: an entry never accidentally reads
/// as generic.
pub class DisambigEntry {
    struct DeclEntry { // 128 bits
        pub var origin: SourceRange
    }

    pub var extend_of_name: u32             = u32::MAX ///< imm ident index of the extended type's name.
    pub var name:           u32             = u32::MAX ///< imm ident index of this entry's name.
    pub var kind:           DisambigKind
    pub var decl:           Self::DeclEntry
    pub var extend_of:      Self::DeclEntry
    pub var generic:        bool            = false ///< See class docs; from TemplateParams::is_generic().
    pub var is_foreign:     bool ///< True if introduced via import.
    pub var extended:       bool ///< True if this is an extended impl of an existing type, not a new declaration.

    fn is_type(self) -> bool {
        match self.kind {
            case DisambigKind::ClassType {
                return true
            } case DisambigKind::EnumType {
                return true
            } case DisambigKind::UnionType {
                return true
            } case DisambigKind::StructType {
                return true
            } case DisambigKind::InterfaceType {
                return true
            } case DisambigKind::TypeAlias {
                return true
            } default {
                return false
            }
        }
    }

    fn is_value(self) -> bool {
        return self.kind == DisambigKind::Function
            || self.kind == DisambigKind::Operator
            || self.kind == DisambigKind::Variable
    }

    fn is_macro(self) -> bool {
        return self.kind == DisambigKind::ProcMacro || self.kind == DisambigKind::BasicMacro
    }

    pub fn is_generic(self) -> bool {
        return self.generic
    }

    fn is_extension(self) -> bool {
        return self.extended
    }

    fn is_from_foreign(self) -> bool {
        return self.is_foreign
    }
}

/// One node in the hoisted scope trie.
///
/// \c entries holds names declared at this scope level.
/// \c children holds nested scopes (modules, classes, enums with variants).
///
/// Keyed on the u32 imm ident index, WIDENED to u64: lookups arrive
/// unguarded, and u32(-1) is DenseMap<u32>'s empty key, which asserts even
/// on a find. Memory is arena-owned; the destructor intentionally leaks
/// child pointers since the arena reclaims everything at once.
///
/// MapVector, in declaration (insertion) order: _collect_extensions and the
/// dumps walk these, and which extension comes first is observable. Each
/// name's entry list lives in the context arena, the map holds its address
/// -- lookup() hands it out as LookupResult.entries, and MapVector's values
/// move as it grows.
pub class DisambigNode {
    pub var entries:  llvm::MapVector<u64, unsafe *cxx::std::vector<DisambigEntry>>
    pub var children: llvm::MapVector<u64, unsafe *DisambigNode>

    fn DisambigNode(self) { }

    // NOTE: no op delete here. The arena reclaims the NODE STRUCT, but
    // `entries` and `children` are MapVectors with heap storage (the entry
    // vecs are cleanup-registered on their own). Their destructors
    // must still run, so DisambigNode is allocated via
    // alloc_init_index_cleanup() and torn down through ASTContext's cleanup
    // registry. Defining a no-op op delete here would silently defeat that.

    /// Inserts \p entry under \p name. First declaration wins; duplicates ignored.
    /// Sema will catch redefinition errors with full source context.
    fn insert(self, name: u32, entry: DisambigEntry, ctx: unsafe *ASTContext) {
        var **slot = &self.entries[name]
        if *slot == &null {
            *slot = ctx->alloc_init_index_cleanup<cxx::std::vector<DisambigEntry>>()
        }

        (*slot)->push_back(entry)
    }

    /// Returns the child scope for \p name, creating it if absent.
    fn get_or_create_child(self, name: u32, ctx: unsafe *ASTContext) -> unsafe *DisambigNode {
        var unsafe **slot = unsafe &self.children[name]
        if *slot == &null {
            *slot = ctx->alloc_init_index_cleanup<DisambigNode>()
        }

        return *slot
    }

    /// Returns the child scope for \p name, or null if absent.
    pub fn get_child(self, name: u32) -> unsafe *DisambigNode {
        var unsafe *it = self.children.find(name as u64)
        if it == self.children.end() {
            return &null
        }

        return it->second
    }

    /// Looks up \p name at this scope level only. Does not search children.
    fn lookup(self, name: u32) -> unsafe *cxx::std::vector<DisambigEntry> {
        var unsafe *it = self.entries.find(name as u64)
        if it == self.entries.end() {
            return &null
        }

        return it->second
    }

    fn has_child(self, name: u32) -> bool {
        return self.children.count(name) > 0
    }

    fn has_entry(self, name: u32) -> bool {
        return self.entries.count(name) > 0
    }
}

/// Result of a lookup into DisambigTable.
/// Carries both the entry and the scope node it was found in,
/// so the parser can continue walking children if needed.
pub class LookupResult {
    pub var entries: unsafe *cxx::std::vector<DisambigEntry> ///< Null if not found.
    pub var node:    unsafe *DisambigNode ///< Scope where entry lives. Null if not found.

    pub fn found(self) -> bool {
        return self.entries != &null && !self.entries->empty()
    }

    fn is_type(self) -> bool {
        return self.found() && (*self.entries)[0].is_type()
    }

    fn is_value(self) -> bool {
        return self.found() && (*self.entries)[0].is_value()
    }

    fn is_macro(self) -> bool {
        return self.found() && (*self.entries)[0].is_macro()
    }

    static fn not_found() -> LookupResult {
        var r = LookupResult{}
        r.entries = &null
        r.node    = &null
        return r
    }

    pub fn first(self) -> unsafe *DisambigEntry {
        if self.entries == &null || self.entries->empty() {
            return &null
        }

        return unsafe &(*self.entries)[0]
    }

    fn is_overloaded(self) -> bool {
        return self.entries != &null && self.entries->size() > 1
    }

    fn is_extended(self) -> bool {
        if self.entries == &null {
            return false
        }

        for entry in *self.entries {
            if entry.extended {
                return true
            }
        }

        return false
    }

    fn extensions(self) -> cxx::std::vector<unsafe *DisambigEntry> {
        var result = cxx::std::vector<unsafe *DisambigEntry>()
        if self.entries == &null {
            return result
        }

        for var i: usize = 0; i < self.entries->size(); ++i {
            if (*self.entries)[i].extended {
                result.push_back(unsafe &(*self.entries)[i])
            }
        }

        return result
    }

    fn non_extensions(self) -> cxx::std::vector<unsafe *DisambigEntry> {
        var result = cxx::std::vector<unsafe *DisambigEntry>()
        if self.entries == &null {
            return result
        }

        for var i: usize = 0; i < self.entries->size(); ++i {
            if !(*self.entries)[i].extended {
                result.push_back(unsafe &(*self.entries)[i])
            }
        }

        return result
    }
}

/// Hierarchical symbol table built by the index pass over a single file
/// and its transitive imports.
///
/// Structured as a trie of \c DisambigNode instances keyed on the u32 imm ident index.
/// Lookup for a qualified name like \c foo::bar::Baz costs one hashmap
/// lookup per segment O(1) per segment, O(depth) total.
///
/// \par Parser API
/// The parser holds a \c *DisambigTable and calls:
///   - \c lookup(ident)         for unqualified names
///   - \c lookup(chain)         for qualified names from a \c ChainExpr
///   - \c is_type / is_value    for quick boolean disambiguation
///   - \c enter(name)           to get a child \c DisambigNode for manual walking
///
/// \par Population
/// The \c Indexer calls \c insert() and \c insert_into() during the index
/// pass. After the pass completes the scope is read-only.
pub class DisambigTable {
    priv var _root: DisambigNode
    priv var _ctx:  unsafe *ASTContext

    fn DisambigTable(self, ctx: unsafe *ASTContext) {
        self._ctx = ctx
    }

    /// # Interning
    ///
    /// Post interner-consolidation the key space IS the per-fid ImmediateTable
    /// ident index, unified with Token.imm. String inputs (synth names, path
    /// segments spanning multiple tokens) are copied in via intern_ident_copy;
    /// token inputs use their resolved imm directly (see lookup_tok / intern_tok).

    priv fn _tbl(self) -> unsafe *ImmediateTable {
        return self._ctx->get_imm_table()
    }

    /// Interns \p s and returns its imm ident index. String path only prefer
    /// \c intern_tok when a token is in hand to avoid the byte copy.
    pub fn intern(self, const s: string) -> u32 {
        return self._tbl()->intern_ident_copy(s)
    }

    /// Imm ident index for an identifier token, using its resolved imm directly.
    /// Returns u32(-1) for non-identifier tokens (never matches an entry).
    pub fn intern_tok(self, tok: Token) -> u32 {
        return self._ctx->get_ident_imm(tok)
    }

    fn str(self, h: u32) -> string {
        return self._tbl()->get_ident(h)
    }

    /// # Population

    /// Inserts \p entry at root scope under \p name.
    pub fn insert(self, const name: string, entry: DisambigEntry) {
        var key = self.intern(name)
        entry.name = key
        self._root.insert(key, entry, self._ctx)
    }

    /// Inserts \p entry at the scope reached by walking \p scope_path from root.
    /// Creates intermediate scope nodes as needed.
    /// \p scope_path is the sequence of parent names, e.g. ["A", "B"] for A::B::Foo.
    pub fn insert_into(self,
                       @inout scope_path: cxx::std::vector<string>,
                       const name:        string,
                       entry:             DisambigEntry) {
        var unsafe *node = unsafe &self._root
        for *s in scope_path {
            var k = self.intern(*s)
            node = node->get_or_create_child(k, self._ctx)
        }

        var key = self.intern(name)
        entry.name = key
        node->insert(key, entry, self._ctx)
    }

    /// # Parser API

    /// Looks up an unqualified name at root scope.
    pub fn lookup(self, const name: string) -> LookupResult {
        var key = self.intern(name)
        return self._lookup_in(unsafe &self._root, key)
    }

    /// Looks up an already-interned imm ident index at root scope. O(1).
    fn lookup(self, name: u32) -> LookupResult {
        return self._lookup_in(unsafe &self._root, name)
    }

    /// Looks up an identifier token at root scope by its resolved imm. O(1),
    /// no byte copy the sanctioned hot-path lookup for the parser.
    fn lookup_tok(self, tok: Token) -> LookupResult {
        var key = self.intern_tok(tok)
        if key == u32::MAX {
            return LookupResult::not_found()
        }

        return self._lookup_in(unsafe &self._root, key)
    }

    /// Non-mutating twins of lookup(string) / lookup(segments), for a probe
    /// from ANOTHER file's parse (GlobalDisambigTable::lookup_in). The
    /// string overloads intern their key, i.e. write this file's imm table
    /// from a thread that does not own it while the owner's parser interns
    /// too -- two unsynchronized writers on `synth_names` and the ident hash.
    /// A spelling the table has never seen cannot key an entry, so a find
    /// miss answers not-found exactly as an intern would have.
    fn lookup_existing(self, const name: string) -> LookupResult {
        var key = self._tbl()->find_ident(name)
        if key == u32::MAX {
            return LookupResult::not_found()
        }

        return self._lookup_in(unsafe &self._root, key)
    }

    fn lookup_existing(self, segments: unsafe *cxx::std::vector<string>) -> LookupResult {
        if segments->empty() {
            return LookupResult::not_found()
        }

        var unsafe *tbl  = self._tbl()
        var unsafe *node = unsafe &self._root
        for var i: usize = 0; i < segments->size() - 1; ++i {
            var k = tbl->find_ident((*segments)[i])
            if k == u32::MAX {
                return LookupResult::not_found()
            }

            var unsafe *next = node->get_child(k)
            if next == &null {
                return LookupResult::not_found()
            }

            node = next
        }

        var last = tbl->find_ident(segments->back())
        if last == u32::MAX {
            return LookupResult::not_found()
        }

        return self._lookup_in(node, last)
    }

    /// Walks a qualified name chain and returns the final entry.
    /// \p segments is the sequence of names from a parsed \c ChainExpr,
    /// e.g. ["foo", "bar", "Baz"] for foo::bar::Baz.
    /// Returns \c LookupResult::not_found() if any segment is missing.
    fn lookup(self, segments: unsafe *cxx::std::vector<string>) -> LookupResult {
        if segments->empty() {
            return LookupResult::not_found()
        }

        var unsafe *node = unsafe &self._root
        for var i: usize = 0; i < segments->size() - 1; ++i {
            var        k     = self.intern((*segments)[i])
            var unsafe *next = node->get_child(k)
            if next == &null {
                return LookupResult::not_found()
            }

            node = next
        }

        var last = self.intern(segments->back())
        return self._lookup_in(node, last)
    }

    fn insert_extension(self,
                        scope_path: unsafe *cxx::std::vector<string>,
                        const name: string,
                        entry:      DisambigEntry) {
        eval if defined!(DEBUG) {
            if !entry.extended {
                kairo::std::ice_fail(
                    r"insert_extension: entry.extended must be true",
                )
            }
        }

        self.insert_into(&*scope_path, name, entry)
    }

    // DisambigTable::lookup_extensions - new
    fn lookup_extensions(self, type_name: u32) -> cxx::std::vector<unsafe *DisambigEntry> {
        var result = cxx::std::vector<unsafe *DisambigEntry>()
        self._collect_extensions(unsafe &self._root, type_name, unsafe &result)
        return result
    }

    /// Returns the child scope node for \p name at root, or null.
    /// Used by the parser to manually walk a scope chain one segment at a time.
    fn enter(self, const name: string) -> unsafe *DisambigNode {
        var k = self.intern(name)
        return self._root.get_child(k)
    }

    fn enter(self, name: u32) -> unsafe *DisambigNode {
        return self._root.get_child(name)
    }

    fn enter(self, segments: unsafe *cxx::std::vector<string>) -> unsafe *DisambigNode {
        var unsafe *node = unsafe &self._root
        for s in *segments {
            var k = self.intern(s)
            node = node->get_child(k)
            if node == &null {
                return &null
            }
        }

        return node
    }

    /// Quick boolean queries on root scope.
    fn is_type(self, const name: string) -> bool {
        return self.lookup(name).is_type()
    }

    fn is_value(self, const name: string) -> bool {
        return self.lookup(name).is_value()
    }

    fn is_macro(self, const name: string) -> bool {
        return self.lookup(name).is_macro()
    }

    pub fn root(self) -> unsafe *DisambigNode {
        return unsafe &self._root
    }

    fn dump(self) {
        io::println("=== DisambigTable Dump ===")
        self._dump_node(unsafe &self._root, "", true)
        io::println("=========================")
    }


    /// # Private

    priv fn _lookup_in(self, node: unsafe *DisambigNode, key: u32) -> LookupResult {
        var unsafe *entries = node->lookup(key)
        if entries == &null {
            return LookupResult::not_found()
        }

        var r = LookupResult{}
        r.entries = entries
        r.node    = node
        return r
    }

    priv fn _collect_extensions(self,
                                node:      unsafe *DisambigNode,
                                type_name: u32,
                                result:    unsafe *cxx::std::vector<unsafe *DisambigEntry>) {
        for var unsafe *it = node->entries.begin(); it != node->entries.end(); ++it {
            for var i: usize = 0; i < it->second->size(); ++i {
                var unsafe *entry = unsafe &(*it->second)[i]
                if entry->extended {
                    if entry->extend_of_name == type_name {
                        result->push_back(entry)
                    }
                }
            }
        }

        for var unsafe *it = node->children.begin(); it != node->children.end(); ++it {
            self._collect_extensions(it->second, type_name, result)
        }
    }

    priv fn _dump_node(self, node: unsafe *DisambigNode, const prefix: string, is_root: bool) {
        var unsafe *entries_it          = node->entries.begin()
        var        total_entries: usize = 0

        // count total entry vectors for branching logic
        for var unsafe *it = node->entries.begin(); it != node->entries.end(); ++it {
            total_entries += 1
        }

        var total_children: usize = node->children.size()
        var total_items:    usize = total_entries + total_children

        var item_idx: usize = 0

        // print entries
        for var unsafe *it = node->entries.begin(); it != node->entries.end(); ++it {
            ++item_idx
            var is_last   = item_idx == total_items
            var connector = (if (is_last) => ("└── ") else => "├── ")
            var child_pfx = (if (is_last) => ("    ") else => "│   ")

            var name = self.str(it->first as u32)
            var vec  = *it->second

            if vec.size() == 1 {
                io::println(
                    f"{prefix}{connector}{name}  [{self._kind_str(vec[0].kind)}]{self._flags_str(&vec[0])}",
                )
            } else {
                io::println(
                    f"{prefix}{connector}{name}  (overloaded x{vec.size()})",
                )

                for var i: usize = 0; i < vec.size(); ++i {
                    var sub_last      = i == vec.size() - 1
                    var sub_connector = (if (sub_last) => ("└── ") else => "├── ")
                    io::println(
                        f"{prefix}{child_pfx}{sub_connector}[{self._kind_str(vec[i].kind)}]{self._flags_str(&vec[i])}",
                    )
                }
            }
        }

        // print children (nested scopes)
        for var unsafe *it = node->children.begin(); it != node->children.end(); ++it {
            ++item_idx
            var is_last   = item_idx == total_items
            var connector = (if (is_last) => ("└── ") else => "├── ")
            var child_pfx = (if (is_last) => ("    ") else => "│   ")

            var name = self.str(it->first as u32)
            io::println(f"{prefix}{connector}{name}/")
            self._dump_node(it->second, prefix + child_pfx, false)
        }
    }

    priv static fn _kind_str(kind: DisambigKind) -> string {
        match kind {
            case DisambigKind::ClassType {
                return "class"
            } case DisambigKind::EnumType {
                return "enum"
            } case DisambigKind::UnionType {
                return "union"
            } case DisambigKind::StructType {
                return "struct"
            } case DisambigKind::InterfaceType {
                return "interface"
            } case DisambigKind::TypeAlias {
                return "type"
            } case DisambigKind::Function {
                return "fn"
            } case DisambigKind::Operator {
                return "fn op"
            } case DisambigKind::Variable {
                return "var"
            } case DisambigKind::ProcMacro {
                return "@macro"
            } case DisambigKind::BasicMacro {
                return "macro!"
            } case DisambigKind::Module {
                return "module"
            }
        }
    }

    priv static fn _flags_str(@inout entry: DisambigEntry) -> string {
        var s: string = ""
        if entry.is_generic() {
            s = s + "  <generic>"
        }

        if entry.is_from_foreign() {
            s = s + "  [foreign]"
        }

        if entry.extended {
            s = s + "  [extension]"
        }

        return s
    }
}
