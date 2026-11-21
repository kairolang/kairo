// The bytes each escape form decodes to, as lowering hands them to codegen:
// the one-letter escapes, octal with one to three digits, `\x` with exactly
// two hex digits, `\u` with four and `\U` with eight (each written as
// UTF-8, `\xff` and `\377` included), a raw segment copied as written, and
// adjacent segments joined with each segment's own raw-ness. The lengths
// after each literal are its bytes and its code points. A string pattern is
// decoded the same way.
fn take(const s: string) -> usize { return s.size() }
fn main() -> i32 {
    var n: usize = 0
    n += take("simple: \n\r\t\v\f\a\b")
    n += take("quotes: \' \" \\")
    n += take("octal: \0 \7 \12 \101 \377 \1019")
    n += take("hex: \x00 \x41 \x7f \xff \x4a4")
    n += take("u4: A é € ￿")
    n += take("u8: \U00000041 \U0001F600 \U0010FFFF")
    n += take(r"raw: \n \x41 \101 \\ end")
    n += take("utf8: é € 😀")
    n += take("chain: \x41" "\102" r"\n" "C")
    n += take(r"raw head \t" "cooked \t" r"raw \t")
    n += take("")
    n += take("" "tail\n")
    match "a\tb" {
        case "a\tb" { n += 1 }
        case "\x41" "\102" r"\n" { n += 2 }
        case r"\x41" { n += 3 }
        default { }
    }
    return (n % 251) as i32
}

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --print-ir -c -o /dev/null --emit-scope=inputs -A S025W | %FileCheck %s
// CHECK: __kairo_slit_t<16> __kairo_slit_15_{{[0-9a-f]+}} = {
// CHECK-NEXT: 15, {
// CHECK-NEXT: 115, 105, 109, 112, 108, 101, 58, 32, 10, 13, 9, 11, 12, 7, 8, 0
// CHECK: __kairo_slit_t<14> __kairo_slit_13_{{[0-9a-f]+}} = {
// CHECK-NEXT: 13, {
// CHECK-NEXT: 113, 117, 111, 116, 101, 115, 58, 32, 39, 32, 34, 32, 92, 0
// CHECK: __kairo_slit_t<21> __kairo_slit_20_{{[0-9a-f]+}} = {
// CHECK-NEXT: 19, {
// CHECK-NEXT: 111, 99, 116, 97, 108, 58, 32, 0, 32, 7, 32, 10, 32, 65, 32, 195, 191, 32, 65, 57, 0
// CHECK: __kairo_slit_t<17> __kairo_slit_16_{{[0-9a-f]+}} = {
// CHECK-NEXT: 15, {
// CHECK-NEXT: 104, 101, 120, 58, 32, 0, 32, 65, 32, 127, 32, 195, 191, 32, 74, 52, 0
// CHECK: __kairo_slit_t<17> __kairo_slit_16_{{[0-9a-f]+}} = {
// CHECK-NEXT: 11, {
// CHECK-NEXT: 117, 52, 58, 32, 65, 32, 195, 169, 32, 226, 130, 172, 32, 239, 191, 191, 0
// CHECK: __kairo_slit_t<16> __kairo_slit_15_{{[0-9a-f]+}} = {
// CHECK-NEXT: 9, {
// CHECK-NEXT: 117, 56, 58, 32, 65, 32, 240, 159, 152, 128, 32, 244, 143, 191, 191, 0
// CHECK: __kairo_slit_t<25> __kairo_slit_24_{{[0-9a-f]+}} = {
// CHECK-NEXT: 24, {
// CHECK-NEXT: 114, 97, 119, 58, 32, 92, 110, 32, 92, 120, 52, 49, 32, 92, 49, 48, 49, 32, 92, 92, 32, 101, 110, 100, 0
// CHECK: __kairo_slit_t<18> __kairo_slit_17_{{[0-9a-f]+}} = {
// CHECK-NEXT: 11, {
// CHECK-NEXT: 117, 116, 102, 56, 58, 32, 195, 169, 32, 226, 130, 172, 32, 240, 159, 152, 128, 0
// CHECK: __kairo_slit_t<13> __kairo_slit_12_{{[0-9a-f]+}} = {
// CHECK-NEXT: 12, {
// CHECK-NEXT: 99, 104, 97, 105, 110, 58, 32, 65, 66, 92, 110, 67, 0
// CHECK: __kairo_slit_t<26> __kairo_slit_25_{{[0-9a-f]+}} = {
// CHECK-NEXT: 25, {
// CHECK-NEXT: 114, 97, 119, 32, 104, 101, 97, 100, 32, 92, 116, 99, 111, 111, 107, 101, 100, 32, 9, 114, 97, 119, 32, 92, 116, 0
// CHECK: __kairo_slit_t<1> __kairo_slit_0_{{[0-9a-f]+}} = {
// CHECK-NEXT: 0, {
// CHECK-NEXT: 0
// CHECK: __kairo_slit_t<6> __kairo_slit_5_{{[0-9a-f]+}} = {
// CHECK-NEXT: 5, {
// CHECK-NEXT: 116, 97, 105, 108, 10, 0
// CHECK: __kairo_slit_t<4> __kairo_slit_3_{{[0-9a-f]+}} = {
// CHECK-NEXT: 3, {
// CHECK-NEXT: 97, 9, 98, 0
// CHECK: ("a\011b"), 3) == 0
// CHECK: ("AB\\n"), 4) == 0
// CHECK: ("\\x41"), 4) == 0
