/// --- The Kairo Project ------------------ Sema/Expand/DeclaredQuery.k --- ///
///
///   \brief `__builtin_is_declared<P>()`: whether the path P names a
///          declaration in the scope the call is written in.
///
///   \detail
///     The one query whose operand may fail to resolve: every other one
///     resolves its type argument first, and an unknown name there is an
///     error. So the call is recognised by its spelling and answered before
///     N or T meet the path:
///
///       DeclaredQuery          reads the call's form and looks P up, with
///                              no diagnostic for a miss.
///       DeclaredQueryFolding   phase E, after EvalIfFolding: every call left
///                              in the tree becomes the literal `true` or
///                              `false`. EvalIfFolding answers the calls in
///                              the conditions it folds itself, through
///                              DeclaredQuery.
///
///     The answer is the FILE's: P is looked up from the declaration scopes
///     that enclose the call (a type's body, module blocks, the file), then
///     in the file's import overlay, which is where a C++ header's names
///     and `cxx` are. A function's locals are not asked. A generic or
///     `inline` body therefore carries one answer, its defining file's, in
///     every file that instantiates or inlines it.
///
///     P is a path of plain names (`a::b::C`, `cxx::std::vector`): a
///     template is named without arguments. Each step is looked up in the
///     scopes the step before it denotes -- a module's every reopening, a
///     type's body -- and the last step may be any declaration: a type, an
///     alias, a template, a module or namespace, a function, a variable. A
///     primitive type's keyword is always declared. A class, struct or
///     union that is only forward-declared does not count (usable()).
///
///     A name only an undecided `eval if` declares (one deferred to the
///     late fold) counts as declared here; in a condition EvalIfFolding
///     folds, such a name makes the condition wait, as an `eval` constant's
///     does.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "vector"

import AST::Context::DeclContext::DeclContext
import AST::Context::SymbolTable::{
    DeclName,
    OverloadCell,
    SymbolTable,
}
import AST::DeclFacts::{
    decl_is_imported,
    decl_pattern,
}
import AST::LangItems::{
    cxx_root_name,
    cxx_std_name,
    declared_query_name,
}
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    RecordType,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations
import AST::Node::Expressions::{
    BinaryOperatorExpr,
    CallExpr,
    ParenExpr,
    UnaryOperatorExpr,
}
import AST::Node::PrimaryExpressions::{
    BooleanLiteralExpr,
    NamedIdentExpr,
}
import AST::Node::Types::ChainType
import AST::Visitor::ASTWriter::ASTWriter
import Diagnostic::Registry::DiagID
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::SemaContext
import Token::Token::Token
import Token::TokenKind::TokenKind

/// \class DeclaredQuery
/// \brief The form and the lookup of one `__builtin_is_declared<P>()`.
pub class DeclaredQuery {
    pub var sc: unsafe *SemaContext
    /// The last resolve() missed only because every declaration a step
    /// found sits in a branch of an `eval if` that is not decided yet.
    pub var pending: bool = false

    fn DeclaredQuery(self) {
        self.sc = &null
    }

    fn DeclaredQuery(self, sc: unsafe *SemaContext) {
        self.sc = sc
    }

    /// The file spells the query's name at all. The passes ask this first:
    /// a file that never wrote it has no call to find.
    fn spelled(self) -> bool {
        var unsafe *imms = self.sc->ctx->get_imm_table()
        return imms != &null && imms->find_ident(declared_query_name()) != u32::MAX
    }

    /// \p e as a `__builtin_is_declared...(...)` call, parentheses dropped,
    /// or null. Only the callee's spelling decides: the name is reserved
    /// (the `__builtin_` prefix), so no declaration can be meant.
    fn call_of(self, e: unsafe *Expr) -> unsafe *CallExpr {
        var unsafe *x = e
        while x != &null && isa<ParenExpr>(x) {
            x = cast<ParenExpr>(x)->inner
        }

        if x == &null || !isa<CallExpr>(x) {
            return &null
        }

        var unsafe *c = cast<CallExpr>(x)
        if c->callee == &null || !isa<NamedIdentExpr>(c->callee) {
            return &null
        }

        var unsafe *n = cast<NamedIdentExpr>(c->callee)
        if self.sc->ctx->get_spelling(n->name) != declared_query_name() {
            return &null
        }

        return c
    }

