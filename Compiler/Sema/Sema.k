


/*
Ordering:
1.  Import Resolution
2.  Attribute Expansion
3.  Eval Evaluation
4.  Type Resolution
5.  Operator Signature Check
6.  Name Resolution
7.  Layout Pass
8.  TypeQuery Lowering
9.  Extends Resolving
10. Extends Lowering
11. ADL Resolver

*/

/// This file needs to provide a clean entry and acces poing into sema
/// var sem = Sema(&tu)
/// sem.Initialize()
/// sem.emit()
/// 