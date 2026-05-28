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

import Preprocessor::IdentifierToken::*;
import Preprocessor::ModulePath::*;

/// \brief represents a single resolved macro import available in a scope
class MacroImport {
    pub var macro_name:    IdentifierToken;  ///< the macro name (interned)
    pub var alias:         IdentifierToken;  ///< alias if renamed, same as macro_name otherwise
    pub var source_scope:  ModulePath;       ///< the module path where the macro lives
    pub var source_fid:    u32;              ///< file ID where the macro is defined
    pub var import_loc:    SourceRange;      ///< source location of the import statement
    pub var is_wildcard:   bool;             ///< true if this came from a wildcard import
}