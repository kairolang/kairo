/// --- The Kairo Project ----------------- Sema/Foreign/BuiltinImport.k --- ///
///
///   \brief A name clang knows as a builtin is a foreign function the TU did
///          not have to import. This mints the Kairo FunctionDecl for one, on
///          the first use anywhere in the build, from the prototype clang
///          gives it.
///
///   \detail
///     Consulted by N(b) only after every Kairo source missed (locals, the DC
///     chain, the extend target, the import overlay), so any declaration of
///     the same name wins. There is no qualified form.
///
///     Policy, in order:
///       library builtin (`memcpy`, `printf`)  -> MISS: its header declares
///                                                it, and without the header
///                                                C++ does not see it either.
///       custom type-checking (`t`)            -> error at the use; these need
///                                                per-builtin typing hooks.
///       type needs a header (FILE, jmp_buf)   -> error at the use.
///       a type Kairo cannot express           -> error at the use. Never an
///                                                opaque parameter: nothing
///                                                could pass one.
///       otherwise                             -> one canonical decl, cached
///                                                build-wide by ID.
///
///     `size_t` and `ptrdiff_t` are read off the TYPE STRING, not the
///     QualType: GetBuiltinType returns canonical types, `size_t` arrives as
///     `unsigned long`, and TypeImport's sugar rule would map it to u64.
///
///   \par Where the decls live
///     In a foreign TU of their own, over a pseudo-header holding every
///     supported name on its own line. A decl's name token is ranged at its
///     line, so TokenText reads it back through the range like any header
///     decl (hard invariant #2), and "declared here" points somewhere true.
///     Every token is minted at init, on the driver thread: the lazy path
///     never touches an interner.
///
///   \par Threading
///     init(): driver thread, before the first SemaContext. resolve(): any
///     thread. Hits take the shared lock; the first resolve of an ID takes the
///     exclusive one, which also covers the oracle's ASTContext and this TU's
///     arena.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/DenseMap.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "clang/AST/ASTContext.h"
ffi "c++" import "clang/AST/Type.h"
ffi "c++" import "clang/Basic/Builtins.h"
ffi "c++" import "string"
ffi "c++" import "vector"
ffi "c++" import "utility"

import AST::Context::ASTContext::ASTContext
import AST::Context::CanonicalTypes::CanonicalTypeStore
import AST::Context::DeclContext::DeclContext
import AST::Context::GlobalDisambigTable::GlobalDisambigTable
import AST::Context::InstantiationRegistry::InstantiationRegistry
import AST::Context::SymbolTable::SymbolTable
import AST::Context::TranslationUnit::TranslationUnit
import AST::DeclFacts::decl_set_imported
import AST::LangItems::LowerTargets
import AST::Mixin::Annotation::VisibilityKind
import AST::Node::Base::Type
import AST::Node::CanonicalNodes::BuiltinKind
import AST::Node::Declarations::{
    FnBodyKind,
    FnModifier,
    FunctionDecl,
    ParamDecl,
}
import Interop::Clang::BuiltinsSet::BuiltinsSet
import Location::SourceManager::SourceManager
import Sema::Foreign::ForeignRegistry::ForeignRegistry
import Sema::Foreign::HeaderIndex::HeaderIndex
import Sema::Foreign::TypeImport::TypeImport
import Support::FileIO::Path::Path
import Support::TimeReport::TimeRegion
import Token::Token::Token
import Token::TokenKind::TokenKind

/// Parameter name tokens minted at init. No builtin comes near it; one that
/// did would be reported, not truncated.
pub
const BUILTIN_MAX_PARAMS: usize = 32

/// One resolve() answer:
///   miss        decl null, why empty: not a builtin, or a library one.
///   unusable    decl null, why set:   a builtin Kairo cannot call; `why` is
///                                     the whole diagnostic text.
///   bound       decl set.
pub struct BuiltinEntry {
    var decl: unsafe *FunctionDecl = &null
    var why:  string               = ""
}

