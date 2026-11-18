pub class C { var y: i32 }

fn local() -> i32 {
    var c = C { y: 10 }
    return c.y
}
