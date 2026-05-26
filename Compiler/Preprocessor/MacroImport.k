///--- The Kairo Project ----------------------------------------------------///
///                                                                          ///
///   Part of the Kairo Project, under the Attribution 4.0 International     ///
///   license (CC BY 4.0).  You are allowed to use, modify, redistribute,    ///
///   and create derivative works, even for commercial purposes, provided    ///
///   that we give appropriate credit, and indicate if changes were made.    ///
///                                                                          ///
///   For more information on the license terms and requirements, please     ///
///     visit: https://creativecommons.org/licenses/by/4.0/                  ///
///                                                                          ///
///   SPDX-License-Identifier: Apache-2.0                                    ///
///   Copyright (c) 2026 The Kairo Project (Apache-2.0)                      ///
///                                                                          ///
///------------------------------------------------------------ KAIRO -------///

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