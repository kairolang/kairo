/// --- The Kairo Project ------------------ Sema/Check/TypeCycleCheck.k --- ///
///
///   \brief Reject types whose definition requires their own layout.
///
///   \detail
///     DFS with a three-colour map over by-value edges only: value
///     members, bases, fixed-array elements, and template arguments that
///     land by value. Pointer and reference edges are excluded, they are
///     satisfied by a forward declaration. Grey-on-grey is the cycle; the
///     DFS stack is the diagnostic path. MUST run before LayoutPass,
///     which assumes acyclicity and will not terminate without it.
///
///     The colour map is two vectors rather than a hash: grey IS the DFS
///     stack (it has to be, the stack is the diagnostic), and black is a
///     append-only set. Both are scanned linearly; the type count per TU
///     is small and the alternative buys nothing measurable.
///
///     A generic argument is a by-value edge only when the parameter it
///     binds is itself reached by value inside the record's own layout.
///     `Box<Node>` closes a cycle when `Box` stores its `T`; `Ptr<Node>`
///     does not when it only points at one. `_param_by_value` answers that
///     by walking the record's layout spine looking for the parameter, so
///     the edge set stays exactly "what contributes to size".
///
///     Every decl on a reported cycle is marked reported, so one cycle
///     produces one error no matter which of its members the outer walk
///     happened to enter it through.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Sema::SemaContext::*;
import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::Context::TranslationUnit::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Declarations::*;
import AST::DeclFacts::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import AST::Kind::TypeKind::*;
import Location::SourceLocation::*;
import Location::SourceRange::*;
import Diagnostic::Registry::*;
import Diagnostic::Engine::*;
import Diagnostic::Code::*;

class TypeCycleCheck {
    pub var sc: *SemaContext;

    /// The DFS stack: the grey set, in path order.
    priv var _stack: vec::<*Decl>;

    /// `_site[i]` is the by-value edge inside `_stack[i]` that the walk
    /// descended through. One entry per stack entry, pushed together.
    priv var _site: vec::<SourceRange>;

    /// Fully explored, acyclic. Never revisited.
    priv var _black: vec::<*Decl>;

    /// Decls already named on a reported cycle.
    priv var _reported: vec::<*Decl>;

    /// Where `unsafe *` goes to hold the record being walked through a
    /// pointer instead: the start of a field's type when that type is the
    /// record itself, else invalid (no fix-it).
    priv var _fix_at: SourceLocation = SourceLocation::invalid();

