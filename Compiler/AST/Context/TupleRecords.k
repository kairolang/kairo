/// --- The Kairo Project ------------------- AST/Context/TupleRecords.k --- ///
///
///   \brief The record a tuple IS. `(A, B)` is `Tuple2<A, B>`: a generic
///          struct of arity N with fields `_0 .. _N-1` typed by its own
///          parameters `T0 .. TN-1`, no constructor, no methods. Minted here
///          on first use, one per arity per BUILD, from no source file.
///
///   \detail
///     A tuple is a language primitive, not a library type, so no builtin
///     file declares one and no TU parses 128 structs it never names. The
///     pattern is built in memory the first time any TU resolves a tuple
///     of that arity, exactly as a user would have written it:
///
///         struct <T0, T1> Tuple2 { var _0: T0  var _1: T1 }
///
///     (the spellings are LangItems::tuple_record_name / tuple_param_name /
///     tuple_field_name; nothing else writes them)
///
///     and from then on it is an ordinary generic record to every pass
///     after T and to C++: TypeResolve canonicalizes the written type to
///     `record(Tuple2, [A, B])` through the instantiation registry, so a
///     tuple written in two TUs is one identity, EmitPlan reaches it like
///     any record (only the arities a TU names are emitted), CXXSpell
///     spells `Tuple2<int, double>`, and `t.1` is the field `_1`.
///
///     The decl is HOMED in the builtin root TU: its name imms live in that
///     TU's table (hard invariant #2: a name is read in its decl's own TU),
///     its semantic scope is that TU (so its C++ namespace is the builtin
///     root's and `qual_name` needs no special case), but it sits in no
///     symbol table and no dc_decls list -- nothing finds it by name, and
///     the root's own plan never lists it as an own decl. Tuple-ness is
///     `StructDecl::tuple_arity` on the pattern, by identity, never the
///     name: a user is free to declare a `Tuple2` of their own.
///
///     Nodes are allocated from this class's own arena under its own lock,
///     the way InstantiationRegistry mints instance shells: a user TU
///     reaches here from its T pass while the root TU is long quiescent,
///     but two user TUs may race, and the root's ast_alloc is not for
///     another thread to touch. Only the two names per arity (`TupleN`,
///     `_i`/`Ti`) touch the root's interner, under the lock.
///
///   Layer: AST. Owned by GlobalDisambigTable; built through
///   SemaContext::tuple_record, which is the ONE canonical builder for a
///   tuple (TypeUtil::tuple_of reaches the same one).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Memory::ArenaAllocator::*;
import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::Context::CanonicalTypes::*;
import AST::LangItems::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::Declarations::*;
import AST::Node::Types::*;
import AST::Kind::DeclKind::*;
import AST::Mixin::Annotation::*;
import Token::Token::*;
import Token::TokenKind::*;
import Location::SourceRange::*;
import Location::SourceManager::*;

class TupleRecords {
    priv var _arena: ArenaAllocator = ArenaAllocator(64 * 1024);
    priv var _mu:    std::Mutex;
    /// Indexed by arity; null until that arity is first asked for. Sized
    /// TUPLE_MAX_ARITY + 1 so the index is the arity.
    priv var _by_arity: vec::<*Decl>;

    fn TupleRecords(self) {
        for var i: usize = 0; i <= TUPLE_MAX_ARITY(); ++i { self._by_arity.push_back(&null); }
    }

    /// The pattern for a tuple of \p arity, minted on first call. Null for
    /// an arity outside [2, TUPLE_MAX_ARITY] or with no root to home it in
    /// (\p ctx null: a build with no builtin root, which TypeResolve reports
    /// as it reports any unbound lang item).
    /// \p root_dc is the root TU as a DeclContext: the caller casts, since
    /// this layer cannot name TranslationUnit (it imports the global table).
    fn pattern(self, arity: usize, ctx: *ASTContext, root_dc: *DeclContext, types: *CanonicalTypeStore) -> *Decl {
        if (arity < 2) || (arity > TUPLE_MAX_ARITY()) { return &null; }
        if (ctx == &null) || (root_dc == &null) || (types == &null) { return &null; }
        var lock = std::LockGuard(self._mu);
        var hit = self._by_arity[arity];
        if hit != &null { return hit; }
        var d = self._mint(arity, ctx, root_dc, types);
        self._by_arity[arity] = d;
        return d;
    }

    // --- minting ---------------------------------------------------------------

    priv fn <T> _alloc(self) -> *T {
        var mem: *void = self._arena.alloc(sizeof(T), alignof(T));
        libcxx::memset(mem, 0, sizeof(T));
        inline "c++" {
            ::new (mem) T();
        }
        return static_cast::<*T>(mem);
    }

    priv fn <T> _alloc_array(self, n: usize) -> *T {
        if n == 0 { return &null; }
        var mem: *void = self._arena.alloc(sizeof(T) * n, alignof(T));
        return static_cast::<*T>(mem);
    }

