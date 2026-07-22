// CASE 5: same TYPE name imported from two modules -> ONE overlay key with TWO
// non-function targets -> AMBIGUOUS import. Expect: R016 emitted HERE (sole
// home), once, when the key tips to >=2 non-function targets. The overlay dump
// marks the `Box` key [AMBIGUOUS].

import bar::{Box}
import baz::{Box}

fn use_ambiguous() -> i32 {
    return 0
}
