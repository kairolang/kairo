/// --- The Kairo Project ----------------------------------- <filename> --- ///
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

import ASTNode::Base::*;
import AST::ASTContext::*;
import AST::Support::*;

class <T> ReDeclarable {
    var first:    *T;   // canonical first decl seen
    var previous: *T;   // previous in chain, null if first
    var most_recent: *T; // tail of chain

    fn get_canonical(self) -> *T { return self.first; }
    fn get_previous(self)  -> *T { return self.previous; }
    fn get_last(self)      -> *T { return self.most_recent; }
}
