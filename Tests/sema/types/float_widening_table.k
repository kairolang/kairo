// Implicit float widening is read off the float formats (conversion-lattice.mdx
// R4): S converts to T without `as` when every value of S is a value of T (T
// has at least S's exponent and mantissa bits, and an infinity when S has
// one) and T is at most 64 bits wide (R5). So `f8e4m3` and `f8e5m2` widen
// into `f16`, `bf16`, `f32` and `f64`; `f16` and `bf16`, 16 bits each, into
// `f32` and `f64` but never into each other; and nothing widens into an f8
// format or into `f128` and wider. One function per ordered pair of the
// float types every target has: the pairs that widen are clean, every other
// pair is SC028E. Under -fno-implicit-conv (NOCONV) every pair is.

fn f8e4m3_to_f8e5m2(x: f8e4m3) -> f8e5m2 { return x }
fn f8e4m3_to_f16(x: f8e4m3) -> f16 { return x }
fn f8e4m3_to_bf16(x: f8e4m3) -> bf16 { return x }
fn f8e4m3_to_f32(x: f8e4m3) -> f32 { return x }
fn f8e4m3_to_f64(x: f8e4m3) -> f64 { return x }
fn f8e4m3_to_f128(x: f8e4m3) -> f128 { return x }
fn f8e4m3_to_f256(x: f8e4m3) -> f256 { return x }
fn f8e4m3_to_f512(x: f8e4m3) -> f512 { return x }

fn f8e5m2_to_f8e4m3(x: f8e5m2) -> f8e4m3 { return x }
fn f8e5m2_to_f16(x: f8e5m2) -> f16 { return x }
fn f8e5m2_to_bf16(x: f8e5m2) -> bf16 { return x }
fn f8e5m2_to_f32(x: f8e5m2) -> f32 { return x }
fn f8e5m2_to_f64(x: f8e5m2) -> f64 { return x }
fn f8e5m2_to_f128(x: f8e5m2) -> f128 { return x }
fn f8e5m2_to_f256(x: f8e5m2) -> f256 { return x }
fn f8e5m2_to_f512(x: f8e5m2) -> f512 { return x }

fn f16_to_f8e4m3(x: f16) -> f8e4m3 { return x }
fn f16_to_f8e5m2(x: f16) -> f8e5m2 { return x }
fn f16_to_bf16(x: f16) -> bf16 { return x }
fn f16_to_f32(x: f16) -> f32 { return x }
fn f16_to_f64(x: f16) -> f64 { return x }
fn f16_to_f128(x: f16) -> f128 { return x }
fn f16_to_f256(x: f16) -> f256 { return x }
fn f16_to_f512(x: f16) -> f512 { return x }

fn bf16_to_f8e4m3(x: bf16) -> f8e4m3 { return x }
fn bf16_to_f8e5m2(x: bf16) -> f8e5m2 { return x }
fn bf16_to_f16(x: bf16) -> f16 { return x }
fn bf16_to_f32(x: bf16) -> f32 { return x }
fn bf16_to_f64(x: bf16) -> f64 { return x }
fn bf16_to_f128(x: bf16) -> f128 { return x }
fn bf16_to_f256(x: bf16) -> f256 { return x }
fn bf16_to_f512(x: bf16) -> f512 { return x }

fn f32_to_f8e4m3(x: f32) -> f8e4m3 { return x }
fn f32_to_f8e5m2(x: f32) -> f8e5m2 { return x }
fn f32_to_f16(x: f32) -> f16 { return x }
fn f32_to_bf16(x: f32) -> bf16 { return x }
fn f32_to_f64(x: f32) -> f64 { return x }
fn f32_to_f128(x: f32) -> f128 { return x }
fn f32_to_f256(x: f32) -> f256 { return x }
fn f32_to_f512(x: f32) -> f512 { return x }

fn f64_to_f8e4m3(x: f64) -> f8e4m3 { return x }
fn f64_to_f8e5m2(x: f64) -> f8e5m2 { return x }
fn f64_to_f16(x: f64) -> f16 { return x }
fn f64_to_bf16(x: f64) -> bf16 { return x }
fn f64_to_f32(x: f64) -> f32 { return x }
fn f64_to_f128(x: f64) -> f128 { return x }
fn f64_to_f256(x: f64) -> f256 { return x }
fn f64_to_f512(x: f64) -> f512 { return x }

fn f128_to_f8e4m3(x: f128) -> f8e4m3 { return x }
fn f128_to_f8e5m2(x: f128) -> f8e5m2 { return x }
fn f128_to_f16(x: f128) -> f16 { return x }
fn f128_to_bf16(x: f128) -> bf16 { return x }
fn f128_to_f32(x: f128) -> f32 { return x }
fn f128_to_f64(x: f128) -> f64 { return x }
fn f128_to_f256(x: f128) -> f256 { return x }
fn f128_to_f512(x: f128) -> f512 { return x }

