// The split subscript at run time beside the other subscript rules.
// As in subscript_split_run.k the read form hands out `r` and the place form
// `w`, so each check sees which form ran; each failing check returns its
// number.
//
//   - A nullable container narrowed by `if o?` (the read goes through the
//     narrowing first): `o[0] = 3` writes, `o[1]` reads.
//   - A method of an `extend Two?` block reads its narrowed `self[0]`.
//   - A fixed array of split elements: `arr[0][1] = 5` is a builtin index
//     then the place form; `arr[1][0]` a builtin index then the read form.

class Two {
    var r: [i32; 2]
    var w: [i32; 2]
    fn Two(self) {
        self.r = [10, 20]
        self.w = [0, 0]
    }

    fn op [] (const self, i: usize) -> *const i32 { return &self.r[i] }
    fn op []= (self, i: usize) -> *i32 { return &self.w[i] }
}

extend Two? {
    fn first(self) -> i32 {
        if self? {
            return self[0]
        }

        return -1
    }
}

fn main() -> i32 {
    var o: Two? = Two()
    if o? {
        o[0] = 3
        if o.w[0] != 3 || o[1] != 20 { return 1 }
    }

    if o.first() != 10 { return 2 }
    var arr: [Two; 2] = [Two(), Two()]
    arr[0][1] = 5
    if arr[0].w[1] != 5 || arr[1][0] != 10 { return 3 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=TC --allow-empty
// TC-NOT: {{error|warning}}
// RUN: { %kairo %s --print-ir -o %t.ir.exe 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-DAG: .__kairo_op_set(0) = 3)
// IR-DAG: arr[0].__kairo_op_set(1) = 5)
// IR-DAG: arr[1].__kairo_op_get(0)
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
