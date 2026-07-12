macro tag! {
    compile_note!("TAG")
    "debug"
}

macro repeat!(m) {
    compile_note!("REPEAT")
    m! m!
}

var result = repeat!(tag)