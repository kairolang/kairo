/// --- The Kairo Project --------------------------- Parser/DeclParse.k --- ///
///
///   \brief Declaration parsing mixin. Recursive-descent over declaration-
///          position productions.
///
///   \detail
///     Entry point: parse_decl() -> consumes leading annotations/visibility,
///     dispatches on the leading (resolved) keyword to the correct production,
///     stamps annotations, and returns a *Decl. Returns null only at EOF or
///     when the current token cannot begin a declaration (caller decides what
///     that means in its context).
///
///     Derives from ASTParse (CRTP) which provides: check, check_peek,
///     match_tok, expect, advance, retreat, current, peek, prev, current_ptr,
///     ctx, diag, scope, is_eof, enter_depth/exit_depth, enter_scope/exit_scope,
///     consume_leading_annotations, apply_annotations_to_decl, parse_type
///     (TypeParse), parse_expr (ExprParse), parse_compound (StmtParse), etc.
///
///     Several productions are intentionally stubbed pending design sign-off;
///     each is marked with ` std::ICE("...")` so it is greppable:
///       - _parse_import          (7+ import forms; owner will fill in)
///       - _parse_ffi             (ffi "lang" { } and ffi "lang" import ...)
///       - _parse_proc_macro_body (compile-time AST macro bodies)
///
///   Part of the Kairo Project, under the Apache License v2.0 with the Kairo
///   Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------- ///

import AST::Node::Base::*;
import AST::Node::Declarations::*;
import AST::Node::Statements::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Casting::*;
import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::Mixin::Annotation::*;
import Diagnostic::Engine::*;
import Diagnostic::Registry::*;
import Location::SourceRange::*;
import Token::Token::*;
import Token::TokenKind::*;
import Parser::LexicalScope::*;

class <T> DeclParse {
    /// \enum DeclSyncCtx
    /// \brief sync contexts for declaration-level error recovery.
    enum DeclSyncCtx derives u8 {
        TopLevel, ///< sync to a decl lead-in keyword / newline / EOF.
        TypeBody, ///< inside a class/struct/enum/union body: sync to a member
                  ///  lead-in or the closing `}`.
        Params,   ///< inside `( )` param list: sync to `,` or `)`.
        Generics, ///< inside `< >` generic list: sync to `,` or `>`.
    }

    // ========================================================================
    //  CRTP helpers
    // ========================================================================

    priv inline fn dyn(self) -> *T {
        return static_cast::<*T>(&self);
    }

    priv inline fn is_fatal_decl(self, d: *Decl) -> bool {
        inline "c++" {
            return dyn()->template is_fatal<Decl>(d);
        }
    }

    /// \brief true if the resolved token can begin a declaration.
    /// \details mirrors StmtParse::_starts_decl; used both there and here.
    inline fn _starts_decl_kw(self, k: TokenKind) -> bool {
        return k == TokenKind::KwFn
            || k == TokenKind::KwClass
            || k == TokenKind::KwStruct
            || k == TokenKind::KwEnum
            || k == TokenKind::KwInterface
            || k == TokenKind::KwUnion
            || k == TokenKind::KwModule
            || k == TokenKind::KwImport
            || k == TokenKind::KwFfi
            || k == TokenKind::KwExtend
            || k == TokenKind::KwType
            || k == TokenKind::KwMacro
            || k == TokenKind::KwTest
            || k == TokenKind::KwStatic
            || k == TokenKind::KwVar
            || k == TokenKind::KwMutable
            || k == TokenKind::KwConst
            || k == TokenKind::KwEval
            || k == TokenKind::KwPub
            || k == TokenKind::KwPriv
            || k == TokenKind::KwProt
            || k == TokenKind::KwOverride
            || k == TokenKind::KwVirtual
            || k == TokenKind::KwFinal;
    }

    // ========================================================================
    //  Entry point
    // ========================================================================

    /// \brief parses a single declaration.
    ///  Grammar (dispatch):
    ///    visibility? modifiers? ( fn | class | struct | enum | interface
    ///      | union | module | extend | type | macro | test | import | ffi
    ///      | var | const | static | eval )
    ///
    /// \details consumes leading doc comments + visibility into a
    ///          PendingAnnotations buffer, parses the core decl, then stamps
    ///          annotations + visibility onto it. Returns null at EOF or when
    ///          the lead token cannot begin a decl.
    fn parse_decl(self) -> *Decl {
        if dyn()->is_eof() { return &null; }

        inline "c++" { typename T::PendingAnnotations annot; }
        dyn()->consume_leading_annotations(&annot);

        if dyn()->is_eof() { return &null; }

        var d = self._dispatch_decl();
        if (d != &null) && (!is_fatal_decl(d)) {
            if !isa::<VisibilityGroupDecl>(d) {
                dyn()->apply_annotations_to_decl(d, &annot);
            }

            // group case: caller owns the annotation-on-group diagnostic,
            // since parse_decl's local annot buffer is empty when the caller
            // (parse / member-body) already consumed the annotations.
        }

        return d;
    }

    /// \brief routes the current token to its declaration production.
    /// \details visibility and the leading-modifier keywords (override/virtual/
    ///          final/static) are consumed here into a small modifier set that
    ///          is threaded into the function/type productions. Anything not a
    ///          decl lead-in returns null (caller's problem).
    priv fn _dispatch_decl(self) -> *Decl {
        var cur_ptr = dyn()->current_ptr();
        if cur_ptr == &null { return &null; }

        // pub { ... } / priv { ... } / prot { ... } visibility group.
        // consume_leading_annotations leaves the keyword when `{` follows.
        var lead_k = dyn()->resolve_kind_deep(cur_ptr);
        if (   lead_k == TokenKind::KwPub
            || lead_k == TokenKind::KwPriv
            || lead_k == TokenKind::KwProt
           ) && dyn()->check_peek(TokenKind::OpLBrace) {
            return self._parse_visibility_group();
        }

        // leading abi/dispatch modifiers (static/virtual/override) and the
        // `final` class/method modifier are collected, then we re-dispatch on
        // the keyword they precede.
        var lead = self._consume_leading_modifiers();

        var k = dyn()->resolve_kind_deep(dyn()->current_ptr());

        switch k {
            case TokenKind::KwFn        { return self._parse_function(&lead); }
            case TokenKind::KwClass     { return self._parse_class(&lead);    }
            case TokenKind::KwStruct    { return self._parse_struct();        }
            case TokenKind::KwEnum      { return self._parse_enum();          }
            case TokenKind::KwInterface { return self._parse_interface();     }
            case TokenKind::KwUnion     { return self._parse_union();         }
            case TokenKind::KwExtend    { return self._parse_extension();     }
            case TokenKind::KwType      { return self._parse_type_alias();    }
            case TokenKind::KwModule    { return self._parse_module();        }
            case TokenKind::KwTest      { return self._parse_test();          }
            case TokenKind::KwMacro     { return self._parse_macro();         }
            case TokenKind::KwImport    { return self._parse_import();        }
            case TokenKind::KwFfi       { return self._parse_ffi();           }

            case TokenKind::KwVar     { return self._parse_var_decl(); }
            case TokenKind::KwConst   { return self._parse_var_decl(); }
            case TokenKind::KwStatic  { return self._parse_var_decl(); }
            case TokenKind::KwMutable { return self._parse_var_decl(); }
            case TokenKind::KwEval {
                // `eval {` decl block vs `eval var/const/fn ...`
                if dyn()->check_peek(TokenKind::OpLBrace) {
                    return self._parse_eval_block_decl();
                }
                return self._parse_var_decl();
            }
        }

        // not a decl lead-in. If we consumed modifiers, that's a malformed
        // decl head report and recover; otherwise let the caller decide.
        if lead.any {
            var r = dyn()->current_ptr()->range;
            dyn()->diag->report(DiagID::S063E, r.start,
                "expected a declaration after modifiers"
            ).first(r).emit();
            self._sync_decl(DeclSyncCtx::TopLevel);
            return static_cast::<*Decl>(FunctionDecl::create_error(dyn()->ctx, r));
        }

        return &null;
    }

    /// \struct LeadMods
    /// \brief leading modifiers consumed before the decl keyword.
    struct LeadMods {
        var abi:      AbiKind;
        var is_final: bool;
        var any:      bool;     ///< true if any modifier was consumed.
        var range:    SourceRange;
    }

    /// \brief consumes static/virtual/override/final appearing before a decl
    ///        keyword. These bind to fn/class productions downstream.
    priv fn _consume_leading_modifiers(self) -> LeadMods {
        var m = LeadMods{};
        m.abi      = AbiKind::None;
        m.is_final = false;
        m.any      = false;

        var start = dyn()->current_ptr()->range;
        m.range   = start;

        while true {
            if dyn()->check(TokenKind::KwStatic) {
                m.abi = AbiKind::Static; m.any = true; dyn()->advance(); continue;
            }
            if dyn()->check(TokenKind::KwVirtual) {
                m.abi = AbiKind::Virtual; m.any = true; dyn()->advance(); continue;
            }
            if dyn()->check(TokenKind::KwOverride) {
                m.abi = AbiKind::Override; m.any = true; dyn()->advance(); continue;
            }
            if dyn()->check(TokenKind::KwFinal) {
                m.is_final = true; m.any = true; dyn()->advance(); continue;
            }
            break;
        }

        if m.any { m.range = start | dyn()->prev().range; }
        return m;
    }

    // ========================================================================
    //  Visibility group   pub { decl* }
    // ========================================================================

    /// \brief parses a visibility group at decl scope.
    ///  Grammar:  ('pub'|'priv'|'prot') '{' decl* '}'
    ///
    /// \details every member's visibility is stamped from the group keyword.
    ///          an explicit visibility keyword on a member inside the group is
    ///          an ERROR the group is an at-a-glance guarantee and local
    ///          overrides destroy it. nesting another group inside is the same
    ///          error by construction (the inner keyword is explicit
    ///          visibility). attributes/doc-comments on the GROUP itself are
    ///          rejected by parse_decl (see annotation check there); members
    ///          carry their own annotations normally.
    priv fn _parse_visibility_group(self) -> *Decl {
        var start = dyn()->current_ptr()->range;

        var vis: u8 = 3; // Public
        if      dyn()->check(TokenKind::KwPriv) { vis = 1; }
        else if dyn()->check(TokenKind::KwProt) { vis = 2; }
        var vis_kind = static_cast::<VisibilityKind>(vis);

        dyn()->advance(T::SkipNL::After); // consume visibility keyword
        dyn()->advance(T::SkipNL::After); // consume `{`

        var vg = VisibilityGroupDecl::create(dyn()->ctx, start, vis);
        var members: std::StackBuf::<*Decl, 8>;

        while (!dyn()->is_eof()) && (!dyn()->check(TokenKind::OpRBrace)) {
            if dyn()->check(TokenKind::TkNewLine) || dyn()->check(TokenKind::OpSemicolon) {
                dyn()->advance();
                continue;
            }

            var d = self.parse_decl();
            if d == &null { break; }
            if is_fatal_decl(d) { break; }

            if d->has_visibility() {
                dyn()->diag->report(DiagID::S048E, d->visibility_range().start,
                    "explicit visibility is not allowed inside a visibility group"
                ).first(d->visibility_range())
                 .note(DiagID::S048N, d->visibility_range().start,
                    "every member of this group already has the group's visibility; "
                    "move the declaration outside the group to give it different visibility")
                 .emit();
            }
            d->set_visibility(vis_kind, start);

            members.push_back(d);
        }

        if dyn()->check(TokenKind::OpRBrace) {
            dyn()->advance(T::SkipNL::Before);
        } else {
            dyn()->diag->report(DiagID::S051E, start.start,
                "expected '}' to close visibility group"
            ).first(start).emit();
        }

        vg->members.from_buf(members.data(), members.size(), dyn()->ctx);
        vg->range = start | dyn()->prev().range;
        return static_cast::<*Decl>(vg);
    }