    /// The path \p c asks about, as its segments' spellings, into \p segs.
    /// False, with SC341E, when the call is not `__builtin_is_declared<P>()`
    /// with one path P of plain names. \p primitive is set when P is a
    /// primitive type's keyword, which names no declaration and is always
    /// there (\p segs is then empty).
    fn path_of(self,
               c:                unsafe *CallExpr,
               segs:             unsafe *cxx::std::vector<string>,
               @inout primitive: bool) -> bool {
        primitive = false
        var unsafe *n = cast<NamedIdentExpr>(c->callee)
        if c->args.size() != 0 || n->generic_args.size() != 1 {
            self._malformed(
                c,
                "it takes one path between '<' and '>' and no arguments",
            )

            return false
        }

        var unsafe *t = n->generic_args.get(0)->ty
        if t == &null || !isa<ChainType>(t) {
            self._malformed(
                c,
                "its operand is a path of names, such as 'a::b::C', not a type built from one",
            )

            return false
        }

        var unsafe *ch = cast<ChainType>(t)
        for var i: usize = 0; i < ch->segments.size(); ++i {
            var unsafe *s = ch->segments.get(i)
            if s->name == &null || s->generic_args.size() != 0 {
                self._malformed(
                    c,
                    "a template is named without its arguments: the question is whether the name is declared",
                )

                return false
            }

            if self.sc->ctx->get_ident_imm(s->name->name) == u32::MAX {
                // `i32`, `string`, `Self`: a keyword, alone, is the
                // language's own; inside a path it is no name.
                if ch->segments.size() == 1 {
                    primitive = true
                    segs->clear()
                    return true
                }

                self._malformed(c, "a keyword cannot be a step of the path")
                return false
            }

            segs->push_back(self.sc->ctx->get_spelling(s->name->name))
        }

        if segs->size() == 0 {
            self._malformed(c, "the path is empty")
            return false
        }

        return true
    }

    priv fn _malformed(self, c: unsafe *CallExpr, const why: string) {
        var b = self.sc->diag->report(
            DiagID::SC341E,
            c->range.start,
            f"'{declared_query_name()}' is written '{declared_query_name()}<path>()': {why}",
        )

        b.first(c->range)
        b.emit()
    }

    /// The declarations the path \p segs names when looked up from \p from
    /// (a scope of any TU; its own TU's overlay answers last), into \p out.
    /// False when a step names nothing. No diagnostic either way.
    /// \p dropped: declarations to read as absent (EvalIfFolding's untaken
    /// branches), or null.
    fn resolve(self,
               from:       unsafe *DeclContext,
               const segs: cxx::std::vector<string>,
               dropped:    unsafe *cxx::std::vector<unsafe *Decl>,
               out:        unsafe *cxx::std::vector<unsafe *Decl>) -> bool {
        self.pending = false
        out->clear()
        if from == &null || segs.size() == 0 {
            return false
        }

        var unsafe *home = NameLookup::tu_of(from)
        if home == &null || home->ctx == &null || home->ctx->get_imm_table() == &null {
            return false
        }

        // A spelling the file never wrote (a path asked on behalf of
        // another file's extension) is interned first: the lookup then runs
        // and misses like any other, and the miss is in the dependency log,
        // so an import that comes to supply the name re-checks this file.
        var imm = home->ctx->get_imm_table()->intern_ident_copy(segs[0])

        var cur = cxx::std::vector<unsafe *Decl>()
        var r   = self.sc->lookup.unqualified(from, DeclName::ident(imm))
        if !r.found() || !self._live(r.cell, dropped, unsafe &cur) {
            return false
        }

        return self.resolve_from(unsafe &cur, segs, 1, dropped, out)
    }

