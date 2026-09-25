// Every declarable operator through X, OperatorLowering, CXXSpell and the
// spell tokenizer, with a use of each. `.*` / `->*` have no right-operand
// type to spell yet; `===` and `=` are rules.k's errors.

fn chk(c: bool) -> i32 { if c { return 1 } return 0 }

struct Full {
    var v: i32

    fn op +(self, o: Full) -> Full { return Full{ v: self.v + o.v } }   // operator+
    fn op +(self) -> Full { return Full{ v: self.v } }                  // operator+  (unary; declared only, the parser has no prefix `+`)
    fn op -(self, o: Full) -> Full { return Full{ v: self.v - o.v } }   // operator-
    fn op -(self) -> Full { return Full{ v: 0 - self.v } }              // operator-  (unary)
    fn op *(self, o: Full) -> Full { return Full{ v: self.v * o.v } }   // operator*
    fn op /(self, o: Full) -> Full { return Full{ v: self.v / o.v } }   // operator/
    fn op %(self, o: Full) -> Full { return Full{ v: self.v % o.v } }   // operator%
    fn op ^^(self, e: i32) -> Full { return Full{ v: self.v ^^ e } }    // __kairo_pow
    fn op <<(self, n: i32) -> Full { return Full{ v: self.v << n } }    // operator
    fn op >>(self, n: i32) -> Full { return Full{ v: self.v >> n } }    // operator>>
    fn op &(self, o: Full) -> Full { return Full{ v: self.v & o.v } }   // operator&
    fn op |(self, o: Full) -> Full { return Full{ v: self.v | o.v } }   // operator|
    fn op ^(self, o: Full) -> Full { return Full{ v: self.v ^ o.v } }   // operator^
    fn op ~(self) -> Full { return Full{ v: ~self.v } }                 // operator~

    fn op ==(self, o: Full) -> bool { return self.v == o.v }            // operator==
    fn op !=(self, o: Full) -> bool { return self.v != o.v }            // operator!=  (declared beats derived)
    fn op <(self, o: Full) -> bool { return self.v < o.v }              // operator
    fn op <=(self, o: Full) -> bool { return self.v <= o.v }            // operator<=
    fn op >(self, o: Full) -> bool { return self.v > o.v }              // operator>
    fn op >=(self, o: Full) -> bool { return self.v >= o.v }            // operator>=
    fn op <=>(self, o: Full) -> Ordering {                              // operator<=>
        if self.v < o.v { return Ordering::Less }
        if self.v > o.v { return Ordering::Greater }
        return Ordering::Equal
    }

    fn op l++(self) -> Full { self.v = self.v + 1; return Full{ v: self.v } }               // operator++()
    fn op r++(self) -> Full { var o = Full{ v: self.v }; self.v = self.v + 1; return o }    // operator++(int)
    fn op l--(self) -> Full { self.v = self.v - 1; return Full{ v: self.v } }               // operator--()
    fn op r--(self) -> Full { var o = Full{ v: self.v }; self.v = self.v - 1; return o }    // operator--(int)

    fn op in(self, x: i32) -> bool { return self.v == x }               // __kairo_contains
    fn op in(self) -> yield i32                                          // __kairo_iter   (declaration only until YieldLowering)
    fn op as(self) -> i32 { return self.v }                              // operator int
    fn op await(self) -> i32 { return self.v }                           // __kairo_await  (declaration emits; no use until the async lowering)
    fn op delete(self) { }                                               // ~Full
}

// Place operators, with the array field they point into.
struct Place {
    var v:   i32
    var buf: [i32; 4]
    fn op [](self, i: usize) -> *i32 { return &self.buf[i] }               // int& operator[](usize)
    fn op [](const self, i: usize) -> *const i32 { return &self.buf[i] }   // const int& operator[](usize) const
    fn op ->(self) -> *i32 { return &self.v }                               // int* operator->()
}

// The ten compound forms. A separate type: `Full` declares the bases.
struct Compound {
    var v: i32
    fn op +=(self, o: Compound) { self.v = self.v + o.v }      // void operator+=
    fn op -=(self, o: Compound) { self.v = self.v - o.v }
    fn op *=(self, o: Compound) { self.v = self.v * o.v }
    fn op /=(self, o: Compound) { self.v = self.v / o.v }
    fn op %=(self, o: Compound) { self.v = self.v % o.v }
    fn op &=(self, o: Compound) { self.v = self.v & o.v }
    fn op |=(self, o: Compound) { self.v = self.v | o.v }
    fn op ^=(self, o: Compound) { self.v = self.v ^ o.v }
    fn op <<=(self, n: i32) { self.v = self.v << n }
    fn op >>=(self, n: i32) { self.v = self.v >> n }
}