pub class BuiltinImport {
    priv var _oracle:    unsafe *BuiltinsSet
    priv var _ksm:       unsafe *SourceManager
    priv var _store:     unsafe *CanonicalTypeStore
    priv var _instances: unsafe *InstantiationRegistry
    priv var _reg:       unsafe *ForeignRegistry
    priv var _ctx:       unsafe *ASTContext
    priv var _tu:        unsafe *TranslationUnit
    priv var _fid:       u32                           = 0
    /// The pseudo-header's bytes. load_virtual BORROWS them for the fid's
    /// lifetime, so they live here, set once, never reassigned.
    priv var _text: cxx::std::string

    priv var _name_tok: llvm::DenseMap<u32, Token> ///< builtin ID -> its line's token.
    priv var _arg_tok:  cxx::std::vector<Token> ///< `__arg0` .. `__arg{MAX-1}`.
    priv var _done:     llvm::DenseMap<u32, BuiltinEntry>
    priv var _mu:       kairo::std::SharedMutex
    priv var _ready:    bool                              = false

    fn BuiltinImport(self) { }

    static fn path() -> string {
        return "<kairo-clang-builtins>"
    }

    fn ready(self) -> bool {
        return self._ready
    }

    /// Is \p name a predefined macro of the target (Compiler/Spec/Eval.md#defined).
    fn macro_predefined(self, const name: string) -> bool {
        if self._oracle == &null {
            return false
        }

        return self._oracle->predefined(name)
    }

    /// The scope a builtin decl answers from, for the resolution trace.
    fn scope(self) -> unsafe *DeclContext {
        return self._tu
    }

    /// # init (driver thread)

    /// Write the pseudo-header, mint its TU, mint every token. False leaves
    /// this unready, and resolve() then misses on everything.
    pub fn init(self,
                oracle: unsafe *BuiltinsSet,
                ksm:    unsafe *SourceManager,
                hidx:   unsafe *HeaderIndex,
                g:      unsafe *GlobalDisambigTable,
                reg:    unsafe *ForeignRegistry) -> bool {
        if self._ready {
            return true
        }

        if oracle == &null || !oracle->ready() {
            return false
        }

        var _t = TimeRegion("BuiltinImport")

        // ASCII only, so a code-point offset IS a byte offset.
        var n    = oracle->count()
        var text = ""
        var offs = cxx::std::vector<usize>()
        for var i: usize = 0; i < n; ++i {
            offs.push_back(text.size())
            text += oracle->name_at(i)
            text += "\n"
        }

        var arg_offs = cxx::std::vector<usize>()
        for var i: usize = 0; i < BUILTIN_MAX_PARAMS; ++i {
            arg_offs.push_back(text.size())
            text += LowerTargets::foreign_param(i) + "\n"
        }

        // Loaded at most once: a retry after a later failure must not
        // reassign _text under a fid that still points into it.
        if self._fid == 0 {
            self._text = kairo::std::to_std_string(text)
            self._fid = ksm->load_virtual(
                Path(BuiltinImport::path()),
                unsafe (self._text.data() as kairo::std::ConstPtr<u8>),
                self._text.size(),
            )

            if self._fid == u32::MAX {
                self._fid = 0
                return false
            }
        }

        var        fid = self._fid
        var unsafe *t  = hidx->ensure_target(fid, BuiltinImport::path())
        if t == &null {
            return false
        }

        // Not Kairo source: the codegen loop must never visit it. _target
        // marks only a TU it creates, so say it here regardless.
        t->tu->is_foreign = true
        // Nothing binds into this TU's table: resolve() is the only way in.
        // It still gets a frozen, empty one, so a probe sees a scope, not a hole.
        if t->tu->dc_symbols == &null {
            var unsafe *tbl = t->ctx->alloc_init_cleanup<SymbolTable>(t->ctx)
            tbl->freeze()
            t->tu->set_symbols(tbl)
        }

        t->frozen = true

        self._oracle    = oracle
        self._ksm       = ksm
        self._reg       = reg
        self._store     = g->types()
        self._instances = g->instances()
        self._ctx       = t->ctx
        self._tu        = t->tu
        self._fid       = fid

        self._name_tok.reserve((n as u32))
        for var i: usize = 0; i < n; ++i {
            var nm = oracle->name_at(i)
            var at = ksm->get_range(fid, ((offs[i])), nm.size())
            self._name_tok.insert(
                cxx::std::pair<u32, Token>(
                    oracle->id_at(i),
                    t->ctx->make_token(at, TokenKind::LitIdentifier, nm),
                ),
            )
        }

        for var i: usize = 0; i < BUILTIN_MAX_PARAMS; ++i {
            var nm = LowerTargets::foreign_param(i)
            var at = ksm->get_range(fid, ((arg_offs[i])), nm.size())
            self._arg_tok.push_back(
                t->ctx->make_token(at, TokenKind::LitIdentifier, nm),
            )
        }

        self._ready = true
        return true
    }

