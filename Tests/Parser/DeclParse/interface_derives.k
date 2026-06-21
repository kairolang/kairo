// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
interface Stream derives Readable, Seekable { fn close(self) fn flush(self) }
