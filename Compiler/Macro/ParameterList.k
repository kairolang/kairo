/// --- The Kairo Project ------------------------ Macro/ParameterList.k --- ///
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Macro::Parameter::*;
import Preprocessor::PreprocessorSymbolTable::*;

class MacroParameterList {
    pub var params: vec::<MacroParameter>;

    const fn as_string(self, sym_table: *PreprocessorSymbolTable) -> string {
        var repr = "MacroParameterList(params: [";
        for param in self.params {
            repr += param.as_string(sym_table) + ", ";
        }
        repr += "])";
        return repr;
    }
}
