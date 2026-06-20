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

import Token::TokenSpan::*;

type SymbolID = u32;;

// =========================================================================
//  EXPANSION CONTEXT
// =========================================================================

/// \brief per-expansion state: tracks recursion depth, cycle detection,
///        and parameter bindings for a single macro invocation.
class ExpansionContext {
    pub var call_stack:        vec::<SymbolID>;            ///< macro names on the current expansion stack
    pub var param_bindings:    map::<SymbolID, TokenSpan>; ///< param name -> argument tokens
    pub var variadic_bindings: vec::<TokenSpan>;           ///< variadic arguments (one TokenSpan per arg)
    pub var invoke_loc:        SourceRange;                ///< source location of the invocation site
    pub var depth:             u32 = 0;                    ///< current recursion depth
    pub var variadic_name:     SymbolID = 0;               ///< 0 = no named variadic (unnamed ... case)

    fn is_in_cycle(self, name: SymbolID, const max_depth: usize) -> bool {
        for id in self.call_stack {
            if id == name {
                return true;
            }
        }
        return false;
    }

    fn push(self, name: SymbolID) {
        self.call_stack.push_back(name);
        self.depth += 1;
    }

    fn pop(self) {
        if self.call_stack.size() > 0 {
            self.call_stack.pop_back();
        }
        if self.depth > 0 {
            self.depth -= 1;
        }
    }

    fn exceeded_depth(self, const max_depth: usize) -> bool {
        return self.depth > max_depth;
    }
}