// The word forms. Each must be the SAME cell as its symbol: `w & w2` resolves
// against `op bitand`, `a bitand b` against `op &`.
struct Words {
    var v: i32
    fn op bitand(self, o: Words) -> Words { return Words{ v: self.v & o.v } }   // operator&
    fn op bitor(self, o: Words) -> Words { return Words{ v: self.v | o.v } }    // operator|
    fn op xor(self, o: Words) -> Words { return Words{ v: self.v ^ o.v } }      // operator^
    fn op compl(self) -> Words { return Words{ v: ~self.v } }                   // operator~
    fn op not_eq(self, o: Words) -> bool { return self.v != o.v }               // operator!=
}

struct WordsAssign {
    var v: i32
    fn op and_eq(self, o: WordsAssign) { self.v = self.v & o.v }   // operator&=
    fn op or_eq(self, o: WordsAssign) { self.v = self.v | o.v }    // operator|=
    fn op xor_eq(self, o: WordsAssign) { self.v = self.v ^ o.v }   // operator^=
}

// Free forms: reached through the declaring file.
struct F { var v: i32 }
fn op +(a: F, b: F) -> F { return F{ v: a.v + b.v } }          // operator+(F, F)
fn op *(k: i32, b: F) -> F { return F{ v: k * b.v } }          // operator*(int, F)
fn op ==(a: F, b: F) -> bool { return a.v == b.v }             // operator==(F, F)
fn op <=>(a: F, b: F) -> Ordering {                            // operator<=>(F, F)
    if a.v < b.v { return Ordering::Less }
    if a.v > b.v { return Ordering::Greater }
    return Ordering::Equal
}
fn op in(xs: F, x: i32) -> bool { return xs.v == x }           // __kairo_contains(F, int)
fn op ^^(a: F, e: i32) -> F { return F{ v: a.v ^^ e } }        // __kairo_pow(F, int)

// Extension forms: non-member C++ operators taking X& / const X&.
struct X { var v: i32 }
extend X {
    fn op -(self) -> X { return X{ v: 0 - self.v } }             // operator-(X&)
    fn op -(self, o: X) -> X { return X{ v: self.v - o.v } }     // operator-(X&, X)
    fn op <<(self, n: i32) -> X { return X{ v: self.v << n } }   // operator<<(X&, int)
    fn op <=>(self, o: X) -> Ordering {                          // operator<=>(X&, X)
        if self.v < o.v { return Ordering::Less }
        if self.v > o.v { return Ordering::Greater }
        return Ordering::Equal
    }
    fn op l++(self) -> X { self.v = self.v + 1; return X{ v: self.v } }               // operator++(X&)
    fn op r--(self) -> X { var o = X{ v: self.v }; self.v = self.v - 1; return o }    // operator--(X&, int)
    fn op +=(self, o: X) { self.v = self.v + o.v }                                    // operator+=(X&, X)
    fn op in(self, x: i32) -> bool { return self.v == x }                             // __kairo_contains(X&, int)
}