    /// # resolve (any thread)

    fn resolve(self, const name: string) -> BuiltinEntry {
        var out = BuiltinEntry{}
        if !self._ready {
            return out
        }

        var id = self._oracle->id_of(name)
        if id == 0 {
            return out
        }

        if self._cached(id, &out) {
            return out
        }

        var lock = kairo::std::LockGuard(self._mu)
        var it   = self._done.find(id)
        if it != self._done.end() { // lost the race to another TU.
            return it->second
        }

        var e = self._import(id, name)
        self._done.insert(cxx::std::pair<u32, BuiltinEntry>(id, e))
        return e
    }

    priv fn _cached(self, id: u32, out: *BuiltinEntry) -> bool {
        var rlock = kairo::std::SharedLock(self._mu)
        var it    = self._done.find(id)
        if it == self._done.end() {
            return false
        }

        *out = it->second
        return true
    }

    /// Under the exclusive lock.
    priv fn _import(self, id: u32, const name: string) -> BuiltinEntry {
        var        out = BuiltinEntry{}
        var unsafe *bi = self._oracle->builtins()

        // Clang's own C++ gate (Sema::LookupBuiltin): a predefined library
        // function (`f`: memcpy, printf) is never implicitly declared in C++;
        // its header declares it, so it misses here too. NOT isLibFunction:
        // that is `F`, the `__builtin_`-prefixed variant, which C++ always has.
        if bi->isPredefinedLibFunction(id) || bi->isHeaderDependentFunction(id) {
            return out
        }

        if bi->hasCustomTypechecking(id) {
            out.why = f"'{name}' is type-checked by clang per call; Kairo cannot call it yet"
            return out
        }

        var unsafe *cctx     = self._oracle->ast()
        var        err       = clang::ASTContext::GE_None
        var        mask: u32 = 0
        var        qt        = cctx->GetBuiltinType(id, &err, unsafe &mask)
        if err != clang::ASTContext::GE_None {
            out.why = f"'{name}' is declared in terms of {BuiltinImport::_missing(err)}, which only a header provides"
            return out
        }

        var fpt: unsafe *const clang::FunctionProtoType = &null
        if !qt.isNull() {
            fpt = qt->getAs<clang::FunctionProtoType>()
        }

        if fpt == &null {
            out.why = f"clang gives '{name}' no prototype"
            return out
        }

        var np = (fpt->getNumParams() as usize)
        if np > BUILTIN_MAX_PARAMS {
            out.why = f"'{name}' takes {np} parameters; Kairo imports builtins of at most {BUILTIN_MAX_PARAMS}"
            return out
        }

        var ti = TypeImport(
            self._store,
            self._instances,
            self._reg,
            cctx,
            self._ctx,
            self._fid,
        )

        var ts = llvm::StringRef(bi->getTypeString(id)) // VERIFY(22.x)
        var slots = BuiltinImport::sized_slots(
            string(
                unsafe ((ts.data() as unsafe *const u8) as *const u8),
                ts.size(),
            ),
        )

        // The decoder and clang disagree on the shape: trust the canonical
        // types over a guess at which slot is which.
        if slots.size() != np + 1 {
            slots.clear()
        }

        var rt: unsafe *Type = &null
        var rq               = fpt->getReturnType()
        if !rq->isVoidType() {
            rt = self._slot_type(&ti, rq, &slots, 0)
            if rt == &null {
                out.why = f"'{name}' returns '{ti.spelling(rq)}', which Kairo cannot express"
                return out
            }
        }

        var ptys = cxx::std::vector<unsafe *Type>()
        for var i: usize = 0; i < np; ++i {
            var        pq  = fpt->getParamType(i as u32)
            var unsafe *pt = self._slot_type(&ti, pq, &slots, i + 1)
            if pt == &null {
                out.why = f"parameter {i + 1} of '{name}' has type '{ti.spelling(pq)}', which Kairo cannot express"
                return out
            }

            ptys.push_back(pt)
        }

        out.decl = self._mint(
            id,
            name,
            fpt,
            rt,
            &ptys,
            &ti,
            mask,
            bi->isNoReturn(id),
            bi->isNoThrow(id),
        )

        if out.decl == &null {
            out.why = f"internal: no token was minted for builtin '{name}'"
        }

        return out
    }

