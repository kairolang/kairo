/// --- The Kairo Project --------------------------- Macro/Definition.k --- ///
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Macro::ParameterList::*;
import Resolution::ModulePath::*;

class MacroDefinition {
    pub var scope:          ModulePath; ///< module path where this macro is defined (excl the name)
    pub var params:         MacroParameterList; ///< list of parameters
    /// body/default-value spans and name tokens are deep-copied into
    /// MacroSymbolTable-owned storage at insert_macro() time (flat-mode
    /// TokenSpans). A registered definition never aliases the lexed token
    /// buffers, so displaced buffers can be freed at end of preprocess.
    pub var body:           TokenSpan; ///< macro body tokens (table-owned after registration)
    pub var name:           IdentifierToken; ///< macro name we cant use a token here since a token doesnt store the text only kind range and imm data which is not sufficient
    pub var definition_loc: SourceRange; ///< source location of the macro definition (for error reporting)
    pub var source_fid:     u32;
    pub var accepts_params: bool;        ///< does this macro accept parameters (true if defined with parens)

    const fn as_string(self, s: *PreprocessorSymbolTable) -> string {
        return f"MacroDefinition(name='{self.name.as_string(s)}', scope='{self.scope.as_string(s)}', params={self.params.as_string(s)}, body={self.body}, definition_loc={self.definition_loc}, accepts_params={self.accepts_params})";
    }
}