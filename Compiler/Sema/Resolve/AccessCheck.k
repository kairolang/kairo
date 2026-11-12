/// --- The Kairo Project ------------------- Sema/Resolve/AccessCheck.k --- ///
///
///   \brief Enforce pub/priv/prot visibility on every resolved reference.
///
///   \detail
///     Runs after expression typing so it checks what was actually chosen
///     (the overload, the constructor), not what was visible. The rule
///     (classes.mdx Visibility, modules.mdx Visibility Scopes;
///     decided 2026-10-26 and 2026-11-08):
///
///       pub    everywhere.
///       priv   the file that declares the member -- every function in it,
///              free ones included -- and the member's own class.
///       prot   what priv allows, plus every file of the declaring file's
///              module (the tree under the nearest module.k), plus every
///              class deriving from the member's class, in any file. A
///              file in no module shares a `prot` with no other file, and
///              a refused use of one says so (SC272W, chained).
///
///     An unmarked declaration is `priv`, or `prot` in a module
///     (AST/VisibilityFacts.k has the exceptions and the old rule that
///     -fdefault-visibility=pub, builtin and std keep). An extension member
///     follows the same rule from the extension's file, so an `extend C`
///     in another file of C's module reaches C's `prot` members.
///
///     Top-level declarations are checked here when reached through a
///     module (`geo::area()`, `geo::Shape`) or named as a type; a bare name
///     folded by an import is N's (NameResolution::_overlay_access_ok).
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
///     `priv` members are `private:`, `prot` ones `protected:` -- `public:`
///     in a module, which C++ cannot say -- and every record befriends the
///     entities of its own file, which is how C++ says "this file". What
///     this pass admits clang must admit too, so two corners of `prot` are
///     C++'s own ([class.protected]) for a subclass outside the module:
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
///     SC242E, the label at the use, a note at the member,
///     and a fix-it that makes the member `pub`; SC272W chained to it when
///     a `prot` failed only for want of a module.k.
///
///   Phase: CHECKS, after ExprTyper, before InitCheck.
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

