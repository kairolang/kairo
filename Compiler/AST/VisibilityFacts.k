/// --- The Kairo Project ------------------------ AST/VisibilityFacts.k --- ///
///
///   \brief Where a declaration is visible: the module a file belongs to,
///          and what a declaration with no visibility keyword is.
///
///   \detail
///     The rule (classes.mdx Visibility, modules.mdx Visibility Scopes):
///
///       priv   the declaring file.
///       prot   the declaring file's MODULE: every file under the nearest
///              directory at or above it that holds a module.k (pinned or
///              not). A file with no module.k above it has no module, and
///              its `prot` reaches what `priv` does (classes keep their
///              subclasses' reach, AccessCheck).
///       pub    everywhere.
///
///     An unmarked declaration is `priv`, or `prot` when its file is in a
///     module. Not for everything: an enum's variants, an interface's
///     requirements and module namespaces carry no visibility of their own,
///     and the members of an `extend X impl I` block serve the interface,
///     which reaches them from wherever the conformance is used.
///
///     Two files the rule does not change yet: builtin and std, which the
///     user owns and which were written for the old rule, keep it until
///     they are marked (TODO(DEFAULT-VIS)); and a build with the hidden
///     -fdefault-visibility=pub, which build.py passes for the compiler's
///     own tree, keeps it everywhere. The old rule: everything public but a
///     class's variables, which are private.
///
///     Each TU's facts are stamped once by the driver, single-threaded,
///     before Sema schedules anything (FrontendAction::_sema), because
///     parallel Sema reads another TU's facts from any worker. A TU nothing
///     stamped (tooling that drives Sema itself) is answered by recomputing,
///     never by writing.
///
///   Layer: AST. Imports AST, Support and Resolution::SearchRoot (the
///   module-root walk it shares with `import module::`).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::Context::DeclContext::{
    DeclContext,
    DeclContextKind,
}
import AST::Context::TranslationUnit::TranslationUnit
import AST::Mixin::Annotation::VisibilityKind
import AST::Node::Base::Decl
import AST::Node::Casting::{
    dyn_cast,
    isa,
}
import AST::Node::Declarations
import Resolution::SearchRoot::module_dir_at_or_above
import Support::FileIO::Path::Path

/// The directory of the module \p file belongs to: the nearest directory at
/// or above it that holds a `module.k`, or "" when none does. The walk is
/// Resolution's (module_dir_at_or_above), so `import module::x` anchors at
/// the same directory this answers for `prot`.
pub fn module_dir_of_path(const file: string) -> string {
    if file.empty() || file.starts_with("<") {
        return ""
    }

    return module_dir_at_or_above(Path::parent_of(Path::real_path_of(file)))
}

/// \p tu is builtin or std: the library roots the compiler registers, whose
/// unmarked declarations keep the old rule until they are marked.
fn _is_lib_tu(tu: unsafe *TranslationUnit) -> bool {
    if tu == &null || tu->ctx == &null {
        return false
    }

    // TODO(DEFAULT-VIS): drop this exemption once Lib/builtin and Lib/std
    // write `pub` on what they export (pending that change; the spec default would
    // make every string method private to its module today).
    if tu->global_scope != &null && tu->global_scope->is_builtin_fid(tu->fid) {
        return true
    }

    var unsafe *ci = tu->ctx->ci
    if ci == &null || tu->ctx->sm == &null {
        return false
    }

    var root = ci->pp.std_dir
    if root.empty() && !ci->target.resource_dir.empty() {
        root = ci->target.resource_dir + "/std"
    }

    if root.empty() {
        return false
    }

    var file  = tu->ctx->sm->get_filename(tu->fid)
    var slash = if (root.ends_with("/")) => (root) else => (root + "/")
    if file.starts_with(slash) {
        return true
    }

    var real_root = Path::real_path_of(root)
    if !real_root.ends_with("/") {
        real_root += "/"
    }

    return Path::real_path_of(file).starts_with(real_root)
}

/// Records \p tu's facts. The driver calls it for every TU of a build
/// before Sema runs; nothing else writes them.
pub fn stamp_tu_visibility(tu: unsafe *TranslationUnit) {
    if tu == &null || tu->ctx == &null {
        return
    }

    if tu->is_foreign {
        tu->vis_stamped = true
        return
    }

    tu->is_lib_tu = _is_lib_tu(tu)
    tu->module_dir = if (tu->ctx->sm != &null) => (module_dir_of_path(
                         tu->ctx->sm->get_filename(tu->fid),
                     ))
                     else => ""
    tu->vis_stamped = true
}