    priv fn _slot_type(self,
                       ti:           *TypeImport,
                       qt:           clang::QualType,
                       @inout slots: cxx::std::vector<u8>,
                       i:            usize) -> unsafe *Type {
        if i < slots.size() {
            if slots[i] == 1 {
                return self._store->builtin(BuiltinKind::USize)
            }

            if slots[i] == 2 {
                return self._store->builtin(BuiltinKind::ISize)
            }
        }

        return ti->try_import(qt)
    }

    priv fn _mint(self,
                  id:          u32,
                  const name:  string,
                  fpt:         unsafe *const clang::FunctionProtoType,
                  rt:          unsafe *Type,
                  @inout ptys: cxx::std::vector<unsafe *Type>,
                  ti:          *TypeImport,
                  mask:        u32,
                  noreturn:    bool,
                  nothrow:     bool) -> unsafe *FunctionDecl {
        var it = self._name_tok.find(id)
        if it == self._name_tok.end() {
            return &null
        }

        var        tok  = it->second
        var        at   = tok.range
        var unsafe *dc  = unsafe (self._tu as unsafe *DeclContext)
        var unsafe *ctx = self._ctx

        // Parented, never added: no table binds a builtin, and nothing walks
        // this TU's decls.
        var unsafe *fd = FunctionDecl::create(ctx, at, tok, dc)
        fd->lexical_dc  = dc
        fd->semantic_dc = dc // NameLookup::ctx_of finds the names through it.
        fd->set_visibility(VisibilityKind::Public, at)

        var params = cxx::std::vector<unsafe *ParamDecl>()
        for var i: usize = 0; i < ptys.size(); ++i {
            var pt = self._arg_tok[i]
            var unsafe *kp = ParamDecl::create(
                ctx,
                pt.range,
                pt,
                ptys[i],
                i as u32,
                true,
            )

            kp->has_default   = false
            kp->cxx_int_alias = ti->is_int_alias(fpt->getParamType(i as u32))
            kp->cxx_alias_ptr = ti->is_alias_indirect(
                fpt->getParamType(i as u32),
            )

            fd->cxx_param_spellings.push_back(
                ti->spelling(fpt->getParamType(i as u32)),
            )

            params.push_back(kp)
        }

        fd->params.from_vec(unsafe &params, ctx)
        fd->is_variadic         = false
        fd->ffi_c_variadic      = fpt->isVariadic()
        fd->return_type         = rt // null: void.
        fd->cxx_return_spelling = ti->spelling(fpt->getReturnType())
        fd->is_noreturn         = noreturn // `__builtin_trap()` types as `!`.
        fd->ffi_noexcept        = nothrow
        fd->body_kind           = FnBodyKind::None
        fd->modifiers           = FnModifier::None
        fd->ffi_builtin_id      = id
        fd->ffi_ice_mask        = mask // X checks these positions.
        // Spelled bare: emitted C++ calls it exactly as written, and clang's
        // own BeginSourceFile in phase B gives it the same meaning.
        decl_set_imported(fd, &null, f"c:@F@{name}", name, &null, self._fid)
        return fd
    }