    /// resolve() from step \p at on, \p cur being what the steps before it
    /// named.
    fn resolve_from(self,
                    cur:        unsafe *cxx::std::vector<unsafe *Decl>,
                    const segs: cxx::std::vector<string>,
                    at:         usize,
                    dropped:    unsafe *cxx::std::vector<unsafe *Decl>,
                    out:        unsafe *cxx::std::vector<unsafe *Decl>) -> bool {
        var now = *cur
        for var i = at; i < segs.size(); ++i {
            var scopes = cxx::std::vector<unsafe *DeclContext>()
            for var k: usize = 0; k < now.size(); ++k {
                if isa<Declarations::ModuleDecl>(now[k]) {
                    NameLookup::module_scopes(now[k], &scopes)
                    continue
                }

                var unsafe *sdc = NameLookup::context_of(now[k])
                if sdc == &null {
                    continue
                }

                var seen = false
                for var j: usize = 0; j < scopes.size(); ++j {
                    if scopes[j] == sdc {
                        seen = true
                        break
                    }
                }

                if !seen {
                    scopes.push_back(sdc)
                }
            }

            var next    = cxx::std::vector<unsafe *Decl>()
            var waiting = false
            for var k: usize = 0; k < scopes.size(); ++k {
                var unsafe *cell = self._in(scopes[k], segs[i])
                if cell == &null || cell->size() == 0 {
                    continue
                }

                if !self._live(cell, dropped, unsafe &next) && self.pending {
                    waiting = true
                }
            }

            if next.size() == 0 {
                self.pending = waiting
                return false
            }

            self.pending = false
            now          = next
        }

        // The last step: a record nobody defined does not count.
        var kept = cxx::std::vector<unsafe *Decl>()
        for var k: usize = 0; k < now.size(); ++k {
            if DeclaredQuery::usable(now[k]) {
                kept.push_back(now[k])
            }
        }

        if kept.size() == 0 {
            return false
        }

        *out = kept
        return true
    }

    /// \p d is more than a name to point at. A class, struct or union that
    /// is only forward-declared (`class basic_string;` in `<iosfwd>`, a
    /// Kairo `struct Node`) is declared in the letter and useless in
    /// practice: it has no size, no members and no constructor, so code
    /// conditional on it could do nothing with it. An alias is what it
    /// names (`std::string` is its `basic_string` instance, and that is its
    /// template); an alias this file has not resolved yet counts. For a
    /// header's record the fact is the build's: the declaration is one per
    /// entity, defined when any header of the build defines it.
    static fn usable(d: unsafe *Decl) -> bool {
        if d == &null {
            return false
        }

        var unsafe *r = d
        if isa<Declarations::TypeAliasDecl>(d) {
            var unsafe *al = cast<Declarations::TypeAliasDecl>(d)
            if al->aliased == &null || al->aliased->canonical == &null {
                return true
            }

            var unsafe *c = canon_unqual(al->aliased->canonical)
            if c == &null || !isa<RecordType>(c) {
                return true
            }

            r = cast<RecordType>(c)->decl
        }

        var unsafe *p = decl_pattern(r)
        if p == &null {
            return true
        }

        // A header's record is one declaration for every header that
        // mentions it, made at the first: whether a definition was found is
        // the import's own fact (FFILinkage::ffi_defined).
        var foreign = decl_is_imported(p)
        if isa<Declarations::ClassDecl>(p) {
            var unsafe *c = cast<Declarations::ClassDecl>(p)
            return if (foreign) => (c->ffi_defined) else => c->has_definition()
        }

        if isa<Declarations::StructDecl>(p) {
            var unsafe *st = cast<Declarations::StructDecl>(p)
            return if (foreign) => (st->ffi_defined) else => st->has_definition()
        }

        if isa<Declarations::UnionDecl>(p) {
            var unsafe *u = cast<Declarations::UnionDecl>(p)
            return if (foreign) => (u->ffi_defined) else => u->has_definition()
        }

        return true
    }

    /// The cell of the name spelled \p nm in the one scope \p dc, whichever
    /// TU owns it: a scope's table is keyed by its own TU's interner, so the
    /// spelling is looked up there.
    priv fn _in(self, dc: unsafe *DeclContext, const nm: string) -> unsafe *OverloadCell {
        var unsafe *owner = NameLookup::tu_of(dc)
        if owner == &null || owner->ctx == &null || owner->ctx->get_imm_table() == &null {
            return &null
        }

        // A spelling the owning file never interned is in none of its
        // tables. lookup_foreign says so and logs the question, which a
        // later declaration of the name in that scope must invalidate.
        var imm = owner->ctx->get_imm_table()->find_ident(nm)
        if imm == u32::MAX {
            return SymbolTable::lookup_foreign(
                dc->dc_symbols,
                owner->ctx->get_imm_table(),
                nm,
            )
        }

        var r = self.sc->lookup.in_context(dc, DeclName::ident(imm), nm)
        return r.cell
    }