    /// \brief visibility group inside a type body. Same rules as decl scope;
    ///        members land in the SAME fields/methods buffers as ungrouped
    ///        members (sema walks one list), and the group node goes into
    ///        owner->dc_decls for printing fidelity, holding member pointers.
    priv fn _parse_member_vis_group(
        self,
        owner:         *DeclContext,
        fields_out:    *std::StackBuf::<*FieldDecl, 8>,
        methods_out:   *std::StackBuf::<*FunctionDecl, 8>,
        allow_methods: bool,
        field_idx:     *u32
    ) {
        var start = dyn()->current_ptr()->range;

        var vis: u8 = 3;
        if      dyn()->check(TokenKind::KwPriv) { vis = 1; }
        else if dyn()->check(TokenKind::KwProt) { vis = 2; }
        var vis_kind = static_cast::<VisibilityKind>(vis);

        dyn()->advance(T::SkipNL::After); // visibility keyword
        dyn()->advance(T::SkipNL::After); // `{`

        var vg = VisibilityGroupDecl::create(dyn()->ctx, start, vis);
        var members: std::StackBuf::<*Decl, 8>;

        while (!dyn()->is_eof()) && (!dyn()->check(TokenKind::OpRBrace)) {
            if dyn()->check(TokenKind::TkNewLine) || dyn()->check(TokenKind::OpSemicolon) {
                dyn()->advance();
                continue;
            }

            inline "c++" { typename T::PendingAnnotations m_annot; }
            dyn()->consume_leading_annotations(&m_annot);
            if dyn()->check(TokenKind::OpRBrace) { break; }

            // explicit visibility inside the group: error, then proceed.
            var m_has_vis = m_annot.visibility != VisibilityKind::None;
            if m_has_vis {
                dyn()->diag->report(DiagID::S048E, m_annot.vis_range.start,
                    "explicit visibility is not allowed inside a visibility group"
                ).first(m_annot.vis_range)
                 .note(DiagID::S048N, start.start,
                    "this visibility group already fixes the visibility of every member; "
                    "move the declaration out of the group to give it different visibility"
                 ).child_first(start)
                 .emit();
            }
            var k = dyn()->resolve_kind_deep(dyn()->current_ptr());

            var is_method_lead = (k == TokenKind::KwFn)
                              || (k == TokenKind::KwStatic)
                              || (k == TokenKind::KwVirtual)
                              || (k == TokenKind::KwOverride)
                              || (k == TokenKind::KwFinal);

            if is_method_lead && allow_methods {
                var lead = self._consume_leading_modifiers();
                if dyn()->check(TokenKind::KwFn) {
                    var m = self._parse_function(&lead);
                    if (m != &null) && isa::<FunctionDecl>(m) {
                        var fm = cast::<FunctionDecl>(m);
                        dyn()->apply_annotations_to_decl(static_cast::<*Decl>(fm), &m_annot);
                        fm->set_visibility(vis_kind, start);
                        methods_out->push_back(fm);
                        members.push_back(static_cast::<*Decl>(fm));
                    }
                } else {
                    self._sync_decl(DeclSyncCtx::TypeBody);
                }
                continue;
            }

            var is_field_lead = (k == TokenKind::KwVar) || (k == TokenKind::KwConst)
                             || (k == TokenKind::KwStatic) || (k == TokenKind::KwEval)
                             || (k == TokenKind::KwMutable);

            if is_field_lead {
                var f = self._parse_field(*field_idx);
                if !is_recovery(static_cast::<*Decl>(f)) {
                    dyn()->apply_annotations_to_decl(static_cast::<*Decl>(f), &m_annot);
                    f->set_visibility(vis_kind, start);
                    fields_out->push_back(f);
                    members.push_back(static_cast::<*Decl>(f));
                    // NOTE: parenthesize the deref. Stage 0 gives prefix `*`
                    // lower precedence than `+=`, so `*field_idx += 1` is
                    // miscompiled as `*(field_idx += 1)` (pointer bump, not
                    // counter bump) -- see the stack-buffer-overflow it caused.
                    (*field_idx) += 1;
                } else {
                    self._sync_decl(DeclSyncCtx::TypeBody);
                }
                continue;
            }

            // nested types etc.
            var nested = self._dispatch_decl();
            if (nested != &null) && (!is_fatal_decl(nested)) {
                dyn()->apply_annotations_to_decl(nested, &m_annot);
                nested->set_visibility(vis_kind, start);
                owner->add_decl(nested);
                members.push_back(nested);
                continue;
            }

            self._sync_decl(DeclSyncCtx::TypeBody);
        }

        if dyn()->check(TokenKind::OpRBrace) {
            dyn()->advance(T::SkipNL::Before);
        } else {
            dyn()->diag->report(DiagID::S051E, start.start,
                "expected '}' to close visibility group"
            ).first(start).emit();
        }

        vg->members.from_buf(members.data(), members.size(), dyn()->ctx);
        vg->range = start | dyn()->prev().range;
        owner->add_decl(static_cast::<*Decl>(vg));
    }

    // ========================================================================
    //  Generic parameter list  <T, T impl Foo, const N: i32, ...T>
    // ========================================================================

    /// \brief parses an optional generic parameter list into `out`.
    ///  Grammar:  '<' generic_param (',' generic_param)* '>'
    ///    generic_param := '...'? identifier (':' kind_bound)?
    ///                     (('impl'|'derives') type (',' type)*)?
    ///                     ('=' type)?
    ///                   | 'const' identifier ':' type ('=' type)?
    ///
    /// \details precondition: current token is `<` (caller checked). On a
    ///          malformed list, recovers to `>` and returns what parsed.
    fn _parse_generic_params(self, out: *std::StackBuf::<*GenericParamDecl, 2>) -> bool {
        if !dyn()->check(TokenKind::OpLess) { return false; }
        var open = dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::After); // consume `<`
        dyn()->nl_push();                 // suppress newlines inside `< >`

        // A nested generic in a *prior* sibling could have left us a pending
        // close-angle, but at the param-list opener that can't have happened
        // yet. Still, clear it defensively so a stale flag from an earlier
        // recovered parse can't leak in.
        if dyn()->_pending_close_angle {
            dyn()->_pending_close_angle = false;
        }

        if dyn()->check(TokenKind::OpGreater) {
            dyn()->diag->report(DiagID::S049E, open.start,
                "empty generic parameter list is not allowed"
            ).first(open).emit();
            dyn()->nl_pop();
            dyn()->advance_raw(); // consume `>`
            return false;
        }

        var idx: u32 = 0;
        while !dyn()->is_eof() {
            var gp = self._parse_one_generic_param(idx);
            if gp == &null {
                self._sync_decl(DeclSyncCtx::Generics);
                // honor a pending close-angle during recovery too
                if dyn()->_pending_close_angle {
                    dyn()->_pending_close_angle = false;
                    dyn()->nl_pop();
                    return false;
                }
                if dyn()->check(TokenKind::OpGreater) {
                    dyn()->nl_pop();
                    dyn()->advance_raw();
                    return false;
                }
                dyn()->nl_pop();
                return false;
            }
            out->push_back(gp);
            ++idx;

            // A bound type on this param (`T: Vec<U>`) may have consumed a
            // `>>` and left us owing one `>`. That closes THIS list.
            if dyn()->_pending_close_angle {
                dyn()->_pending_close_angle = false;
                dyn()->nl_pop();
                return true;
            }

            if dyn()->check(TokenKind::OpComma) {
                dyn()->advance(T::SkipNL::After);
                // trailing comma before either closer
                if dyn()->check(TokenKind::OpGreater) { break; }
                if dyn()->check(TokenKind::OpGreaterGreater) { break; }
                continue;
            }
            break;
        }

        // single `>` closes the list cleanly
        if dyn()->check(TokenKind::OpGreater) {
            dyn()->nl_pop();
            dyn()->advance_raw();
            return true;
        }

        // `>>` here means a nested generic did NOT consume it (e.g. the list
        // itself nests: `<T<U>>` is not valid param syntax, but a trailing
        // comma path can land us on `>>`). Consume one level, leave the other
        // for an enclosing list via the pending flag mirroring TypeParse.
        if dyn()->check(TokenKind::OpGreaterGreater) {
            dyn()->_pending_close_angle = true;
            dyn()->nl_pop();
            dyn()->advance_raw();
            return true;
        }

