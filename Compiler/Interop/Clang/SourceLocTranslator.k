/// --- The Kairo Project ---------- Interop/Clang/SourceLocTranslator.k --- ///
///
///   <short description>
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///
ffi "c++" import "Interop/Clang/ClangBridgeImpl.hh";

import Location::SourceLocation::*;
import Location::SourceRange::*;
import Location::SourceManager::*;

///
/// \brief kairo SourceLocation -> clang::SourceLocation.
///
/// \param loc   valid kairo SourceLocation.
/// \param sm    kairo SourceManager that owns loc.
/// \param csm   clang SourceManager for the TU being processed.
/// \return      corresponding clang::SourceLocation, or invalid if loc is
///              invalid or the file is not loaded in csm.
///
fn to_clang_source_loc(
    loc: SourceLocation,
    sm:  *SourceManager,
    csm: *clang::SourceManager
) -> clang::SourceLocation {
    if !loc.is_valid() {
        return clang::SourceLocation();
    }

    var coord = clang_detail::to_file_coord(loc, *sm);

    if !coord.is_valid() {
        return clang::SourceLocation();
    }

    return clang_detail::to_clang_loc(coord, *csm);
}

///
/// \brief clang::SourceLocation -> kairo SourceLocation.
///
/// \param loc   valid clang::SourceLocation.
/// \param csm   clang SourceManager that owns loc.
/// \param sm    kairo SourceManagerfile is loaded into it if not already.
/// \return      corresponding kairo SourceLocation, or invalid if loc is
///              invalid or the file cannot be loaded.
///
fn to_kairo_source_loc(
    loc: clang::SourceLocation,
    csm: *clang::SourceManager,
    sm:  *SourceManager
) -> SourceLocation {
    if loc.isInvalid() {
        return SourceLocation();
    }

    var coord = clang_detail::to_file_coord(loc, *csm);

    if !coord.is_valid() {
        return SourceLocation();
    }

    var path = Path(std::nstring_to_string(coord.filename), false);
    var fid  = sm->load_file(path, true);  // skip_indexing: we only need offsets

    return sm->get_loc(fid, static_cast::<usize>(coord.offset));
}