alignof f       // alignof(named(identifier))
alignof i8      // alignof(named(i8))
(alignof i16)   // alignof(named(i16))
alignof i32 + 1 // CHECK: binop(+, alignof(named(i32)), int(integer))
alignof "hello there" // CHECK: error   [S045E]: expected type, found 'string'
alignof broken(45)    // FAILED: FIXME
alignof 1 + 2 // CHECK: error   [S045E]: expected type, found 'integer'
alignof (i64  // CHECK: error   [S019E]: unclosed ')' opened here
              // CHECK: alignof(named(i64))
alignof i128  // CHECK: alignof(named(i128))
alignof i256) // CHECK: <recovery:13>
              // CHECK: error   [S045E]: expected expression, found ')'
alignof i512  // CHECK: alignof(named(i512))