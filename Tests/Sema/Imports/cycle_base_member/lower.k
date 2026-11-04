// Corpus for stmts.k: reads a base member through the derived class.
import stmts::*
import base::*

pub fn t(n: unsafe *LabeledStmt) -> i32 { return n->range + n->label }
