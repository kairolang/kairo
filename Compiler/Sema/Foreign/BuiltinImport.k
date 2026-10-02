/// --- The Kairo Project ------------------ Sema/Foreign/BuiltinImport.k --- ///
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
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh";
ffi "c++" import "clang/AST/ASTContext.h";
ffi "c++" import "clang/AST/Type.h";
ffi "c++" import "clang/Basic/Builtins.h";

import AST::Context::ASTContext::*;
import AST::Context::CanonicalTypes::*;
import AST::Context::DeclContext::*;
import AST::Context::GlobalDisambigTable::*;
import AST::Context::InstantiationRegistry::*;
import AST::Context::SymbolTable::*;
import AST::Context::TranslationUnit::*;
import AST::ASTSupport::*;
import AST::DeclFacts::*;
import AST::Node::Base::*;
import AST::Node::Declarations::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import Location::SourceManager::*;
import Support::FileIO::Path::*;
import Location::SourceRange::*;
import Support::TimeReport::*;
import Token::Token::*;
import Token::TokenKind::*;
import Sema::Foreign::ForeignRegistry::*;
import Sema::Foreign::TypeImport::*;
import Sema::Foreign::DeclImport::*;
import Sema::Foreign::HeaderIndex::*;
import Interop::Clang::BuiltinsSet::*;

/// Parameter name tokens minted at init. No builtin comes near it; one that
/// did would be reported, not truncated.
eval fn BUILTIN_MAX_PARAMS() -> usize { return 32; }

/// One resolve() answer:
///   miss        decl null, why empty: not a builtin, or a library one.
///   unusable    decl null, why set:   a builtin Kairo cannot call; `why` is
///                                     the whole diagnostic text.
///   bound       decl set.
struct BuiltinEntry {
    var decl: *FunctionDecl = &null;
    var why:  string = "";
}

class BuiltinImport {
    priv var _oracle:    obs::<BuiltinsSet>;
    priv var _ksm:       obs::<SourceManager>;
    priv var _store:     obs::<CanonicalTypeStore>;
    priv var _instances: obs::<InstantiationRegistry>;
    priv var _reg:       obs::<ForeignRegistry>;
    priv var _ctx:       obs::<ASTContext>;
    priv var _tu:        obs::<TranslationUnit>;
    priv var _fid:       u32 = 0;
    /// The pseudo-header's bytes. load_virtual BORROWS them for the fid's
    /// lifetime, so they live here, set once, never reassigned.
    priv var _text:      libcxx::string;

    priv var _name_tok:  libcxx::unordered_map::<u32, Token>;   ///< builtin ID -> its line's token.
    priv var _arg_tok:   vec::<Token>;                          ///< `__arg0` .. `__arg{MAX-1}`.
    priv var _done:      libcxx::unordered_map::<u32, BuiltinEntry>;
    priv var _mu:        std::SharedMutex;
    priv var _ready:     bool = false;

    fn BuiltinImport(self) { }

    static fn path() -> string { return "<kairo-clang-builtins>"; }

    fn ready(self) -> bool { return self._ready; }

    /// The scope a builtin decl answers from, for the resolution trace.
    fn scope(self) -> *DeclContext { return static_cast::<*DeclContext>(self._tu); }

    // === init (driver thread) ===============================================

