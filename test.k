macro foo! { 12 }

macro error!(msg) {
    compile_error!(msg)
}

fn (foo!)() -> u32 {
    error!("yes")
    return 12
}

macro square!(x) {
    x * x
}

macro quad!(x) {
    square!(square!(x))
}

fn main() -> quad!(3) {
    var a = square!(3)
    var b = quad!(2)
    return a + b
}