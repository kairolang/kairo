// A RUN line must not end a pipeline in `grep -q` (or any reader that exits
// at its first match). The reader closes the pipe early, the producer dies of
// SIGPIPE, and lit's `pipefail` turns that into a failure that appears only
// when the producer is still writing: the test fails intermittently while
// every pattern matched. Read the whole output instead (`| grep pattern
// > /dev/null`, `| grep .`, `| %FileCheck`). A negated reader
// (`{ ! grep -q ...; }`) is fine: it exits early only when the test is
// already failing.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { grep -rnIE --exclude-dir=Output --exclude-dir=Triage --exclude-dir=Manual --exclude=run_lines_no_early_exit_grep.k 'RU[N]:.*\|[[:space:]]*gre[p][[:space:]]+-[a-zA-Z]*q' % || true; } | { grep -vF '{ ! gre'p || true; } | %FileCheck %s --allow-empty
// CHECK-NOT: {{.}}