    /// Write the pseudo-header, mint its TU, mint every token. False leaves
    /// this unready, and resolve() then misses on everything.
    fn init(self, oracle: *BuiltinsSet, ksm: *SourceManager, hidx: *HeaderIndex,
            g: *GlobalDisambigTable, reg: *ForeignRegistry) -> bool {
        if self._ready { return true; }
        if (oracle == &null) || (!oracle->ready()) { return false; }
        var _t = TimeRegion("BuiltinImport");

        // ASCII only, so a code-point offset IS a byte offset.
        var n = oracle->count();
        var text = string("");
        var offs = vec::<usize>();
        for var i: usize = 0; i < n; ++i {
            offs.push_back(text.size());
            text += oracle->name_at(i);
            text += "\n";
        }
        var arg_offs = vec::<usize>();
        for var i: usize = 0; i < BUILTIN_MAX_PARAMS(); ++i {
            arg_offs.push_back(text.size());
            text += f"__arg{i}\n";
        }

        // Loaded at most once: a retry after a later failure must not
        // reassign _text under a fid that still points into it.
        if self._fid == 0 {
            self._text = libcxx::string(std::string_to_nstring(text));
            self._fid = ksm->load_virtual(Path(BuiltinImport::path()),
                reinterpret_cast::<std::ConstPtr::<u8>>(self._text.data()), self._text.size());
            if self._fid == u32(-1) { self._fid = 0; return false; }
        }
        var fid = self._fid;
        var t = hidx->ensure_target(fid, BuiltinImport::path());
        if t == &null { return false; }
        // Nothing binds into this TU's table: resolve() is the only way in.
        // It still gets a frozen, empty one, so a probe sees a scope, not a hole.
        if t->tu->dc_symbols == &null {
            var tbl = t->ctx->alloc_init_cleanup::<SymbolTable>();
            tbl->freeze();
            t->tu->set_symbols(tbl);
        }
        t->frozen = true;

        self._oracle = oracle; self._ksm = ksm; self._reg = reg;
        self._store = g->types(); self._instances = g->instances();
        self._ctx = t->ctx; self._tu = t->tu; self._fid = fid;

        self._name_tok.reserve(n);
        for var i: usize = 0; i < n; ++i {
            var nm = oracle->name_at(i);
            var at = ksm->get_range(fid, offs[i], nm.size());
            self._name_tok.insert(libcxx::make_pair(oracle->id_at(i),
                t->ctx->make_token(at, TokenKind::LitIdentifier, nm)));
        }
        for var i: usize = 0; i < BUILTIN_MAX_PARAMS(); ++i {
            var nm = f"__arg{i}";
            var at = ksm->get_range(fid, arg_offs[i], nm.size());
            self._arg_tok.push_back(t->ctx->make_token(at, TokenKind::LitIdentifier, nm));
        }

        self._ready = true;
        return true;
    }

    // === resolve (any thread) ===============================================

    fn resolve(self, name: string) -> BuiltinEntry {
        var out = BuiltinEntry{};
        if !self._ready { return out; }
        var id = self._oracle->id_of(name);
        if id == 0 { return out; }
        if self._cached(id, &out) { return out; }

        var lock = std::LockGuard(self._mu);
        var it = self._done.find(id);
        if it != self._done.end() { return it->second; }      // lost the race to another TU.
        var e = self._import(id, name);
        self._done.insert(libcxx::make_pair(id, e));
        return e;
    }

    priv fn _cached(self, id: u32, out: *BuiltinEntry) -> bool {
        var rlock = std::SharedLock(self._mu);
        var it = self._done.find(id);
        if it == self._done.end() { return false; }
        (*out) = it->second;
        return true;
    }