/// \p tu's module directory, or "" when it is in no module.
pub fn tu_module_dir(tu: unsafe *TranslationUnit) -> string {
    if tu == &null || tu->is_foreign || tu->ctx == &null {
        return ""
    }

    if tu->vis_stamped {
        return tu->module_dir
    }

    if tu->ctx->sm == &null {
        return ""
    }

    return module_dir_of_path(tu->ctx->sm->get_filename(tu->fid))
}

/// \p a and \p b are files of one module. Never true for files in no
/// module, even the same one: the caller asks only across files.
pub fn same_module(a: unsafe *TranslationUnit, b: unsafe *TranslationUnit) -> bool {
    if a == &null || b == &null {
        return false
    }

    var da = tu_module_dir(a)
    if da.empty() {
        return false
    }

    return da == tu_module_dir(b)
}

/// The visibility an unmarked top-level declaration of \p tu has: Public
/// under the old rule (-fdefault-visibility=pub, builtin, std, a C/C++
/// header), else Protected in a module and Private outside one.
pub fn tu_default_vis(tu: unsafe *TranslationUnit) -> VisibilityKind {
    if tu == &null || tu->is_foreign || tu->ctx == &null {
        return VisibilityKind::Public
    }

    var unsafe *ci = tu->ctx->ci
    // No invocation is a tool driving the AST on its own (ParseAPI): no
    // flag was given either way, and refusing nothing is the safe answer.
    if ci == &null || ci->lang.default_vis_pub {
        return VisibilityKind::Public
    }

    var lib = if (tu->vis_stamped) => (tu->is_lib_tu) else => _is_lib_tu(tu)
    if lib {
        return VisibilityKind::Public
    }

    if tu_module_dir(tu).empty() {
        return VisibilityKind::Private
    }

    return VisibilityKind::Protected
}

/// The TranslationUnit scope \p dc is in, or null.
pub fn tu_of_scope(dc: unsafe *DeclContext) -> unsafe *TranslationUnit {
    var unsafe *c         = dc
    var        depth: u32 = 0
    while c != &null && depth < 256 {
        if c->dc_kind == DeclContextKind::TranslationUnit {
            return unsafe (c as unsafe *TranslationUnit)
        }

        c = c->dc_parent
        depth += 1
    }

    return &null
}

/// What \p d is when it writes no visibility keyword, \p home being the
/// file it is relative to (a member's class's file: a generic instance's
/// members are minted wherever it is used; null for \p d's own).
pub fn default_visibility_of(d:    unsafe *Decl,
                             home: unsafe *TranslationUnit = &null) -> VisibilityKind {
    if d == &null {
        return VisibilityKind::Public
    }

    var unsafe *dc = d->semantic_dc
    if dc == &null {
        return VisibilityKind::Public
    }

    // No visibility of their own: a variant is its enum's, a requirement
    // its interface's, and a namespace or an `extend` block only groups
    // what it holds, each member answering for itself.
    if isa<Declarations::EnumVariantDecl>(d)
        || isa<Declarations::ModuleDecl>(d)
        || isa<Declarations::ExtensionDecl>(d) {
        return VisibilityKind::Public
    }

    if dc->dc_kind == DeclContextKind::Interface {
        return VisibilityKind::Public
    }

    var unsafe *tu    = if (home != &null) => (home) else => tu_of_scope(dc)
    var        td     = tu_default_vis(tu)
    var unsafe *owner = dc->owner_decl()
    if dc->dc_kind == DeclContextKind::Extension {
        if td == VisibilityKind::Public {
            return VisibilityKind::Public
        }

        // An `extend X impl I` block's members implement I, and a use of
        // the conformance reaches them from any file that can name X and I.
        var unsafe *ext = dyn_cast<Declarations::ExtensionDecl>(owner)
        if ext != &null && ext->implements.size() > 0 {
            return VisibilityKind::Public
        }

        return td
    }

    if td == VisibilityKind::Public {
        // The old rule: a class's variables are private, all else public.
        if owner != &null
            && isa<Declarations::ClassDecl>(owner)
            && (isa<Declarations::FieldDecl>(d) || isa<Declarations::VariableDecl>(d)) {
            return VisibilityKind::Private
        }

        return VisibilityKind::Public
    }

    return td
}

/// \p d is an operator (`op +`, `op ==`, `op panic`, ...). What C++ sees of
/// an unmarked one stays public whatever its default: C++ reaches them
/// through probes (a `requires`, the panic helpers' `op panic` test), which
/// turn false silently on a private member instead of failing, so a C++
/// host would quietly behave unlike the Kairo program (InterfaceEmitter::
/// _cxx_vis, EmitPlan::_hidden). Kairo itself still checks the default.
pub fn is_operator_fn(d: unsafe *Decl) -> bool {
    var unsafe *f = dyn_cast<Declarations::FunctionDecl>(d)
    return f != &null && f->is_operator
}