fn f256_to_f8e4m3(x: f256) -> f8e4m3 { return x }
fn f256_to_f8e5m2(x: f256) -> f8e5m2 { return x }
fn f256_to_f16(x: f256) -> f16 { return x }
fn f256_to_bf16(x: f256) -> bf16 { return x }
fn f256_to_f32(x: f256) -> f32 { return x }
fn f256_to_f64(x: f256) -> f64 { return x }
fn f256_to_f128(x: f256) -> f128 { return x }
fn f256_to_f512(x: f256) -> f512 { return x }

fn f512_to_f8e4m3(x: f512) -> f8e4m3 { return x }
fn f512_to_f8e5m2(x: f512) -> f8e5m2 { return x }
fn f512_to_f16(x: f512) -> f16 { return x }
fn f512_to_bf16(x: f512) -> bf16 { return x }
fn f512_to_f32(x: f512) -> f32 { return x }
fn f512_to_f64(x: f512) -> f64 { return x }
fn f512_to_f128(x: f512) -> f128 { return x }
fn f512_to_f256(x: f512) -> f256 { return x }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --cmax-errors=200 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// RUN: { %kairo %s --type-check-only --cmax-errors=200 -fno-implicit-conv 2>&1 || true; } | %FileCheck %s --check-prefix=NOCONV --implicit-check-not="error ["
// CHECK: {{.*}}float_widening_table.k:11:51: error [SC028E]: cannot convert 'f8e4m3' to 'f8e5m2'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:16:47: error [SC028E]: cannot convert 'f8e4m3' to 'f128'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:17:47: error [SC028E]: cannot convert 'f8e4m3' to 'f256'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:18:47: error [SC028E]: cannot convert 'f8e4m3' to 'f512'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:20:51: error [SC028E]: cannot convert 'f8e5m2' to 'f8e4m3'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:25:47: error [SC028E]: cannot convert 'f8e5m2' to 'f128'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:26:47: error [SC028E]: cannot convert 'f8e5m2' to 'f256'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:27:47: error [SC028E]: cannot convert 'f8e5m2' to 'f512'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:29:45: error [SC028E]: cannot convert 'f16' to 'f8e4m3'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:30:45: error [SC028E]: cannot convert 'f16' to 'f8e5m2'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:31:41: error [SC028E]: cannot convert 'f16' to 'bf16'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:34:41: error [SC028E]: cannot convert 'f16' to 'f128'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:35:41: error [SC028E]: cannot convert 'f16' to 'f256'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:36:41: error [SC028E]: cannot convert 'f16' to 'f512'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:38:47: error [SC028E]: cannot convert 'bf16' to 'f8e4m3'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:39:47: error [SC028E]: cannot convert 'bf16' to 'f8e5m2'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:40:41: error [SC028E]: cannot convert 'bf16' to 'f16'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:43:43: error [SC028E]: cannot convert 'bf16' to 'f128'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:44:43: error [SC028E]: cannot convert 'bf16' to 'f256'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:45:43: error [SC028E]: cannot convert 'bf16' to 'f512'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:47:45: error [SC028E]: cannot convert 'f32' to 'f8e4m3'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:48:45: error [SC028E]: cannot convert 'f32' to 'f8e5m2'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:49:39: error [SC028E]: cannot convert 'f32' to 'f16'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:50:41: error [SC028E]: cannot convert 'f32' to 'bf16'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:52:41: error [SC028E]: cannot convert 'f32' to 'f128'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:53:41: error [SC028E]: cannot convert 'f32' to 'f256'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:54:41: error [SC028E]: cannot convert 'f32' to 'f512'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:56:45: error [SC028E]: cannot convert 'f64' to 'f8e4m3'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:57:45: error [SC028E]: cannot convert 'f64' to 'f8e5m2'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:58:39: error [SC028E]: cannot convert 'f64' to 'f16'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:59:41: error [SC028E]: cannot convert 'f64' to 'bf16'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:60:39: error [SC028E]: cannot convert 'f64' to 'f32'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:61:41: error [SC028E]: cannot convert 'f64' to 'f128'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:62:41: error [SC028E]: cannot convert 'f64' to 'f256'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:63:41: error [SC028E]: cannot convert 'f64' to 'f512'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:65:47: error [SC028E]: cannot convert 'f128' to 'f8e4m3'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:66:47: error [SC028E]: cannot convert 'f128' to 'f8e5m2'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:67:41: error [SC028E]: cannot convert 'f128' to 'f16'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:68:43: error [SC028E]: cannot convert 'f128' to 'bf16'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:69:41: error [SC028E]: cannot convert 'f128' to 'f32'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:70:41: error [SC028E]: cannot convert 'f128' to 'f64'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:71:43: error [SC028E]: cannot convert 'f128' to 'f256'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:72:43: error [SC028E]: cannot convert 'f128' to 'f512'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:74:47: error [SC028E]: cannot convert 'f256' to 'f8e4m3'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:75:47: error [SC028E]: cannot convert 'f256' to 'f8e5m2'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:76:41: error [SC028E]: cannot convert 'f256' to 'f16'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:77:43: error [SC028E]: cannot convert 'f256' to 'bf16'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:78:41: error [SC028E]: cannot convert 'f256' to 'f32'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:79:41: error [SC028E]: cannot convert 'f256' to 'f64'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:80:43: error [SC028E]: cannot convert 'f256' to 'f128'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:81:43: error [SC028E]: cannot convert 'f256' to 'f512'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:83:47: error [SC028E]: cannot convert 'f512' to 'f8e4m3'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:84:47: error [SC028E]: cannot convert 'f512' to 'f8e5m2'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:85:41: error [SC028E]: cannot convert 'f512' to 'f16'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:86:43: error [SC028E]: cannot convert 'f512' to 'bf16'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:87:41: error [SC028E]: cannot convert 'f512' to 'f32'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:88:41: error [SC028E]: cannot convert 'f512' to 'f64'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:89:43: error [SC028E]: cannot convert 'f512' to 'f128'; the conversion may lose value and needs an explicit 'as'
// CHECK: {{.*}}float_widening_table.k:90:43: error [SC028E]: cannot convert 'f512' to 'f256'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:11:51: error [SC028E]: cannot convert 'f8e4m3' to 'f8e5m2'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:12:45: error [SC028E]: cannot convert 'f8e4m3' to 'f16'; implicit conversions are disabled (-fno-implicit-conv), write 'as'
// NOCONV: {{.*}}float_widening_table.k:13:47: error [SC028E]: cannot convert 'f8e4m3' to 'bf16'; implicit conversions are disabled (-fno-implicit-conv), write 'as'
// NOCONV: {{.*}}float_widening_table.k:14:45: error [SC028E]: cannot convert 'f8e4m3' to 'f32'; implicit conversions are disabled (-fno-implicit-conv), write 'as'
// NOCONV: {{.*}}float_widening_table.k:15:45: error [SC028E]: cannot convert 'f8e4m3' to 'f64'; implicit conversions are disabled (-fno-implicit-conv), write 'as'
// NOCONV: {{.*}}float_widening_table.k:16:47: error [SC028E]: cannot convert 'f8e4m3' to 'f128'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:17:47: error [SC028E]: cannot convert 'f8e4m3' to 'f256'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:18:47: error [SC028E]: cannot convert 'f8e4m3' to 'f512'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:20:51: error [SC028E]: cannot convert 'f8e5m2' to 'f8e4m3'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:21:45: error [SC028E]: cannot convert 'f8e5m2' to 'f16'; implicit conversions are disabled (-fno-implicit-conv), write 'as'
// NOCONV: {{.*}}float_widening_table.k:22:47: error [SC028E]: cannot convert 'f8e5m2' to 'bf16'; implicit conversions are disabled (-fno-implicit-conv), write 'as'
// NOCONV: {{.*}}float_widening_table.k:23:45: error [SC028E]: cannot convert 'f8e5m2' to 'f32'; implicit conversions are disabled (-fno-implicit-conv), write 'as'
// NOCONV: {{.*}}float_widening_table.k:24:45: error [SC028E]: cannot convert 'f8e5m2' to 'f64'; implicit conversions are disabled (-fno-implicit-conv), write 'as'
// NOCONV: {{.*}}float_widening_table.k:25:47: error [SC028E]: cannot convert 'f8e5m2' to 'f128'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:26:47: error [SC028E]: cannot convert 'f8e5m2' to 'f256'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:27:47: error [SC028E]: cannot convert 'f8e5m2' to 'f512'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:29:45: error [SC028E]: cannot convert 'f16' to 'f8e4m3'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:30:45: error [SC028E]: cannot convert 'f16' to 'f8e5m2'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:31:41: error [SC028E]: cannot convert 'f16' to 'bf16'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:32:39: error [SC028E]: cannot convert 'f16' to 'f32'; implicit conversions are disabled (-fno-implicit-conv), write 'as'
// NOCONV: {{.*}}float_widening_table.k:33:39: error [SC028E]: cannot convert 'f16' to 'f64'; implicit conversions are disabled (-fno-implicit-conv), write 'as'
// NOCONV: {{.*}}float_widening_table.k:34:41: error [SC028E]: cannot convert 'f16' to 'f128'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:35:41: error [SC028E]: cannot convert 'f16' to 'f256'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:36:41: error [SC028E]: cannot convert 'f16' to 'f512'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:38:47: error [SC028E]: cannot convert 'bf16' to 'f8e4m3'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:39:47: error [SC028E]: cannot convert 'bf16' to 'f8e5m2'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:40:41: error [SC028E]: cannot convert 'bf16' to 'f16'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:41:41: error [SC028E]: cannot convert 'bf16' to 'f32'; implicit conversions are disabled (-fno-implicit-conv), write 'as'
// NOCONV: {{.*}}float_widening_table.k:42:41: error [SC028E]: cannot convert 'bf16' to 'f64'; implicit conversions are disabled (-fno-implicit-conv), write 'as'
// NOCONV: {{.*}}float_widening_table.k:43:43: error [SC028E]: cannot convert 'bf16' to 'f128'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:44:43: error [SC028E]: cannot convert 'bf16' to 'f256'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:45:43: error [SC028E]: cannot convert 'bf16' to 'f512'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:47:45: error [SC028E]: cannot convert 'f32' to 'f8e4m3'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:48:45: error [SC028E]: cannot convert 'f32' to 'f8e5m2'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:49:39: error [SC028E]: cannot convert 'f32' to 'f16'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:50:41: error [SC028E]: cannot convert 'f32' to 'bf16'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:51:39: error [SC028E]: cannot convert 'f32' to 'f64'; implicit conversions are disabled (-fno-implicit-conv), write 'as'
// NOCONV: {{.*}}float_widening_table.k:52:41: error [SC028E]: cannot convert 'f32' to 'f128'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:53:41: error [SC028E]: cannot convert 'f32' to 'f256'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:54:41: error [SC028E]: cannot convert 'f32' to 'f512'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:56:45: error [SC028E]: cannot convert 'f64' to 'f8e4m3'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:57:45: error [SC028E]: cannot convert 'f64' to 'f8e5m2'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:58:39: error [SC028E]: cannot convert 'f64' to 'f16'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:59:41: error [SC028E]: cannot convert 'f64' to 'bf16'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:60:39: error [SC028E]: cannot convert 'f64' to 'f32'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:61:41: error [SC028E]: cannot convert 'f64' to 'f128'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:62:41: error [SC028E]: cannot convert 'f64' to 'f256'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:63:41: error [SC028E]: cannot convert 'f64' to 'f512'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:65:47: error [SC028E]: cannot convert 'f128' to 'f8e4m3'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:66:47: error [SC028E]: cannot convert 'f128' to 'f8e5m2'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:67:41: error [SC028E]: cannot convert 'f128' to 'f16'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:68:43: error [SC028E]: cannot convert 'f128' to 'bf16'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:69:41: error [SC028E]: cannot convert 'f128' to 'f32'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:70:41: error [SC028E]: cannot convert 'f128' to 'f64'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:71:43: error [SC028E]: cannot convert 'f128' to 'f256'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:72:43: error [SC028E]: cannot convert 'f128' to 'f512'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:74:47: error [SC028E]: cannot convert 'f256' to 'f8e4m3'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:75:47: error [SC028E]: cannot convert 'f256' to 'f8e5m2'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:76:41: error [SC028E]: cannot convert 'f256' to 'f16'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:77:43: error [SC028E]: cannot convert 'f256' to 'bf16'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:78:41: error [SC028E]: cannot convert 'f256' to 'f32'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:79:41: error [SC028E]: cannot convert 'f256' to 'f64'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:80:43: error [SC028E]: cannot convert 'f256' to 'f128'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:81:43: error [SC028E]: cannot convert 'f256' to 'f512'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:83:47: error [SC028E]: cannot convert 'f512' to 'f8e4m3'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:84:47: error [SC028E]: cannot convert 'f512' to 'f8e5m2'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:85:41: error [SC028E]: cannot convert 'f512' to 'f16'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:86:43: error [SC028E]: cannot convert 'f512' to 'bf16'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:87:41: error [SC028E]: cannot convert 'f512' to 'f32'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:88:41: error [SC028E]: cannot convert 'f512' to 'f64'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:89:43: error [SC028E]: cannot convert 'f512' to 'f128'; the conversion may lose value and needs an explicit 'as'
// NOCONV: {{.*}}float_widening_table.k:90:43: error [SC028E]: cannot convert 'f512' to 'f256'; the conversion may lose value and needs an explicit 'as'
