/// --- The Kairo Project ------------------- Sema/Resolve/AccessCheck.k --- ///
///
///   \brief Enforce pub/priv/prot visibility on every resolved reference.
///
///   \detail
///     Runs after expression typing so it checks what was actually chosen
///     (the overload, the constructor), not what was visible. The rule is
///     module-wide (classes.mdx Visibility, modules.mdx Visibility Scopes;
///     user decision 2026-10-26):
///
///       pub    everywhere.
///       priv   the file that declares the member -- every function in it,
///              free ones included -- and the member's own class.
///       prot   what priv allows, plus every class deriving from the
///              member's class, in any file.
///
///     A record's variables (instance, static, const, eval, thread) are
///     `priv` unless marked; everything else in a class, and everything in
///     a struct or union, is `pub`. An extension member is `pub` unless
///     marked and follows the same rule from the extension's file.
///
///     Inheritance visibility (`derives priv Base`) narrows what is reached
///     through the derived class: a base member found through an edge
///     marked `priv` is private to the file (and class) that wrote the
///     edge, through one marked `prot` protected to it.
///
///     What is checked: every `.` / `->` / `::` step of an expression chain
///     (fields, methods, statics, nested types named in an expression), the
///     constructor a construction selected, the fields a named initializer
///     fills, and the nested types a type path names. Imported C++ members
///     are clang's to judge, and compiler-made ones have no user to answer.
///
///     The emitted C++ no longer carries Kairo's visibility (every Kairo
///     member is `public:`, InterfaceEmitter): C++ has no access level that
///     means "this file's functions", so this pass is the only check.
///
///     SC001E (placeholder), the label at the use, a note at the member,
///     and a fix-it that makes the member `pub`.
///
///   Phase: CHECKS, after ExprTyper, before InitCheck.
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
import Sema::Type::TypeUtil::*;
import Sema::Resolve::NameLookup::*;
import AST::Context::ASTContext::*;
import AST::Context::TranslationUnit::*;
import AST::Context::DeclContext::*;
import AST::ASTSupport::*;
import AST::DeclFacts::*;
import AST::Mixin::Annotation::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Location::SourceRange::*;
import Diagnostic::Registry::*;

class AccessCheck derives RecursiveASTVisitor::<AccessCheck> {
    pub var sc: *SemaContext;
    priv var _tu: TypeUtil;
    /// The functions being walked, innermost last: their classes are the
    /// use site's (a method's own class, a subclass for `prot`).
    priv var _fns: vec::<*FunctionDecl>;
    /// The records being walked lexically: a field default is in its class.
    priv var _recs: vec::<*Decl>;