        dyn()->diag->report(DiagID::S049E, open.start,
            "expected '>' to close generic parameter list"
        ).first(open).emit();
        self._sync_decl(DeclSyncCtx::Generics);
        dyn()->nl_pop();
        return false;
    }

    /// \brief parses a single generic parameter.
    priv fn _parse_one_generic_param(self, idx: u32) -> *GenericParamDecl {
        var start = dyn()->current_ptr()->range;

        // const value parameter: `const N: T`
        if dyn()->check(TokenKind::KwConst) {
            dyn()->advance(T::SkipNL::After); // consume `const`
            if !dyn()->check(TokenKind::LitIdentifier) {
                dyn()->diag->report(DiagID::S049E, start.start,
                    "expected parameter name after 'const' in generic parameter list"
                ).first(start).emit();
                return &null;
            }
            var nm = dyn()->current();
            dyn()->advance();
            if !dyn()->check(TokenKind::OpColon) {
                dyn()->diag->report(DiagID::S049E, start.start,
                    "expected ':' and a type for a const generic value parameter"
                ).first(start).emit();
                return &null;
            }
            dyn()->advance(T::SkipNL::After); // consume `:`
            var vty = dyn()->parse_type();
            if (vty == &null) || is_recovery(vty) {
                return &null;
            }
            var gp = GenericParamDecl::create(dyn()->ctx, start | dyn()->prev().range, nm, idx);
            gp->is_const_param = true;
            gp->value_type     = vty;
            self._maybe_parse_generic_default(gp);
            return gp;
        }

        // variadic pack: `...T`
        var is_pack = false;
        if dyn()->check(TokenKind::OpEllipsis) {
            is_pack = true;
            dyn()->advance(); // consume `...`
        }

        if !dyn()->check(TokenKind::LitIdentifier) {
            dyn()->diag->report(DiagID::S049E, start.start,
                "expected type parameter name in generic parameter list"
            ).first(start).emit();
            return &null;
        }
        var name = dyn()->current();
        dyn()->advance();

        var gp = GenericParamDecl::create(dyn()->ctx, start | dyn()->prev().range, name, idx);
        gp->is_pack = is_pack;

        // optional kind bound: `: class|struct|enum|union`
        if dyn()->check(TokenKind::OpColon) {
            dyn()->advance(T::SkipNL::After); // consume `:`
            gp->kind_bound = self._parse_kind_bound(start);
        }

        // optional impl/derives bounds
        if dyn()->check(TokenKind::KwImpl) || dyn()->check(TokenKind::KwDerives) {
            var bounds: std::StackBuf::<*Type, 4>;
            self._parse_param_bounds(&bounds);
            gp->bounds.from_buf(bounds.data(), bounds.size(), dyn()->ctx);
        }

        self._maybe_parse_generic_default(gp);
        gp->range = start | dyn()->prev().range;
        return gp;
    }

    priv fn _parse_kind_bound(self, ctx_range: SourceRange) -> GenericParamKindBound {
        if dyn()->check(TokenKind::KwClass)     { dyn()->advance(); return GenericParamKindBound::Class;  }
        if dyn()->check(TokenKind::KwStruct)    { dyn()->advance(); return GenericParamKindBound::Struct; }
        if dyn()->check(TokenKind::KwEnum)      { dyn()->advance(); return GenericParamKindBound::Enum;   }
        if dyn()->check(TokenKind::KwUnion)     { dyn()->advance(); return GenericParamKindBound::Union;  }
        dyn()->diag->report(DiagID::S049E, ctx_range.start,
            "expected 'class', 'struct', 'enum', or 'union' as a kind bound after ':\x27"
        ).first(ctx_range).emit();
        return GenericParamKindBound::Any;
    }

    /// \brief parses one or more impl/derives bound types after a generic param.
    ///  Grammar:  ('impl'|'derives') type (',' type)*  -- but stops at the
    ///  list-level ',' that separates generic params (we only greedily take
    ///  additional bound types when they follow another impl/derives keyword).
    priv fn _parse_param_bounds(self, out: *std::StackBuf::<*Type, 4>) {
        while true {
            // consume `impl` or `derives`
            if dyn()->check(TokenKind::KwImpl) || dyn()->check(TokenKind::KwDerives) {
                dyn()->advance(T::SkipNL::After);
            } else {
                break;
            }
            var bty = dyn()->parse_type();
            if (bty == &null) || is_recovery(bty) {
                break;
            }
            out->push_back(bty);

            // another bound only if another impl/derives follows (a bare `,`
            // belongs to the generic param list, not the bound list).
            if dyn()->check(TokenKind::KwImpl) || dyn()->check(TokenKind::KwDerives) {
                continue;
            }
            break;
        }
    }

    priv fn _maybe_parse_generic_default(self, gp: *GenericParamDecl) {
        if dyn()->check(TokenKind::OpEqual) {
            dyn()->advance(T::SkipNL::After); // consume `=`
            var dty = dyn()->parse_type();
            if (dty != &null) && (!is_recovery(dty)) {
                gp->default_type = dty;
            }
        }
    }

    // ========================================================================
    //  Function declaration
    // ========================================================================

    /// \brief parses a function/method/operator declaration.
    ///  Grammar:  'fn' generics? (identifier | 'op' operator | qualified-name)
    ///            '(' params? ')' fn_mods? ('->' return_type)? requires? body
    ///    body := block | '=' expr | '=' ('default'|'delete'|'virtual') | <none>
    ///
    /// \details precondition: current token is `fn`. `lead` carries any
    ///          static/virtual/override/final consumed before `fn`.
    priv fn _parse_function(self, lead: *LeadMods) -> *Decl {
        var start = (lead->range) if (lead->any) else (dyn()->current_ptr()->range);

        if !dyn()->enter_depth() {
            return static_cast::<*Decl>(FunctionDecl::create_error(dyn()->ctx, start));
        }
        dyn()->advance(T::SkipNL::After); // consume `fn`

        // capture the enclosing context *before* the function opens its own
        // scope: it tells us whether a `self` receiver is legal here.
        var enclosing_dc  = dyn()->scope.current_dc();
        var in_type_scope = (enclosing_dc != &null) && enclosing_dc->is_type_scope();

        var fd = FunctionDecl::create(dyn()->ctx, start, Token(), enclosing_dc);
        fd->abi = lead->abi;
        if lead->is_final {
            fd->modifiers |= FnModifier::IsFinal;
        }

        // optional generics: `fn <T> name(...)`
        if dyn()->check(TokenKind::OpLess) {
            var gparams: std::StackBuf::<*GenericParamDecl, 2>;
            self._parse_generic_params(&gparams);
            fd->generic_params.from_buf(gparams.data(), gparams.size(), dyn()->ctx);
        }

        // name | `op <operator>` | qualified `Class::method`
        if dyn()->check(TokenKind::KwOp) {
            dyn()->advance(); // consume `op`
            fd->is_operator = true;
            fd->op_token    = dyn()->current();
            // operators may be multi-token (l++/r++, op as, op in, op delete,
            // op [], op ==, etc). The lexer hands these as distinct tokens; we
            // record the first and let sema validate the operator spelling.
            dyn()->advance();
            fd->name = fd->op_token;
        } else if dyn()->check(TokenKind::LitIdentifier) || dyn()->check(TokenKind::KwSelf) {
            var name_tok = dyn()->current();
            dyn()->advance();

            // out-of-line `Class::method` / `Class::Inner::method`
            if dyn()->check(TokenKind::OpColonColon) {
                fd->qualifier = self._parse_qualified_fn_name(name_tok);
                // the trailing segment becomes the function name.
                if dyn()->check(TokenKind::KwOp) {
                    dyn()->advance();
                    fd->is_operator = true;
                    fd->op_token    = dyn()->current();
                    dyn()->advance();
                    fd->name = fd->op_token;
                } else {
                    fd->name = dyn()->current();
                    dyn()->advance();
                }
            } else {
                fd->name = name_tok;
            }
        } else {
            dyn()->report_tok(DiagID::S047E, dyn()->current_ptr(),
                "expected function name, 'op', or a qualified name after 'fn\x27"
            );
            dyn()->exit_depth();
            self._sync_decl(DeclSyncCtx::TopLevel);
            return static_cast::<*Decl>(FunctionDecl::create_error(dyn()->ctx, start | dyn()->prev().range));
        }

        // parameter list
        dyn()->enter_scope(ScopeKind::Function, static_cast::<*DeclContext>(fd));

        if !dyn()->check(TokenKind::OpLParen) {
            dyn()->report_tok(DiagID::S047E, dyn()->current_ptr(),
                "expected '(' to begin the parameter list"
            );
            dyn()->exit_scope();
            dyn()->exit_depth();
            self._sync_decl(DeclSyncCtx::TopLevel);
            return static_cast::<*Decl>(FunctionDecl::create_error(dyn()->ctx, start | dyn()->prev().range));
        }

        var params: std::StackBuf::<*ParamDecl, 4>;
        var is_variadic = self._parse_param_list(&params);
        fd->params.from_buf(params.data(), params.size(), dyn()->ctx);
        fd->is_variadic = is_variadic;

        // a signature with any type-only (unnamed) parameter is a forward
        // declaration: it is purely a type signature and cannot carry a body.
        var is_type_only_sig = false;
        var has_self_param   = false;
        for var i: usize = 0; i < fd->params.size(); ++i {
            if fd->params[i]->unname  { is_type_only_sig = true; }
            if fd->params[i]->is_self { has_self_param   = true; }
        }

        // `self` is a method receiver: legal only inside a type body or on an
        // out-of-line method definition (`fn Class::m(self)`), never in a free
        // function.
        if has_self_param && (!in_type_scope) && (!fd->is_out_of_line()) {
            dyn()->diag->report(DiagID::S047E, start.start,
                "the `self` receiver is only allowed on a method; a free "
                "function cannot take `self`"
            ).first(start).emit();
        }

        // function modifiers: const volatile unsafe eval async final panic inline
        self._parse_fn_modifiers(fd);

        // return type
        if dyn()->check(TokenKind::OpArrow) {
            dyn()->advance(T::SkipNL::After); // consume `->`
            if dyn()->check(TokenKind::OpExclaim) {
                fd->is_noreturn = true;
                dyn()->advance(); // consume `!`
            } else {
                var rty = dyn()->parse_type();
                if (rty != &null) && (!is_recovery(rty)) {
                    fd->return_type = rty;
                }
            }
        }

        // optional `requires <expr>` constraint
        if dyn()->check(TokenKind::KwRequires) {
            dyn()->advance(T::SkipNL::After);
            var req = dyn()->parse_expr();
            if (req != &null) && (!is_recovery(req)) {
                fd->requires_clause = req;
            }
        }

        // body
        self._parse_fn_body(fd);

        // type-only signatures are forward declarations: reject any body.
        if is_type_only_sig && (fd->body_kind != FnBodyKind::None) {
            dyn()->diag->report(DiagID::S047E, start.start,
                "a function signature with type-only (unnamed) parameters is a "
                "forward declaration and cannot have a body; name the parameters "
                "to give it one"
            ).first(start).emit();
        }

        // a type-only signature is a forward declaration; never mark it as the
        // definition (even on the errored with-a-body path above) so it cannot
        // poison the redeclaration chain.
        if (fd->body_kind != FnBodyKind::None) && (!is_type_only_sig) {
            fd->mark_definition();
        }

        fd->range = start | dyn()->prev().range;
        dyn()->exit_scope();
        dyn()->exit_depth();
        return static_cast::<*Decl>(fd);
    }

    /// \brief parses the `Class::` (or `Class::Inner::`) qualifier path of an
    ///        out-of-line definition, leaving the cursor on the final segment.
    /// \returns a ChainExpr representing the qualifier path.
    priv fn _parse_qualified_fn_name(self, first: Token) -> *Expr {
        var start = first.range;
        var base  = NamedIdentExpr::create(dyn()->ctx, first.range, first);

        var ce = ChainExpr::create(dyn()->ctx, start, static_cast::<*Expr>(base));
        var steps: std::StackBuf::<ChainExpr::Step, 4>;

        // we are sitting on the first `::`
        while dyn()->check(TokenKind::OpColonColon) {
            dyn()->advance(); // consume `::`
            // if the next-next is NOT another `::` and this is the trailing
            // segment, stop so the caller can read the method name. We detect
            // the trailing segment by: identifier NOT followed by `::`.
            if dyn()->check(TokenKind::LitIdentifier) && (!dyn()->check_peek(TokenKind::OpColonColon)) {
                // leave cursor on the trailing segment for the caller.
                break;
            }
            if !dyn()->check(TokenKind::LitIdentifier) {
                break;
            }
            var seg_tok = dyn()->current();
            var step = ChainExpr::Step{};
            step.name        = NamedIdentExpr::create(dyn()->ctx, seg_tok.range, seg_tok);
            step.range       = seg_tok.range;
            step.access_kind = ChainExpr::AccessKind::ColonColon;
            step.resolved_type = &null;
            step.resolved_decl = &null;
            steps.push_back(step);
            dyn()->advance(); // consume the segment identifier
        }

        ce->steps.from_buf(steps.data(), steps.size(), dyn()->ctx);
        ce->range = start | dyn()->prev().range;
        return static_cast::<*Expr>(ce);
    }

    /// \brief parses a parameter list `( param (',' param)* )`.
    ///  Grammar:  param := 'self' | '...'? name ':' type ('=' expr)?
    /// \returns true if a trailing variadic pack `...name: T` was seen.
    priv fn _parse_param_list(self, out: *std::StackBuf::<*ParamDecl, 4>) -> bool {
        var lparen_tok = dyn()->current(); // kept whole: expansion-aware diags below need the token, not just the range
        var lparen     = lparen_tok.range;
        dyn()->advance(T::SkipNL::After); // consume `(`

        var variadic = false;
        var idx: u32 = 0;

        // a parameter list is either all-named (`name: T`, the ordinary form,
        // which may carry a body) or all type-only (`T`, a forward-declaration
        // signature with no body). these track the two so a mixed list errors.
        var saw_named   = false;
        var saw_unnamed = false;

        if dyn()->check(TokenKind::OpRParen) {
            dyn()->advance(); // consume `)`
            return false;
        }

        while !dyn()->is_eof() {
            // `self`. The receiver is neutral w.r.t. the named/type-only split:
            // it is compatible with both a named method (`fn m(self, x: T)`) and
            // a type-only member forward declaration (`fn m(self, T)`), so it
            // sets neither saw_named nor saw_unnamed. (Whether `self` is allowed
            // at all here is a placement check in `_parse_function`.)
            if dyn()->check(TokenKind::KwSelf) {
                var s_tok = dyn()->current();
                dyn()->advance();
                var pd = ParamDecl::create_self(dyn()->ctx, s_tok.range, s_tok);
                pd->index = idx;
                out->push_back(pd);
                ++idx;
                if dyn()->check(TokenKind::OpComma) { dyn()->advance(T::SkipNL::After); continue; }
                break;
            }

            // variadic pack `...name: T`
            var p_start = dyn()->current_ptr()->range;
            if dyn()->check(TokenKind::OpEllipsis) {
                variadic = true;
                dyn()->advance(); // consume `...`
            }

            // Disambiguate a named param (`name: T`) from a bare type-only
            // param (`T`). A name is an identifier immediately followed by `:`
            // (but not `::`, which begins a scoped type path). Anything else
            // -- a leading `*`/`[`/`(`, a scoped name, a bare type name -- is a
            // type-only parameter, i.e. a forward-declaration signature
            // (`fn foo(i32, f64)`, the equivalent of C's `void foo(int, double)`).
            var is_named = dyn()->check(TokenKind::LitIdentifier)
                        && dyn()->check_peek(TokenKind::OpColon)
                        && (!dyn()->check_peek(TokenKind::OpColonColon));

            var pname = Token();
            if is_named {
                saw_named = true;
                pname = dyn()->current();
                dyn()->advance();                 // consume name
                dyn()->advance(T::SkipNL::After); // consume `:`
            } else {
                saw_unnamed = true;
            }

            // Prevent parse_type from consuming delimiters on error
            if dyn()->check(TokenKind::OpComma) || dyn()->check(TokenKind::OpRParen) {
                dyn()->report_tok(DiagID::S053E, dyn()->current_ptr(),
                    "expected type"
                );
                if dyn()->check(TokenKind::OpComma) {
                    dyn()->advance(T::SkipNL::After);
                    continue;
                }
                break;
            }

            var pty = dyn()->parse_type();
            if (pty == &null) || is_recovery(pty) {
                self._sync_decl(DeclSyncCtx::Params);
                if dyn()->check(TokenKind::OpComma) { dyn()->advance(T::SkipNL::After); continue; }
                break;
            }

            var pd = ParamDecl::create(dyn()->ctx, p_start | dyn()->prev().range, pname, pty, idx, !is_named);

            // default value
            if dyn()->check(TokenKind::OpEqual) {
                dyn()->advance(T::SkipNL::After); // consume `=`
                var dv = dyn()->parse_expr(T::ExprStopKind::StopComma);
                if (dv != &null) && (!is_recovery(dv)) {
                    pd->default_val = dv;
                }
            }

            // bind named params in the function scope for body lookups.
            // type-only params have no name to bind.
            if is_named {
                dyn()->scope.bind(
                    dyn()->ctx->get_spelling(pname),
                    static_cast::<*Decl>(pd),
                    pname.range
                );
            }

            out->push_back(pd);
            ++idx;

            if dyn()->check(TokenKind::OpComma) {
                dyn()->advance(T::SkipNL::After);
                if dyn()->check(TokenKind::OpRParen) { break; } // trailing comma
                continue;
            }
            break;
        }

        if dyn()->check(TokenKind::OpRParen) {
            dyn()->advance();
        } else {
            dyn()->report_tok(DiagID::S047E, &lparen_tok,
                "expected ')' to close the parameter list"
            );

            // Only synchronize to TopLevel if we are not at a capture list or body block
            if !dyn()->check(TokenKind::OpPipe) && !dyn()->check(TokenKind::OpPipePipe) && !dyn()->check(TokenKind::OpLBrace) {
                self._sync_decl(DeclSyncCtx::TopLevel);
            }
        }

        // a list may be all-named or all type-only, never a mix: type-only
        // params name no binding for a body to refer to.
        if saw_named && saw_unnamed {
            dyn()->report_tok(DiagID::S047E, &lparen_tok,
                "cannot mix named parameters (`name: T`) and type-only "
                "parameters (`T`) in one signature; a type-only signature is a "
                "bodyless forward declaration"
            );
        }

        return variadic;
    }

    /// \brief Parses the capture list for a closure, supporting value, pointer, and const pointer captures.
    /// \details Implements the updated grammar:
    ///            '|' capture (',' capture)* '|'
    ///            capture := 'const'? '*'? identifier | '*'
    pub fn _parse_capture_list(self, out: *std::StackBuf::<ClosureExpr::Capture, 4>) -> void {
        dyn()->advance(T::SkipNL::After); // consume opening `|`

        // empty capture list `||`
        if dyn()->check(TokenKind::OpPipe) {
            dyn()->advance(); // consume closing `|`
            return;
        }

        // first capture, handled separately to avoid comma-before-first logic
        {
            var p_start   = dyn()->current_ptr()->range;
            var is_const: bool = false;
            var by_ptr:   bool = false;

            if dyn()->check(TokenKind::KwConst) {
                is_const = true;
                dyn()->advance(); // consume `const`

                // Recovery: ensure 'const' is followed by a valid next token
                if !dyn()->check(TokenKind::OpStar) && !dyn()->check(TokenKind::LitIdentifier) {
                    dyn()->report_tok(DiagID::S047E, dyn()->current_ptr(),
                        "expected '*' or identifier after 'const' in capture list"
                    );
                    self._sync_decl(DeclSyncCtx::Params);
                }
            }

            if dyn()->check(TokenKind::OpStar) {
                var star_range = dyn()->current_ptr()->range;
                dyn()->advance(); // consume `*`

                // `|*|` or `|const *|`, all-by-ptr sentinel, no named capture
                if dyn()->check(TokenKind::OpPipe) {
                    dyn()->advance(); // consume `|`
                    var capture = ClosureExpr::Capture();
                    capture.name     = &null;
                    capture.by_ptr   = true;
                    capture.is_const = is_const;
                    out->push_back(capture);
                    return;
                }

                by_ptr = true;

                if !dyn()->check(TokenKind::LitIdentifier) {
                    dyn()->diag->report(DiagID::S047E, star_range.start,
                        "expected capture name after '*\x27"
                    ).first(star_range).emit();
                    self._sync_decl(DeclSyncCtx::Params);
                    // fall through to closing `|` check
                } else {
                    var cname = dyn()->current();
                    dyn()->advance();
                    var capture = ClosureExpr::Capture();
                    capture.name     = NamedIdentExpr::create(dyn()->ctx, p_start | cname.range, cname);
                    capture.by_ptr   = true;
                    capture.is_const = is_const;
                    out->push_back(capture);
                }

            } else if dyn()->check(TokenKind::LitIdentifier) {
                var cname = dyn()->current();
                dyn()->advance();
                var capture = ClosureExpr::Capture();
                capture.name     = NamedIdentExpr::create(dyn()->ctx, p_start | cname.range, cname);
                capture.by_ptr   = false;
                capture.is_const = is_const;
                out->push_back(capture);

            } else {
                dyn()->diag->report(DiagID::S047E, p_start.start,
                    "expected capture name or '*' in capture list"
                ).first(p_start).emit();
                self._sync_decl(DeclSyncCtx::Params);
            }

            // after first capture: comma continues, pipe or nothing closes
            if dyn()->check(TokenKind::OpComma) {
                dyn()->advance(T::SkipNL::After);
                if dyn()->check(TokenKind::OpPipe) {
                    dyn()->advance(); // handle trailing comma before closing `|`
                    return;
                }
            } else {
                if dyn()->check(TokenKind::OpPipe) { dyn()->advance(); }
                return;
            }
        }

        // remaining captures
        while !dyn()->is_eof() {
            var p_start   = dyn()->current_ptr()->range;
            var is_const: bool = false;
            var by_ptr:   bool = false;

            if dyn()->check(TokenKind::KwConst) {
                 //TODO recovery incase of anything other than const here
                is_const = true;
                dyn()->advance(); // consume `const`

                // Recovery: ensure valid structural capture token follows
                if !dyn()->check(TokenKind::OpStar) && !dyn()->check(TokenKind::LitIdentifier) {
                    dyn()->report_tok(DiagID::S047E, dyn()->current_ptr(),
                        "expected '*' or identifier after 'const' in capture list"
                    );
                    self._sync_decl(DeclSyncCtx::Params);
                    if dyn()->check(TokenKind::OpComma) { dyn()->advance(T::SkipNL::After); continue; }
                    break;
                }
            }

            if dyn()->check(TokenKind::OpStar) {
                by_ptr = true;
                dyn()->advance(); // consume `*`
            }

            if !dyn()->check(TokenKind::LitIdentifier) {
                dyn()->diag->report(DiagID::S047E, p_start.start,
                    "expected capture name"
                ).first(p_start).emit();
                self._sync_decl(DeclSyncCtx::Params);
                if dyn()->check(TokenKind::OpComma) { dyn()->advance(T::SkipNL::After); continue; }
                break;
            }

            var cname = dyn()->current();
            dyn()->advance();

            var capture = ClosureExpr::Capture();
            capture.name     = NamedIdentExpr::create(dyn()->ctx, p_start | cname.range, cname);
            capture.by_ptr   = by_ptr;
            capture.is_const = is_const;
            out->push_back(capture);

            if dyn()->check(TokenKind::OpComma) {
                dyn()->advance(T::SkipNL::After);
                if dyn()->check(TokenKind::OpPipe) { break; } // trailing comma
                continue;
            }
            break;
        }

        if dyn()->check(TokenKind::OpPipe) {
            dyn()->advance(); // consume closing `|`
        } else {
            dyn()->report_tok(DiagID::S047E, dyn()->current_ptr(),
                "expected '|' to close the capture list"
            );
            self._sync_decl(DeclSyncCtx::TopLevel);
        }
    }

    priv fn _sync_to_closure_milestone(self) {
        var depth: i32 = 0;
        while !dyn()->is_eof() {
            var k = dyn()->current().kind;
            if k == TokenKind::OpLParen || k == TokenKind::OpLSquare || k == TokenKind::OpLBrace {
                ++depth;
            } else if k == TokenKind::OpRParen || k == TokenKind::OpRSquare || k == TokenKind::OpRBrace {
                if depth > 0 { --depth; }
            } else if depth == 0 {
                if k == TokenKind::OpPipe
                || k == TokenKind::OpArrow
                || k == TokenKind::OpEqual
                || self._is_closure_modifier(k) {
                    return;
                }
            }
            dyn()->advance();
        }
    }

    priv fn _is_closure_modifier(self, k: TokenKind) -> bool {
        return k == TokenKind::KwPanic
            || k == TokenKind::KwVolatile
            || k == TokenKind::KwAsync
            || k == TokenKind::KwConst
            || k == TokenKind::KwUnsafe
            || k == TokenKind::KwEval
            || k == TokenKind::KwFinal
            || k == TokenKind::KwInline
            || k == TokenKind::KwVirtual
            || k == TokenKind::KwOverride;
    }

    /// \brief parses trailing function modifiers into fd->modifiers.
    priv fn _parse_fn_modifiers(self, fd: *FunctionDecl) {
        while true {
            if      dyn()->check(TokenKind::KwConst)    { fd->modifiers |= FnModifier::IsConst;    dyn()->advance(); }
            else if dyn()->check(TokenKind::KwVolatile) { fd->modifiers |= FnModifier::IsVolatile; dyn()->advance(); }
            else if dyn()->check(TokenKind::KwUnsafe)   { fd->modifiers |= FnModifier::IsUnsafe;   dyn()->advance(); }
            else if dyn()->check(TokenKind::KwEval)     { fd->modifiers |= FnModifier::IsEval;     dyn()->advance(); }
            else if dyn()->check(TokenKind::KwAsync)    { fd->modifiers |= FnModifier::IsAsync;    dyn()->advance(); }
            else if dyn()->check(TokenKind::KwFinal)    { fd->modifiers |= FnModifier::IsFinal;    dyn()->advance(); }
            else if dyn()->check(TokenKind::KwPanic)    { fd->modifiers |= FnModifier::IsPanic;    dyn()->advance(); }
            else if dyn()->check(TokenKind::KwInline)   { fd->modifiers |= FnModifier::IsInline;   dyn()->advance(); }
            else { break; }
        }
    }

    priv fn _parse_closure_fn_modifiers(self, fd: *ClosureExpr) {
        while true {
            if      dyn()->check(TokenKind::KwConst)    { fd->modifiers |= FnModifier::IsConst;    dyn()->advance(); }
            else if dyn()->check(TokenKind::KwVolatile) { fd->modifiers |= FnModifier::IsVolatile; dyn()->advance(); }
            else if dyn()->check(TokenKind::KwUnsafe)   { fd->modifiers |= FnModifier::IsUnsafe;   dyn()->advance(); }
            else if dyn()->check(TokenKind::KwEval)     { fd->modifiers |= FnModifier::IsEval;     dyn()->advance(); }
            else if dyn()->check(TokenKind::KwAsync)    { fd->modifiers |= FnModifier::IsAsync;    dyn()->advance(); }
            else if dyn()->check(TokenKind::KwFinal)    { fd->modifiers |= FnModifier::IsFinal;    dyn()->advance(); }
            else if dyn()->check(TokenKind::KwPanic)    { fd->modifiers |= FnModifier::IsPanic;    dyn()->advance(); }
            else if dyn()->check(TokenKind::KwInline)   { fd->modifiers |= FnModifier::IsInline;   dyn()->advance(); }
            else { break; }
        }
    }

    /// \brief parses the function body, setting body_kind + body_block/expr.
    ///  Grammar:  block | '=' expr | '=' ('default'|'delete'|'virtual') | <none>
    priv fn _parse_fn_body(self, fd: *FunctionDecl) {
        // `= default` / `= delete` / `= virtual` / `= expr`
        if dyn()->check(TokenKind::OpEqual) {
            dyn()->advance(T::SkipNL::After); // consume `=`

            if dyn()->check(TokenKind::KwDefault) {
                dyn()->advance(); fd->body_kind = FnBodyKind::Default; return;
            }
            if dyn()->check(TokenKind::KwDelete) {
                dyn()->advance(); fd->body_kind = FnBodyKind::Delete; return;
            }
            if dyn()->check(TokenKind::KwVirtual) {
                dyn()->report_tok(DiagID::S047E, dyn()->current_ptr(),
                    "virtual functions must be declared with the 'virtual' modifier"
                );
                dyn()->advance();
                return;
            }
            if dyn()->check(TokenKind::KwStatic) {
                dyn()->report_tok(DiagID::S047E, dyn()->current_ptr(),
                    "static functions must be declared with the 'static' modifier"
                );
                dyn()->advance();
                return;
            }
            if dyn()->check(TokenKind::KwAsync) {
                dyn()->report_tok(DiagID::S047E, dyn()->current_ptr(),
                    "async functions must be declared with the 'async' modifier"
                );
                dyn()->advance();
                return;
            }
            if dyn()->check(TokenKind::KwInline) {
                dyn()->report_tok(DiagID::S047E, dyn()->current_ptr(),
                    "inline functions must be declared with the 'inline' modifier"
                );
                dyn()->advance();
                return;
            }
            if dyn()->check(TokenKind::KwFinal) {
                dyn()->report_tok(DiagID::S047E, dyn()->current_ptr(),
                    "final functions must be declared with the 'final' modifier"
                );
                dyn()->advance();
                return;
            }
            if dyn()->check(TokenKind::KwPanic) {
                dyn()->report_tok(DiagID::S047E, dyn()->current_ptr(),
                    "panic functions must be declared with the 'panic' modifier"
                );
                dyn()->advance();
                return;
            }
            // expression-bodied
            var e = dyn()->parse_expr();
            if (e != &null) && (!is_recovery(e)) {
                fd->body_kind = FnBodyKind::Expr;
                fd->body_expr = e;
            }
            return;
        }

        // block body
        if dyn()->check(TokenKind::OpLBrace) {
            var block = dyn()->parse_compound();
            fd->body_kind  = FnBodyKind::Block;
            fd->body_block = block;
            return;
        }

        // no body forward declaration / FFI import.
        fd->body_kind = FnBodyKind::None;
    }

    // ========================================================================
    //  Variable / field declaration
    // ========================================================================

    /// \brief parses a var/const/static/eval binding as a VariableDecl.
    ///  Grammar:  ('var'|'const'|'static'|'eval') identifier (':' type)?
    ///            ('=' expr)?
    ///
    /// \note destructuring (`var (a, b) = ...`) is handled by StmtParse at
    ///       statement scope; this path is for plain single-name bindings,
    ///       including the C-style for-loop init and namespace/local decls.
    fn _parse_var_decl(self) -> *Decl {
        var start = dyn()->current_ptr()->range;

        var storage = StorageClass::Var;
        if      dyn()->check(TokenKind::KwConst)  { storage = StorageClass::Const;  }
        else if dyn()->check(TokenKind::KwStatic) { storage = StorageClass::Static; }
        else if dyn()->check(TokenKind::KwEval)   { storage = StorageClass::Eval;   }
        dyn()->advance(); // consume the storage keyword

        if !dyn()->check(TokenKind::LitIdentifier) {
            dyn()->diag->report(DiagID::S046E, start.start,
                "expected a name after the binding keyword"
            ).first(start).emit();
            self._sync_decl(DeclSyncCtx::TopLevel);
            return static_cast::<*Decl>(VariableDecl::create_error(dyn()->ctx, start | dyn()->prev().range));
        }
        var name = dyn()->current();
        dyn()->advance();

        var vd = VariableDecl::create(dyn()->ctx, start, name, storage);

        // optional `: type`
        if dyn()->check(TokenKind::OpColon) {
            dyn()->advance(T::SkipNL::After); // consume `:`
            var ty = dyn()->parse_type();
            if (ty != &null) && (!is_recovery(ty)) {
                vd->type_ = ty;
            }
        }

        // optional `= init`
        if dyn()->check(TokenKind::OpEqual) {
            dyn()->advance(T::SkipNL::After); // consume `=`
            var init = dyn()->parse_expr();
            if (init != &null) && (!is_recovery(init)) {
                vd->init = init;
            }
        }

        // bind into the current scope for subsequent lookups.
        dyn()->scope.bind(
            dyn()->ctx->get_spelling(name),
            static_cast::<*Decl>(vd),
            name.range
        );

        vd->range = start | dyn()->prev().range;
        return static_cast::<*Decl>(vd);
    }

    /// \brief parses a class/struct/union member field as a FieldDecl.
    ///  Grammar:  'mutable'? ('var'|'const'|'static'|'eval') name ':' type
    ///            ('=' expr)?
    ///
    /// \details fields require an explicit type (no inference at member scope)
    ///          except where a default initializer is present; sema enforces.
    priv fn _parse_field(self, idx: u32) -> *FieldDecl {
        var start = dyn()->current_ptr()->range;

        var is_mutable = false;
        if dyn()->check(TokenKind::KwMutable) {
            is_mutable = true;
            dyn()->advance();
        }

        var storage = StorageClass::Var;
        if      dyn()->check(TokenKind::KwConst)  { storage = StorageClass::Const;  }
        else if dyn()->check(TokenKind::KwStatic) { storage = StorageClass::Static; }
        else if dyn()->check(TokenKind::KwEval)   { storage = StorageClass::Eval;   }
        else if dyn()->check(TokenKind::KwVar)    { storage = StorageClass::Var;    }
        else {
            dyn()->diag->report(DiagID::S048E, start.start,
                "expected 'var', 'const', 'static', or 'eval' to begin a field"
            ).first(start).emit();
            return FieldDecl::create_error(dyn()->ctx, start);
        }
        dyn()->advance(); // consume storage keyword

        if !dyn()->check(TokenKind::LitIdentifier) {
            dyn()->diag->report(DiagID::S048E, start.start,
                "expected field name"
            ).first(start).emit();
            return FieldDecl::create_error(dyn()->ctx, start | dyn()->prev().range);
        }
        var name = dyn()->current();
        dyn()->advance();

        var fty: *Type = &null;
        if dyn()->check(TokenKind::OpColon) {
            dyn()->advance(T::SkipNL::After); // consume `:`
            fty = dyn()->parse_type();
            if (fty != &null) && is_recovery(fty) { fty = &null; }
        }

        var fd = FieldDecl::create(dyn()->ctx, start, name, storage, fty, idx);
        fd->is_mutable = is_mutable;

        if dyn()->check(TokenKind::OpEqual) {
            dyn()->advance(T::SkipNL::After); // consume `=`
            var init = dyn()->parse_expr();
            if (init != &null) && (!is_recovery(init)) {
                fd->init = init;
            }
        }

        fd->range = start | dyn()->prev().range;
        return fd;
    }

    // ========================================================================
    //  Inheritance clauses:  derives <edges> | impl <edges>
    // ========================================================================

    /// \brief parses an inheritance edge list following `derives` or `impl`.
    ///  Grammar:  ('derives'|'impl') ('virtual'? visibility? type)
    ///            (',' 'virtual'? visibility? type)*
    ///
    /// \details precondition: current is `derives` or `impl` (caller decides
    ///          which list it fills). Visibility/virtual modifiers attach
    ///          per-edge. Stops at `{`, `requires`, or a non-comma token.
    priv fn _parse_inherit_edges(self, out: *std::StackBuf::<InheritEdge, 4>) {
        dyn()->advance(T::SkipNL::After); // consume `derives` / `impl`

        while true {
            var e_start = dyn()->current_ptr()->range;
            var edge = InheritEdge{};
            edge.visibility = 0;
            edge.is_virtual = false;

            if dyn()->check(TokenKind::KwVirtual) {
                edge.is_virtual = true;
                dyn()->advance();
            }
            // per-edge visibility (derives pub/prot/priv Base)
            if      dyn()->check(TokenKind::KwPub)  { edge.visibility = 3; dyn()->advance(); }
            else if dyn()->check(TokenKind::KwProt) { edge.visibility = 2; dyn()->advance(); }
            else if dyn()->check(TokenKind::KwPriv) { edge.visibility = 1; dyn()->advance(); }

            var bty = dyn()->parse_type();
            if (bty == &null) || is_recovery(bty) {
                break;
            }
            edge.base  = bty;
            edge.range = e_start | dyn()->prev().range;
            out->push_back(edge);

            if dyn()->check(TokenKind::OpComma) {
                dyn()->advance(T::SkipNL::After);
                continue;
            }
            break;
        }
    }

    /// \brief parses the `derives ...` and `impl ...` clauses in either order,
    ///        filling the provided edge buffers. Either may be absent.
    priv fn _parse_class_heritage(
        self,
        derives_out: *std::StackBuf::<InheritEdge, 4>,
        impl_out:    *std::StackBuf::<InheritEdge, 4>
    ) {
        while true {
            if dyn()->check(TokenKind::KwDerives) {
                self._parse_inherit_edges(derives_out);
                continue;
            }
            if dyn()->check(TokenKind::KwImpl) {
                self._parse_inherit_edges(impl_out);
                continue;
            }
            break;
        }
    }

    // ========================================================================
    //  Type-scope body  { fields, methods, nested types }
    // ========================================================================

    /// \brief parses a braced member body into the given DeclContext owner,
    ///        collecting fields and methods into the supplied buffers.
    ///  Grammar:  '{' (field | method | nested-decl | visibility-group)* '}'
    ///
    /// \param allow_methods  false for structs/unions (no in-body methods).
    /// \details pushes no scope of its own the caller owns scope lifetime;
    ///          this only routes members. Nested type decls are appended to
    ///          the owner's dc_decls via add_decl.
    priv fn _parse_member_body(
        self,
        owner:        *DeclContext,
        fields_out:   *std::StackBuf::<*FieldDecl, 8>,
        methods_out:  *std::StackBuf::<*FunctionDecl, 8>,
        allow_methods: bool
    ) -> bool {
        if !dyn()->check(TokenKind::OpLBrace) {
            var r = dyn()->current_ptr()->range;
            dyn()->diag->report(DiagID::S048E, r.start,
                "expected '{' to begin the type body"
            ).first(r).emit();
            return false;
        }
        dyn()->advance(T::SkipNL::After); // consume `{`

        var field_idx: u32 = 0;
        var prev_idx: usize = 0;
        var have_prev = false;

        while (!dyn()->is_eof()) && (!dyn()->check(TokenKind::OpRBrace)) {
            // progress guard: if the previous iteration consumed nothing -- a
            // recovery path whose `_sync_decl` stopped on a member-start token
            // it could not parse (e.g. a `fn` in a method-less body) -- force a
            // single advance so a malformed member can never spin the parser.
            if have_prev && (dyn()->c_idx == prev_idx) {
                dyn()->advance();
                continue;
            }
            prev_idx  = dyn()->c_idx;
            have_prev = true;

            if dyn()->check(TokenKind::TkNewLine) || dyn()->check(TokenKind::OpSemicolon) {
                dyn()->advance();
                continue;
            }

            // leading annotations on a member (doc comments, @attr, visibility)
            inline "c++" { typename T::PendingAnnotations m_annot; }
            dyn()->consume_leading_annotations(&m_annot);

            if dyn()->check(TokenKind::OpRBrace) { break; }

            var k = dyn()->resolve_kind_deep(dyn()->current_ptr());

            // visibility group inside a type body: members route through the
            // normal field/method paths with the group's visibility stamped.
            if (k == TokenKind::KwPub || k == TokenKind::KwPriv || k == TokenKind::KwProt)
            && dyn()->check_peek(TokenKind::OpLBrace) {
                var grp_annot = !m_annot.empty();
                if grp_annot {
                    dyn()->report_tok(DiagID::S048E, dyn()->current_ptr(),
                        "annotations and attributes cannot be applied to a visibility group; "
                        "apply them to individual members instead"
                    );
                }
                self._parse_member_vis_group(owner, fields_out, methods_out,
                                             allow_methods, &field_idx);
                continue;
            }

            // method (only in classes / interfaces)
            var is_method_lead = (k == TokenKind::KwFn)
                              || (k == TokenKind::KwStatic)
                              || (k == TokenKind::KwVirtual)
                              || (k == TokenKind::KwOverride)
                              || (k == TokenKind::KwFinal);

            if is_method_lead && allow_methods {
                var lead = self._consume_leading_modifiers();
                if dyn()->check(TokenKind::KwFn) {
                    var m = self._parse_function(&lead);
                    if (m != &null) && isa::<FunctionDecl>(m) {
                        var fm = cast::<FunctionDecl>(m);
                        dyn()->apply_annotations_to_decl(static_cast::<*Decl>(fm), &m_annot);
                        methods_out->push_back(fm);
                    }
                } else {
                    var r = dyn()->current_ptr()->range;
                    dyn()->diag->report(DiagID::S048E, r.start,
                        "expected 'fn' after method modifiers"
                    ).first(r).emit();
                    self._sync_decl(DeclSyncCtx::TypeBody);
                }
                continue;
            }

            // a method where methods are not allowed (struct/union body). Parse
            // and discard it so the tokens are consumed -- a bare `fn` would
            // otherwise fall through to the unknown-member path, whose
            // `_sync_decl` stops on `fn` without consuming it, spinning forever.
            // (Only `fn` is handled here; `static`/`virtual` leads stay ambiguous
            // with static fields and are left to the field/recovery paths, which
            // the progress guard above keeps bounded.)
            if (k == TokenKind::KwFn) && (!allow_methods) {
                var mr   = dyn()->current_ptr()->range;
                var lead = self._consume_leading_modifiers();
                self._parse_function(&lead);
                dyn()->diag->report(DiagID::S048E, mr.start,
                    "methods are not allowed in a struct or union body; only "
                    "fields and nested types are permitted"
                ).first(mr).emit();
                continue;
            }

            // nested type decl
            if (k == TokenKind::KwClass) || (k == TokenKind::KwStruct)
            || (k == TokenKind::KwEnum)  || (k == TokenKind::KwUnion)
            || (k == TokenKind::KwInterface) || (k == TokenKind::KwType) {
                var nested = self._dispatch_decl();
                if (nested != &null) && (!is_fatal_decl(nested)) {
                    dyn()->apply_annotations_to_decl(nested, &m_annot);
                    owner->add_decl(nested);
                }
                continue;
            }

            // field: mutable? var/const/static/eval ...
            var is_field_lead = (k == TokenKind::KwVar)    || (k == TokenKind::KwConst)
                             || (k == TokenKind::KwStatic) || (k == TokenKind::KwEval)
                             || (k == TokenKind::KwMutable);

            if is_field_lead {
                var f = self._parse_field(field_idx);
                if !is_recovery(static_cast::<*Decl>(f)) {
                    dyn()->apply_annotations_to_decl(static_cast::<*Decl>(f), &m_annot);
                    fields_out->push_back(f);
                    ++field_idx;
                } else {
                    self._sync_decl(DeclSyncCtx::TypeBody);
                }
                continue;
            }

            // unknown member lead recover.
            var r = dyn()->current_ptr()->range;
            dyn()->diag->report(DiagID::S048E, r.start,
                "expected a field, method, or nested type in the type body"
            ).first(r).emit();
            self._sync_decl(DeclSyncCtx::TypeBody);
        }

        if dyn()->check(TokenKind::OpRBrace) {
            dyn()->advance(T::SkipNL::Before); // consume `}`
            return true;
        }
        dyn()->diag->report(DiagID::S048E, dyn()->prev().range.start,
            "expected '}' to close the type body"
        ).first(dyn()->prev().range).emit();
        return false;
    }

    // ========================================================================
    //  Class
    // ========================================================================

    /// \brief parses a class declaration.
    ///  Grammar:  'final'? 'class' generics? name (derives ...)? (impl ...)? body
    priv fn _parse_class(self, lead: *LeadMods) -> *Decl {
        var start = (lead->range) if (lead->any) else (dyn()->current_ptr()->range);

        if !dyn()->enter_depth() {
            return static_cast::<*Decl>(ClassDecl::create_error(dyn()->ctx, start));
        }
        dyn()->advance(T::SkipNL::After); // consume `class`

        // a class name may itself carry generics: `class <T> Foo`
        var gparams: std::StackBuf::<*GenericParamDecl, 2>;
        var has_generics = false;
        if dyn()->check(TokenKind::OpLess) {
            self._parse_generic_params(&gparams);
            has_generics = true;
        }

        if !dyn()->check(TokenKind::LitIdentifier) {
            dyn()->diag->report(DiagID::S046E, start.start,
                "expected class name"
            ).first(start).emit();
            dyn()->exit_depth();
            self._sync_decl(DeclSyncCtx::TopLevel);
            return static_cast::<*Decl>(ClassDecl::create_error(dyn()->ctx, start | dyn()->prev().range));
        }
        var name = dyn()->current();
        dyn()->advance();

        var cd = ClassDecl::create(dyn()->ctx, start, name, dyn()->scope.current_dc());
        cd->is_final = lead->is_final;
        if has_generics {
            cd->generic_params.from_buf(gparams.data(), gparams.size(), dyn()->ctx);
        }

        // heritage
        var dlist: std::StackBuf::<InheritEdge, 4>;
        var ilist: std::StackBuf::<InheritEdge, 4>;
        self._parse_class_heritage(&dlist, &ilist);
        cd->derives_list.from_buf(dlist.data(), dlist.size(), dyn()->ctx);
        cd->implements.from_buf(ilist.data(), ilist.size(), dyn()->ctx);

        // optional requires
        if dyn()->check(TokenKind::KwRequires) {
            dyn()->advance(T::SkipNL::After);
            var req = dyn()->parse_expr(T::ExprStopKind::NoStructLiteral);
            if (req != &null) && (!is_recovery(req)) { cd->requires_clause = req; }
        }

        // body, or a bodyless forward declaration (`class Foo`). A `{` opens the
        // definition; anything else leaves `cd` a forward declaration (a
        // non-definition redecl link) for FFI / mutually-recursive types.
        if dyn()->check(TokenKind::OpLBrace) {
            dyn()->enter_scope(ScopeKind::Block, static_cast::<*DeclContext>(cd));
            var fields:  std::StackBuf::<*FieldDecl, 8>;
            var methods: std::StackBuf::<*FunctionDecl, 8>;
            self._parse_member_body(static_cast::<*DeclContext>(cd), &fields, &methods, true);
            cd->fields.from_buf(fields.data(), fields.size(), dyn()->ctx);
            cd->methods.from_buf(methods.data(), methods.size(), dyn()->ctx);

            // mark abstract if any method is `= virtual`.
            for var i: usize = 0; i < cd->methods.size(); ++i {
                if cd->methods[i]->body_kind == FnBodyKind::Virtual {
                    cd->is_abstract = true;
                    break;
                }
            }

            cd->mark_definition();
            dyn()->exit_scope();
        }

        cd->range = start | dyn()->prev().range;
        dyn()->exit_depth();
        return static_cast::<*Decl>(cd);
    }

    // ========================================================================
    //  Struct
    // ========================================================================

    /// \brief parses a struct declaration.
    ///  Grammar:  'struct' generics? name (impl ...)? body   (no methods in-body)
    priv fn _parse_struct(self) -> *Decl {
        var start = dyn()->current_ptr()->range;

        if !dyn()->enter_depth() {
            return static_cast::<*Decl>(StructDecl::create_error(dyn()->ctx, start));
        }
        dyn()->advance(T::SkipNL::After); // consume `struct`

        var gparams: std::StackBuf::<*GenericParamDecl, 2>;
        var has_generics = false;
        if dyn()->check(TokenKind::OpLess) {
            self._parse_generic_params(&gparams);
            has_generics = true;
        }

        if !dyn()->check(TokenKind::LitIdentifier) {
            dyn()->diag->report(DiagID::S046E, start.start,
                "expected struct name"
            ).first(start).emit();
            dyn()->exit_depth();
            self._sync_decl(DeclSyncCtx::TopLevel);
            return static_cast::<*Decl>(StructDecl::create_error(dyn()->ctx, start | dyn()->prev().range));
        }
        var name = dyn()->current();
        dyn()->advance();

        var sd = StructDecl::create(dyn()->ctx, start, name, dyn()->scope.current_dc());
        if has_generics {
            sd->generic_params.from_buf(gparams.data(), gparams.size(), dyn()->ctx);
        }

        // structs take only `impl` (no derives).
        var ilist: std::StackBuf::<InheritEdge, 4>;
        while dyn()->check(TokenKind::KwImpl) {
            self._parse_inherit_edges(&ilist);
        }
        sd->implements.from_buf(ilist.data(), ilist.size(), dyn()->ctx);

        if dyn()->check(TokenKind::KwRequires) {
            dyn()->advance(T::SkipNL::After);
            var req = dyn()->parse_expr(T::ExprStopKind::NoStructLiteral);
            if (req != &null) && (!is_recovery(req)) { sd->requires_clause = req; }
        }

        dyn()->enter_scope(ScopeKind::Block, static_cast::<*DeclContext>(sd));
        var fields:  std::StackBuf::<*FieldDecl, 8>;
        var methods: std::StackBuf::<*FunctionDecl, 8>; // unused for structs
        self._parse_member_body(static_cast::<*DeclContext>(sd), &fields, &methods, false);
        sd->fields.from_buf(fields.data(), fields.size(), dyn()->ctx);

        sd->mark_definition();
        sd->range = start | dyn()->prev().range;
        dyn()->exit_scope();
        dyn()->exit_depth();
        return static_cast::<*Decl>(sd);
    }

    // ========================================================================
    //  Union
    // ========================================================================

    /// \brief parses a union declaration.
    ///  Grammar:  'union' generics? name body   (fields only, no methods)
    priv fn _parse_union(self) -> *Decl {
        var start = dyn()->current_ptr()->range;

        if !dyn()->enter_depth() {
            return static_cast::<*Decl>(UnionDecl::create_error(dyn()->ctx, start));
        }
        dyn()->advance(T::SkipNL::After); // consume `union`

        var gparams: std::StackBuf::<*GenericParamDecl, 2>;
        var has_generics = false;
        if dyn()->check(TokenKind::OpLess) {
            self._parse_generic_params(&gparams);
            has_generics = true;
        }

        if !dyn()->check(TokenKind::LitIdentifier) {
            dyn()->diag->report(DiagID::S046E, start.start,
                "expected union name"
            ).first(start).emit();
            dyn()->exit_depth();
            self._sync_decl(DeclSyncCtx::TopLevel);
            return static_cast::<*Decl>(UnionDecl::create_error(dyn()->ctx, start | dyn()->prev().range));
        }
        var name = dyn()->current();
        dyn()->advance();

        var ud = UnionDecl::create(dyn()->ctx, start, name, dyn()->scope.current_dc());
        if has_generics {
            ud->generic_params.from_buf(gparams.data(), gparams.size(), dyn()->ctx);
        }

        dyn()->enter_scope(ScopeKind::Block, static_cast::<*DeclContext>(ud));
        var fields:  std::StackBuf::<*FieldDecl, 8>;
        var methods: std::StackBuf::<*FunctionDecl, 8>; // unused
        self._parse_member_body(static_cast::<*DeclContext>(ud), &fields, &methods, false);
        ud->fields.from_buf(fields.data(), fields.size(), dyn()->ctx);

        ud->mark_definition();
        ud->range = start | dyn()->prev().range;
        dyn()->exit_scope();
        dyn()->exit_depth();
        return static_cast::<*Decl>(ud);
    }

    // ========================================================================
    //  Interface
    // ========================================================================

    /// \brief parses an interface declaration.
    ///  Grammar:  'interface' generics? name (derives ...)? '{' sig* '}'
    ///    sig := method/operator/ctor/static signature (no body)
    priv fn _parse_interface(self) -> *Decl {
        var start = dyn()->current_ptr()->range;

        if !dyn()->enter_depth() {
            return static_cast::<*Decl>(InterfaceDecl::create_error(dyn()->ctx, start));
        }
        dyn()->advance(T::SkipNL::After); // consume `interface`

        var gparams: std::StackBuf::<*GenericParamDecl, 2>;
        var has_generics = false;
        if dyn()->check(TokenKind::OpLess) {
            self._parse_generic_params(&gparams);
            has_generics = true;
        }

        if !dyn()->check(TokenKind::LitIdentifier) {
            dyn()->diag->report(DiagID::S046E, start.start,
                "expected interface name"
            ).first(start).emit();
            dyn()->exit_depth();
            self._sync_decl(DeclSyncCtx::TopLevel);
            return static_cast::<*Decl>(InterfaceDecl::create_error(dyn()->ctx, start | dyn()->prev().range));
        }
        var name = dyn()->current();
        dyn()->advance();

        var id = InterfaceDecl::create(dyn()->ctx, start, name, dyn()->scope.current_dc());
        if has_generics {
            id->generic_params.from_buf(gparams.data(), gparams.size(), dyn()->ctx);
        }

        // interface inheritance via `derives`
        var dlist: std::StackBuf::<InheritEdge, 4>;
        while dyn()->check(TokenKind::KwDerives) {
            self._parse_inherit_edges(&dlist);
        }
        id->derives_list.from_buf(dlist.data(), dlist.size(), dyn()->ctx);

        if dyn()->check(TokenKind::KwRequires) {
            dyn()->advance(T::SkipNL::After);
            var req = dyn()->parse_expr(T::ExprStopKind::NoStructLiteral);
            if (req != &null) && (!is_recovery(req)) { id->requires_clause = req; }
        }

        // body: method signatures (bodies are a sema error; parser still
        // accepts a body for recovery via _parse_member_body's method path,
        // which yields FunctionDecls with body_kind set sema rejects bodies).
        dyn()->enter_scope(ScopeKind::Block, static_cast::<*DeclContext>(id));
        var fields:  std::StackBuf::<*FieldDecl, 8>;   // sema rejects fields in interfaces
        var methods: std::StackBuf::<*FunctionDecl, 8>;
        self._parse_member_body(static_cast::<*DeclContext>(id), &fields, &methods, true);
        id->methods.from_buf(methods.data(), methods.size(), dyn()->ctx);

        id->mark_definition();
        id->range = start | dyn()->prev().range;
        dyn()->exit_scope();
        dyn()->exit_depth();
        return static_cast::<*Decl>(id);
    }

    // ========================================================================
    //  Extension
    // ========================================================================

    /// \brief parses an extension declaration.
    ///  Grammar:  'extend' generics? type (impl ...)? '{' (method|static)* '}'
    priv fn _parse_extension(self) -> *Decl {
        var start = dyn()->current_ptr()->range;

        if !dyn()->enter_depth() {
            return static_cast::<*Decl>(ExtensionDecl::create_error(dyn()->ctx, start));
        }
        dyn()->advance(T::SkipNL::After); // consume `extend`

        var gparams: std::StackBuf::<*GenericParamDecl, 2>;
        var has_generics = false;
        if dyn()->check(TokenKind::OpLess) {
            self._parse_generic_params(&gparams);
            has_generics = true;
        }

        var target = dyn()->parse_type();
        if (target == &null) || is_recovery(target) {
            dyn()->diag->report(DiagID::S053E, start.start,
                "expected a type to extend after 'extend\x27"
            ).first(start).emit();
            dyn()->exit_depth();
            self._sync_decl(DeclSyncCtx::TopLevel);
            return static_cast::<*Decl>(ExtensionDecl::create_error(dyn()->ctx, start | dyn()->prev().range));
        }

        var ed = ExtensionDecl::create(dyn()->ctx, start, target, dyn()->scope.current_dc());
        if has_generics {
            ed->generic_params.from_buf(gparams.data(), gparams.size(), dyn()->ctx);
        }

        var ilist: std::StackBuf::<InheritEdge, 4>;
        while dyn()->check(TokenKind::KwImpl) {
            self._parse_inherit_edges(&ilist);
        }
        ed->implements.from_buf(ilist.data(), ilist.size(), dyn()->ctx);

        dyn()->enter_scope(ScopeKind::Block, static_cast::<*DeclContext>(ed));
        var fields:  std::StackBuf::<*FieldDecl, 8>;   // not valid in extends; sema rejects
        var methods: std::StackBuf::<*FunctionDecl, 8>;
        self._parse_member_body(static_cast::<*DeclContext>(ed), &fields, &methods, true);
        ed->methods.from_buf(methods.data(), methods.size(), dyn()->ctx);

        ed->range = start | dyn()->prev().range;
        dyn()->exit_scope();
        dyn()->exit_depth();
        return static_cast::<*Decl>(ed);
    }

    // ========================================================================
    //  Enum
    // ========================================================================

    /// \brief parses an enum declaration.
    ///  Grammar:  'enum' generics? name ('derives' int_type)? '{' variant* '}'
    ///    variant := name ('=' const_expr)?                  (plain)
    ///             | name '{' field (',' field)* '}'         (ADT payload)
    priv fn _parse_enum(self) -> *Decl {
        var start = dyn()->current_ptr()->range;

        if !dyn()->enter_depth() {
            return static_cast::<*Decl>(EnumDecl::create_error(dyn()->ctx, start));
        }
        dyn()->advance(T::SkipNL::After); // consume `enum`

        var gparams: std::StackBuf::<*GenericParamDecl, 2>;
        var has_generics = false;
        if dyn()->check(TokenKind::OpLess) {
            self._parse_generic_params(&gparams);
            has_generics = true;
        }

        if !dyn()->check(TokenKind::LitIdentifier) {
            dyn()->diag->report(DiagID::S046E, start.start,
                "expected enum name"
            ).first(start).emit();
            dyn()->exit_depth();
            self._sync_decl(DeclSyncCtx::TopLevel);
            return static_cast::<*Decl>(EnumDecl::create_error(dyn()->ctx, start | dyn()->prev().range));
        }
        var name = dyn()->current();
        dyn()->advance();

        var en = EnumDecl::create(dyn()->ctx, start, name, dyn()->scope.current_dc());
        if has_generics {
            en->generic_params.from_buf(gparams.data(), gparams.size(), dyn()->ctx);
        }

        // `derives <int type>` underlying type (NOT inheritance for enums).
        if dyn()->check(TokenKind::KwDerives) {
            dyn()->advance(T::SkipNL::After); // consume `derives`
            var uty = dyn()->parse_type();
            if (uty != &null) && (!is_recovery(uty)) {
                en->underlying = uty;
            }
        }

        // forward decl: `enum Foo derives u8` with no body.
        if !dyn()->check(TokenKind::OpLBrace) {
            en->range = start | dyn()->prev().range;
            dyn()->exit_depth();
            return static_cast::<*Decl>(en);
        }

        dyn()->advance(T::SkipNL::After); // consume `{`

        var variants: std::StackBuf::<*EnumVariantDecl, 8>;
        var vidx: u32 = 0;
        var any_adt = false;

        while (!dyn()->is_eof()) && (!dyn()->check(TokenKind::OpRBrace)) {
            if dyn()->check(TokenKind::TkNewLine) || dyn()->check(TokenKind::OpComma) {
                dyn()->advance();
                continue;
            }

            inline "c++" { typename T::PendingAnnotations v_annot; }
            dyn()->consume_leading_annotations(&v_annot);
            if dyn()->check(TokenKind::OpRBrace) { break; }

            var v = self._parse_enum_variant(vidx);
            if v == &null {
                self._sync_decl(DeclSyncCtx::TypeBody);
                continue;
            }
            dyn()->apply_annotations_to_decl(static_cast::<*Decl>(v), &v_annot);
            if v->is_adt() { any_adt = true; }
            variants.push_back(v);
            ++vidx;

            if dyn()->check(TokenKind::OpComma) {
                dyn()->advance(T::SkipNL::After);
                continue;
            }
            if dyn()->check(TokenKind::TkNewLine) {
                dyn()->advance(T::SkipNL::Only);
                continue;
            }
            break;
        }

        en->variants.from_buf(variants.data(), variants.size(), dyn()->ctx);
        en->is_adt = any_adt;

        if dyn()->check(TokenKind::OpRBrace) {
            dyn()->advance(T::SkipNL::Before); // consume `}`
        } else {
            dyn()->diag->report(DiagID::S048E, start.start,
                "expected '}' to close the enum body"
            ).first(start).emit();
        }

        en->mark_definition();
        en->range = start | dyn()->prev().range;
        dyn()->exit_depth();
        return static_cast::<*Decl>(en);
    }

    /// \brief parses one enum variant (plain or ADT-payload).
    priv fn _parse_enum_variant(self, idx: u32) -> *EnumVariantDecl {
        if !dyn()->check(TokenKind::LitIdentifier) {
            var r = dyn()->current_ptr()->range;
            dyn()->diag->report(DiagID::S048E, r.start,
                "expected variant name in enum body"
            ).first(r).emit();
            return &null;
        }
        var name  = dyn()->current();
        var start = name.range;
        dyn()->advance();

        var v = EnumVariantDecl::create(dyn()->ctx, start, name, idx);

        // ADT payload: `Found { key: K, value: V }`
        if dyn()->check(TokenKind::OpLBrace) {
            dyn()->advance(T::SkipNL::After); // consume `{`
            var pf: std::StackBuf::<*FieldDecl, 4>;
            var fidx: u32 = 0;
            while (!dyn()->is_eof()) && (!dyn()->check(TokenKind::OpRBrace)) {
                if dyn()->check(TokenKind::TkNewLine) || dyn()->check(TokenKind::OpComma) {
                    dyn()->advance();
                    continue;
                }
                // payload fields are `name: Type` (no var/const keyword).
                if !dyn()->check(TokenKind::LitIdentifier) { break; }
                var fname = dyn()->current();
                var fstart = fname.range;
                dyn()->advance();
                if !dyn()->check(TokenKind::OpColon) {
                    dyn()->diag->report(DiagID::S048E, fstart.start,
                        "expected ':' and a type in enum variant payload"
                    ).first(fstart).emit();
                    break;
                }
                dyn()->advance(T::SkipNL::After); // consume `:`
                var fty = dyn()->parse_type();
                if (fty == &null) || is_recovery(fty) { break; }
                var fd = FieldDecl::create(dyn()->ctx, fstart | dyn()->prev().range, fname, StorageClass::Var, fty, fidx);
                pf.push_back(fd);
                ++fidx;
                if dyn()->check(TokenKind::OpComma) { dyn()->advance(T::SkipNL::After); continue; }
                break;
            }
            if dyn()->check(TokenKind::OpRBrace) { dyn()->advance(); }
            v->payload.from_buf(pf.data(), pf.size(), dyn()->ctx);
        }
        // explicit discriminant: `= <const expr>`
        else if dyn()->check(TokenKind::OpEqual) {
            dyn()->advance(T::SkipNL::After); // consume `=`
            var disc = dyn()->parse_expr(T::ExprStopKind::StopComma);
            if (disc != &null) && (!is_recovery(disc)) {
                v->discriminant = disc;
            }
        }

        v->range = start | dyn()->prev().range;
        return v;
    }

    // ========================================================================
    //  Type alias
    // ========================================================================

    /// \brief parses a type alias.
    ///  Grammar:  'type' generics? name '=' type
    priv fn _parse_type_alias(self) -> *Decl {
        var start = dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::After); // consume `type`

        var gparams: std::StackBuf::<*GenericParamDecl, 2>;
        var has_generics = false;
        if dyn()->check(TokenKind::OpLess) {
            self._parse_generic_params(&gparams);
            has_generics = true;
        }

        if !dyn()->check(TokenKind::LitIdentifier) {
            dyn()->diag->report(DiagID::S046E, start.start,
                "expected alias name after 'type\x27"
            ).first(start).emit();
            self._sync_decl(DeclSyncCtx::TopLevel);
            return static_cast::<*Decl>(TypeAliasDecl::create_error(dyn()->ctx, start | dyn()->prev().range));
        }
        var name = dyn()->current();
        dyn()->advance();

        if !dyn()->check(TokenKind::OpEqual) {
            dyn()->diag->report(DiagID::S050E, start.start,
                "expected '=' in type alias declaration"
            ).first(start).emit();
            self._sync_decl(DeclSyncCtx::TopLevel);
            return static_cast::<*Decl>(TypeAliasDecl::create_error(dyn()->ctx, start | dyn()->prev().range));
        }
        dyn()->advance(T::SkipNL::After); // consume `=`

        var aliased = dyn()->parse_type();
        if (aliased == &null) || is_recovery(aliased) {
            return static_cast::<*Decl>(TypeAliasDecl::create_error(dyn()->ctx, start | dyn()->prev().range));
        }

        var ta = TypeAliasDecl::create(dyn()->ctx, start | dyn()->prev().range, name, aliased);
        if has_generics {
            ta->generic_params.from_buf(gparams.data(), gparams.size(), dyn()->ctx);
        }
        return static_cast::<*Decl>(ta);
    }

    // ========================================================================
    //  Module
    // ========================================================================

    /// \brief parses a module declaration.
    ///  Grammar:  'inline'? 'module' name? '{' decl* '}'
    priv fn _parse_module(self) -> *Decl {
        var start = dyn()->current_ptr()->range;

        if !dyn()->enter_depth() {
            return static_cast::<*Decl>(ModuleDecl::create_error(dyn()->ctx, start));
        }

        var is_inline = false;
        // `inline` may precede `module` (rare; the dispatcher routes KwInline
        // to the stmt path normally, but a module-inline reaches here when the
        // caller pre-checked). Defensive handling:
        if dyn()->check(TokenKind::KwInline) {
            is_inline = true;
            dyn()->advance(T::SkipNL::After);
        }
        dyn()->advance(T::SkipNL::After); // consume `module`

        var name_tok = Token();
        var anon = true;
        if dyn()->check(TokenKind::LitIdentifier) {
            name_tok = dyn()->current();
            anon = false;
            dyn()->advance();
        }

        var md = ModuleDecl::create(dyn()->ctx, start, name_tok, dyn()->scope.current_dc());
        md->is_inline    = is_inline;
        md->is_anonymous = anon;

        if !dyn()->check(TokenKind::OpLBrace) {
            dyn()->diag->report(DiagID::S050E, start.start,
                "expected '{' to begin module body"
            ).first(start).emit();
            dyn()->exit_depth();
            self._sync_decl(DeclSyncCtx::TopLevel);
            return static_cast::<*Decl>(ModuleDecl::create_error(dyn()->ctx, start | dyn()->prev().range));
        }
        dyn()->advance(T::SkipNL::After); // consume `{`

        dyn()->enter_scope(ScopeKind::Block, static_cast::<*DeclContext>(md));

        while (!dyn()->is_eof()) && (!dyn()->check(TokenKind::OpRBrace)) {
            if dyn()->check(TokenKind::TkNewLine) || dyn()->check(TokenKind::OpSemicolon) {
                dyn()->advance();
                continue;
            }
            var inner = self.parse_decl();
            if inner == &null { break; }
            if is_fatal_decl(inner) { break; }
            static_cast::<*DeclContext>(md)->add_decl(inner);
        }

        if dyn()->check(TokenKind::OpRBrace) {
            dyn()->advance(T::SkipNL::Before); // consume `}`
        } else {
            dyn()->diag->report(DiagID::S051E, start.start,
                "expected '}' to close module body"
            ).first(start).emit();
        }

        md->mark_definition();
        md->range = start | dyn()->prev().range;
        dyn()->exit_scope();
        dyn()->exit_depth();
        return static_cast::<*Decl>(md);
    }

    // ========================================================================
    //  Test
    // ========================================================================

    /// \brief parses a test declaration.
    ///  Grammar:  'test' string_literal block
    priv fn _parse_test(self) -> *Decl {
        var start = dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::After); // consume `test`

        var td = TestDecl::create(dyn()->ctx, start, dyn()->scope.current_dc());

        if dyn()->check(TokenKind::LitString) {
            var s_tok = dyn()->current();
            td->label = static_cast::<*Expr>(
                StringLiteralExpr::create(dyn()->ctx, s_tok.range, s_tok, StringLiteralExpr::StringKind::Plain)
            );
            dyn()->advance(T::SkipNL::After);
        }

        if !dyn()->check(TokenKind::OpLBrace) {
            dyn()->diag->report(DiagID::S050E, start.start,
                "expected '{' to begin test body"
            ).first(start).emit();
            self._sync_decl(DeclSyncCtx::TopLevel);
            return static_cast::<*Decl>(TestDecl::create_error(dyn()->ctx, start | dyn()->prev().range));
        }

        dyn()->enter_scope(ScopeKind::Function, static_cast::<*DeclContext>(td));
        td->body = dyn()->parse_compound();
        dyn()->exit_scope();

        td->range = start | dyn()->prev().range;
        return static_cast::<*Decl>(td);
    }

    // ========================================================================
    //  Macro (token macro vs proc/attribute macro)
    // ========================================================================

    /// \brief parses a macro declaration.
    ///  Grammar:  'macro' ( name '!' '(' params? ')' '{' raw '}'      (token macro)
    ///                     | '@' name '(' typed_params? ')' block )   (proc macro)
    priv fn _parse_macro(self) -> *Decl {
        var start = dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::After); // consume `macro`

        if dyn()->check(TokenKind::OpAt) {
            return self._parse_proc_macro(start);
        }

        var hdr = dyn()->parse_macro_header();
        if !hdr.ok {
            self._sync_decl(DeclSyncCtx::TopLevel);
            return static_cast::<*Decl>(MacroDecl::create_error(dyn()->ctx, start | dyn()->prev().range));
        }

        var mac = MacroDecl::create(dyn()->ctx, start, hdr.name);

        // step 1: keep MacroDecl's existing lossy Token param list pure
        // adapter, zero node changes. step 2 swaps this block for
        // FrozenList<MacroParamSpec>.
        var params: vec::<MacroParamSpec>;
        for var i: usize = 0; i < hdr.params.size(); ++i {
            if hdr.params[i].variadic != 0 { mac->is_variadic = true; }
            if hdr.params[i].variadic != 2 {
                var sp = MacroParamSpec{};
                sp.name     = hdr.params[i].name;
                sp.variadic = hdr.params[i].variadic;
                params.push_back(sp);
            }
        }
        mac->params_spec.from_buf(params.data(), params.size(), dyn()->ctx);

        // body: unchanged from current implementation (brace-balance, span)
        if !dyn()->check(TokenKind::OpLBrace) {
            dyn()->diag->report(DiagID::S050E, start.start,
                "expected '{' to begin macro body"
            ).first(start).emit();
            self._sync_decl(DeclSyncCtx::TopLevel);
            return static_cast::<*Decl>(MacroDecl::create_error(dyn()->ctx, start | dyn()->prev().range));
        }
        dyn()->advance();
        var body_start = dyn()->current_ptr()->range;
        var body_end   = body_start;
        var depth: u32 = 1;
        while (!dyn()->is_eof()) && depth > 0 {
            var k = dyn()->current().kind;
            if k == TokenKind::OpLBrace { depth += 1; }
            else if k == TokenKind::OpRBrace {
                depth -= 1;
                if depth == 0 { break; }
            }
            body_end = dyn()->current_ptr()->range;
            dyn()->advance();
        }
        if dyn()->check(TokenKind::OpRBrace) { dyn()->advance(T::SkipNL::Before); }

        mac->body_span = body_start | body_end;
        mac->range     = start | dyn()->prev().range;
        return static_cast::<*Decl>(mac);
    }

    /// \brief parses a procedural / attribute macro `macro @name(...) { }`.
    priv fn _parse_proc_macro(self, start: SourceRange) -> *Decl {
        dyn()->advance(); // consume `@`
        if !dyn()->check(TokenKind::LitIdentifier) {
            dyn()->diag->report(DiagID::S046E, start.start,
                "expected name after 'macro @\x27"
            ).first(start).emit();
            self._sync_decl(DeclSyncCtx::TopLevel);
            return static_cast::<*Decl>(ProcedureMacroDecl::create_error(dyn()->ctx, start | dyn()->prev().range));
        }
        var name = dyn()->current();
        dyn()->advance();

        var pm = ProcedureMacroDecl::create(dyn()->ctx, start, name, dyn()->scope.current_dc());

        dyn()->enter_scope(ScopeKind::Function, static_cast::<*DeclContext>(pm));

        // typed param list (reuse the function param parser shape)
        if dyn()->check(TokenKind::OpLParen) {
            var params: std::StackBuf::<*ParamDecl, 4>;
            self._parse_param_list(&params);
            pm->params.from_buf(params.data(), params.size(), dyn()->ctx);
        }

        // attribute macros transform AST in place they cannot declare a
        // return type. catch `-> T` here for a targeted message instead of
        // letting the body parser produce garbage.
        if dyn()->check(TokenKind::OpArrow) {
            var r = dyn()->current_ptr()->range;
            dyn()->diag->report(DiagID::S047E, r.start,
                "an attribute macro cannot declare a return type; it transforms its node argument in place"
            ).first(r).emit();
            dyn()->advance(T::SkipNL::After); // consume `->`
            var dead = dyn()->parse_type();   // consume the type for recovery
            // discard; body parse continues below
        }

        // STUB: proc-macro bodies execute compile-time AST transforms; the
        // body parses as a normal block here, but the AST-API surface it uses
        // (std::AST) is not finalized. Parse the block for structure now;
        // semantic handling is deferred.
        if dyn()->check(TokenKind::OpLBrace) {
            pm->body = dyn()->parse_compound();
        } else {
            self._parse_proc_macro_body_stub();
        }

        dyn()->exit_scope();
        pm->range = start | dyn()->prev().range;
        return static_cast::<*Decl>(pm);
    }

    priv fn _parse_proc_macro_body_stub(self) {
        std::ICE("DeclParse::_parse_proc_macro_body: proc-macro body handling not yet defined");
    }

    // ========================================================================
    //  Import
    // ========================================================================

    /// \brief parses an import declaration.
    ///  Grammar:
    ///    'import' 'module'? path
    ///      ('::' '{' import_item (',' import_item)* '}')?
    ///      ('::' '*')?
    ///      ('as' name)?
    ///    path        := identifier ('::' identifier)*
    ///    import_item := sub_path ('as' name)? | '*'
    ///    sub_path    := identifier ('::' identifier)*
    ///
    /// \details resolution semantics (enforced by the import resolution pass,
    ///          not the parser):
    ///    `import Foo`        file-first: Foo.k, fallback Foo/module.k
    ///    `import module Foo` library-only: Foo/module.k, no fallback
    ///    `import Foo::bar`   resolve Foo (file-first), then find symbol bar
    fn _parse_import(self) -> *Decl {
        var start = dyn()->current_ptr()->range;

        var spec = dyn()->parse_import_spec();
        if !spec.ok {
            self._sync_decl(DeclSyncCtx::TopLevel);
            return static_cast::<*Decl>(ImportDecl::create_error(dyn()->ctx, start | dyn()->prev().range));
        }

        var id = ImportDecl::create(dyn()->ctx, spec.range,
            (ImportKind::ModuleOnly) if (spec.is_module) else (ImportKind::Native));

        // base path
        var segs: std::StackBuf::<Token, 8>;
        for var i: usize = 0; i < spec.segments.size(); ++i {
            segs.push_back(spec.segments[i]);
        }
        id->path_segments.from_buf(segs.data(), segs.size(), dyn()->ctx);
        id->last_seg_is_macro = spec.last_seg_is_macro;   // NEW field, see below
        id->is_wildcard       = spec.is_wildcard;

        // selective items
        if spec.has_items {
            var items: std::StackBuf::<ImportItem, 8>;
            for var i: usize = 0; i < spec.items.size(); ++i {
                var s = &spec.items[i];
                var item = ImportItem{};
                var sub: std::StackBuf::<Token, 4>;
                for var j: usize = 0; j < s->sub_path.size(); ++j {
                    sub.push_back(s->sub_path[j]);
                }
                item.sub_path.from_buf(sub.data(), sub.size(), dyn()->ctx);
                item.alias       = s->alias;
                item.has_alias   = s->has_alias;
                item.is_wildcard = s->is_wildcard;
                item.is_macro    = s->is_macro;            // NEW field, see below
                item.range       = s->range;
                items.push_back(item);
            }
            id->items.from_buf(items.data(), items.size(), dyn()->ctx);
            id->has_items = true;
        }

        id->alias     = spec.alias;
        id->has_alias = spec.has_alias;
        id->range     = spec.range;
        return static_cast::<*Decl>(id);
    }

    // ========================================================================
    //  FFI
    // ========================================================================

    /// \brief parses an ffi construct.
    ///  Grammar:
    ///    'ffi' string_literal 'import' string_literal ('as' name)?
    ///    'ffi' string_literal '{' decl* '}'
    ///    'ffi' string_literal decl
    ///
    /// \details
    ///   - ffi import      ImportDecl with FFILinkage stamped
    ///   - ffi { } block   FFIBlockDecl grouping N child decls, each stamped
    ///   - ffi single decl the decl itself, stamped with FFILinkage
    ///
    ///   The parser rejects decl kinds that don't carry the FFILinkage mixin
    ///   (test, macro, enum, etc.). Sema validates deeper constraints (e.g.
    ///   ffi "c" on a ClassDecl).
    fn _parse_ffi(self) -> *Decl {
        var start = dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::After); // consume `ffi`

        // language string: "c", "c++", etc.
        if !dyn()->check(TokenKind::LitString) {
            dyn()->diag->report(DiagID::S064E, start.start,
                "expected a language string after 'ffi' (e.g. \"c++\")"
            ).first(start).emit();
            self._sync_decl(DeclSyncCtx::TopLevel);
            return static_cast::<*Decl>(ImportDecl::create_error(dyn()->ctx, start | dyn()->prev().range));
        }
        var lang_tok  = dyn()->current();
        var lang = dyn()->parse_ffi_lang(lang_tok, start);
        var linkage_kind: LinkageKind;
        switch lang {
            case FFILang::C { linkage_kind = LinkageKind::C; }
            case FFILang::Cpp { linkage_kind = LinkageKind::Cpp; }
            default {
                dyn()->diag->report(DiagID::S064E, start.start,
                    f"unsupported FFI language, expected 'c' or 'c++\x27"
                ).first(start).emit();
                self._sync_decl(DeclSyncCtx::TopLevel);
                return static_cast::<*Decl>(ImportDecl::create_error(dyn()->ctx, start | dyn()->prev().range));
            }
        }
        
        var ffi_range = (start | lang_tok.range);

        // ---- ffi "c++" import "header.h" (as alias)? ----------------------
        if dyn()->check(TokenKind::KwImport) {
            dyn()->advance(T::SkipNL::After); // consume `import`

            if !dyn()->check(TokenKind::LitString) {
                dyn()->diag->report(DiagID::S064E, start.start,
                    "expected a header path string after 'ffi \"...\" import\x27"
                ).first(start).emit();
                self._sync_decl(DeclSyncCtx::TopLevel);
                return static_cast::<*Decl>(ImportDecl::create_error(dyn()->ctx, start | dyn()->prev().range));
            }

            var header_tok = dyn()->current();
            dyn()->advance();

            var id = ImportDecl::create(dyn()->ctx, start, ImportKind::Native);
            id->set_ffi_linkage(linkage_kind, lang_tok, ffi_range);
            id->header = header_tok;

            // optional alias: `as gfx`
            if dyn()->check(TokenKind::KwAs) {
                dyn()->advance(T::SkipNL::After); // consume `as`
                if dyn()->check(TokenKind::LitIdentifier) {
                    id->alias     = dyn()->current();
                    id->has_alias = true;
                    dyn()->advance();
                } else {
                    dyn()->report_tok(DiagID::S064E, dyn()->current_ptr(),
                        "expected a name after 'as' in ffi import"
                    );
                }
            }

            id->range = start | dyn()->prev().range;
            return static_cast::<*Decl>(id);
        }

        // ---- ffi "c++" { decl* } ------------------------------------------
        if dyn()->check(TokenKind::OpLBrace) {
            dyn()->advance(T::SkipNL::After); // consume `{`

            var fb = FFIBlockDecl::create(dyn()->ctx, start, lang_tok);
            var decls: std::StackBuf::<*Decl, 8>;

            while (!dyn()->is_eof()) && (!dyn()->check(TokenKind::OpRBrace)) {
                if dyn()->check(TokenKind::TkNewLine) || dyn()->check(TokenKind::OpSemicolon) {
                    dyn()->advance();
                    continue;
                }
                var d = self.parse_decl();
                if d == &null { break; }
                if is_fatal_decl(d) { break; }

                if !self._stamp_ffi_linkage(d, linkage_kind, lang_tok, ffi_range) {
                    dyn()->diag->report(DiagID::S064E, d->range.start,
                        "this declaration cannot appear in an ffi block"
                    ).first(d->range).emit();
                }

                decls.push_back(d);
            }

            if dyn()->check(TokenKind::OpRBrace) {
                dyn()->advance(T::SkipNL::Before); // consume `}`
            } else {
                dyn()->diag->report(DiagID::S064E, start.start,
                    "expected '}' to close ffi block"
                ).first(start).emit();
            }

            fb->body.from_buf(decls.data(), decls.size(), dyn()->ctx);
            fb->range = start | dyn()->prev().range;
            return static_cast::<*Decl>(fb);
        }

        // ---- ffi "c++" fn foo(...) ----------------------------------------
        var d = self._dispatch_decl();
        if (d == &null) || is_fatal_decl(d) {
            dyn()->diag->report(DiagID::S064E, start.start,
                "expected a declaration, 'import', or '{' after 'ffi \"...\"\x27"
            ).first(start).emit();
            self._sync_decl(DeclSyncCtx::TopLevel);
            return static_cast::<*Decl>(ImportDecl::create_error(dyn()->ctx, start | dyn()->prev().range));
        }

        if !self._stamp_ffi_linkage(d, linkage_kind, lang_tok, ffi_range) {
            dyn()->diag->report(DiagID::S064E, d->range.start,
                "this declaration cannot have foreign linkage"
            ).first(d->range).emit();
        }

        return d;
    }

    /// \brief stamps FFILinkage on a decl if it carries the mixin.
    /// \returns true if the stamp succeeded, false if the decl kind doesn't
    ///          support foreign linkage.
    priv fn _stamp_ffi_linkage(
        self,
        d:            *Decl,
        kind:         LinkageKind,
        lang_tok:     Token,
        ffi_range:    SourceRange
    ) -> bool {
        if isa::<FunctionDecl>(d) {
            cast::<FunctionDecl>(d)->set_ffi_linkage(kind, lang_tok, ffi_range);
            return true;
        }
        if isa::<ClassDecl>(d) {
            cast::<ClassDecl>(d)->set_ffi_linkage(kind, lang_tok, ffi_range);
            return true;
        }
        if isa::<StructDecl>(d) {
            cast::<StructDecl>(d)->set_ffi_linkage(kind, lang_tok, ffi_range);
            return true;
        }
        if isa::<UnionDecl>(d) {
            cast::<UnionDecl>(d)->set_ffi_linkage(kind, lang_tok, ffi_range);
            return true;
        }
        if isa::<TypeAliasDecl>(d) {
            cast::<TypeAliasDecl>(d)->set_ffi_linkage(kind, lang_tok, ffi_range);
            return true;
        }
        if isa::<VariableDecl>(d) {
            cast::<VariableDecl>(d)->set_ffi_linkage(kind, lang_tok, ffi_range);
            return true;
        }
        if isa::<ImportDecl>(d) {
            cast::<ImportDecl>(d)->set_ffi_linkage(kind, lang_tok, ffi_range);
            return true;
        }
        return false;
    }

    // ========================================================================
    //  eval { decl* }  decl block
    // ========================================================================

    /// \brief parses a decl-only eval block at namespace/type scope.
    ///  Grammar:  'eval' '{' decl* '}'
    priv fn _parse_eval_block_decl(self) -> *Decl {
        var start = dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::After); // consume `eval`

        if !dyn()->check(TokenKind::OpLBrace) {
            dyn()->diag->report(DiagID::S050E, start.start,
                "expected '{' after 'eval\x27"
            ).first(start).emit();
            self._sync_decl(DeclSyncCtx::TopLevel);
            return static_cast::<*Decl>(EvalBlockDecl::create_error(dyn()->ctx, start | dyn()->prev().range));
        }
        dyn()->advance(T::SkipNL::After); // consume `{`

        var eb = EvalBlockDecl::create(dyn()->ctx, start);
        var decls: std::StackBuf::<*Decl, 8>;

        while (!dyn()->is_eof()) && (!dyn()->check(TokenKind::OpRBrace)) {
            if dyn()->check(TokenKind::TkNewLine) || dyn()->check(TokenKind::OpSemicolon) {
                dyn()->advance();
                continue;
            }
            var d = self.parse_decl();
            if d == &null { break; }
            if is_fatal_decl(d) { break; }
            decls.push_back(d);
        }

        if dyn()->check(TokenKind::OpRBrace) {
            dyn()->advance(T::SkipNL::Before); // consume `}`
        } else {
            dyn()->diag->report(DiagID::S051E, start.start,
                "expected '}' to close eval block"
            ).first(start).emit();
        }

        eb->body.from_buf(decls.data(), decls.size(), dyn()->ctx);
        eb->range = start | dyn()->prev().range;
        return static_cast::<*Decl>(eb);
    }

    // ========================================================================
    //  Recovery
    // ========================================================================

    /// \brief consumes tokens until a declaration boundary or stop delimiter.
    /// \details delimiter-aware (tracks ()/[]/{} and <> for generics). Stops
    ///          at depth 0 on a decl lead-in keyword, a `}` closing the
    ///          enclosing scope, a newline/`;` at top level, or EOF. Capped at
    ///          MAX_SYNC tokens.
    fn _sync_decl(self, ctx: DeclSyncCtx) {
        var bp: i32 = 0;  // paren
        var bs: i32 = 0;  // square
        var bb: i32 = 0;  // brace
        var ba: i32 = 0;  // angle (generics)
        var consumed: u32 = 0;
        const var MAX_SYNC: u32 = 128;

        while !dyn()->is_eof() {
            if consumed >= MAX_SYNC { return; }
            ++consumed;

            var k = dyn()->current().kind;

            if      k == TokenKind::OpLParen  { ++bp; }
            else if k == TokenKind::OpLSquare { ++bs; }
            else if k == TokenKind::OpLBrace  { ++bb; }
            else if k == TokenKind::OpLess    { ++ba; }
            else if k == TokenKind::OpRParen  { if bp == 0 && ctx == DeclSyncCtx::Params { return; } if bp > 0 { --bp; } }
            else if k == TokenKind::OpRSquare { if bs > 0 { --bs; } }
            else if k == TokenKind::OpGreater { if ba == 0 && ctx == DeclSyncCtx::Generics { return; } if ba > 0 { --ba; } }
            else if k == TokenKind::OpRBrace  {
                if bb == 0 {
                    // closer of the enclosing type/module body don't consume.
                    return;
                }
                --bb;
            }
            else if (bp == 0) && (bs == 0) && (bb == 0) && (ba == 0) {
                if ctx == DeclSyncCtx::Params || ctx == DeclSyncCtx::Generics {
                    if k == TokenKind::OpComma { return; }
                    if k == TokenKind::OpPipe || k == TokenKind::OpPipePipe || k == TokenKind::OpLBrace { return; }
                }
                if ctx == DeclSyncCtx::TopLevel {
                    if k == TokenKind::TkNewLine || k == TokenKind::OpSemicolon { return; }
                    if self._starts_decl_kw(k) { return; }
                }
                if ctx == DeclSyncCtx::TypeBody {
                    // member lead-ins inside a type body.
                    if k == TokenKind::KwFn      || k == TokenKind::KwVar
                    || k == TokenKind::KwConst   || k == TokenKind::KwStatic
                    || k == TokenKind::KwEval    || k == TokenKind::KwClass
                    || k == TokenKind::KwStruct  || k == TokenKind::KwEnum
                    || k == TokenKind::KwUnion   || k == TokenKind::KwInterface
                    || k == TokenKind::KwType    || k == TokenKind::KwOverride
                    || k == TokenKind::KwVirtual || k == TokenKind::KwFinal
                    || k == TokenKind::KwMutable {
                        return;
                    }
                }
            }

            dyn()->advance();
        }
    }

    // =========================================================================
    // Closures
    // =========================================================================

    /// \brief Parses a complete closure signature with structured error recovery.
    pub fn _parse_closure_sig(self) -> (FrozenList::<*ParamDecl>, FrozenList::<*GenericParamDecl>, FrozenList::<ClosureExpr::Capture>, FnModifier, *Type, bool) {
        var gparams: std::StackBuf::<*GenericParamDecl, 2>;
        var params:   std::StackBuf::<*ParamDecl, 4>;
        var captures: std::StackBuf::<ClosureExpr::Capture, 4>;
        var ret_type: *Type = &null;
        var explicit_no_capture = false;

        // optional generic params: `fn <T> |captures| (params) -> T`
        if dyn()->check(TokenKind::OpLess) {
            self._parse_generic_params(&gparams);
        }

        // parameter list: `(x: i32, y: i32)`
        if dyn()->check(TokenKind::OpLParen) {
            self._parse_param_list(&params);
        }

        // Recovery: If parameter list parsing exited unexpectedly or left corrupt tokens,
        // synchronize up to the next logical milestone before proceeding.
        if( !dyn()->check(TokenKind::OpPipe)) && (!dyn()->check(TokenKind::OpPipePipe)) && (!dyn()->check(TokenKind::OpArrow)) &&
           (!dyn()->check(TokenKind::OpLBrace)) && (!dyn()->check(TokenKind::OpEqual)) &&
           (!self._is_closure_modifier(dyn()->current().kind)) && !dyn()->is_eof() {
            self._sync_to_closure_milestone();
        }

        // capture list: `|a, *b|` / `|*|` / `||`
        if dyn()->check(TokenKind::OpPipe) {
            self._parse_capture_list(&captures);
        } else if dyn()->check(TokenKind::OpPipePipe) {
            dyn()->advance(); // consume `||`
            explicit_no_capture = true;
        }

        // capture list: `|a, *b|` / `|*|` / `||`
        if dyn()->check(TokenKind::OpPipe) {
            self._parse_capture_list(&captures);
        }

        // trailing modifiers: const / unsafe / async / eval
        var modifiers = FnModifier::None;
        while true {
            if dyn()->check(TokenKind::KwConst) {
                var r = dyn()->current_ptr()->range;
                dyn()->diag->report(DiagID::S047E, r.start, "'const' is not a valid closure modifier").first(r).emit();
                dyn()->advance();
            }

            else if dyn()->check(TokenKind::KwUnsafe) {
                var r = dyn()->current_ptr()->range;
                dyn()->diag->report(DiagID::S047E, r.start, "'unsafe' is not a valid closure modifier").first(r).emit();
                dyn()->advance();
            }

            else if dyn()->check(TokenKind::KwEval) {
                var r = dyn()->current_ptr()->range;
                dyn()->diag->report(DiagID::S047E, r.start, "'eval' is not a valid closure modifier").first(r).emit();
                dyn()->advance();
            }

            else if dyn()->check(TokenKind::KwFinal) {
                var r = dyn()->current_ptr()->range;
                dyn()->diag->report(DiagID::S047E, r.start, "'final' is not a valid closure modifier").first(r).emit();
                dyn()->advance();
            }

            else if dyn()->check(TokenKind::KwInline) {
                var r = dyn()->current_ptr()->range;
                dyn()->diag->report(DiagID::S047E, r.start, "'inline' is not a valid closure modifier").first(r).emit();
                dyn()->advance();
            }

            else if dyn()->check(TokenKind::KwVirtual) {
                var r = dyn()->current_ptr()->range;
                dyn()->diag->report(DiagID::S047E, r.start, "'virtual' is not a valid closure modifier").first(r).emit();
                dyn()->advance();
            }

            else if dyn()->check(TokenKind::KwOverride) {
                var r = dyn()->current_ptr()->range;
                dyn()->diag->report(DiagID::S047E, r.start, "'override' is not a valid closure modifier").first(r).emit();
                dyn()->advance();
            }

            else if dyn()->check(TokenKind::KwPanic)    { modifiers |= FnModifier::IsPanic;    dyn()->advance(); }
            else if dyn()->check(TokenKind::KwVolatile) { modifiers |= FnModifier::IsVolatile; dyn()->advance(); }
            else if dyn()->check(TokenKind::KwAsync)    { modifiers |= FnModifier::IsAsync;    dyn()->advance(); }
            else { break; }
        }

        // return type: `-> T`
        if dyn()->check(TokenKind::OpArrow) {
            dyn()->advance(T::SkipNL::After); // consume `->`
            if dyn()->check(TokenKind::OpExclaim) {
                dyn()->advance(); // consume `!`, noreturn closure, sema validates
            } else {
                var rty = dyn()->parse_type();
                if (rty != &null) && (!is_recovery(rty)) {
                    ret_type = rty;
                }
            }
        }

        var gp_list:  FrozenList::<*GenericParamDecl>;
        var p_list:   FrozenList::<*ParamDecl>;
        var cap_list: FrozenList::<ClosureExpr::Capture>;

        gp_list.from_buf(gparams.data(),  gparams.size(),  dyn()->ctx);
        p_list.from_buf(params.data(),    params.size(),   dyn()->ctx);
        cap_list.from_buf(captures.data(), captures.size(), dyn()->ctx);

        return (p_list, gp_list, cap_list, modifiers, ret_type, explicit_no_capture);
    }
}