    priv static fn _missing(e: clang::ASTContext::GetBuiltinTypeError) -> string {
        if e == clang::ASTContext::GE_Missing_stdio {
            return "'FILE' (<stdio.h>)"
        }

        if e == clang::ASTContext::GE_Missing_setjmp {
            return "'jmp_buf' (<setjmp.h>)"
        }

        if e == clang::ASTContext::GE_Missing_ucontext {
            return "'ucontext_t' (<ucontext.h>)"
        }

        return "a type"
    }

    /// # the type string

    /// One entry per type in a builtin's type string, the return type first:
    /// 1 for a plain size_t (`z`), 2 for a plain ptrdiff_t (`Y`) or signed
    /// size_t (`Sz`), 0 for anything else. A pointer or reference to one is 0:
    /// its pointee is canonical by the time TypeImport maps it either way.
    ///
    /// Grammar (Builtins.td's encoding): prefix modifiers [ILNOSUWZ]*, a base
    /// char, then suffixes `*`[addrspace], `&`, `C`, `D`, `R`. `V`/`E`/`q` take
    /// a count and an element type, `X` an element type, `Q` one more char.
    /// A trailing `.` is C variadic, not a type.
    static fn sized_slots(const ts: string) -> cxx::std::vector<u8> {
        var out       = cxx::std::vector<u8>()
        var i:  usize = 0
        var n         = ts.size()
        while i < n {
            if ts[i] == ('.' as u8) {
                break
            }

            var sgn   = false
            var base  = BuiltinImport::_skip_type(ts, unsafe &i, unsafe &sgn)
            var plain = true
            while i < n {
                var c = ts[i]
                if c == ('*' as u8) {
                    plain = false
                    i += 1
                    while i < n && ts[i] >= ('0' as u8) && ts[i] <= ('9' as u8) {
                        i += 1
                    }

                    continue
                }

                if c == ('&' as u8) {
                    plain = false
                    i += 1
                    continue
                }

                if c == ('C' as u8) || c == ('D' as u8) || c == ('R' as u8) {
                    i += 1
                    continue
                }

                break
            }

            var k: u8 = 0
            if plain && base == ('z' as u8) {
                k = if (sgn) => (2) else => 1
            }

            if plain && base == ('Y' as u8) {
                k = 2
            }

            out.push_back(k)
        }

        return out
    }

    /// Consume one type's prefixes and base at \p i; return the base char.
    priv static fn _skip_type(const ts: string, i: unsafe *usize, sgn: unsafe *bool) -> u8 {
        var n = ts.size()
        while *i < n {
            var c = ts[*i]
            if c == ('S' as u8) {
                *sgn = true
                *i += 1
                continue
            }

            if c == ('I' as u8)
                || c == ('L' as u8)
                || c == ('N' as u8)
                || c == ('O' as u8)
                || c == ('U' as u8)
                || c == ('W' as u8)
                || c == ('Z' as u8) {
                *i += 1
                continue
            }

            break
        }

        if *i >= n {
            return ' ' as u8
        }

        var b = ts[*i]
        *i += 1
        if b == ('V' as u8) || b == ('E' as u8) || b == ('q' as u8) {
            while *i < n && ts[*i] >= ('0' as u8) && ts[*i] <= ('9' as u8) {
                *i += 1
            }

            var ignore = false
            BuiltinImport::_skip_type(ts, i, unsafe &ignore)
            return b
        }

        if b == ('X' as u8) {
            var ignore = false
            BuiltinImport::_skip_type(ts, i, unsafe &ignore)
            return b
        }

        if b == ('Q' as u8) {
            if *i < n {
                *i += 1
            }
        }

        return b
    }
}