    /// An identifier token whose imm is the ROOT's: the decl is spelled in
    /// its own TU (CXXSpell::leaf reads the name through fid_of(d)).
    priv fn _ident(self, ctx: *ASTContext, at: SourceRange, spelling: string) -> Token {
        var t = Token();
        t.kind  = TokenKind::LitIdentifier;
        t.range = at;
        t.imm   = ctx->get_imm_table()->intern_ident_copy(spelling);
        return t;
    }

    /// `struct <T0, .., TN-1> TupleN { var _0: T0 .. var _N-1: TN-1 }`.
    priv fn _mint(self, arity: usize, ctx: *ASTContext, root_dc: *DeclContext, types: *CanonicalTypeStore) -> *Decl {
        // A VALID range in the root file: a decl whose range is invalid
        // reaches the token sink and ICEs there. Byte 0 of the root, the
        // anchor the emitter itself uses for tokens with no bytes of their
        // own (InterfaceEmitter::_tu_at).
        var at = SourceRange::invalid();
        if ctx->sm != &null {
            at = (ctx->sm->get_range(ctx->fid, 0, 1)) if (ctx->sm->get_file_size(ctx->fid) > 0)
                 else (ctx->sm->get_range(ctx->fid, 0, 0));
        }

        var s = self._alloc::<StructDecl>();
        s->kind  = DeclKind::StructDecl;
        s->range = at;
        s->name  = self._ident(ctx, at, tuple_record_name(arity));
        s->init_annotations(&(self._arena));
        s->init_dc(DeclContextKind::Struct, ctx, root_dc, static_cast::<*Decl>(s));
        s->dc_decls.set_allocator(&(self._arena));   // NOT the root's ast_alloc: another thread's arena.
        s->init_redecl();
        s->is_this_definition = true;
        s->is_implicit        = true;
        s->tuple_arity        = static_cast::<u32>(arity);
        s->spec_kind          = SpecKind::Primary;
        s->instantiated_from  = &null;
        s->requires_clause    = &null;
        s->spec_args.from_raw(static_cast::<*(*Type)>(&null), 0);
        s->methods.from_raw(static_cast::<*(*FunctionDecl)>(&null), 0);
        s->implements.from_raw(static_cast::<*InheritEdge>(&null), 0);
        var sd = static_cast::<*Decl>(s);
        sd->semantic_dc = reinterpret_cast::<*void>(root_dc);
        sd->lexical_dc  = reinterpret_cast::<*void>(root_dc);
        sd->set_visibility(VisibilityKind::Public, at);
        var sdc = static_cast::<*DeclContext>(s);

        // The parameters first: a field's type is one of them, and the
        // canonical GenericParamType is uniqued on (owner, index), so the
        // owner must exist before the first field is typed.
        var gps = self._alloc_array::<*GenericParamDecl>(arity);
        for var i: usize = 0; i < arity; ++i {
            var gp = self._alloc::<GenericParamDecl>();
            gp->kind  = DeclKind::GenericParamDecl;
            gp->range = at;
            gp->name  = self._ident(ctx, at, tuple_param_name(i));
            gp->init_annotations(&(self._arena));
            gp->index = static_cast::<u32>(i);
            gp->owner = sd;                       // what T stamps on a parsed one.
            gp->impl_bounds.from_raw(static_cast::<*InheritEdge>(&null), 0);
            gp->derives_bounds.from_raw(static_cast::<*InheritEdge>(&null), 0);
            var gd = static_cast::<*Decl>(gp);
            gd->is_implicit = true;
            gps[i] = gp;
        }
        s->generic_params.from_raw(gps, arity);

        // The fields, in element order, which is layout order: `_i: Ti`.
        // The type is the canonical itself (canonical == self), as
        // EnumLayoutLowering types the fields it mints.
        var fs = self._alloc_array::<*FieldDecl>(arity);
        for var i: usize = 0; i < arity; ++i {
            var f = self._alloc::<FieldDecl>();
            f->kind    = DeclKind::FieldDecl;
            f->range   = at;
            f->name    = self._ident(ctx, at, tuple_field_name(i));
            f->init_annotations(&(self._arena));
            f->storage = StorageClass::Var;
            f->type_   = types->generic_param(sd, static_cast::<u32>(i), false);
            f->index   = static_cast::<u32>(i);
            var fd = static_cast::<*Decl>(f);
            fd->is_implicit = true;
            // A member of the record to C++: where a spelling of it
            // (CXXSpell::leaf, by its scope's TU) and a use of it
            // (EmitPlan::_member_owner) find it.
            fd->semantic_dc = reinterpret_cast::<*void>(sdc);
            fd->lexical_dc  = reinterpret_cast::<*void>(sdc);
            fd->set_visibility(VisibilityKind::Public, at);
            sdc->add_decl(fd);
            fs[i] = f;
        }
        s->fields.from_raw(fs, arity);
        return sd;
    }
}