    /// Under the exclusive lock.
    priv fn _import(self, id: u32, name: string) -> BuiltinEntry {
        var out = BuiltinEntry{};
        var bi  = self._oracle->builtins();

        // Clang's own C++ gate (Sema::LookupBuiltin): a predefined library
        // function (`f`: memcpy, printf) is never implicitly declared in C++;
        // its header declares it, so it misses here too. NOT isLibFunction:
        // that is `F`, the `__builtin_`-prefixed variant, which C++ always has.
        if bi->isPredefinedLibFunction(id) || bi->isHeaderDependentFunction(id) { return out; }
        if bi->hasCustomTypechecking(id) {
            out.why = f"'{name}' is type-checked by clang per call; Kairo cannot call it yet";
            return out;
        }

        var cctx = self._oracle->ast();
        var err  = clang::ASTContext::GE_None;
        var mask: u32 = 0;
        var qt   = cctx->GetBuiltinType(id, err, &mask);
        if err != clang::ASTContext::GE_None {
            out.why = f"'{name}' is declared in terms of {BuiltinImport::_missing(err)}, which only a header provides";
            return out;
        }
        var fpt: const_obs::<clang::FunctionProtoType> = &null;
        if !qt.isNull() { fpt = qt->getAs::<clang::FunctionProtoType>(); }
        if fpt == &null {
            out.why = f"clang gives '{name}' no prototype";
            return out;
        }
        var np = static_cast::<usize>(fpt->getNumParams());
        if np > BUILTIN_MAX_PARAMS() {
            out.why = f"'{name}' takes {np} parameters; Kairo imports builtins of at most {BUILTIN_MAX_PARAMS()}";
            return out;
        }

        var ti = TypeImport(self._store, self._instances, self._reg, cctx, self._ctx, self._fid);
        var ts = llvm::StringRef(bi->getTypeString(id));                // VERIFY(22.x)
        var slots = BuiltinImport::sized_slots(string(ts.data(), ts.size()));
        // The decoder and clang disagree on the shape: trust the canonical
        // types over a guess at which slot is which.
        if slots.size() != (np + 1) { slots.clear(); }

        var rt: *Type = &null;
        var rq = fpt->getReturnType();
        if !rq->isVoidType() {
            rt = self._slot_type(&ti, rq, slots, 0);
            if rt == &null {
                out.why = f"'{name}' returns '{ti.spelling(rq)}', which Kairo cannot express";
                return out;
            }
        }
        var ptys = vec::<*Type>();
        for var i: usize = 0; i < np; ++i {
            var pq = fpt->getParamType(static_cast::<u32>(i));
            var pt = self._slot_type(&ti, pq, slots, i + 1);
            if pt == &null {
                out.why = f"parameter {i + 1} of '{name}' has type '{ti.spelling(pq)}', which Kairo cannot express";
                return out;
            }
            ptys.push_back(pt);
        }

        out.decl = self._mint(id, name, fpt, rt, ptys, &ti, mask, bi->isNoReturn(id), bi->isNoThrow(id));
        if out.decl == &null { out.why = f"internal: no token was minted for builtin '{name}\x27"; }
        return out;
    }

    priv fn _slot_type(self, ti: *TypeImport, qt: clang::QualType, slots: ref!(vec::<u8>), i: usize) -> *Type {
        if i < slots.size() {
            if slots[i] == 1 { return self._store->builtin(BuiltinKind::USize); }
            if slots[i] == 2 { return self._store->builtin(BuiltinKind::ISize); }
        }
        return ti->try_import(qt);
    }

    priv fn _mint(self, id: u32, name: string, fpt: const_obs::<clang::FunctionProtoType>,
                  rt: *Type, ptys: ref!(vec::<*Type>), ti: *TypeImport, mask: u32,
                  noreturn: bool, nothrow: bool) -> *FunctionDecl {
        var it = self._name_tok.find(id);
        if it == self._name_tok.end() { return &null; }
        var tok = it->second;
        var at  = tok.range;
        var dc  = static_cast::<*DeclContext>(self._tu);
        var ctx = self._ctx;

        // Parented, never added: no table binds a builtin, and nothing walks
        // this TU's decls.
        var fd = FunctionDecl::create(ctx, at, tok, dc);
        fd->lexical_dc  = reinterpret_cast::<*void>(dc);
        fd->semantic_dc = reinterpret_cast::<*void>(dc);      // NameLookup::ctx_of finds the names through it.
        fd->set_visibility(VisibilityKind::Public, at);

        var params = vec::<*ParamDecl>();
        for var i: usize = 0; i < ptys.size(); ++i {
            var pt = self._arg_tok[i];
            var kp = ParamDecl::create(ctx, pt.range, pt, ptys[i], static_cast::<u32>(i), true);
            kp->has_default = false;
            fd->cxx_param_spellings.push_back(ti->spelling(fpt->getParamType(static_cast::<u32>(i))));
            params.push_back(kp);
        }
        fd->params.from_vec(&params, ctx);
        fd->is_variadic         = false;
        fd->ffi_c_variadic      = fpt->isVariadic();
        fd->return_type         = rt;                          // null: void.
        fd->cxx_return_spelling = ti->spelling(fpt->getReturnType());
        fd->is_noreturn         = noreturn;                    // `__builtin_trap()` types as `!`.
        fd->ffi_noexcept        = nothrow;
        fd->body_kind           = FnBodyKind::None;
        fd->modifiers           = FnModifier::None;
        fd->ffi_builtin_id      = id;
        fd->ffi_ice_mask        = mask;                        // X checks these positions.
        // Spelled bare: emitted C++ calls it exactly as written, and clang's
        // own BeginSourceFile in phase B gives it the same meaning.
        decl_set_imported(static_cast::<*Decl>(fd), &null, f"c:@F@{name}", name, &null, self._fid);
        return fd;
    }