    /// \p cell's declarations that exist, appended to \p out: not null, not
    /// in \p dropped. False when none is, or when every one that is sits in
    /// an undecided `eval if` branch and \p dropped is given (a condition
    /// being folded: `pending` is then set, and it waits).
    priv fn _live(self,
                  cell:    unsafe *OverloadCell,
                  dropped: unsafe *cxx::std::vector<unsafe *Decl>,
                  out:     unsafe *cxx::std::vector<unsafe *Decl>) -> bool {
        var n:      usize = 0
        var waiting       = true
        var first         = out->size()
        for var i: usize = 0; i < cell->size(); ++i {
            var unsafe *d = cell->get(i)
            if d == &null {
                continue
            }

            if dropped != &null {
                var gone = false
                for var k: usize = 0; k < dropped->size(); ++k {
                    if (*dropped)[k] == d {
                        gone = true
                        break
                    }
                }

                if gone {
                    continue
                }
            }

            var dup = false
            for var k: usize = 0; k < out->size(); ++k {
                if (*out)[k] == d {
                    dup = true
                    break
                }
            }

            n += 1
            if !self.sc->eval_branches.in_pending(d) {
                waiting = false
            }

            if !dup {
                out->push_back(d)
            }
        }

        if n == 0 {
            return false
        }

        if dropped != &null && waiting {
            out->resize(first)
            self.pending = true
            return false
        }

        return true
    }

    /// resolve() over every C++ header of the build instead of one file's
    /// scope: the declarations \p segs names in any header some file of
    /// the build imports. `cxx` has one member, C++'s `std`; any other head
    /// is a name a header declares at its top level, as a bare ffi import
    /// folds it into the importing file's scope. Header declarations are
    /// one per entity build-wide (ForeignRegistry), so a path that resolves
    /// in two files' scopes resolves to the same declarations here.
    fn resolve_in_headers(self,
                          const segs: cxx::std::vector<string>,
                          out:        unsafe *cxx::std::vector<unsafe *Decl>) -> bool {
        self.pending = false
        out->clear()
        if segs.size() == 0 || self.sc->g == &null || self.sc->ctx->tcm == &null {
            return false
        }

        var is_cxx = segs[0] == cxx_root_name()
        if is_cxx && (segs.size() < 2 || segs[1] != cxx_std_name()) {
            return false
        }

        var head  = if (is_cxx) => (cxx_std_name()) else => segs[0]
        var heads = cxx::std::vector<unsafe *Decl>()
        var fids  = self.sc->g->all_fids()
        for var i: usize = 0; i < fids.size(); ++i {
            var unsafe *ctx = self.sc->g->get_context(fids[i])
            if ctx == &null || ctx->tu == &null || !ctx->tu->is_foreign {
                continue
            }

            var unsafe *cell = SymbolTable::lookup_foreign(
                ctx->tu->symbols(),
                self.sc->ctx->tcm->get_imm_table_for_fid(fids[i]),
                head,
            )

            if cell == &null {
                continue
            }

            for var k: usize = 0; k < cell->size(); ++k {
                var unsafe *d = cell->get(k)
                if d == &null || (is_cxx && !isa<Declarations::ModuleDecl>(d)) {
                    continue
                }

                var dup = false
                for var j: usize = 0; j < heads.size(); ++j {
                    if heads[j] == d {
                        dup = true
                        break
                    }
                }

                if !dup {
                    heads.push_back(d)
                }
            }
        }

        if heads.size() == 0 {
            return false
        }

        return self.resolve_from(
            unsafe &heads,
            segs,
            if (is_cxx) => (2 as usize) else => 1 as usize,
            &null,
            out,
        )
    }

    /// The conditional extension \p e exists in this TU: every path its
    /// clause asks about names, from this file's scope, one of the
    /// declarations it named for the extension's own file. Identity, not
    /// only presence: the extension's signatures were resolved against
    /// those declarations, and a file whose `Foo` is another entity is not
    /// a file where the extension's `Foo` is declared.
    fn gate_holds(self, e: unsafe *Declarations::ExtensionDecl) -> bool {
        var unsafe *g = e->gate
        if g == &null {
            return true
        }

        if self.sc->tu == &null {
            return false
        }

        // The block's own file: its members call each other and use its
        // conversions, in bodies that are checked here whether or not this
        // file declares the paths (they are bound in the block's scope).
        // Lookup is per file, not per position, so the rest of the file
        // sees the block too; ConditionalExtensionCheck reports a use
        // from outside such a block (SC343E).
        if !g->local && NameLookup::tu_of(unsafe (e as unsafe *DeclContext)) == self.sc->tu {
            return true
        }

        var from: usize = 0
        for var i: usize = 0; i < g->paths.size(); ++i {
            var segs  = DeclaredQuery::split(g->paths[i])
            var found = cxx::std::vector<unsafe *Decl>()
            if !self.resolve(
                unsafe (self.sc->tu as unsafe *DeclContext),
                segs,
                &null,
                unsafe &found,
            ) {
                return false
            }

            var same = false
            for var a: usize = 0; a < found.size() && !same; ++a {
                for var b = from; b < g->ends[i]; ++b {
                    if NameLookup::representative(found[a]) == NameLookup::representative(
                        g->decls[b],
                    ) {
                        same = true
                        break
                    }
                }
            }

            if !same {
                return false
            }

            from = g->ends[i]
        }

        return true
    }