    fn TypeCycleCheck(self, sc: *SemaContext) {
        self.sc = sc;
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::TypesResolved);
        var tu = self.sc->tu;
        if tu == &null { return; }
        if tu->program == &null { return; }

        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); ++i {
            var item = *(items->get(i));
            if item.kind == TopLevelKind::Decl {
                self._walk_decl(item.as_decl());
            }
        }
    }

    // --- The outer walk: find every record, root a DFS at it -----------------

    priv fn _walk_decl(self, d: *Decl) {
        if d == &null { return; }
        if self._is_record(d) {
            self._visit(d, d->range);
        }
        var dc = self._context_of(d);
        if dc == &null { return; }
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            self._walk_decl(*(dc->dc_decls.get(i)));
        }
    }

    /// The DeclContext a decl owns, or null if it owns none. Only the
    /// kinds that can nest another record need an answer here.
    priv fn _context_of(self, d: *Decl) -> *DeclContext {
        switch d->kind {
            case DeclKind::ModuleDecl {
                return static_cast::<*DeclContext>(cast::<ModuleDecl>(d));
            } case DeclKind::ClassDecl {
                return static_cast::<*DeclContext>(cast::<ClassDecl>(d));
            } case DeclKind::StructDecl {
                return static_cast::<*DeclContext>(cast::<StructDecl>(d));
            } case DeclKind::UnionDecl {
                return static_cast::<*DeclContext>(cast::<UnionDecl>(d));
            } case DeclKind::EnumDecl {
                return static_cast::<*DeclContext>(cast::<EnumDecl>(d));
            } case DeclKind::InterfaceDecl {
                return static_cast::<*DeclContext>(cast::<InterfaceDecl>(d));
            } case DeclKind::ExtensionDecl {
                return static_cast::<*DeclContext>(cast::<ExtensionDecl>(d));
            } default {
                return &null;
            }
        }
        return &null;
    }

    priv fn _is_record(self, d: *Decl) -> bool {
        return (d->kind == DeclKind::ClassDecl)
            || (d->kind == DeclKind::StructDecl)
            || (d->kind == DeclKind::UnionDecl)
            || (d->kind == DeclKind::EnumDecl);
    }

    // --- The DFS -------------------------------------------------------------

    /// Descend into \p d, having arrived through the by-value edge written
    /// at \p site. Grey-on-grey is the cycle.
    priv fn _visit(self, d: *Decl, site: SourceRange) {
        if d == &null { return; }
        if !self._is_record(d) { return; }
        if d->is_poisoned() { return; }
        if self._index_of(&self._black, d) != usize(-1) { return; }

        var grey = self._index_of(&self._stack, d);
        if grey != usize(-1) {
            self._report(grey, site);
            return;
        }

        self._stack.push_back(d);
        self._site.push_back(site);

        self._edges(d);

        self._stack.pop_back();
        self._site.pop_back();
        self._black.push_back(d);
    }

    /// Every by-value edge out of one record.
    priv fn _edges(self, d: *Decl) {
        switch d->kind {
            case DeclKind::ClassDecl {
                var n = cast::<ClassDecl>(d);
                self._base_edges(&(n->derives_list));
                self._field_edges(&(n->fields));
            } case DeclKind::StructDecl {
                var n = cast::<StructDecl>(d);
                self._field_edges(&(n->fields));
            } case DeclKind::UnionDecl {
                var n = cast::<UnionDecl>(d);
                self._field_edges(&(n->fields));
            } case DeclKind::EnumDecl {
                // Only an ADT has layout of its own beyond the discriminant;
                // `underlying` is always a builtin.
                var n = cast::<EnumDecl>(d);
                for var i: usize = 0; i < n->variants.size(); ++i {
                    var v = *(n->variants.get(i));
                    if v == &null { continue; }
                    self._field_edges(&(v->payload));
                }
            } default {
                break;
            }
        }
    }

    /// A base class contributes its whole layout; an interface does not, so
    /// only `derives_list` reaches here.
    priv fn _base_edges(self, bases: *FrozenList::<InheritEdge>) {
        for var i: usize = 0; i < bases->size(); ++i {
            var e = bases->get(i);
            if e == &null { continue; }
            self._type_edges(e->base, e->range);
        }
    }

    priv fn _field_edges(self, fields: *FrozenList::<*FieldDecl>) {
        for var i: usize = 0; i < fields->size(); ++i {
            var f = *(fields->get(i));
            if f == &null { continue; }
            // static/eval storage lives outside the object.
            if f->storage == StorageClass::Static { continue; }
            if f->storage == StorageClass::Eval   { continue; }
            // A field typed exactly the record gets the pointer fix-it; a
            // record buried in an array or a generic argument does not.
            self._fix_at = SourceLocation::invalid();
            if f->type_ != &null {
                var fc = canon_unqual(f->type_->canonical);
                if (fc != &null) && isa::<RecordType>(fc) { self._fix_at = f->type_->range.start; }
            }
            self._type_edges(f->type_, f->range);
            self._fix_at = SourceLocation::invalid();
        }
    }

    /// Follow \p t down its by-value spine, visiting every record it puts
    /// inside the object being laid out.
    priv fn _type_edges(self, t: *Type, site: SourceRange) {
        if t == &null { return; }
        var c = t->canonical;
        if c == &null { c = t; }

        switch c->kind {
            case TypeKind::RecordType {
                var r = cast::<RecordType>(c);
                // The same by-value edge that would close a cycle needs the
                // held record's layout: a forward declaration never defined
                // has none to give (C++ "field has incomplete type").
                if decl_only_forward(r->decl) {
                    self._report_incomplete(r->decl, site);
                    return;
                }
                self._visit(r->decl, site);
                // Which arguments the record stores by value is a question
                // for the PATTERN: an instance shell has no fields until M2
                // fills it, and would answer "none" for every `(i32, Arr)`.
                var pat = decl_pattern(r->decl);
                for var i: usize = 0; i < r->args.size(); ++i {
                    if self._param_by_value(pat, i, 0) {
                        self._type_edges(*(r->args.get(i)), site);
                    }
                }
            } case TypeKind::FixedArrayType {
                self._type_edges(cast::<FixedArrayType>(c)->element, site);
            } case TypeKind::NullableType {
                // `T?` holds its T in place (NULLABLE.md 1.2: tagged, and a
                // niche is the T itself), so `class Node { var next: Node? }`
                // is a by-value loop like `var next: Node`.
                self._type_edges(cast::<NullableType>(c)->inner, site);
            } case TypeKind::QualifiedType {
                // A const field is still by value.
                self._type_edges(cast::<QualifiedType>(c)->inner, site);
            } case TypeKind::SelfType {
                // `var x: Self` inside a record is that record by value.
                if self._stack.size() > 0 {
                    self._visit(self._stack[self._stack.size() - 1], site);
                }
            } default {
                // Pointer, nullable, vector, map, set, function pointer,
                // builtin, generic param: all satisfied by a forward
                // declaration, none contribute a size that recurses.
                break;
            }
        }
    }

    // --- Generic arguments ---------------------------------------------------

    /// True when \p index's generic parameter of \p rec is reached by value
    /// somewhere in \p rec's own layout, i.e. binding it to a type puts that
    /// type inside the object. Depth-capped rather than colour-mapped: the
    /// walk is over a record's fields, and a genuinely recursive one is what
    /// the outer DFS is here to report.
    priv fn _param_by_value(self, rec: *Decl, index: usize, depth: u32) -> bool {
        if rec == &null { return false; }
        if depth > 8 { return true; } // give up conservatively: assume by value

        switch rec->kind {
            case DeclKind::ClassDecl {
                var n = cast::<ClassDecl>(rec);
                if self._bases_use_param(&(n->derives_list), rec, index, depth) { return true; }
                return self._fields_use_param(&(n->fields), rec, index, depth);
            } case DeclKind::StructDecl {
                return self._fields_use_param(&(cast::<StructDecl>(rec)->fields), rec, index, depth);
            } case DeclKind::UnionDecl {
                return self._fields_use_param(&(cast::<UnionDecl>(rec)->fields), rec, index, depth);
            } case DeclKind::EnumDecl {
                var n = cast::<EnumDecl>(rec);
                for var i: usize = 0; i < n->variants.size(); ++i {
                    var v = *(n->variants.get(i));
                    if v == &null { continue; }
                    if self._fields_use_param(&(v->payload), rec, index, depth) { return true; }
                }
                return false;
            } default {
                return false;
            }
        }
        return false;
    }

    priv fn _bases_use_param(self, bases: *FrozenList::<InheritEdge>, rec: *Decl,
                             index: usize, depth: u32) -> bool {
        for var i: usize = 0; i < bases->size(); ++i {
            var e = bases->get(i);
            if e == &null { continue; }
            if self._type_uses_param(e->base, rec, index, depth) { return true; }
        }
        return false;
    }

    priv fn _fields_use_param(self, fields: *FrozenList::<*FieldDecl>, rec: *Decl,
                              index: usize, depth: u32) -> bool {
        for var i: usize = 0; i < fields->size(); ++i {
            var f = *(fields->get(i));
            if f == &null { continue; }
            if f->storage == StorageClass::Static { continue; }
            if f->storage == StorageClass::Eval   { continue; }
            if self._type_uses_param(f->type_, rec, index, depth) { return true; }
        }
        return false;
    }

    /// The by-value spine again, but looking for one generic parameter
    /// rather than collecting records.
    priv fn _type_uses_param(self, t: *Type, rec: *Decl, index: usize, depth: u32) -> bool {
        if t == &null { return false; }
        var c = t->canonical;
        if c == &null { c = t; }

        switch c->kind {
            case TypeKind::GenericParamType {
                var g = cast::<GenericParamType>(c);
                return (g->owner == rec) && (usize(g->param_index) == index);
            } case TypeKind::RecordType {
                var r = cast::<RecordType>(c);
                for var i: usize = 0; i < r->args.size(); ++i {
                    if !self._param_by_value(r->decl, i, depth + 1) { continue; }
                    if self._type_uses_param(*(r->args.get(i)), rec, index, depth + 1) {
                        return true;
                    }
                }
                return false;
            } case TypeKind::FixedArrayType {
                return self._type_uses_param(cast::<FixedArrayType>(c)->element, rec, index, depth);
            } case TypeKind::NullableType {
                return self._type_uses_param(cast::<NullableType>(c)->inner, rec, index, depth);
            } case TypeKind::QualifiedType {
                return self._type_uses_param(cast::<QualifiedType>(c)->inner, rec, index, depth);
            } default {
                return false;
            }
        }
        return false;
    }

    // --- Reporting -----------------------------------------------------------

    /// The cycle is `_stack[grey ..]` plus the closing edge at \p site. Report
    /// it once, at the type the walk re-entered, with one note per step.
    priv fn _report(self, grey: usize, site: SourceRange) {
        for var i: usize = grey; i < self._stack.size(); ++i {
            if self._index_of(&self._reported, self._stack[i]) != usize(-1) {
                return; // this cycle already has an error
            }
        }

        var head = self._stack[grey];
        var hn   = self._decl_name(head);
        var msg  = f"'{hn}' contains itself by value; its layout would have to include its own size";

        // Built through std::create rather than the report()/chain idiom: the
        // note count is the cycle length, so the chain cannot be written as
        // one expression, and DiagBuilder is move-only.
        var b = std::create::<DiagBuilder>(
            self.sc->diag, DiagCode(DiagID::SC002E), head->range.start, msg);
        b->first(head->range);

        // One note per by-value step, in path order. The edge INTO stack[i+1]
        // is the site recorded when stack[i+1] was pushed; the closing edge
        // back to `head` is the caller's site.
        for var i: usize = grey; i + 1 < self._stack.size(); ++i {
            var step = self._holds(self._stack[i], self._stack[i + 1]);
            b->note(self._site[i + 1].start, step);
        }
        var tail = self._stack[self._stack.size() - 1];
        var last = self._holds(tail, head) + ", closing the cycle";
        b->note(site.start, last);
        b->emit();
        std::destroy(b);

        for var i: usize = grey; i < self._stack.size(); ++i {
            var d = self._stack[i];
            self._reported.push_back(d);
            d->poison();
        }
    }

    /// \p held, only ever forward-declared, reached by value at \p site from
    /// the record on top of the stack. Reported once per edge: each record's
    /// edges are walked once (black), so no dedup set is needed.
    priv fn _report_incomplete(self, held: *Decl, site: SourceRange) {
        if self._stack.size() == 0 { return; }
        var owner = self._stack[self._stack.size() - 1];
        var on = self._decl_name(owner);
        var hn = self._decl_name(held);
        var b = self.sc->diag->report(DiagID::SC001E, site.start,
            f"'{on}' holds '{hn}' by value, but '{hn}' is only forward-declared, so its size is unknown");
        b.first(site);
        b.note(DiagID::SC001N, held->range.start,
            f"'{hn}' is forward-declared here and never defined").first(held->range);
        if self._fix_at.is_valid() {
            b.insert(self._fix_at, "unsafe *", f"hold a pointer to '{hn}' instead");
        }
        b.emit();
    }

    // --- Small helpers -------------------------------------------------------

    /// "'A' holds 'B' by value", the one shape every path note takes.
    priv fn _holds(self, owner: *Decl, held: *Decl) -> string {
        var a = self._decl_name(owner);
        var b = self._decl_name(held);
        return f"'{a}' holds '{b}' by value";
    }

    priv fn _index_of(self, v: *vec::<*Decl>, d: *Decl) -> usize {
        for var i: usize = 0; i < v->size(); ++i {
            if (*v)[i] == d { return i; }
        }
        return usize(-1);
    }

    priv fn _decl_name(self, d: *Decl) -> string {
        if d == &null { return "<null>"; }
        return self._imm(decl_name_tok(d).imm);
    }

    priv fn _imm(self, imm: u32) -> string {
        if imm == u32(-1) { return "<?>"; }
        return self.sc->imm_table()->get_ident(imm);
    }
}