    fn AccessCheck(self, sc: *SemaContext) {
        self.sc  = sc;
        self._tu = TypeUtil(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::TypesResolved);
        var tu = self.sc->tu;
        if (tu == &null) || (tu->program == &null) { return; }
        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); ++i {
            if self.stop { break; }
            var item = *(items->get(i));
            switch item.get_kind() {
                case TopLevelKind::Decl { self.dyn()->dispatch_decl(item.as_decl()); }
                case TopLevelKind::Stmt { self.dyn()->dispatch_stmt(item.as_stmt()); }
                case TopLevelKind::Expr { self.dyn()->dispatch_expr(item.as_expr()); }
            }
        }
    }

    // === where the use is ======================================================

    fn traverse_function_decl(self, n: *FunctionDecl) -> *FunctionDecl {
        self._fns.push_back(n);
        var r = RecursiveASTVisitor::<AccessCheck>::traverse_function_decl(n);
        self._fns.pop_back();
        return r;
    }

    fn traverse_class_decl(self, n: *ClassDecl) -> *ClassDecl {
        self._recs.push_back(static_cast::<*Decl>(n));
        var r = RecursiveASTVisitor::<AccessCheck>::traverse_class_decl(n);
        self._recs.pop_back();
        return r;
    }

    fn traverse_struct_decl(self, n: *StructDecl) -> *StructDecl {
        self._recs.push_back(static_cast::<*Decl>(n));
        var r = RecursiveASTVisitor::<AccessCheck>::traverse_struct_decl(n);
        self._recs.pop_back();
        return r;
    }

    fn traverse_union_decl(self, n: *UnionDecl) -> *UnionDecl {
        self._recs.push_back(static_cast::<*Decl>(n));
        var r = RecursiveASTVisitor::<AccessCheck>::traverse_union_decl(n);
        self._recs.pop_back();
        return r;
    }

    /// Every class the use site is inside, as pattern representatives: the
    /// records being walked, and the scopes enclosing the innermost
    /// function -- an out-of-line method's class too, which is not its
    /// lexical parent; an extension member's target.
    priv fn _use_classes(self) -> vec::<*Decl> {
        var out = vec::<*Decl>();
        for var i: usize = 0; i < self._recs.size(); ++i { out.push_back(self._rep(self._recs[i])); }
        if self._fns.size() == 0 { return out; }
        var f = self._fns[self._fns.size() - 1];
        var dc = reinterpret_cast::<*DeclContext>(f->semantic_dc);
        var depth: u32 = 0;
        while (dc != &null) && (depth < 64) {
            depth += 1;
            if dc->dc_kind == DeclContextKind::Extension {
                var ext = dyn_cast::<ExtensionDecl>(dc->owner_decl());
                if (ext != &null) && (ext->target != &null) && (ext->target->canonical != &null) {
                    var rd = self._tu.record_decl(canon_unqual(ext->target->canonical));
                    if rd != &null { out.push_back(self._rep(rd)); }
                }
            } else if dc->is_type_scope() && (dc->owner_decl() != &null) {
                out.push_back(self._rep(dc->owner_decl()));
            }
            dc = dc->dc_parent;
        }
        return out;
    }

    priv fn _rep(self, d: *Decl) -> *Decl {
        if d == &null { return &null; }
        return NameLookup::representative(decl_pattern(NameLookup::representative(d)));
    }

    // === the references ========================================================

    fn visit_chain_expr(self, n: *ChainExpr) -> bool {
        if n->is_poisoned() { return true; }
        for var i: usize = 0; i < n->steps.size(); ++i {
            var st = n->steps.get(i);
            if (st == &null) || (st->resolved_decl == &null) { continue; }
            var through: *Type = &null;
            if i == 0 { through = self._chain_head_type(n->base); }
            else { through = n->steps.get(i - 1)->resolved_type; }
            self._check(st->resolved_decl, st->range, through);
        }
        return true;
    }

    /// The record a chain starts at: the value's type, or the type the head
    /// names (`Acc::hidden`).
    priv fn _chain_head_type(self, e: *Expr) -> *Type {
        if e == &null { return &null; }
        if e->type_ != &null { return e->type_; }
        var ni = dyn_cast::<NamedIdentExpr>(e);
        if (ni == &null) || (ni->resolved_decl == &null) { return &null; }
        return &null;
    }

    fn visit_call_expr(self, n: *CallExpr) -> bool {
        if n->is_poisoned() || (n->ctor_decl == &null) { return true; }
        self._check(n->ctor_decl, n->range, &null);
        return true;
    }

    fn visit_named_initializer_expr(self, n: *NamedInitializerExpr) -> bool {
        if n->is_poisoned() || (n->type_ == &null) { return true; }
        var rd = self._tu.record_decl(canon_unqual(n->type_));
        if rd == &null { return true; }
        var body = self.sc->record_body(canon_unqual(n->type_));
        if body == &null { body = decl_pattern(rd); }
        var fields: *FrozenList::<*FieldDecl> = &null;
        if isa::<ClassDecl>(body)       { fields = &(cast::<ClassDecl>(body)->fields);  }
        else if isa::<StructDecl>(body) { fields = &(cast::<StructDecl>(body)->fields); }
        else if isa::<UnionDecl>(body)  { fields = &(cast::<UnionDecl>(body)->fields);  }
        if fields == &null { return true; }
        var fctx = NameLookup::ctx_of(body);
        if fctx == &null { return true; }
        for var i: usize = 0; i < n->fields.size(); ++i {
            var fi = n->fields.get(i);
            if fi == &null { continue; }
            var want = self.sc->ctx->get_spelling(fi->name);
            for var j: usize = 0; j < fields->size(); ++j {
                var f = (*fields)[j];
                if (f == &null) || (fctx->get_spelling(f->name) != want) { continue; }
                self._check(static_cast::<*Decl>(f), fi->range, &null);
                break;
            }
        }
        return true;
    }

    fn visit_chain_type(self, n: *ChainType) -> bool {
        if n->is_poisoned() { return true; }
        for var i: usize = 1; i < n->segments.size(); ++i {
            var seg = n->segments.get(i);
            if (seg == &null) || (seg->resolved_decl == &null) { continue; }
            self._check(seg->resolved_decl, seg->range, &null);
        }
        return true;
    }

    // === the rule ===============================================================

    /// Report \p d used at \p at when the use site may not see it; \p through
    /// is the type it was reached through (inheritance visibility), or null.
    priv fn _check(self, d_in: *Decl, at: SourceRange, through: *Type) {
        var d = d_in;
        if (d == &null) || d->is_implicit || d->is_poisoned() || decl_is_imported(d) { return; }
        var owner = self._owner(d);
        if owner == &null { return; }
        if decl_is_imported(owner) { return; }
        var v = self._effective(d, owner);
        if (v != VisibilityKind::Private) && (v != VisibilityKind::Protected) {
            self._check_edges(d, owner, at, through);
            return;
        }
        if !self._may_see(d, owner, v) {
            self._report(d, owner, v, at);
            return;
        }
        self._check_edges(d, owner, at, through);
    }

    /// The use site may see a member of \p owner at visibility \p v whose
    /// home is \p d's file.
    priv fn _may_see(self, d: *Decl, owner: *Decl, v: VisibilityKind) -> bool {
        var home = self._home(d, owner);
        if (home == &null) || (home == self.sc->tu) { return true; }
        var users = self._use_classes();
        for var i: usize = 0; i < users.size(); ++i { if users[i] == owner { return true; } }
        if v != VisibilityKind::Protected { return false; }
        for var i: usize = 0; i < users.size(); ++i {
            var seen = vec::<*Decl>();
            if self._derives(users[i], owner, &seen, 0) { return true; }
        }
        return false;
    }

    /// The record (or extension target) \p d is a member of, as a pattern
    /// representative; null for anything that is not a member.
    priv fn _owner(self, d: *Decl) -> *Decl {
        if d->semantic_dc == &null { return &null; }
        var dc = reinterpret_cast::<*DeclContext>(d->semantic_dc);
        var od = dc->owner_decl();
        if od == &null { return &null; }
        if dc->dc_kind == DeclContextKind::Extension {
            var ext = dyn_cast::<ExtensionDecl>(od);
            if (ext == &null) || (ext->target == &null) || (ext->target->canonical == &null) { return &null; }
            var rd = self._tu.record_decl(canon_unqual(ext->target->canonical));
            if rd == &null { return &null; }
            return self._rep(rd);
        }
        if isa::<ClassDecl>(od) || isa::<StructDecl>(od) || isa::<UnionDecl>(od) || isa::<EnumDecl>(od) {
            return self._rep(od);
        }
        return &null;
    }

    /// \p d's own visibility, the default applied: a class's variables are
    /// `priv`, everything else `pub` (classes.mdx, Default visibility).
    priv fn _effective(self, d: *Decl, owner: *Decl) -> VisibilityKind {
        var r = NameLookup::representative(d);
        var v = d->visibility;
        if (v == VisibilityKind::None) && (r != &null) { v = r->visibility; }
        if v != VisibilityKind::None { return v; }
        var dc = reinterpret_cast::<*DeclContext>(d->semantic_dc);
        if dc->dc_kind == DeclContextKind::Extension { return VisibilityKind::Public; }
        if isa::<ClassDecl>(dc->owner_decl()) && (isa::<FieldDecl>(d) || isa::<VariableDecl>(d)) { return VisibilityKind::Private; }
        return VisibilityKind::Public;
    }

    /// The file \p d's visibility is relative to: its class's, read off the
    /// pattern (an instance's members are minted wherever it is used), or
    /// an extension's own.
    priv fn _home(self, d: *Decl, owner: *Decl) -> *TranslationUnit {
        var dc = reinterpret_cast::<*DeclContext>(d->semantic_dc);
        if dc->dc_kind == DeclContextKind::Extension { return NameLookup::tu_of(dc); }
        return NameLookup::tu_of(NameLookup::context_of(owner));
    }

    /// \p d reaches \p base through `derives` edges, by pattern entity.
    priv fn _derives(self, d: *Decl, base: *Decl, seen: *vec::<*Decl>, depth: u32) -> bool {
        if (d == &null) || (depth > 64) || (!isa::<ClassDecl>(d)) { return false; }
        for var i: usize = 0; i < seen->size(); ++i { if (*seen)[i] == d { return false; } }
        seen->push_back(d);
        var cd = cast::<ClassDecl>(d);
        for var i: usize = 0; i < cd->derives_list.size(); ++i {
            var bd = self._edge_rep(cd->derives_list.get(i));
            if bd == &null { continue; }
            if bd == base { return true; }
            if self._derives(bd, base, seen, depth + 1) { return true; }
        }
        return false;
    }

    priv fn _edge_rep(self, e: *InheritEdge) -> *Decl {
        if (e == &null) || (e->base == &null) || (e->base->canonical == &null) { return &null; }
        var r = dyn_cast::<RecordType>(canon_unqual(e->base->canonical));
        if (r == &null) || (r->decl == &null) { return &null; }
        return self._rep(r->decl);
    }

    // === inheritance visibility ===============================================

    /// A member of \p owner reached through a record that derives it with a
    /// `priv` or `prot` edge on the way: the edge's class is the member's
    /// home for this use, at the edge's visibility.
    priv fn _check_edges(self, d: *Decl, owner: *Decl, at: SourceRange, through: *Type) {
        if through == &null { return; }
        var rd = self._tu.record_decl(canon_unqual(self._tu.as_value(self._strip(through))));
        if rd == &null { return; }
        var from = self._rep(rd);
        if (from == &null) || (from == owner) { return; }
        var seen = vec::<*Decl>();
        var path = vec::<*InheritEdge>();
        var holders = vec::<*Decl>();
        if !self._path(from, owner, &path, &holders, &seen, 0) { return; }
        for var i: usize = 0; i < path.size(); ++i {
            var e = path[i];
            var ev = e->visibility;
            if (ev != 1) && (ev != 2) { continue; }   // VIS_PRIV / VIS_PROT; none and pub are public.
            var holder = holders[i];
            var users = self._use_classes();
            var ok = (NameLookup::tu_of(NameLookup::context_of(holder)) == self.sc->tu);
            for var k: usize = 0; (k < users.size()) && (!ok); ++k {
                if users[k] == holder { ok = true; }
                var s2 = vec::<*Decl>();
                if (ev == 2) && self._derives(users[k], holder, &s2, 0) { ok = true; }
            }
            if ok { continue; }
            var nm = self._tu.decl_name(d);
            var hn = self._tu.decl_name(holder);
            var bn = self._tu.decl_name(owner);
            var word = ("private") if (ev == 1) else ("protected");
            var kw   = ("priv") if (ev == 1) else ("prot");
            var b = self.sc->diag->report(DiagID::SC001E, at.start,
                f"'{nm}' is inaccessible through '{hn}': '{hn}' derives '{bn}' as {word}");
            b.first(at, "not accessible here");
            b.note(DiagID::SC001N, e->range.start, f"'{hn}' declares its base '{bn}' '{kw}' here, so the members of '{bn}' are {word} to '{hn}' and its file").first(e->range);
            b.emit();
            return;
        }
    }

    priv fn _strip(self, t: *Type) -> *Type {
        var c = canon_unqual(t);
        var p = self._tu.pointee(c);
        if p != &null { c = canon_unqual(p); }
        var n = self._tu.nullable_inner(c);
        if n != &null { c = canon_unqual(n); }
        p = self._tu.pointee(c);
        if p != &null { c = canon_unqual(p); }
        return c;
    }

    /// One `derives` path from \p d up to \p base: the edges, and for each
    /// the class that wrote it.
    priv fn _path(self, d: *Decl, base: *Decl, path: *vec::<*InheritEdge>, holders: *vec::<*Decl>,
                  seen: *vec::<*Decl>, depth: u32) -> bool {
        if (d == &null) || (depth > 64) || (!isa::<ClassDecl>(d)) { return false; }
        for var i: usize = 0; i < seen->size(); ++i { if (*seen)[i] == d { return false; } }
        seen->push_back(d);
        var cd = cast::<ClassDecl>(d);
        for var i: usize = 0; i < cd->derives_list.size(); ++i {
            var e = cd->derives_list.get(i);
            var bd = self._edge_rep(e);
            if bd == &null { continue; }
            path->push_back(e);
            holders->push_back(d);
            if bd == base { return true; }
            if self._path(bd, base, path, holders, seen, depth + 1) { return true; }
            path->pop_back();
            holders->pop_back();
        }
        return false;
    }

    // === the diagnostic ========================================================

    priv fn _report(self, d: *Decl, owner: *Decl, v: VisibilityKind, at: SourceRange) {
        var nm   = self._tu.decl_name(d);
        var on   = self._tu.decl_name(owner);
        var word = ("private") if (v == VisibilityKind::Private) else ("protected");
        var kind = self._kind_word(d);
        var msg  = f"{kind} '{nm}' of '{on}' is {word}";
        if kind == "constructor" { msg = f"this constructor of '{on}' is {word}"; }
        var b = self.sc->diag->report(DiagID::SC001E, at.start, msg);
        b.first(at, "not accessible here");
        var r = NameLookup::representative(d);
        if r == &null { r = d; }
        var why = f"accessible only in the file that declares '{on}\x27";
        if v == VisibilityKind::Protected { why = f"accessible only in the file that declares '{on}' and in classes that derive from it"; }
        var written = r->visibility_range();
        var tok = decl_name_tok(r);
        if written.is_valid() {
            b.note(DiagID::SC001N, tok.range.start, f"'{nm}' is declared {word} here: {why}").first(tok.range);
            b.fix(written, "pub", f"make '{nm}' public");
        } else {
            b.note(DiagID::SC001N, tok.range.start, f"'{nm}' is {word} by default (a variable of a class is 'priv' unless marked): {why}").first(tok.range);
            b.insert(r->range.start, "pub ", f"make '{nm}' public");
        }
        b.emit();
    }

    priv fn _kind_word(self, d: *Decl) -> string {
        if isa::<FieldDecl>(d) { return ("static member") if (cast::<FieldDecl>(d)->is_static()) else ("field"); }
        if isa::<VariableDecl>(d) { return "static member"; }
        if isa::<FunctionDecl>(d) {
            var f = cast::<FunctionDecl>(d);
            var dc = reinterpret_cast::<*DeclContext>(f->semantic_dc);
            if (dc != &null) && (dc->owner_decl() != &null) && (self._tu.decl_name(d) == self._tu.decl_name(dc->owner_decl())) { return "constructor"; }
            return "method";
        }
        return "type";
    }
}
