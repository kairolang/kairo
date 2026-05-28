
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

import Preprocessor::MacroImport::*;

/// \brief result of parsing a single import statement from the token stream
class ParsedImport {
    /// \brief a single item from a grouped import { A, B as C, Mac! }

    
    class Item {
        pub var name:       IdentifierToken;  ///< original name
        pub var alias:      IdentifierToken;  ///< alias (same as name if no `as`)
        pub var has_alias:  bool = false;
        pub var is_macro:   bool = false;      ///< true if name ends with `!`
    }

    pub var items:           vec::<Item>;  ///< individual import items (1 for simple, N for grouped)
    pub var scope:           ModulePath;   ///< scope where this import appears (from ScopeTracker)
    pub var base_path:       ModulePath;   ///< the module path prefix (everything before the last segment or group)
    pub var import_loc:      SourceRange;  ///< full source range of the import statement
    pub var tokens_consumed: usize = 0;
    pub var end_index:       usize = 0;
    pub var is_wildcard:     bool = false; ///< true for `import Foo::Bar::*`
    pub var is_module:       bool = false; ///< true for `import module Foo::Bar`
    pub var is_ffi:          bool = false; ///< true for `ffi "..." import ...`
}