    /// `a::b::C` as its steps.
    static fn split(const path: string) -> cxx::std::vector<string> {
        var out       = cxx::std::vector<string>()
        var cur       = ""
        var i:  usize = 0
        while i < path.size() {
            if path[i] == (':' as u8) && i + 1 < path.size() && path[i + 1] == (':' as u8) {
                out.push_back(cur)
                cur = ""
                i += 2
                continue
            }

            cur.push_back(path[i])
            i += 1
        }

        out.push_back(cur)
        return out
    }

    /// SC342E at \p c: the query cannot be asked where it is written.
    fn refuse(self, c: unsafe *Expr, const why: string) {
        var b = self.sc->diag->report(
            DiagID::SC342E,
            c->range.start,
            f"'{declared_query_name()}' cannot be used here: {why}",
        )

        b.first(c->range)
        b.emit()
    }
}

/// \class DeclaredQueryFolding
/// \brief Phase E, after EvalIfFolding: each `__builtin_is_declared<P>()`
///        becomes its answer.
pub class DeclaredQueryFolding derives ASTWriter<DeclaredQueryFolding> {
    pub var  sc: unsafe *SemaContext
    priv var _q: DeclaredQuery
    /// The declaration scopes enclosing the walk, innermost last.
    priv var _dcs: cxx::std::vector<unsafe *DeclContext>
    /// > 0 inside a live conditional extension; _gate_at is its index in
    /// _dcs.
    priv var _gate_depth: u32   = 0
    priv var _gate_at:    usize = 0

    fn DeclaredQueryFolding(self, sc: unsafe *SemaContext) {
        self.sc  = sc
        self.ctx = sc->ctx
        self._q  = DeclaredQuery(sc)
    }

    fn run(self) {
        if self.sc->tu == &null || !self._q.spelled() {
            return
        }

        self._dcs.push_back(unsafe (self.sc->tu as unsafe *DeclContext))
        ASTWriter<DeclaredQueryFolding>::run(self, self.sc->tu)
    }

    fn transform_module_decl(self,
                             n: unsafe *Declarations::ModuleDecl) -> cxx::std::vector<unsafe *Decl> {
        self._dcs.push_back(unsafe (n as unsafe *DeclContext))
        var out = ASTWriter<DeclaredQueryFolding>::transform_module_decl(
            self,
            n,
        )

        self._dcs.pop_back()
        return out
    }

    fn transform_class_decl(self,
                            n: unsafe *Declarations::ClassDecl) -> cxx::std::vector<unsafe *Decl> {
        self._dcs.push_back(unsafe (n as unsafe *DeclContext))
        var out = ASTWriter<DeclaredQueryFolding>::transform_class_decl(self, n)
        self._dcs.pop_back()
        return out
    }

    fn transform_struct_decl(self,
                             n: unsafe *Declarations::StructDecl) -> cxx::std::vector<unsafe *Decl> {
        self._dcs.push_back(unsafe (n as unsafe *DeclContext))
        var out = ASTWriter<DeclaredQueryFolding>::transform_struct_decl(
            self,
            n,
        )

        self._dcs.pop_back()
        return out
    }