    priv static fn _missing(e: clang::ASTContext::GetBuiltinTypeError) -> string {
        if e == clang::ASTContext::GE_Missing_stdio    { return "'FILE' (<stdio.h>)"; }
        if e == clang::ASTContext::GE_Missing_setjmp   { return "'jmp_buf' (<setjmp.h>)"; }
        if e == clang::ASTContext::GE_Missing_ucontext { return "'ucontext_t' (<ucontext.h>)"; }
        return "a type";
    }

    // === the type string ====================================================

    /// One entry per type in a builtin's type string, the return type first:
    /// 1 for a plain size_t (`z`), 2 for a plain ptrdiff_t (`Y`) or signed
    /// size_t (`Sz`), 0 for anything else. A pointer or reference to one is 0:
    /// its pointee is canonical by the time TypeImport maps it either way.
    ///
    /// Grammar (Builtins.td's encoding): prefix modifiers [ILNOSUWZ]*, a base
    /// char, then suffixes `*`[addrspace], `&`, `C`, `D`, `R`. `V`/`E`/`q` take
    /// a count and an element type, `X` an element type, `Q` one more char.
    /// A trailing `.` is C variadic, not a type.
    static fn sized_slots(ts: string) -> vec::<u8> {
        var out = vec::<u8>();
        var i: usize = 0;
        var n = ts.size();
        while i < n {
            if ts[i] == '.' { break; }
            var sgn = false;
            var base = BuiltinImport::_skip_type(ts, &i, &sgn);
            var plain = true;
            while i < n {
                var c = ts[i];
                if c == '*' {
                    plain = false;
                    i += 1;
                    while (i < n) && (ts[i] >= '0') && (ts[i] <= '9') { i += 1; }
                    continue;
                }
                if c == '&' { plain = false; i += 1; continue; }
                if (c == 'C') || (c == 'D') || (c == 'R') { i += 1; continue; }
                break;
            }
            var k: u8 = 0;
            if plain && (base == 'z') { k = (2) if (sgn) else (1); }
            if plain && (base == 'Y') { k = 2; }
            out.push_back(k);
        }
        return out;
    }

    /// Consume one type's prefixes and base at \p i; return the base char.
    priv static fn _skip_type(ts: string, i: *usize, sgn: *bool) -> char {
        var n = ts.size();
        while (*i) < n {
            var c = ts[*i];
            if c == 'S' { (*sgn) = true; (*i) += 1; continue; }
            if (c == 'I') || (c == 'L') || (c == 'N') || (c == 'O') || (c == 'U') || (c == 'W') || (c == 'Z') {
                (*i) += 1;
                continue;
            }
            break;
        }
        if (*i) >= n { return ' '; }
        var b = ts[*i];
        (*i) += 1;
        if (b == 'V') || (b == 'E') || (b == 'q') {
            while ((*i) < n) && (ts[*i] >= '0') && (ts[*i] <= '9') { (*i) += 1; }
            var ignore = false;
            BuiltinImport::_skip_type(ts, i, &ignore);
            return b;
        }
        if b == 'X' {
            var ignore = false;
            BuiltinImport::_skip_type(ts, i, &ignore);
            return b;
        }
        if b == 'Q' { if (*i) < n { (*i) += 1; } }
        return b;
    }
}