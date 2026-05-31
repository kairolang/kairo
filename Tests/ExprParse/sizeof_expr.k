sizeof f       // sizeof(named(identifier))
sizeof i8      // sizeof(named(i8))
(sizeof i16)   // sizeof(named(i16))
sizeof i32 + 1 // CHECK: binop(+, sizeof(named(i32)), int(integer))
sizeof "hello there" // CHECK: error   [S045E]: expected type, found 'string'
sizeof broken(45)    // FAILED: FIXME
sizeof 1 + 2  // CHECK: error   [S045E]: expected type, found 'integer'
sizeof (i64   // CHECK: error   [S019E]: unclosed ')' opened here
              // CHECK: sizeof(named(i64))
sizeof i128   // CHECK: sizeof(named(i128))
sizeof i256)  // CHECK: <recovery:13>
              // CHECK: error   [S045E]: expected expression, found ')'
sizeof i512   // CHECK: sizeof(named(i512))