    fn transform_function_decl(self,
                               n: unsafe *Declarations::FunctionDecl) -> cxx::std::vector<unsafe *Decl> {
        // The call is recognised by its spelling alone, so the spelling
        // cannot be a function of the program's.
        if !n->is_operator && self.ctx->get_spelling(n->name) == declared_query_name() {
            var b = self.sc->diag->report(
                DiagID::SC341E,
                n->range.start,
                f"'{declared_query_name()}' is the compiler's query and cannot be declared",
            )

            b.first(n->range)
            b.emit()
        }

        self._dcs.push_back(unsafe (n as unsafe *DeclContext))
        var out = ASTWriter<DeclaredQueryFolding>::transform_function_decl(
            self,
            n,
        )

        self._dcs.pop_back()
        return out
    }

    /// An extension whose clause asks the query is CONDITIONAL: it exists in
    /// the files where every path asked about is declared, and its
    /// signatures and bodies may name those paths although this file does
    /// not declare them. Decided here, once, for the extension's own file:
    ///
    ///   - each path is looked up in this file's scope, and failing that in
    ///     the C++ headers of the whole build. Every one found: the block is
    ///     LIVE. It keeps the declarations found (ExtensionDecl::gate), which
    ///     every other file's member lookup compares its own answer with
    ///     (DeclaredQuery::gate_holds), and a path only the headers declare
    ///     is bound in the block's own scope, to exactly that declaration,
    ///     so N and T resolve the block here as they resolve any other.
    ///   - one path that nothing in the build declares: the block is an
    ///     untaken branch. It leaves the tree as an untaken `eval if` does;
    ///     no file can see it, and nothing in it is resolved.
    ///
    /// A member of a live block is `inline`: its body is compiled by the
    /// translation units that use it, which are files that declare the
    /// paths, and never by this file's own unit, which may not.
    fn transform_extension_decl(self,
                                n: unsafe *Declarations::ExtensionDecl) -> cxx::std::vector<unsafe *Decl> {
        var leaves = cxx::std::vector<unsafe *Expr>()
        self._conjuncts(n->requires_clause, unsafe &leaves)
        var gates       = cxx::std::vector<unsafe *CallExpr>()
        var rest: usize = 0
        var bad         = false
        for var i: usize = 0; i < leaves.size(); ++i {
            var unsafe *c = self._q.call_of(leaves[i])
            if c != &null {
                gates.push_back(c)
                continue
            }

            rest += 1
            if self._mentions(leaves[i]) {
                self._q.refuse(
                    leaves[i],
                    "in an extension's 'requires' clause it is a whole operand of '&&', so the extension's body can rely on the path being declared",
                )

                bad = true
            }
        }

        if gates.size() == 0 && !bad {
            self._dcs.push_back(unsafe (n as unsafe *DeclContext))
            var out = ASTWriter<DeclaredQueryFolding>::transform_extension_decl(
                self,
                n,
            )

            self._dcs.pop_back()
            return out
        }

        var none = cxx::std::vector<unsafe *Decl>()
        if bad {
            return none
        }

        if n->implements.size() > 0 {
            self._q.refuse(
                unsafe (gates[0] as unsafe *Expr),
                "an extension that implements an interface cannot depend on what a file declares yet; conformance is one fact for the whole build",
            )

            return none
        }

        var unsafe *g = self.ctx->alloc_init_cleanup<Declarations::ExtensionGate>()
        var bound = cxx::std::vector<cxx::std::vector<string>>() // paths to bind in the block's scope.
        var bdecl = cxx::std::vector<cxx::std::vector<unsafe *Decl>>()
        for var i: usize = 0; i < gates.size(); ++i {
            var segs      = cxx::std::vector<string>()
            var primitive = false
            if !self._q.path_of(gates[i], unsafe &segs, &primitive) {
                return none
            }

            if primitive {
                continue
            }

            var found = cxx::std::vector<unsafe *Decl>()
            var here = self._q.resolve(
                self._dcs[self._dcs.size() - 1],
                segs,
                &null,
                unsafe &found,
            )

            if !here && !self._q.resolve_in_headers(segs, unsafe &found) {
                return none
            }

            var path = ""
            for var k: usize = 0; k < segs.size(); ++k {
                if k > 0 {
                    path += "::"
                    g->scope += "__"
                }

                path += segs[k]
                g->scope += segs[k]
            }

            if i + 1 < gates.size() {
                g->scope += "__and__"
            }

            g->paths.push_back(path)
            for var k: usize = 0; k < found.size(); ++k {
                g->decls.push_back(found[k])
            }

            g->ends.push_back(g->decls.size())
            if !here {
                bound.push_back(segs)
                bdecl.push_back(found)
            }
        }

        if g->paths.size() > 0 {
            n->gate = g
            for var i: usize = 0; i < n->methods.size(); ++i {
                var unsafe *m = n->methods[i]
                if m != &null {
                    m->modifiers = m->modifiers | Declarations::FnModifier::IsInline
                }
            }

            if bound.size() > 0 {
                g->local = false
                self.sc->conditional_blocks += 1
                self._bind_paths(n, unsafe &bound, unsafe &bdecl)
            }
        }

        // The paths are declared wherever the block exists: each query in
        // the clause is `true` there. A clause of nothing else is no clause.
        if rest == 0 {
            n->requires_clause = &null
        }

        self._gate_depth += 1
        self._dcs.push_back(unsafe (n as unsafe *DeclContext))
        self._gate_at = self._dcs.size() - 1
        var out = ASTWriter<DeclaredQueryFolding>::transform_extension_decl(
            self,
            n,
        )

        self._dcs.pop_back()
        self._gate_depth -= 1
        return out
    }

