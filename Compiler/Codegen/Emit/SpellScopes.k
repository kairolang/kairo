/// --- The Kairo Project ------------------- Codegen/Emit/SpellScopes.k --- ///
///
///   Speller, part: names and namespaces. A declaration's leaf name and its
///   fully qualified one, the namespace path of its module and file, the entry
///   TU's top-level namespace, anonymous and function-local scopes, hoisted
///   locals, and extension scope names.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import AST::Context::DeclContext::{
    DeclContext,
    DeclContextKind,
}
import AST::Context::TranslationUnit::TranslationUnit
import AST::DeclFacts
import AST::ForeignReservedWords::is_cxx_keyword
import AST::LangItems::{
    LowerTargets,
    builtin_root_name,
    entry_point_name,
    std_root_spelling,
}
import AST::Node::Base::Decl
import AST::Node::CanonicalNodes::{
    BuiltinType,
    RecordType,
    builtin_info,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations
import AST::Node::Types::{
    FixedArrayType,
    NullableType,
}
import Codegen::CodegenContext::CodegenContext
import Codegen::Emit::Spell::{
    Speller,
    VIS_INTERNAL,
    VIS_PRIV,
    _NS_TOPS,
    is_entry_point_name,
}
import Codegen::Emit::SpellFacts
import Codegen::Emit::SpellOperators
import Codegen::Emit::SpellRecords
import Codegen::Emit::SpellTypes
import Support::Ascii::is_ident_char

extend Speller {
    pub fn leaf(self, d: unsafe *Decl) -> string {
        var unsafe *f = dyn_cast<Declarations::FunctionDecl>(d)
        if f != &null && f->is_operator {
            return self.operator_name(f)
        }

        var t = DeclFacts::decl_name_tok(d)
        // The table the name was interned in is chosen BEFORE it is read: an
        // index read through the wrong table is not merely the wrong name but
        // can lie past that table's end (Stage 1.5 SIGSEGV'd building
        // itself on `__fwd/memory.h`'s table, 31 names, asked for #44).
        var nfid = Speller::fid_of(d)
        // An imported enumerator's name was interned in the table of the
        // file its range lies in (DeclImport::_tok), which is not the TU of
        // the scope it lives in when a class and its nested enum sit in
        // different headers of one fill: reading the scope's table gave a
        // different identifier at that index (`Triple::UnknownVendor` came
        // out as `VendorType::mips64`). The range names the right table.
        if isa<Declarations::EnumVariantDecl>(d)
            && self._cg->ctx->sm != &null
            && t.range.is_valid() {
            nfid = self._cg->ctx->sm->get_fid(t.range)
        } else if DeclFacts::decl_is_imported(d)
            && self._cg->ctx->sm != &null
            && self._cg->ctx->tcm != &null
            && t.range.is_valid() {
            // Any imported member, for the same reason: a class template
            // forward-declared in one header and defined in another (libc++'s
            // `<__fwd/string.h>` and `<string>`) has its members' names in
            // the defining header's table, so `basic_string<char>::npos` read
            // from the scope's came out as `cend`. A range in a file
            // with no table of its own was interned in the scope's, as
            // DeclImport::_tok falls back.
            var rf = self._cg->ctx->sm->get_fid(t.range)
            if self._cg->ctx->tcm->get_imm_table_for_fid(rf) != &null {
                nfid = rf
            }
        }

        var nm = self.tok_name(t, nfid)
        // An ADT's layout record IS the enum to C++, and takes its name.
        var unsafe *lay   = dyn_cast<Declarations::StructDecl>(d)
        var unsafe *named = d
        if lay != &null && lay->adt_of != &null {
            named = lay->adt_of
        }

        if Speller::is_hoisted_local(named) {
            return self._local_leaf(named, nm)
        }

        // A member specialization is named apart from every other member of
        // its scope struct, from the position of its own name: the same in
        // every TU, and unique in its file.
        if f != &null && f->member_spec_of != &null && self._cg->ctx->sm != &null {
            var at = DeclFacts::decl_name_tok(d).range.start
            if at.is_valid() {
                var lc = self._cg->ctx->sm->get_line_col(at)
                return LowerTargets::member_spec(
                    nm,
                    lc.line as u32,
                    lc.column as u32,
                )
            }
        }

        return nm
    }

    /// A hoisted local's namespace-scope name (LowerTargets::local_decl),
    /// from the position of its own name: the same in every TU, since it is
    /// a fact about the source alone.
    priv fn _local_leaf(self, d: unsafe *Decl, const nm: string) -> string {
        var unsafe *r  = Speller::rep(d)
        var        at  = DeclFacts::decl_name_tok(r).range.start
        var unsafe *sm = self._cg->ctx->sm
        if sm == &null || !at.is_valid() {
            self._ice(
                r->range,
                "CXXSpell: a local declaration with no source position to name it by",
            )
        }

        var lc = sm->get_line_col(at)
        return LowerTargets::local_decl(nm, lc.line as u32, (lc.column as u32))
    }

    /// The module path of a TU as strings: root name + directories + file.
    pub fn module_segments(self, tu: unsafe *TranslationUnit) -> cxx::std::vector<string> {
        var out = cxx::std::vector<string>()
        if tu == &null || tu->ctx == &null {
            return out
        }

        if self._cg->psym == &null {
            kairo::std::ice_fail(
                "CXXSpell: no PreprocessorSymbolTable on the CodegenContext",
            )
        }

        // Resolve the SymbolID directly: module_base segments are
        // synthesized and carry no token, so as_string() falls back to a
        // debug rendering that is not a C++ identifier.
        var *mb = &tu->ctx->module_base
        for var i: usize = 0; i < mb->segments.size(); ++i {
            var unsafe *p = self._cg->psym->resolve(mb->segments[i].name)
            if p == &null {
                kairo::std::ice_fail(
                    "CXXSpell: module_base segment is not in the PP symbol table",
                )
            }

            // A segment is a FILE or directory name, not a Kairo identifier:
            // every input is a module, and `operator.k` or
            // `01_basic.k` in the cwd is module `operator` / `01_basic`.
            out.push_back(Speller::cxx_segment(*p))
        }

        return out
    }

    /// `tu` has no module path: a file outside every search dir (or one
    /// whose path a named library owns, ImportResolver::input_module_path),
    /// the driver's virtual library entry, or a tool's bare parse. Not
    /// "a command-line input": an input takes the module path an import
    /// gives it, and only these keep the pathless rules
    /// below (stem namespace, priv decls in the unnamed namespace, no header).
    pub static fn is_entry_tu(tu: unsafe *TranslationUnit) -> bool {
        if tu == &null || tu->ctx == &null {
            return true
        }

        return tu->ctx->module_base.segments.size() == 0
    }

    /// `d` is the program's `main`: a free function named `main` at file
    /// scope, in ANY TU. Emitted as the global `int main`, never in a
    /// namespace and never in a header. A `main` is the program's wherever its
    /// file sits, because every input is a module. One in a `module foo
    /// { }` block is `foo::main`, an ordinary function.
    fn is_main(self, d: unsafe *Decl) -> bool {
        if d == &null || !isa<Declarations::FunctionDecl>(d) {
            return false
        }

        if cast<Declarations::FunctionDecl>(d)->is_method() {
            return false
        }

        var unsafe *dc = d->semantic_dc
        if dc == &null || !dc->is_translation_unit() {
            return false
        }

        return self.leaf(d) == entry_point_name()
    }

    /// `s` as one C++ identifier: anything else becomes `_`, a leading
    /// digit gets a `_` before it, and a C++ keyword one after it
    /// (`operator` -> `operator_`; a trailing `_` cannot collide with another
    /// keyword). For names that come from FILES -- module path segments and
    /// a pathless TU's stem -- which reach the ABI only through here
    /// (invariant 9a).
    static fn cxx_segment(const s: string) -> string {
        var out = ""
        for var i: usize = 0; i < s.size(); ++i {
            var c  = s.data()[i]
            var ok = is_ident_char(c)
            if ok {
                out.push(c)
            } else {
                out += "_"
            }
        }

        if out.size() == 0 {
            return "_"
        }

        if out[0] >= ('0' as u8) && out[0] <= ('9' as u8) {
            return "_" + out
        }

        if is_cxx_keyword(out) {
            return out + "_"
        }

        return out
    }

    /// `tu`'s first namespace segment as the module path spells it, before
    /// any rename: the module root, or a pathless TU's stem.
    pub fn top_segment(self, tu: unsafe *TranslationUnit) -> string {
        var segs = self.module_segments(tu)
        if segs.size() > 0 {
            return segs[0].copy()
        }

        return Speller::entry_stem(tu)
    }

    /// The Kairo top segment a C++ one was renamed from (identity if none).
    static fn kairo_top_of(const c: string) -> string {
        return _NS_TOPS.kairo_of(c)
    }

    /// Decides the C++ spelling of every top segment in `tops` (one
    /// build's modules) that is not decided yet, and records it (NsTops).
    /// `header_global` answers whether a header of the build declares
    /// `::name` as anything but a namespace. A segment keeps its spelling
    /// unless taken; a taken one gets `_` appended until it is free. Taken:
    /// an entry-point name, `header_global`, another module's own top
    /// segment in `tops`, or another segment's recorded rename. The roots
    /// the toolchain's prebuilt objects live under (builtin, std, kairo) are
    /// never renamed: --kairo-lib builds those once for every later link.
    /// Sorted first, so the answer depends on the set of names, not on the
    /// order the graph listed them.
    pub static fn decide_tops(@inout tops:   cxx::std::vector<string>,
                              header_global: fn(string) -> bool) {
        // Insertion sort: a build has a handful of roots.
        for var i: usize = 1; i < tops.size(); ++i {
            var j = i
            while j > 0 && tops[j] < tops[j - 1] {
                var tmp = tops[j].copy()
                tops[j]     = tops[j - 1].copy()
                tops[j - 1] = tmp.copy()
                j -= 1
            }
        }

        for var i: usize = 0; i < tops.size(); ++i {
            var t = tops[i].copy()
            if i > 0 && tops[i - 1] == t {
                continue
            }

            if t == builtin_root_name() || t == std_root_spelling() || t == "kairo" {
                continue
            }

            if _NS_TOPS.decided(t) {
                continue
            }

            var c = t.copy()
            while true {
                var taken = is_entry_point_name(c) || header_global(c.copy())
                if !taken && c != t {
                    for var j: usize = 0; j < tops.size(); ++j {
                        if tops[j] == c {
                            taken = true
                            break
                        }
                    }

                    if !taken && _NS_TOPS.is_target(c) {
                        taken = true
                    }
                }

                if !taken {
                    break
                }

                c += "_"
            }

            _NS_TOPS.record(t, c)
        }
    }

    /// A pathless TU's namespace: its FILE STEM, sanitized to a C++
    /// identifier. Before this its decls landed in one unnamed namespace and
    /// two such TUs in a build could not both define `helper`. The stem is a
    /// name the source already has.
    static fn entry_stem(tu: unsafe *TranslationUnit) -> string {
        if tu == &null || tu->ctx == &null || tu->ctx->sm == &null {
            return "_"
        }

        var path = tu->ctx->sm->get_filename(tu->fid)
        // basename, then drop the extension.
        var start: usize = 0
        for var i: usize = 0; i < path.size(); ++i {
            if path[i] == ('/' as u8) || path[i] == ('\\' as u8) {
                start = i + 1
            }
        }

        var end = path.size()
        for var i: usize = start; i < path.size(); ++i {
            if path[i] == ('.' as u8) {
                end = i
                break
            }
        }

        return Speller::cxx_segment(
            string(
                unsafe (((path.data() as unsafe *const u8) + start) as *const u8),
                end - start,
            ),
        )
    }

    /// A decl with no linkage outside its own file: `priv` or `internal` in
    /// the entry TU. It goes in an unnamed namespace NESTED in the file's,
    /// so `::<stem>::helper` still names it -- C++'s implicit using-directive
    /// reaches into the unnamed one -- and qual_name is unchanged.
    ///
    /// Not when an inline or template body of the file names it
    /// (TranslationUnit::cxx_escaping): that body is compiled in every C++
    /// TU that includes the file, and calls it by external linkage.
    ///
    /// Never a function or a record: a record befriends its file's functions
    /// and records (EmitPlan::file_friends), and a friend declaration cannot
    /// reach into an unnamed namespace -- an unqualified one declares a NEW
    /// `stem::f`, a qualified one matches nothing. So those keep the stem
    /// namespace and external linkage; nothing imports a pathless file, and
    /// two of them share a namespace only when their stems do, where their
    /// `pub` decls already collide.
    static fn is_anon(d: unsafe *Decl) -> bool {
        if d == &null {
            return false
        }

        if isa<Declarations::FunctionDecl>(d)
            || isa<Declarations::ClassDecl>(d)
            || isa<Declarations::StructDecl>(d)
            || isa<Declarations::UnionDecl>(d) {
            return false
        }

        var unsafe *tu = Speller::tu_of(d)
        if !Speller::is_entry_tu(tu) {
            return false
        }

        var v = Speller::vis_of(d)
        if v != VIS_PRIV() && v != VIS_INTERNAL() {
            return false
        }

        if tu != &null {
            var unsafe *r = Speller::rep(d)
            for var i: usize = 0; i < tu->cxx_escaping.size(); ++i {
                if tu->cxx_escaping[i] == d || tu->cxx_escaping[i] == r {
                    return false
                }
            }
        }

        return true
    }

    /// `d` is declared inside a function body: its semantic scope, or one
    /// enclosing it, is a function, block or lambda (FinallyLowering's guard
    /// record, its members and its local). Such a decl has no namespace: it
    /// is named by leaf, emitted inside the body, and never planned.
    ///
    /// A HOISTED local (is_hoisted_local) is the exception, and so is
    /// everything declared in one: it is emitted at namespace scope, so
    /// the walk stops at it as at a namespace. A local of one of its
    /// functions still meets that function's scope first.
    static fn in_function_scope(d: unsafe *Decl) -> bool {
        if d == &null {
            return false
        }

        if Speller::is_hoisted_local(d) {
            return false
        }

        var unsafe *dc = d->semantic_dc
        while dc != &null {
            if dc->is_function()
                || dc->dc_kind == DeclContextKind::Block
                || dc->dc_kind == DeclContextKind::Lambda {
                return true
            }

            if dc->is_translation_unit()
                || dc->dc_kind == DeclContextKind::Module
                || dc->dc_kind == DeclContextKind::Extension {
                return false
            }

            if dc->is_type_scope()
                && dc->dc_owner != &null
                && Speller::is_hoisted_local(dc->dc_owner) {
                return false
            }

            dc = dc->dc_parent
        }

        return false
    }

    /// `d` is a `fn`, class, struct, union or enum the user wrote in a
    /// function body. C++ has no local functions, and a local class can have
    /// no member template, no static data member and no out-of-line member,
    /// so each is emitted at NAMESPACE scope instead -- the scope of the
    /// function it is written in -- under a name that carries its position
    /// (LowerTargets::local_decl), and planned and emitted as any other own
    /// declaration (Compiler/Spec/Codegen.md#emitir, Local declarations). It cannot reach the
    /// function's locals (ClosureCaptures rejects that), so nothing it needs
    /// is lost by the move. A lowering's record (FinallyLowering's guard) is
    /// implicit and stays in the body.
    static fn is_hoisted_local(d: unsafe *Decl) -> bool {
        if d == &null || d->is_implicit {
            return false
        }

        if (!isa<Declarations::FunctionDecl>(d))
            && (!isa<Declarations::ClassDecl>(d))
            && (!isa<Declarations::StructDecl>(d))
            && (!isa<Declarations::UnionDecl>(d))
            && !isa<Declarations::EnumDecl>(d) {
            return false
        }

        var unsafe *dc = d->semantic_dc
        if dc == &null {
            return false
        }

        return dc->is_function()
            || dc->dc_kind == DeclContextKind::Block
            || dc->dc_kind == DeclContextKind::Lambda
    }

    /// The scope a decl's NAMESPACE is read from: for an extension member
    /// the extension's parent (its scope struct lives in the enclosing
    /// module; owner_types supplies the struct), otherwise the decl's
    /// semantic scope.
    prot fn _home_dc(self, d: unsafe *Decl) -> unsafe *DeclContext {
        // A function specialization is declared in its primary's namespace
        // ([temp.expl.spec]), which is another module's when it was written
        // away from the primary.
        if Speller::is_fn_spec(d) {
            var unsafe *prim = Speller::rep(
                DeclFacts::decl_instantiated_from(d),
            )

            if prim != &null && prim->semantic_dc != &null {
                return prim->semantic_dc
            }
        }

        var unsafe *lex = d->lexical_dc
        if lex != &null && lex->dc_kind == DeclContextKind::Extension {
            return lex->dc_parent
        }

        return d->semantic_dc
    }

    /// Namespace segments (modules only) enclosing `d`, outermost first.
    pub fn ns_segments(self, d: unsafe *Decl) -> cxx::std::vector<string> {
        return self._ns_from(self._home_dc(d))
    }

    /// The namespace N of `x`'s scope struct: the scope its members are
    /// qualified from (_home_dc), read off the extension itself, so a scope
    /// has a namespace even before a member is picked.
    fn scope_ns(self, x: unsafe *Declarations::ExtensionDecl) -> cxx::std::vector<string> {
        var unsafe *dc = Speller::dc_of(unsafe (x as unsafe *Decl))
        return self._ns_from(if (dc != &null) => (dc->dc_parent) else => &null)
    }

    priv fn _ns_from(self, home: unsafe *DeclContext) -> cxx::std::vector<string> {
        var        mods = cxx::std::vector<string>()
        var unsafe *dc  = home
        while dc != &null {
            if dc->dc_kind == DeclContextKind::TranslationUnit {
                break
            }

            if dc->dc_kind == DeclContextKind::Module {
                var unsafe *m = cast<Declarations::ModuleDecl>(dc->dc_owner)
                if m != &null && !m->is_anonymous {
                    mods.push_back(self.tok_name(m->name, Speller::fid_of(m)))
                }
            }

            dc = dc->dc_parent
        }

        var unsafe *tu = Speller::tu_of_dc(home)
        var        out = self.module_segments(tu)
        // An entry TU declares no module, so module_segments gives nothing;
        // its file stem is the namespace instead.
        if out.size() == 0 {
            out.push_back(Speller::entry_stem(tu))
        }

        // Only the first segment is at global scope, so only it can meet a
        // header's `::malloc` or the program's `int main`.
        if !self.kairo_top {
            out[0] = _NS_TOPS.spelling(out[0])
        }

        for var i: usize = 0; i < mods.size(); ++i {
            out.push_back(mods[mods.size() - 1 - i])
        }

        return out
    }

    /// `__kairo_ext_<X>`: the struct whose static members are `x`'s (and
    /// every other extend of X in the same namespace N). X is the target's
    /// leaf when the target is declared in N itself, nested owners joined
    /// with `__` (`__kairo_ext_Outer__Inner`); otherwise its FULL path joined
    /// with `__` (`__kairo_ext_a__Point`), because an `impl` extend in an
    /// interface's file can target two modules' `Point`s, and one struct per
    /// leaf would hold both or be defined twice. A generic record is named
    /// by its primary, a builtin by its Kairo spelling (`__kairo_ext_i32`).
    /// Deterministic, and a function of the source tree alone (invariant 9a).
    ///
    /// A conditional block (ExtensionDecl::gate) is in a scope of its own,
    /// `__kairo_ext_<X>__if__<paths>`: it is defined only in the
    /// translation units that use it, and the unconditional scope of the
    /// same target must be one text in all of them.
    fn ext_scope_name(self, x: unsafe *Declarations::ExtensionDecl) -> string {
        var base = self._ext_scope_base(x)
        if x->gate != &null {
            return base + "__if__" + x->gate->scope
        }

        return base
    }

    priv fn _ext_scope_base(self, x: unsafe *Declarations::ExtensionDecl) -> string {
        if x == &null || x->target == &null || x->target->canonical == &null {
            kairo::std::ice_fail(
                "CXXSpell: extension with an unresolved target reached codegen",
            )
        }

        var unsafe *c = canon_unqual(x->target->canonical)
        var        s  = LowerTargets::ext_scope_prefix()
        if isa<BuiltinType>(c) {
            return s + builtin_info(cast<BuiltinType>(c)->builtin)->spelling
        }

        // `extend [i32; 2]`: a fixed array is neither a record nor a
        // builtin; its scope is named from its C++ spelling, which is a
        // function of the type and the target (an `isize` element is `long`
        // or `long long`), never of the build order. A scope struct never
        // crosses targets, so that is as stable as it needs to be.
        if isa<FixedArrayType>(c) && !c->is_dependent() {
            return s + "arr__" + Speller::_path_ident(self._type(c))
        }

        // `extend i32?`, `extend <T> [T]?`: a nullable is its
        // `::builtin::Null<T>` record to C++, but EmitPlan keys a
        // non-record target's scope by the exact canonical (_same_scope), so
        // each nullable gets its own struct, named from its C++ spelling as
        // a fixed array's is: a function of the type and the target alone.
        if isa<NullableType>(c) {
            return s + "nul__" + Speller::_path_ident(self._type(c))
        }

        if !isa<RecordType>(c) {
            self._ice(
                x->range,
                "CXXSpell: extension of a non-record, non-builtin target; no scope naming rule for it yet",
            )
        }

        var unsafe *prim = Speller::rep(
            DeclFacts::decl_pattern(Speller::rep(cast<RecordType>(c)->decl)),
        )

        if DeclFacts::decl_is_imported(prim) {
            return s + Speller::_path_ident(DeclFacts::decl_cxx_spelling(prim))
        }

        var tns  = self.ns_segments(prim)
        var sns  = self.scope_ns(x)
        var same = tns.size() == sns.size()
        for var i: usize = 0; same && i < tns.size(); ++i {
            if tns[i] != sns[i] {
                same = false
            }
        }

        if !same {
            for var i: usize = 0; i < tns.size(); ++i {
                s += tns[i]
                s += "__"
            }
        }

        var ow = self.owner_types(prim)
        for var i: usize = 0; i < ow.size(); ++i {
            s += ow[i]
            s += "__"
        }

        return s + self.leaf(prim)
    }

    /// `::ns::Point` as `ns__Point`: `::` becomes `__`, the leading one is
    /// dropped, and anything else that is not an identifier byte is `_`.
    static fn _path_ident(const sp: string) -> string {
        var out       = ""
        var i:  usize = 0
        if sp.size() >= 2 && sp.data()[0] == (':' as u8) && sp.data()[1] == (':' as u8) {
            i = 2
        }

        while i < sp.size() {
            var ch = sp.data()[i]
            if ch == (':' as u8) && i + 1 < sp.size() && sp.data()[i + 1] == (':' as u8) {
                out += "__"
                i += 2
                continue
            }

            var ok = is_ident_char(ch)
            if ok {
                out.push(ch)
            } else {
                out += "_"
            }

            i += 1
        }

        return out
    }

    /// Enclosing TYPE names for a nested decl, outermost first. An extension
    /// member's one owner is its scope struct.
    pub fn owner_types(self, d: unsafe *Decl) -> cxx::std::vector<string> {
        var unsafe *x = DeclFacts::decl_extension_of(d)
        if x != &null {
            var one = cxx::std::vector<string>()
            one.push_back(self.ext_scope_name(x))
            return one
        }

        var        rev = cxx::std::vector<string>()
        var unsafe *dc = self._home_dc(d)
        while dc != &null && dc->is_type_scope() {
            if dc->dc_kind != DeclContextKind::Extension {
                rev.push_back(self.leaf(Speller::rep(dc->dc_owner)))
            }

            dc = dc->dc_parent
        }

        var out = cxx::std::vector<string>()
        for var i: usize = 0; i < rev.size(); ++i {
            out.push_back(rev[rev.size() - 1 - i])
        }

        return out
    }

    /// `::ns::Outer::Inner`. An entry-TU decl's segment is its file stem, so
    /// `::stem::Name` is the same name whether the decl is `pub` or `priv`:
    /// C++'s implicit using-directive reaches into the nested unnamed
    /// namespace `priv` puts it in, and qual_name never has to know.
    /// `q`, an imported enum's C++ name, cut before an unnamed segment:
    /// clang prints `enum { a };` as `::ns::(unnamed enum at f.h:2:16)`,
    /// which is no C++ name. An unnamed enum is never scoped, so its
    /// enumerators are its enclosing scope's (`::clang::diag::err_x`);
    /// `::` alone is the global scope.
    static fn _unnamed_scope_cut(q: string) -> string {
        for var i: usize = 0; i < q.size(); ++i {
            if q.data()[i] == ('(' as u8)
                && i >= 2
                && q.data()[i - 1] == (':' as u8)
                && q.data()[i - 2] == (':' as u8) {
                // The text before the segment ends in `::`; drop it.
                return q.subslice(0, i - 2)
            }
        }

        return q
    }

    pub fn qual_name(self, d: unsafe *Decl) -> string {
        if Speller::in_function_scope(d) {
            return self.leaf(d)
        }

        var unsafe *r = Speller::rep(d)
        if DeclFacts::decl_is_imported(r) {
            return DeclFacts::decl_cxx_spelling(r)
        }

        // A Kairo definition of a C++-declared function is called by
        // the C++ name, not under the module it is written in.
        var unsafe *rf = dyn_cast<Declarations::FunctionDecl>(r)
        if rf != &null && Speller::defines_foreign(rf) {
            return DeclFacts::decl_cxx_spelling(
                unsafe (rf->first_decl() as unsafe *Decl),
            )
        }

        // An imported enum's enumerator carries no import facts of its own
        // (DeclImport makes a bare EnumVariantDecl), so it fell through to
        // the Kairo path below and was spelled under its HEADER's module
        // (`::memory_order::std::memory_order::relaxed`), which names
        // nothing in C++. Its enum's C++ name is its scope: `E::b` is
        // legal C++11 for a scoped and an unscoped enum alike.
        if isa<Declarations::EnumVariantDecl>(r) {
            var unsafe *hdc = self._home_dc(r)
            if hdc != &null && hdc->is_type_scope() && hdc->owner_decl() != &null {
                var unsafe *en = Speller::rep(hdc->owner_decl())
                if DeclFacts::decl_is_imported(en) {
                    return Speller::_unnamed_scope_cut(
                        DeclFacts::decl_cxx_spelling(en),
                    ) + "::" + self.leaf(r)
                }
            }
        }

        // An enumerator of an enum nested in a class template: the plain
        // `::ns::G::E::B` names the template without arguments, which C++
        // rejects. Spell the owner chain over its own parameters, as the
        // template body sees it (the same path a nested type takes).
        if isa<Declarations::EnumVariantDecl>(r) {
            var gq = self._generic_owner_qual(r)
            if gq.size() > 0 {
                return gq + "::" + self.leaf(r)
            }
        }

        var s  = ""
        var ns = self.ns_segments(r)
        for var i: usize = 0; i < ns.size(); ++i {
            s += "::"
            s += ns[i]
        }

        var ow = self.owner_types(r)
        for var i: usize = 0; i < ow.size(); ++i {
            s += "::"
            s += ow[i]
        }

        s += "::"
        s += self.leaf(r)
        return s
    }

    /// `ns::a::b {` as `namespace a::b`, or "" for the entry TU.
    fn ns_join(self, @inout segs: cxx::std::vector<string>) -> string {
        var s = ""
        for var i: usize = 0; i < segs.size(); ++i {
            if i > 0 {
                s += "::"
            }

            s += segs[i]
        }

        return s
    }
}
