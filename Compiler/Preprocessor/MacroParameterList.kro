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

import Preprocessor::MacroParameter::*;
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