    /// The operands of \p e's `&&` tree, parentheses dropped.
    priv fn _conjuncts(self, e: unsafe *Expr, out: unsafe *cxx::std::vector<unsafe *Expr>) {
        var unsafe *x = e
        while x != &null && isa<ParenExpr>(x) {
            x = cast<ParenExpr>(x)->inner
        }

        if x == &null {
            return
        }

        var unsafe *b = dyn_cast<BinaryOperatorExpr>(x)
        if b != &null
            && (b->op_token.kind == TokenKind::OpAmpAmp || b->op_token.kind == TokenKind::KwAnd) {
            self._conjuncts(b->lhs, out)
            self._conjuncts(b->rhs, out)
            return
        }

        out->push_back(x)
    }

    /// Bind each path of \p paths in the scope of the block \p n, to the
    /// declarations of \p decls and to nothing else: `cxx::std::string`
    /// becomes a module `cxx` holding a module `std` holding the one name
    /// `string`. A name beside it in the real namespace stays undeclared in
    /// the block, so the block resolves the same in every build where it
    /// is live, whatever else that build's headers declare. The modules
    /// are scopes only: the declarations keep their own parents and are
    /// spelled in C++ as they always are (ImportResolution::_bind_cxx is
    /// the same shape for a whole file).
    priv fn _bind_paths(self,
                        n:     unsafe *Declarations::ExtensionDecl,
                        paths: unsafe *cxx::std::vector<cxx::std::vector<string>>,
                        decls: unsafe *cxx::std::vector<cxx::std::vector<unsafe *Decl>>) {
        var unsafe *dc  = unsafe (n as unsafe *DeclContext)
        var unsafe *old = dc->dc_symbols
        var unsafe *nt  = self.ctx->alloc_init_cleanup<SymbolTable>(self.ctx)
        if old != &null {
            var es = cxx::std::vector<SymbolTable::Entry>()
            old->collect_entries(&es)
            for var i: usize = 0; i < es.size(); ++i {
                if es[i].cell == &null {
                    continue
                }

                for var k: usize = 0; k < es[i].cell->size(); ++k {
                    nt->append(es[i].name, es[i].cell->get(k))
                }
            }
        }

        self._bind_level(nt, dc, n, paths, decls, 0, "")
        nt->freeze()
        dc->set_symbols(nt)
    }

