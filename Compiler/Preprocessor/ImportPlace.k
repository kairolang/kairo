/// --- The Kairo Project ------------------- Preprocessor/ImportPlace.k --- ///
///
///   Where an import's path leads: the one resolution rule the dependency
///   scan (DepScanner) and the PP walk (FileImportIndex) both apply, so the
///   graph reaches exactly the files the walk resolves.
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

import AST::Node::Declarations::ImportKind
import Diagnostic::Code::DiagCode
import Diagnostic::Engine::DiagEngine
import Diagnostic::Registry::DiagID
import Location::SourceManager::{
    FileID,
    SourceManager,
}
import Location::SourceRange::SourceRange
import Resolution::ImportProbe::{
    ImportResolver,
    ModuleResolution,
}
import Resolution::SearchRoot::module_dir_at_or_above
import Support::FileIO::Path::Path

/// The file an import path names, and how it was reached.
pub struct ImportPlace {
    var found:     bool  = false
    var fid:       u32   = u32::MAX ///< the loaded file; u32::MAX when not found (0 is a file: the first input)
    var seg_count: usize = 0 ///< leading segments that name the file; the rest name symbols in it
    /// The file's module path from its owning search root: its identity,
    /// whatever anchor the import was written with.
    var canonical: cxx::std::vector<string>
    /// A plain import only the importing file's directory answered
    /// (Compiler/Spec/Imports.md#migration); the walk reports R068E.
    var legacy_sibling: bool = false
    /// `module::` in a file with no module.k at or above it; the walk
    /// reports R069E.
    var no_module_root: bool = false
}

/// `a::b::c` from its segments.
pub fn join_import_segments(const segs: cxx::std::vector<string>) -> string {
    var s = ""
    for var i: usize = 0; i < segs.size(); ++i {
        if i > 0 {
            s += "::"
        }

        s += segs[i]
    }

    return s
}

/// Resolves \p segs, written with anchor \p kind in a file whose directory
/// is \p dir (\p has_dir false for a file with none).
///
/// Each form looks in one place: the search roots (plain), \p dir
/// (`self::`) or the module root at or above \p dir (`module::`). The
/// longest prefix of \p segs that names a module wins; the segments past it
/// name symbols. A plain import no search root answers is retried in \p dir
/// alone, after every root has missed every prefix, so a root answer is
/// never overridden by it.
///
/// With \p diag, each prefix the resolver finds ambiguous is reported at
/// \p at (R017E across two search directories, R005E for `foo.k` beside
/// `foo/module.k`) as it is met; with null, nothing is reported. Reads the
/// resolver and loads the file found; reports nothing else.
pub fn resolve_import_place(res:        *ImportResolver,
                            sm:         *SourceManager,
                            kind:       ImportKind,
                            const segs: cxx::std::vector<string>,
                            const dir:  Path,
                            has_dir:    bool,
                            diag:       unsafe *DiagEngine,
                            at:         SourceRange) -> ImportPlace {
    var out = ImportPlace()
    if segs.size() == 0 {
        return out
    }

    var in_dir = kind != ImportKind::Native
    var anchor = dir
    if kind == ImportKind::ModuleRelative {
        var mdir = if (has_dir) => (module_dir_at_or_above(dir.full_path())) else => ""
        if mdir.empty() {
            out.no_module_root = true
            return out
        }

        anchor = Path(mdir)
    } else if in_dir && !has_dir {
        return out
    }

    out = _import_place_greedy(
        res,
        sm,
        segs,
        in_dir,
        anchor,
        dir,
        has_dir,
        diag,
        at,
    )

    if !out.found && kind == ImportKind::Native && has_dir {
        out = _import_place_greedy(
            res,
            sm,
            segs,
            true,
            dir,
            dir,
            has_dir,
            diag,
            at,
        )

        out.legacy_sibling = out.found
    }

    return out
}

/// The longest prefix of \p segs that names a module and loads: in \p dir
/// alone (\p in_dir), else in the search roots relative to \p from_dir.
fn _import_place_greedy(res:            *ImportResolver,
                        sm:             *SourceManager,
                        const segs:     cxx::std::vector<string>,
                        in_dir:         bool,
                        const dir:      Path,
                        const from_dir: Path,
                        has_from:       bool,
                        diag:           unsafe *DiagEngine,
                        at:             SourceRange) -> ImportPlace {
    var out     = ImportPlace()
    var try_len = segs.size()
    while try_len > 0 {
        var try_segs = cxx::std::vector<string>()
        for var i: usize = 0; i < try_len; ++i {
            try_segs.push_back(segs[i])
        }

        var rr: ModuleResolution
        if in_dir {
            rr = res->resolve_module_in(try_segs, dir)
        } else {
            rr = res->resolve_module_rel(try_segs, from_dir, has_from)
        }

        if rr.found {
            if diag != &null {
                _report_ambiguous_place(diag, at, try_segs, rr)
            }

            var fid = sm->load_file(rr.path)
            if fid != (u32::MAX as FileID) {
                out.found     = true
                out.fid       = fid
                out.seg_count = try_len
                out.canonical = rr.canonical
                return out
            }
        }

        try_len -= 1
    }

    return out
}

fn _report_ambiguous_place(diag:           unsafe *DiagEngine,
                           at:             SourceRange,
                           const try_segs: cxx::std::vector<string>,
                           const rr:       ModuleResolution) {
    if rr.ambiguous && rr.cross_root {
        // Two unnamed search dirs hold one path. Qualifying cannot help: an
        // unnamed dir has no name to write. One file has to go, or be
        // pinned into a library of its own.
        diag->report(
            DiagCode(DiagID::R017E),
            at.start,
            f"ambiguous import '{join_import_segments(try_segs)}': it matches both '{rr.path.full_path()}' and '{rr.other_path.full_path()}', in two search directories; a search directory adds nothing to a module path, so no spelling tells them apart: remove or rename one, or pin one as a library with a module.k",
        ).first(at)->emit()
    }

    if rr.file_dir {
        // `foo.k` and `foo/module.k` in the one place this form looks. Each
        // would be module `foo`; the file answers so the import does not
        // cascade into "not found".
        diag->report(
            DiagCode(DiagID::R005E),
            at.start,
            f"ambiguous module '{join_import_segments(try_segs)}': both '{rr.path.full_path()}' and '{rr.dir_path.full_path()}' are that module; rename or remove one",
        ).first(at)->emit()
    }
}
