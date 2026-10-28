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
///     fills, the nested types a type path names, and the user operator an
///     operator expression or a cast selected. Imported C++ members are
///     clang's to judge, and compiler-made ones have no user to answer.
///
///     The emitted C++ carries the same rule (InterfaceEmitter::_cxx_vis):
///     `priv` members are `private:`, `prot` ones `protected:`, and every
///     record befriends the entities of its own file, which is how C++
///     says "this file". What this pass admits clang must admit too, so
///     two corners of `prot` are C++'s own ([class.protected]):
///
///       - a subclass in another file reaches an instance member of its
///         base only through an object of its own class (or one deriving
///         from it), never through a bare `*Base` or a sibling class;
///       - it calls a `prot` constructor only as a base initializer
///         (`Base::Base(self, ...)`), never to build a standalone `Base`.
///
///     And an extension written in another file is not its target's class
///     here (extends.mdx): its members read what their own file may, and
///     its C++ scope struct is no friend of the target.
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
    /// lexical parent; an extension member's target, when the extension is
    /// written in the target's own file. One written anywhere else reads
    /// only what its own file may (extends.mdx: an `extend ... impl` in the
    /// interface's file cannot read the type's private members); its scope
    /// struct is not among the target's C++ friends either.
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
                    var tgt = (self._rep(rd)) if (rd != &null) else (&null);
                    if (tgt != &null) && (NameLookup::tu_of(dc) == NameLookup::tu_of(NameLookup::context_of(tgt))) { out.push_back(tgt); }
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

    /// A construction (`Base(5)`), never a base initializer: that form
    /// names the constructor through `::` and is a chain step.
    fn visit_call_expr(self, n: *CallExpr) -> bool {
        if n->is_poisoned() || (n->ctor_decl == &null) { return true; }
        self._check(n->ctor_decl, n->range, &null, true);
        return true;
    }

    // An operator expression is a call of the member operator X selected,
    // reached through its left (or only) operand, as `a.op+(b)` would be.
    // A free operator found by ADL is no member: nothing to check here.

    fn visit_binary_operator_expr(self, n: *BinaryOperatorExpr) -> bool {
        if n->is_poisoned() || (n->resolved_op == &null) || n->op_via_free { return true; }
        self._check(n->resolved_op, n->op_token.range, self._type_of(n->lhs));
        return true;
    }

    fn visit_assign_operator_expr(self, n: *AssignOperatorExpr) -> bool {
        if n->is_poisoned() || (n->resolved_op == &null) || n->op_via_free { return true; }
        self._check(n->resolved_op, n->op_token.range, self._type_of(n->lhs));
        return true;
    }

    fn visit_unary_operator_expr(self, n: *UnaryOperatorExpr) -> bool {
        if n->is_poisoned() || (n->resolved_op == &null) || n->op_via_free { return true; }
        self._check(n->resolved_op, n->op_token.range, self._type_of(n->operand));
        return true;
    }

    fn visit_subscript_expr(self, n: *SubscriptExpr) -> bool {
        if n->is_poisoned() || (n->resolved_op == &null) || n->op_via_free { return true; }
        self._check(n->resolved_op, n->range, self._type_of(n->base));
        return true;
    }

    /// `x as T` through a conversion operator of x's class, or a
    /// converting constructor of T's -- a construction like any other.
    fn visit_type_cast_expr(self, n: *TypeCastExpr) -> bool {
        if n->is_poisoned() { return true; }
        if (n->resolved_op != &null) && (!n->op_via_free) { self._check(n->resolved_op, n->range, self._type_of(n->operand)); }
        if n->resolved_ctor != &null { self._check(n->resolved_ctor, n->range, &null, true); }
        return true;
    }

    priv fn _type_of(self, e: *Expr) -> *Type {
        return (e->type_) if (e != &null) else (&null);
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
    /// is the type it was reached through (inheritance visibility, and the
    /// object a subclass reaches a `prot` member through), or null.
    /// \p construction: \p d is the constructor a construction selected.
    priv fn _check(self, d_in: *Decl, at: SourceRange, through: *Type, construction: bool = false) {
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
        var why = self._may_see(d, owner, v, through, construction);
        if why != 0 {
            if why == 2 { self._report_prot_object(d, owner, at, through); }
            else if why == 3 { self._report_prot_ctor(d, owner, at); }
            else { self._report(d, owner, v, at); }
            return;
        }
        self._check_edges(d, owner, at, through);
    }

    /// Whether the use site may see a member of \p owner at visibility \p v
    /// whose home is \p d's file: 0 it may; 1 it is outside the member's
    /// reach; 2 a subclass reaches an instance `prot` member through an
    /// object that is not of its own class; 3 a subclass builds a
    /// standalone object through a `prot` constructor.
    priv fn _may_see(self, d: *Decl, owner: *Decl, v: VisibilityKind, through: *Type, construction: bool) -> u8 {
        var home = self._home(d, owner);
        if (home == &null) || (home == self.sc->tu) { return 0; }
        var users = self._use_classes();
        for var i: usize = 0; i < users.size(); ++i { if users[i] == owner { return 0; } }
        if v != VisibilityKind::Protected { return 1; }
        var why: u8 = 1;
        for var i: usize = 0; i < users.size(); ++i {
            var seen = vec::<*Decl>();
            if !self._derives(users[i], owner, &seen, 0) { continue; }
            // [class.protected]: the C++ a subclass is emitted as reaches
            // the base's protected constructor only from its own
            // mem-initializer, and an instance member only through its own
            // kind of object. Kairo's rule is C++'s here, or the emitted
            // `protected:` refuses what this pass admitted.
            if construction && self._is_ctor(d) { why = 3; continue; }
            if !self._prot_object_ok(d, users[i], through) { why = 2; continue; }
            return 0;
        }
        return why;
    }

    /// \p d is reached by subclass \p user through a \p through that C++
    /// lets it reach a protected member by: a static member, a nested type
    /// or a constructor named by `::` need no object; an instance member
    /// needs one whose class is \p user or derives from it.
    priv fn _prot_object_ok(self, d: *Decl, user: *Decl, through: *Type) -> bool {
        if (through == &null) || (!self._is_instance_member(d)) { return true; }
        var rd = self._tu.record_decl(canon_unqual(self._tu.as_value(self._strip(through))));
        if rd == &null { return true; }
        var from = self._rep(rd);
        if (from == &null) || (from == user) { return true; }
        var seen = vec::<*Decl>();
        return self._derives(from, user, &seen, 0);
    }

    priv fn _is_instance_member(self, d: *Decl) -> bool {
        if isa::<FieldDecl>(d) { return !cast::<FieldDecl>(d)->is_static(); }
        if isa::<FunctionDecl>(d) {
            var f = cast::<FunctionDecl>(d);
            return f->is_method() && (!self._is_ctor(d));
        }
        return false;
    }

    priv fn _is_ctor(self, d: *Decl) -> bool {
        if (!isa::<FunctionDecl>(d)) || cast::<FunctionDecl>(d)->is_operator { return false; }
        var dc = reinterpret_cast::<*DeclContext>(d->semantic_dc);
        return (dc != &null) && (dc->owner_decl() != &null) && (self._name(d) == self._tu.decl_name(dc->owner_decl()));
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
            var nm = self._name(d);
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
        var nm   = self._name(d);
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
        var tok_r = self._name_range(r);
        if written.is_valid() {
            b.note(DiagID::SC001N, tok_r.start, f"'{nm}' is declared {word} here: {why}").first(tok_r);
            b.fix(written, "pub", f"make '{nm}' public");
        } else {
            b.note(DiagID::SC001N, tok_r.start, f"'{nm}' is {word} by default (a variable of a class is 'priv' unless marked): {why}").first(tok_r);
            b.insert(r->range.start, "pub ", f"make '{nm}' public");
        }
        b.emit();
    }

    /// A subclass reached an instance `prot` member through an object that
    /// is not of its own kind (`b->hits` with `b: *Base`, or a sibling).
    priv fn _report_prot_object(self, d: *Decl, owner: *Decl, at: SourceRange, through: *Type) {
        var nm   = self._name(d);
        var on   = self._tu.decl_name(owner);
        var kind = self._kind_word(d);
        var ts   = self._tu.str(self._tu.as_value(self._strip(through)));
        var un   = "the class it is used in";
        var users = self._use_classes();
        for var i: usize = 0; i < users.size(); ++i {
            var seen = vec::<*Decl>();
            if self._derives(users[i], owner, &seen, 0) { un = f"'{self._tu.decl_name(users[i])}\x27"; break; }
        }
        var b = self.sc->diag->report(DiagID::SC001E, at.start,
            f"protected {kind} '{nm}' of '{on}' is reached here through a '{ts}', not through {un} or a class deriving from it");
        b.first(at, "not accessible through this object");
        var r = NameLookup::representative(d);
        if r == &null { r = d; }
        var tok_r = self._name_range(r);
        b.note(DiagID::SC001N, tok_r.start,
            f"'{nm}' is protected: outside the file that declares '{on}', a class deriving from it reaches it only through an object of its own class (as C++ does, [class.protected])").first(tok_r);
        self._pub_fix(&b, r, nm);
        b.emit();
    }

    /// A subclass built a standalone object through a `prot` constructor.
    priv fn _report_prot_ctor(self, d: *Decl, owner: *Decl, at: SourceRange) {
        var on = self._tu.decl_name(owner);
        var b = self.sc->diag->report(DiagID::SC001E, at.start,
            f"this constructor of '{on}' is protected: a class deriving from '{on}' calls it only as a base initializer, not to build a separate '{on}\x27");
        b.first(at, "not accessible here");
        var r = NameLookup::representative(d);
        if r == &null { r = d; }
        var tok_r = self._name_range(r);
        b.note(DiagID::SC001N, tok_r.start,
            f"declared protected here: outside the file that declares '{on}', a subclass calls it only as '{on}::{on}(self, ...)' at the start of its own constructor").first(tok_r);
        self._pub_fix(&b, r, on);
        b.emit();
    }

    /// The fix-it every refusal offers: make the member `pub`.
    priv fn _pub_fix(self, b: *DiagBuilder, r: *Decl, nm: string) {
        var written = r->visibility_range();
        if written.is_valid() { b->fix(written, "pub", f"make '{nm}' public"); }
        else { b->insert(r->range.start, "pub ", f"make '{nm}' public"); }
    }

    priv fn _kind_word(self, d: *Decl) -> string {
        if isa::<FieldDecl>(d) { return ("static member") if (cast::<FieldDecl>(d)->is_static()) else ("field"); }
        if isa::<VariableDecl>(d) { return "static member"; }
        if isa::<FunctionDecl>(d) {
            if cast::<FunctionDecl>(d)->is_operator { return "operator"; }
            if self._is_ctor(d) { return "constructor"; }
            return "method";
        }
        return "type";
    }

    /// A member's name as the user wrote it: `op +` for an operator, whose
    /// name token is not an identifier.
    priv fn _name(self, d: *Decl) -> string {
        var f = dyn_cast::<FunctionDecl>(d);
        if (f == &null) || (!f->is_operator) { return self._tu.decl_name(d); }
        var ctx = NameLookup::ctx_of(d);
        var s = "op ";
        for var i: usize = 0; i < f->op_token.size(); ++i { s += ctx->get_spelling(f->op_token[i]); }
        return s;
    }

    /// Where a member's name is written, for the note: an operator's symbol.
    priv fn _name_range(self, d: *Decl) -> SourceRange {
        var f = dyn_cast::<FunctionDecl>(d);
        if (f != &null) && f->is_operator && (f->op_token.size() > 0) { return f->op_token[0].range; }
        return decl_name_tok(d).range;
    }
}