fn main() -> i32 {
    var t: i32 = 0

    // Full: a = 6, b = 3
    var a = Full{ v: 6 }
    var b = Full{ v: 3 }
    t += chk((a + b).v == 9)
    t += chk((a - b).v == 3)
    t += chk((-a).v == -6)
    t += chk((a * b).v == 18)
    t += chk((a / b).v == 2)
    t += chk((a % b).v == 0)
    t += chk((a ^^ 2).v == 36)
    t += chk((a << 1).v == 12)
    t += chk((a >> 1).v == 3)
    t += chk((a & b).v == 2)
    t += chk((a | b).v == 7)
    t += chk((a ^ b).v == 5)
    t += chk((~a).v == -7)
    t += chk((a bitand b).v == 2)              // word use, symbol decl
    t += chk(!(a == b))
    t += chk(a != b)
    t += chk(!(a < b))
    t += chk(!(a <= b))
    t += chk(a > b)
    t += chk(a >= b)
    t += chk((a <=> b) == Ordering::Greater)
    t += chk((++a).v == 7)
    t += chk((a++).v == 7)
    t += chk(a.v == 8)
    t += chk((--a).v == 7)
    t += chk((a--).v == 7)
    t += chk(a.v == 6)
    t += chk(6 in a)
    t += chk((a as i32) == 6)

    // Place
    var p = Place{ v: 5, buf: [1, 2, 3, 4] }
    t += chk(p[2] == 3)
    p[1] = 9
    t += chk(p.buf[1] == 9)

    // Compound: c = 1
    var c = Compound{ v: 1 }
    c += Compound{ v: 2 };  t += chk(c.v == 3)
    c -= Compound{ v: 1 };  t += chk(c.v == 2)
    c *= Compound{ v: 5 };  t += chk(c.v == 10)
    c /= Compound{ v: 2 };  t += chk(c.v == 5)
    c %= Compound{ v: 3 };  t += chk(c.v == 2)
    c &= Compound{ v: 3 };  t += chk(c.v == 2)
    c |= Compound{ v: 4 };  t += chk(c.v == 6)
    c ^= Compound{ v: 1 };  t += chk(c.v == 7)
    c <<= 2;                t += chk(c.v == 28)
    c >>= 1;                t += chk(c.v == 14)
    t += chk((c + Compound{ v: 1 }).v == 15)   // derived + from +=
    t += chk(c.v == 14)                        // and c untouched

    // Words: w = 6, w2 = 3
    var w  = Words{ v: 6 }
    var w2 = Words{ v: 3 }
    t += chk((w & w2).v == 2)                  // symbol use, word decl
    t += chk((w | w2).v == 7)
    t += chk((w ^ w2).v == 5)
    t += chk((~w).v == -7)
    t += chk(w != w2)
    t += chk((w bitand w2).v == 2)             // word use, word decl

    // WordsAssign: wa = 6
    var wa = WordsAssign{ v: 6 }
    wa &= WordsAssign{ v: 3 };      t += chk(wa.v == 2)
    wa |= WordsAssign{ v: 4 };      t += chk(wa.v == 6)
    wa xor_eq WordsAssign{ v: 1 };  t += chk(wa.v == 7)

    // F: free operators, prvalue operands
    t += chk((F{ v: 1 } + F{ v: 2 }).v == 3)
    t += chk((2 * F{ v: 2 }).v == 4)
    t += chk(F{ v: 1 } == F{ v: 1 })
    t += chk(F{ v: 1 } != F{ v: 2 })           // derived from free ==
    t += chk(F{ v: 1 } < F{ v: 2 })            // derived from free <=>
    t += chk(1 in F{ v: 1 })
    t += chk((F{ v: 2 } ^^ 3).v == 8)

    // X: extension operators, x = 6, x2 = 3
    var x  = X{ v: 6 }
    var x2 = X{ v: 3 }
    t += chk((-x).v == -6)
    t += chk((x - x2).v == 3)
    t += chk((x << 1).v == 12)
    t += chk(x > x2)                           // derived from extension <=>
    t += chk((++x).v == 7)
    t += chk((x--).v == 7)
    t += chk(x.v == 6)
    x += x2;  t += chk(x.v == 9)
    t += chk(9 in x)

    return t                                   // 68
}

// --- lit wiring -----------------------------------------------------------
// At the BOTTOM: the CHECK prefixes assert declaration text and the checks
// above are what the exit code counts.

// RUN: { %kairo %s --type-check-only --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-DAG: Full operator+(::all::Full o);
// CXX-DAG: Full operator+();
// CXX-DAG: Full operator~();
// CXX-DAG: bool operator!=(
// CXX-DAG: Ordering operator<=>(
// CXX-DAG: Full operator++();
// CXX-DAG: Full operator++(int);
// CXX-DAG: Full operator--();
// CXX-DAG: Full operator--(int);
// CXX-DAG: operator signed int();
// CXX-DAG: ~Full();
// CXX-DAG: __kairo_contains(
// CXX-DAG: __kairo_iter(
// CXX-DAG: __kairo_pow(
// CXX-DAG: __kairo_await(
// CXX-DAG: {{^ *}}signed int& operator[](
// CXX-DAG: const signed int& operator[]({{.*}}) const;
// CXX-DAG: signed int* operator->();
// CXX-DAG: void operator+=(::all::Compound o);
// CXX-DAG: void operator<<=(
// CXX-DAG: void operator>>=(
// CXX-DAG: X operator-(::all::X&);
// CXX-DAG: X operator-(::all::X&,
// CXX-DAG: X operator--(::all::X&, int);
// CXX-DAG: void operator+=(::all::X&,

// RUN: { %kairo %s --type-check-only --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=NOEXT
// NOEXT-NOT: __kairo_op_

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 68
