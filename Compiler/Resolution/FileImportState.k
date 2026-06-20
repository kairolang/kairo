/// --- The Kairo Project -------------------------------------------------- ///
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Resolution::ModulePath::*;
import Resolution::MacroImport::*;

/// \brief per-file import state: what macros are available and from where
class FileImportState {
    pub var fid:            u32;                                   ///< file ID
    pub var module_base:    ModulePath;                            ///< base module path derived from filename
    pub var macro_imports:  vec::<MacroImport>;                    ///< resolved macro imports
    pub var wildcard_fids:  vec::<u32>;                            ///< files imported with *, need full macro table scan
    pub var scoped_imports: map::<ModulePath, vec::<MacroImport>>; ///< imports grouped by scope they're visible in
    pub var module_aliases: map::<SymbolID, ModulePath>;           ///< module aliases (e.g., import foo as bar)`
}