import AST::ASTSupport::FrozenList
import AST::Context::DeclContext::DeclContextKind
import AST::Context::TranslationUnit::TranslationUnit
import AST::DeclFacts::{
    decl_is_imported,
    decl_name_tok,
    decl_pattern,
}
import AST::Mixin::Annotation::VisibilityKind
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
import AST::Node::Declarations::{
    ClassDecl,     EnumDecl,   ExtensionDecl, FieldDecl, FunctionDecl, InheritEdge,
    InterfaceDecl, StructDecl, TypeAliasDecl, UnionDecl, VariableDecl,
}
import AST::Node::Expressions::{
    AssignOperatorExpr, BinaryOperatorExpr, CallExpr, NamedInitializerExpr, SubscriptExpr,
    TypeCastExpr,       UnaryOperatorExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Program::TopLevelKind
import AST::Node::Types::ChainType
import AST::VisibilityFacts::{
    default_visibility_of,
    same_module,
    tu_module_dir,
    tu_of_scope,
}
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Code::DiagCode
import Diagnostic::DiagBuilder::DiagBuilder
import Diagnostic::Registry::DiagID
import Location::SourceRange::SourceRange
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::TypeUtil::TypeUtil
import Support::Tuning::DERIVES_WALK_DEPTH_MAX

pub class AccessCheck derives RecursiveASTVisitor<AccessCheck> {
    pub var  sc:  unsafe *SemaContext
    priv var _tu: TypeUtil
    /// The functions being walked, innermost last: their classes are the
    /// use site's (a method's own class, a subclass for `prot`).
    priv var _fns: cxx::std::vector<unsafe *FunctionDecl>
    /// The records being walked lexically: a field default is in its class.
    priv var _recs: cxx::std::vector<unsafe *Decl>

    fn AccessCheck(self, sc: unsafe *SemaContext) {
        self.sc  = sc
        self._tu = TypeUtil(sc)
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::TypesResolved)
        var unsafe *tu = self.sc->tu
        if tu == &null || tu->program == &null {
            return
        }

        var *items = &tu->program->items
        for var i: usize = 0; i < items->size(); ++i {
            if self.stop {
                break
            }

            var item = *items->get(i)
            match item.get_kind() {
                case TopLevelKind::Decl {
                    self.dyn()->dispatch_decl(item.as_decl())
                } case TopLevelKind::Stmt {
                    self.dyn()->dispatch_stmt(item.as_stmt())
                } case TopLevelKind::Expr {
                    self.dyn()->dispatch_expr(item.as_expr())
                }
            }
        }
    }

    /// # where the use is

    fn traverse_function_decl(self, n: unsafe *FunctionDecl) -> unsafe *FunctionDecl {
        self._fns.push_back(n)
        var unsafe *r = RecursiveASTVisitor<AccessCheck>::traverse_function_decl(self, n)
        self._fns.pop_back()
        return r
    }

    fn traverse_class_decl(self, n: unsafe *ClassDecl) -> unsafe *ClassDecl {
        self._recs.push_back(n)
        var unsafe *r = RecursiveASTVisitor<AccessCheck>::traverse_class_decl(self, n)
        self._recs.pop_back()
        return r
    }

    fn traverse_struct_decl(self, n: unsafe *StructDecl) -> unsafe *StructDecl {
        self._recs.push_back(n)
        var unsafe *r = RecursiveASTVisitor<AccessCheck>::traverse_struct_decl(self, n)
        self._recs.pop_back()
        return r
    }

    fn traverse_union_decl(self, n: unsafe *UnionDecl) -> unsafe *UnionDecl {
        self._recs.push_back(n)
        var unsafe *r = RecursiveASTVisitor<AccessCheck>::traverse_union_decl(self, n)
        self._recs.pop_back()
        return r
    }

    /// Every class the use site is inside, as pattern representatives: the
    /// records being walked, and the scopes enclosing the innermost
    /// function -- an out-of-line method's class too, which is not its
    /// lexical parent; an extension member's target, when the extension is
    /// written in the target's own file. One written anywhere else reads
    /// only what its own file may (extends.mdx: an `extend ... impl` in the
    /// interface's file cannot read the type's private members); its scope
    /// struct is not among the target's C++ friends either.
    priv fn _use_classes(self) -> cxx::std::vector<unsafe *Decl> {
        var out = cxx::std::vector<unsafe *Decl>()
        for var i: usize = 0; i < self._recs.size(); ++i {
            out.push_back(self._rep(self._recs[i]))
        }

        if self._fns.size() == 0 {
            return out
        }

        var unsafe *f         = self._fns[self._fns.size() - 1]
        var unsafe *dc        = f->semantic_dc
        var        depth: u32 = 0
        while dc != &null && depth < 64 {
            depth += 1
            if dc->dc_kind == DeclContextKind::Extension {
                var unsafe *ext = dyn_cast<ExtensionDecl>(dc->owner_decl())
                if ext != &null && ext->target != &null && ext->target->canonical != &null {
                    var unsafe *rd  = self._tu.record_decl(canon_unqual(ext->target->canonical))
                    var unsafe *tgt = if (rd != &null) => (self._rep(rd)) else => &null
                    if tgt != &null
                        && NameLookup::tu_of(dc) == NameLookup::tu_of(NameLookup::context_of(tgt)) {
                        out.push_back(tgt)
                    }
                }
            } else if dc->is_type_scope() && dc->owner_decl() != &null {
                out.push_back(self._rep(dc->owner_decl()))
            }

            dc = dc->dc_parent
        }

        return out
    }

    priv fn _rep(self, d: unsafe *Decl) -> unsafe *Decl {
        if d == &null {
            return &null
        }

        return NameLookup::representative(decl_pattern(NameLookup::representative(d)))
    }

    /// # the references

    fn visit_chain_expr(self, n: *ChainExpr) -> bool {
        if n->is_poisoned() {
            return true
        }

        for var i: usize = 0; i < n->steps.size(); ++i {
            var unsafe *st = n->steps.get(i)
            if st == &null || st->resolved_decl == &null {
                continue
            }

            var through: unsafe *Type = &null
            if i == 0 {
                through = self._chain_head_type(n->base)
            } else {
                through = n->steps.get(i - 1)->resolved_type
            }

            self._check(st->resolved_decl, st->range, through)
        }

        return true
    }

    /// The record a chain starts at: the value's type, or the type the head
    /// names (`Acc::hidden`).
    priv fn _chain_head_type(self, e: unsafe *Expr) -> unsafe *Type {
        if e == &null {
            return &null
        }

        if e->type_ != &null {
            return e->type_
        }

        var unsafe *ni = dyn_cast<NamedIdentExpr>(e)
        if ni == &null || ni->resolved_decl == &null {
            return &null
        }

        return &null
    }

    /// A construction (`Base(5)`), never a base initializer: that form
    /// names the constructor through `::` and is a chain step.
    fn visit_call_expr(self, n: *CallExpr) -> bool {
        if n->is_poisoned() || n->ctor_decl == &null {
            return true
        }

        self._check(n->ctor_decl, n->range, &null, true)
        return true
    }

    // An operator expression is a call of the member operator X selected,
    // reached through its left (or only) operand, as `a.op+(b)` would be.
    // A free operator found by ADL is no member: nothing to check here.

    fn visit_binary_operator_expr(self, n: unsafe *BinaryOperatorExpr) -> bool {
        if n->is_poisoned() || n->resolved_op == &null || n->op_via_free {
            return true
        }

        self._check(n->resolved_op, n->op_token.range, self._type_of(n->lhs))
        return true
    }

    fn visit_assign_operator_expr(self, n: unsafe *AssignOperatorExpr) -> bool {
        if n->is_poisoned() || n->resolved_op == &null || n->op_via_free {
            return true
        }

        self._check(n->resolved_op, n->op_token.range, self._type_of(n->lhs))
        return true
    }

    fn visit_unary_operator_expr(self, n: unsafe *UnaryOperatorExpr) -> bool {
        if n->is_poisoned() || n->resolved_op == &null || n->op_via_free {
            return true
        }

        self._check(n->resolved_op, n->op_token.range, self._type_of(n->operand))
        return true
    }

    fn visit_subscript_expr(self, n: unsafe *SubscriptExpr) -> bool {
        if n->is_poisoned() || n->resolved_op == &null || n->op_via_free {
            return true
        }

        self._check(n->resolved_op, n->range, self._type_of(n->base))
        return true
    }

    /// `x as T` through a conversion operator of x's class, or a
    /// converting constructor of T's -- a construction like any other.
    fn visit_type_cast_expr(self, n: unsafe *TypeCastExpr) -> bool {
        if n->is_poisoned() {
            return true
        }

        if n->resolved_op != &null && !n->op_via_free {
            self._check(n->resolved_op, n->range, self._type_of(n->operand))
        }

        if n->resolved_ctor != &null {
            self._check(n->resolved_ctor, n->range, &null, true)
        }

        return true
    }

    priv fn _type_of(self, e: unsafe *Expr) -> unsafe *Type {
        return if (e != &null) => (e->type_) else => &null
    }

    fn visit_named_initializer_expr(self, n: unsafe *NamedInitializerExpr) -> bool {
        if n->is_poisoned() || n->type_ == &null {
            return true
        }

        var unsafe *rd = self._tu.record_decl(canon_unqual(n->type_))
        if rd == &null {
            return true
        }

        var unsafe *body = self.sc->record_body(canon_unqual(n->type_))
        if body == &null {
            body = decl_pattern(rd)
        }

        var fields: unsafe *FrozenList<unsafe *FieldDecl> = &null
        if isa<ClassDecl>(body) {
            fields = unsafe &cast<ClassDecl>(body)->fields
        } else if isa<StructDecl>(body) {
            fields = unsafe &cast<StructDecl>(body)->fields
        } else if isa<UnionDecl>(body) {
            fields = unsafe &cast<UnionDecl>(body)->fields
        }

        if fields == &null {
            return true
        }

        var unsafe *fctx = NameLookup::ctx_of(body)
        if fctx == &null {
            return true
        }

        for var i: usize = 0; i < n->fields.size(); ++i {
            var unsafe *fi = n->fields.get(i)
            if fi == &null {
                continue
            }

            var want = self.sc->ctx->get_spelling(fi->name)
            for var j: usize = 0; j < fields->size(); ++j {
                var unsafe *f = (*fields)[j]
                if f == &null || fctx->get_spelling(f->name) != want {
                    continue
                }

                self._check(unsafe (f as unsafe *Decl), fi->range, &null)
                break
            }
        }

        return true
    }

    fn visit_chain_type(self, n: *ChainType) -> bool {
        if n->is_poisoned() {
            return true
        }

        // The first segment is a bare type name: in this file, or folded by
        // an import, whose file's visibility it keeps. Only the top-level
        // rule: a member type named bare is in its class's own scope.
        if n->segments.size() > 0 {
            var unsafe *s0 = n->segments.get(0)
            if s0 != &null
                && s0->resolved_decl != &null
                && self._owner(s0->resolved_decl) == &null {
                self._check(s0->resolved_decl, s0->range, &null)
            }
        }

        for var i: usize = 1; i < n->segments.size(); ++i {
            var unsafe *seg = n->segments.get(i)
            if seg == &null || seg->resolved_decl == &null {
                continue
            }

            self._check(seg->resolved_decl, seg->range, &null)
        }

        return true
    }

    /// # the rule

    /// Report \p d used at \p at when the use site may not see it; \p through
    /// is the type it was reached through (inheritance visibility, and the
    /// object a subclass reaches a `prot` member through), or null.
    /// \p construction: \p d is the constructor a construction selected.
    priv fn _check(self,
                   d_in:         unsafe *Decl,
                   at:           SourceRange,
                   through:      unsafe *Type,
                   construction: bool = false) {
        var unsafe *d = d_in
        if d == &null || d->is_implicit || d->is_poisoned() || decl_is_imported(d) {
            return
        }

        var unsafe *owner = self._owner(d)
        if owner == &null {
            self._check_top(d, at)
            return
        }

        if decl_is_imported(owner) {
            return
        }

        var v = self._effective(d, owner)
        if v != VisibilityKind::Private && v != VisibilityKind::Protected {
            self._check_edges(d, owner, at, through)
            return
        }

        var why = self._may_see(d, owner, v, through, construction)
        if why != 0 {
            if why == 2 {
                self._report_prot_object(d, owner, at, through)
            } else if why == 3 {
                self._report_prot_ctor(d, owner, at)
            } else {
                self._report(d, owner, v, at)
            }

            return
        }

        self._check_edges(d, owner, at, through)
    }

    /// Whether the use site may see a member of \p owner at visibility \p v
    /// whose home is \p d's file: 0 it may; 1 it is outside the member's
    /// reach; 2 a subclass reaches an instance `prot` member through an
    /// object that is not of its own class; 3 a subclass builds a
    /// standalone object through a `prot` constructor.
    priv fn _may_see(self,
                     d:            unsafe *Decl,
                     owner:        unsafe *Decl,
                     v:            VisibilityKind,
                     through:      unsafe *Type,
                     construction: bool) -> u8 {
        var unsafe *home = self._home(d, owner)
        if home == &null || home == self.sc->tu {
            return 0
        }

        var users = self._use_classes()
        for var i: usize = 0; i < users.size(); ++i {
            if users[i] == owner {
                return 0
            }
        }

        if v != VisibilityKind::Protected {
            return 1
        }

        // A file of the module: `prot` is emitted `public:` there
        // (InterfaceEmitter::_cxx_vis), so no C++ corner applies.
        if same_module(home, self.sc->tu) {
            return 0
        }

        var why: u8 = 1
        for var i: usize = 0; i < users.size(); ++i {
            var seen = cxx::std::vector<unsafe *Decl>()
            if !self._derives(users[i], owner, unsafe &seen, 0) {
                continue
            }

            // [class.protected]: the C++ a subclass is emitted as reaches
            // the base's protected constructor only from its own
            // mem-initializer, and an instance member only through its own
            // kind of object. Kairo's rule is C++'s here, or the emitted
            // `protected:` refuses what this pass admitted.
            if construction && self._is_ctor(d) {
                why = 3
                continue
            }

            if !self._prot_object_ok(d, users[i], through) {
                why = 2
                continue
            }

            return 0
        }

        return why
    }

    /// \p d is reached by subclass \p user through a \p through that C++
    /// lets it reach a protected member by: a static member, a nested type
    /// or a constructor named by `::` need no object; an instance member
    /// needs one whose class is \p user or derives from it.
    priv fn _prot_object_ok(self,
                            d:       unsafe *Decl,
                            user:    unsafe *Decl,
                            through: unsafe *Type) -> bool {
        if through == &null || !self._is_instance_member(d) {
            return true
        }

        var unsafe *rd = self._tu.record_decl(canon_unqual(self._tu.as_value(self._strip(through))))
        if rd == &null {
            return true
        }

        var unsafe *from = self._rep(rd)
        if from == &null || from == user {
            return true
        }

        var seen = cxx::std::vector<unsafe *Decl>()
        return self._derives(from, user, unsafe &seen, 0)
    }

    priv fn _is_instance_member(self, d: unsafe *Decl) -> bool {
        if isa<FieldDecl>(d) {
            return !cast<FieldDecl>(d)->is_static()
        }

        if isa<FunctionDecl>(d) {
            var unsafe *f = cast<FunctionDecl>(d)
            return f->is_method() && !self._is_ctor(d)
        }

        return false
    }

    priv fn _is_ctor(self, d: unsafe *Decl) -> bool {
        if (!isa<FunctionDecl>(d)) || cast<FunctionDecl>(d)->is_operator {
            return false
        }

        var unsafe *dc = d->semantic_dc
        return dc != &null
            && dc->owner_decl() != &null
            && self._name(d) == self._tu.decl_name(dc->owner_decl())
    }

    /// The record (or extension target) \p d is a member of, as a pattern
    /// representative; null for anything that is not a member.
    priv fn _owner(self, d: unsafe *Decl) -> unsafe *Decl {
        if d->semantic_dc == &null {
            return &null
        }

        var unsafe *dc = d->semantic_dc
        var unsafe *od = dc->owner_decl()
        if od == &null {
            return &null
        }

        if dc->dc_kind == DeclContextKind::Extension {
            var unsafe *ext = dyn_cast<ExtensionDecl>(od)
            if ext == &null || ext->target == &null || ext->target->canonical == &null {
                return &null
            }

            var unsafe *rd = self._tu.record_decl(canon_unqual(ext->target->canonical))
            if rd == &null {
                return &null
            }

            return self._rep(rd)
        }

        if isa<ClassDecl>(od) || isa<StructDecl>(od) || isa<UnionDecl>(od) || isa<EnumDecl>(od) {
            return self._rep(od)
        }

        return &null
    }

    /// \p d's own visibility, the default applied (AST/VisibilityFacts.k):
    /// `priv`, or `prot` in a module; under the old rule a class's
    /// variables `priv` and everything else `pub`.
    priv fn _effective(self, d: unsafe *Decl, owner: unsafe *Decl) -> VisibilityKind {
        var v = self._written(d)
        if v != VisibilityKind::None {
            return v
        }

        var unsafe *home = if (owner != &null) => (self._home(d, owner)) else => &null
        return default_visibility_of(d, home)
    }

    /// The keyword \p d's redeclaration chain wrote, or None.
    priv fn _written(self, d: unsafe *Decl) -> VisibilityKind {
        var unsafe *r = NameLookup::representative(d)
        var        v  = d->visibility
        if v == VisibilityKind::None && r != &null {
            v = r->visibility
        }

        return v
    }

    /// # top-level declarations

    /// A function, variable or type declared at a file's top level (or in
    /// a `module` block in it), reached from another file: through a module
    /// (`geo::area`), or by a bare type name an import folded. `priv` is
    /// its file's, `prot` its module's.
    priv fn _check_top(self, d_in: unsafe *Decl, at: SourceRange) {
        var unsafe *d = self._rep(d_in)
        if d == &null {
            d = d_in
        }

        if !(isa<FunctionDecl>(d)
            || isa<VariableDecl>(d)
            || isa<ClassDecl>(d)
            || isa<StructDecl>(d)
            || isa<UnionDecl>(d)
            || isa<EnumDecl>(d)
            || isa<InterfaceDecl>(d)
            || isa<TypeAliasDecl>(d)) {
            return
        }

        var unsafe *dc = d->semantic_dc
        if dc == &null {
            return
        }

        if dc->dc_kind != DeclContextKind::TranslationUnit
            && dc->dc_kind != DeclContextKind::Module {
            return
        }

        var unsafe *home = tu_of_scope(dc)
        if home == &null || home == self.sc->tu || home->is_foreign {
            return
        }

        var v = self._written(d)
        if v == VisibilityKind::None {
            v = default_visibility_of(d, home)
        }

        if v != VisibilityKind::Private && v != VisibilityKind::Protected {
            return
        }

        if v == VisibilityKind::Protected && same_module(home, self.sc->tu) {
            return
        }

        var nm   = self._tu.decl_name(d)
        var word = if (v == VisibilityKind::Private) => ("private") else => "protected"
        var msg  = f"'{nm}' is private to its file"
        if v == VisibilityKind::Protected {
            msg = if (tu_module_dir(
                      home,
                  ).empty()) => (f"'{nm}' is protected, and its file is in no module, so it is visible only in its file")
                  else => f"'{nm}' is protected to its module"
        }

        var b = self.sc->diag->report(DiagID::SC242E, at.start, msg)
        b.first(at, "not accessible here")
        var tok_r   = self._name_range(d)
        var written = d->visibility_range()
        if written.is_valid() {
            b.note(DiagCode(DiagID::SC242N), tok_r.start, f"'{nm}' is declared {word} here")->first(
                tok_r,
            )
        } else {
            b.note(
                DiagCode(DiagID::SC242N),
                tok_r.start,
                f"'{nm}' is {word} by default: {self._default_why(home)}",
            )->first(tok_r)
        }

        self._pub_fix(&b, d, nm)
        self._no_module_warning(&b, v, home, at, nm)
        b.emit()
    }

    /// Why an unmarked declaration of \p home is what it is.
    priv fn _default_why(self, home: unsafe *TranslationUnit) -> string {
        if tu_module_dir(home).empty() {
            return "a declaration with no visibility keyword is 'priv' when its file has no module.k above it"
        }

        return "a declaration with no visibility keyword is 'prot', visible in the files of its module (the directory of the nearest module.k)"
    }

    /// SC272W, chained to a refusal: \p v is `prot` and its file is in no
    /// module, so the use failed only for want of a module.k.
    priv fn _no_module_warning(self,
                               b:        *DiagBuilder,
                               v:        VisibilityKind,
                               home:     unsafe *TranslationUnit,
                               at:       SourceRange,
                               const nm: string) {
        if v != VisibilityKind::Protected || !tu_module_dir(home).empty() {
            return
        }

        b->warning(
            DiagCode(DiagID::SC272W),
            at.start,
            f"'{nm}' is 'prot', but its file has no module.k above it, so it is shared with no other file; add a module.k to the directory that should share it",
        )->child_first(at)
    }

    /// The file \p d's visibility is relative to: its class's, read off the
    /// pattern (an instance's members are minted wherever it is used), or
    /// an extension's own.
    priv fn _home(self, d: unsafe *Decl, owner: unsafe *Decl) -> unsafe *TranslationUnit {
        var unsafe *dc = d->semantic_dc
        if dc->dc_kind == DeclContextKind::Extension {
            return NameLookup::tu_of(dc)
        }

        return NameLookup::tu_of(NameLookup::context_of(owner))
    }

    /// \p d reaches \p base through `derives` edges, by pattern entity.
    priv fn _derives(self,
                     d:     unsafe *Decl,
                     base:  unsafe *Decl,
                     seen:  unsafe *cxx::std::vector<unsafe *Decl>,
                     depth: u32) -> bool {
        if d == &null || depth > DERIVES_WALK_DEPTH_MAX || !isa<ClassDecl>(d) {
            return false
        }

        for var i: usize = 0; i < seen->size(); ++i {
            if (*seen)[i] == d {
                return false
            }
        }

        seen->push_back(d)
        var unsafe *cd = cast<ClassDecl>(d)
        for var i: usize = 0; i < cd->derives_list.size(); ++i {
            var unsafe *bd = self._edge_rep(cd->derives_list.get(i))
            if bd == &null {
                continue
            }

            if bd == base {
                return true
            }

            if self._derives(bd, base, seen, depth + 1) {
                return true
            }
        }

        return false
    }

    priv fn _edge_rep(self, e: unsafe *InheritEdge) -> unsafe *Decl {
        if e == &null || e->base == &null || e->base->canonical == &null {
            return &null
        }

        var unsafe *r = dyn_cast<RecordType>(canon_unqual(e->base->canonical))
        if r == &null || r->decl == &null {
            return &null
        }

        return self._rep(r->decl)
    }

    /// # inheritance visibility

    /// A member of \p owner reached through a record that derives it with a
    /// `priv` or `prot` edge on the way: the edge's class is the member's
    /// home for this use, at the edge's visibility.
    priv fn _check_edges(self,
                         d:       unsafe *Decl,
                         owner:   unsafe *Decl,
                         at:      SourceRange,
                         through: unsafe *Type) {
        if through == &null {
            return
        }

        var unsafe *rd = self._tu.record_decl(canon_unqual(self._tu.as_value(self._strip(through))))
        if rd == &null {
            return
        }

        var unsafe *from = self._rep(rd)
        if from == &null || from == owner {
            return
        }

        var seen    = cxx::std::vector<unsafe *Decl>()
        var path    = cxx::std::vector<unsafe *InheritEdge>()
        var holders = cxx::std::vector<unsafe *Decl>()
        if !self._path(from, owner, unsafe &path, unsafe &holders, unsafe &seen, 0) {
            return
        }

        for var i: usize = 0; i < path.size(); ++i {
            var unsafe *e = path[i]
            var        ev = e->visibility
            if ev != 1 && ev != 2 { // VIS_PRIV / VIS_PROT; none and pub are public.
                continue
            }

            var unsafe *holder = holders[i]
            var        users   = self._use_classes()
            var unsafe *htu    = NameLookup::tu_of(NameLookup::context_of(holder))
            var        ok      = htu == self.sc->tu || ev == 2 && same_module(htu, self.sc->tu)
            for var k: usize = 0; k < users.size() && !ok; ++k {
                if users[k] == holder {
                    ok = true
                }

                var s2 = cxx::std::vector<unsafe *Decl>()
                if ev == 2 && self._derives(users[k], holder, unsafe &s2, 0) {
                    ok = true
                }
            }

            if ok {
                continue
            }

            var nm   = self._name(d)
            var hn   = self._tu.decl_name(holder)
            var bn   = self._tu.decl_name(owner)
            var word = if (ev == 1) => ("private") else => "protected"
            var kw   = if (ev == 1) => ("priv") else => "prot"
            var b = self.sc->diag->report(
                DiagID::SC242E,
                at.start,
                f"'{nm}' is inaccessible through '{hn}': '{hn}' derives '{bn}' as {word}",
            )

            b.first(at, "not accessible here")
            b.note(
                DiagCode(DiagID::SC242N),
                e->range.start,
                f"'{hn}' declares its base '{bn}' '{kw}' here, so the members of '{bn}' are {word} to '{hn}' and its file",
            )->first(e->range)
            b.emit()
            return
        }
    }

    priv fn _strip(self, t: unsafe *Type) -> unsafe *Type {
        var unsafe *c = canon_unqual(t)
        var unsafe *p = self._tu.pointee(c)
        if p != &null {
            c = canon_unqual(p)
        }

        var unsafe *n = self._tu.nullable_inner(c)
        if n != &null {
            c = canon_unqual(n)
        }

        p = self._tu.pointee(c)
        if p != &null {
            c = canon_unqual(p)
        }

        return c
    }

    /// One `derives` path from \p d up to \p base: the edges, and for each
    /// the class that wrote it.
    priv fn _path(self,
                  d:       unsafe *Decl,
                  base:    unsafe *Decl,
                  path:    unsafe *cxx::std::vector<unsafe *InheritEdge>,
                  holders: unsafe *cxx::std::vector<unsafe *Decl>,
                  seen:    unsafe *cxx::std::vector<unsafe *Decl>,
                  depth:   u32) -> bool {
        if d == &null || depth > DERIVES_WALK_DEPTH_MAX || !isa<ClassDecl>(d) {
            return false
        }

        for var i: usize = 0; i < seen->size(); ++i {
            if (*seen)[i] == d {
                return false
            }
        }

        seen->push_back(d)
        var unsafe *cd = cast<ClassDecl>(d)
        for var i: usize = 0; i < cd->derives_list.size(); ++i {
            var unsafe *e  = cd->derives_list.get(i)
            var unsafe *bd = self._edge_rep(e)
            if bd == &null {
                continue
            }

            path->push_back(e)
            holders->push_back(d)
            if bd == base {
                return true
            }

            if self._path(bd, base, path, holders, seen, depth + 1) {
                return true
            }

            path->pop_back()
            holders->pop_back()
        }

        return false
    }

    /// # the diagnostic

    priv fn _report(self,
                    d:     unsafe *Decl,
                    owner: unsafe *Decl,
                    v:     VisibilityKind,
                    at:    SourceRange) {
        var nm   = self._name(d)
        var on   = self._tu.decl_name(owner)
        var word = if (v == VisibilityKind::Private) => ("private") else => "protected"
        var kind = self._kind_word(d)
        var msg  = f"{kind} '{nm}' of '{on}' is {word}"
        if kind == "constructor" {
            msg = f"this constructor of '{on}' is {word}"
        }

        var b = self.sc->diag->report(DiagID::SC242E, at.start, msg)
        b.first(at, "not accessible here")
        var unsafe *r = NameLookup::representative(d)
        if r == &null {
            r = d
        }

        var unsafe *home     = self._home(d, owner)
        var        in_module = !tu_module_dir(home).empty()
        var        why       = f"accessible only in the file that declares '{on}'"
        if v == VisibilityKind::Protected {
            why = f"accessible only in the file that declares '{on}' and in classes that derive from it"
            if in_module {
                why = f"accessible only in the module of the file that declares '{on}' and in classes that derive from it"
            }
        }

        var written = r->visibility_range()
        var tok_r   = self._name_range(r)
        if written.is_valid() {
            b.note(
                DiagCode(DiagID::SC242N),
                tok_r.start,
                f"'{nm}' is declared {word} here: {why}",
            )->first(tok_r)
            b.fix(written, "pub", f"make '{nm}' public")
        } else {
            // The old rule's one default, kept word for word where the new
            // rule agrees (a class's variable outside a module).
            var unsafe *odc = d->semantic_dc
            var class_var = odc != &null
                && odc->owner_decl() != &null
                && isa<ClassDecl>(odc->owner_decl())
                && (isa<FieldDecl>(d) || isa<VariableDecl>(d))
            var dflt = "a variable of a class is 'priv' unless marked"
            if !class_var || in_module {
                dflt = if (in_module) => ("a member with no visibility keyword is 'prot' in a module")
                       else => "a member with no visibility keyword is 'priv' when its file has no module.k above it"
            }

            b.note(
                DiagCode(DiagID::SC242N),
                tok_r.start,
                f"'{nm}' is {word} by default ({dflt}): {why}",
            )->first(tok_r)
            b.insert(r->range.start, "pub ", f"make '{nm}' public")
        }

        self._no_module_warning(&b, v, home, at, nm)
        b.emit()
    }

    /// A subclass reached an instance `prot` member through an object that
    /// is not of its own kind (`b->hits` with `b: *Base`, or a sibling).
    priv fn _report_prot_object(self,
                                d:       unsafe *Decl,
                                owner:   unsafe *Decl,
                                at:      SourceRange,
                                through: unsafe *Type) {
        var nm    = self._name(d)
        var on    = self._tu.decl_name(owner)
        var kind  = self._kind_word(d)
        var ts    = self._tu.str(self._tu.as_value(self._strip(through)))
        var un    = "the class it is used in"
        var users = self._use_classes()
        for var i: usize = 0; i < users.size(); ++i {
            var seen = cxx::std::vector<unsafe *Decl>()
            if self._derives(users[i], owner, unsafe &seen, 0) {
                un = f"'{self._tu.decl_name(users[i])}'"
                break
            }
        }

        var b = self.sc->diag->report(
            DiagID::SC242E,
            at.start,
            f"protected {kind} '{nm}' of '{on}' is reached here through a '{ts}', not through {un} or a class deriving from it",
        )

        b.first(at, "not accessible through this object")
        var unsafe *r = NameLookup::representative(d)
        if r == &null {
            r = d
        }

        var tok_r = self._name_range(r)
        b.note(
            DiagCode(DiagID::SC242N),
            tok_r.start,
            f"'{nm}' is protected: outside the file that declares '{on}', a class deriving from it reaches it only through an object of its own class (as C++ does, [class.protected])",
        )->first(tok_r)
        self._pub_fix(&b, r, nm)
        b.emit()
    }

    /// A subclass built a standalone object through a `prot` constructor.
    priv fn _report_prot_ctor(self, d: unsafe *Decl, owner: unsafe *Decl, at: SourceRange) {
        var on = self._tu.decl_name(owner)
        var b = self.sc->diag->report(
            DiagID::SC242E,
            at.start,
            f"this constructor of '{on}' is protected: a class deriving from '{on}' calls it only as a base initializer, not to build a separate '{on}'",
        )

        b.first(at, "not accessible here")
        var unsafe *r = NameLookup::representative(d)
        if r == &null {
            r = d
        }

        var tok_r = self._name_range(r)
        b.note(
            DiagCode(DiagID::SC242N),
            tok_r.start,
            f"declared protected here: outside the file that declares '{on}', a subclass calls it only as '{on}::{on}(self, ...)' at the start of its own constructor",
        )->first(tok_r)
        self._pub_fix(&b, r, on)
        b.emit()
    }

    /// The fix-it every refusal offers: make the member `pub`.
    priv fn _pub_fix(self, b: *DiagBuilder, r: unsafe *Decl, const nm: string) {
        var written = r->visibility_range()
        if written.is_valid() {
            b->fix(written, "pub", f"make '{nm}' public")
        } else {
            b->insert(r->range.start, "pub ", f"make '{nm}' public")
        }
    }

    priv fn _kind_word(self, d: unsafe *Decl) -> string {
        if isa<FieldDecl>(d) {
            return if (cast<FieldDecl>(d)->is_static()) => ("static member") else => "field"
        }

        if isa<VariableDecl>(d) {
            return "static member"
        }

        if isa<FunctionDecl>(d) {
            if cast<FunctionDecl>(d)->is_operator {
                return "operator"
            }

            if self._is_ctor(d) {
                return "constructor"
            }

            return "method"
        }

        return "type"
    }

    /// A member's name as the user wrote it: `op +` for an operator, whose
    /// name token is not an identifier.
    priv fn _name(self, d: unsafe *Decl) -> string {
        var unsafe *f = dyn_cast<FunctionDecl>(d)
        if f == &null || !f->is_operator {
            return self._tu.decl_name(d)
        }

        var unsafe *ctx = NameLookup::ctx_of(d)
        var        s    = "op "
        for var i: usize = 0; i < f->op_token.size(); ++i {
            s += ctx->get_spelling(f->op_token[i])
        }

        return s
    }

    /// Where a member's name is written, for the note: an operator's symbol.
    priv fn _name_range(self, d: unsafe *Decl) -> SourceRange {
        var unsafe *f = dyn_cast<FunctionDecl>(d)
        if f != &null && f->is_operator && f->op_token.size() > 0 {
            return f->op_token[0].range
        }

        return decl_name_tok(d).range
    }
}
