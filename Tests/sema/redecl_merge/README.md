# RedeclMerge corpus

Oracle policy:

  parity/     has a C++ equivalent alongside it. The .cpp is the ORACLE.
              Run clang on the .cpp and kcc on the .k; assert both accept
              or both reject, and that the rejection is the same rule.
              If they disagree, clang is right by definition (OVERLOAD.md:
              behaviour must be 1:1) unless the divergence is listed in
              kairo-only/README as a deliberate Kairo rule.

  kairo-only/ no C++ analog exists. Hand-written expectation, and every
              file states WHY there is no oracle. Do not add a file here
              to avoid writing the .cpp.

Ported from clang test tree. Record the revision:
  clang tree: Lib/llvm-runtimes  rev: <FILL IN>
Sources are cited per file so an expectation can be rechecked on an LLVM
bump: if a ported case changes verdict, this tells you whether clang moved
or we did.

Expectation convention (until kcc grows a -verify mode):
  // EXPECT-ERROR: <line>: <short rule name>
  // EXPECT-CLEAN
Assert on diag CODE and LINE, never on message text. Assert the count on
clean files too: a spurious error is as much a bug as a missing one.
Snapshot the --print-sema chains section for every linking case; the
diagnostic stream cannot show that two decls merged into one chain.