    /// One level of _bind_paths: into \p tbl, every distinct step at depth
    /// \p depth of the paths that start with \p prefix (their steps so far,
    /// each followed by `::`).
    priv fn _bind_level(self,
                        tbl:          unsafe *SymbolTable,
                        parent:       unsafe *DeclContext,
                        n:            unsafe *Declarations::ExtensionDecl,
                        paths:        unsafe *cxx::std::vector<cxx::std::vector<string>>,
                        decls:        unsafe *cxx::std::vector<cxx::std::vector<unsafe *Decl>>,
                        depth:        usize,
                        const prefix: string) {
        var done = cxx::std::vector<string>()
        for var i: usize = 0; i < paths->size(); ++i {
            var *p = &(*paths)[i]
            if p->size() <= depth || self._prefix_of(*p, depth) != prefix {
                continue
            }

            var step = (*p)[depth].copy()
            var dup  = false
            for var k: usize = 0; k < done.size(); ++k {
                if done[k] == step {
                    dup = true
                    break
                }
            }

            if dup {
                continue
            }

            done.push_back(step)
            var key = self.sc->imm_table()->intern_ident_copy(step)
            // A path that ends here names its declarations; a longer one
            // through the same step goes on through them.
            var leaf = false
            for var j: usize = 0; j < paths->size(); ++j {
                var *q = &(*paths)[j]
                if q->size() == depth + 1
                    && self._prefix_of(*q, depth) == prefix
                    && (*q)[depth] == step {
                    leaf = true
                    for var k: usize = 0; k < (*decls)[j].size(); ++k {
                        tbl->append_ident(key, (*decls)[j][k])
                    }
                }
            }

            if leaf {
                continue
            }

            var tok = Token()
            tok.kind  = TokenKind::LitIdentifier
            tok.range = n->range
            tok.imm   = key
            var unsafe *md = Declarations::ModuleDecl::create(
                self.ctx,
                n->range,
                tok,
                parent,
            )

            var unsafe *mt = self.ctx->alloc_init_cleanup<SymbolTable>(self.ctx)
            self._bind_level(
                mt,
                unsafe (md as unsafe *DeclContext),
                n,
                paths,
                decls,
                depth + 1,
                prefix + step + "::",
            )

            mt->freeze()
            md->set_symbols(mt)
            tbl->append_ident(key, md)
        }
    }

    priv fn _prefix_of(self, const p: cxx::std::vector<string>, depth: usize) -> string {
        var out = ""
        for var i: usize = 0; i < depth; ++i {
            out += p[i] + "::"
        }

        return out
    }

    fn transform_call_expr(self, n: unsafe *CallExpr) -> unsafe *Expr {
        var unsafe *c = self._q.call_of(unsafe (n as unsafe *Expr))
        if c == &null {
            return ASTWriter<DeclaredQueryFolding>::transform_call_expr(self, n)
        }

        // In a live conditional extension (its clause, its signatures, its
        // bodies) a path the clause asks about is declared by definition.
        if self._gate_depth > 0 && self._in_gate(c) {
            return BooleanLiteralExpr::create(self.ctx, n->range, true)
        }

        var segs      = cxx::std::vector<string>()
        var primitive = false
        var value     = false
        if self._q.path_of(c, unsafe &segs, &primitive) {
            if primitive {
                value = true
            } else {
                var found = cxx::std::vector<unsafe *Decl>()
                value = self._q.resolve(
                    self._dcs[self._dcs.size() - 1],
                    segs,
                    &null,
                    unsafe &found,
                )
            }
        }

        return BooleanLiteralExpr::create(self.ctx, n->range, value)
    }

    /// \p c asks about a path the enclosing conditional extension's clause
    /// asks about.
    priv fn _in_gate(self, c: unsafe *CallExpr) -> bool {
        var unsafe *x = dyn_cast<Declarations::ExtensionDecl>(
            self._dcs[self._gate_at]->owner_decl(),
        )

        if x == &null || x->gate == &null {
            return false
        }

        var unsafe *nm = cast<NamedIdentExpr>(c->callee)
        if c->args.size() != 0 || nm->generic_args.size() != 1 {
            return false
        }

        var unsafe *ch = dyn_cast<ChainType>(nm->generic_args.get(0)->ty)
        if ch == &null {
            return false
        }

        var path = ""
        for var i: usize = 0; i < ch->segments.size(); ++i {
            var unsafe *sg = ch->segments.get(i)
            if sg->name == &null {
                return false
            }

            if i > 0 {
                path += "::"
            }

            path += self.ctx->get_spelling(sg->name->name)
        }

        for var i: usize = 0; i < x->gate->paths.size(); ++i {
            if x->gate->paths[i] == path {
                return true
            }
        }

        return false
    }

    /// \p e holds a query call, at any depth of `!`, `&&`, `||` and
    /// parentheses.
    priv fn _mentions(self, e: unsafe *Expr) -> bool {
        var unsafe *x = e
        while x != &null && isa<ParenExpr>(x) {
            x = cast<ParenExpr>(x)->inner
        }

        if x == &null {
            return false
        }

        if self._q.call_of(x) != &null {
            return true
        }

        var unsafe *b = dyn_cast<BinaryOperatorExpr>(x)
        if b != &null {
            return self._mentions(b->lhs) || self._mentions(b->rhs)
        }

        var unsafe *u = dyn_cast<UnaryOperatorExpr>(x)
        return u != &null && self._mentions(u->operand)
    }
}
