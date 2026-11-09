// RUN: %kfmt --stdout %s | diff -u %S/Expected/blank_after_closer.k -
// RUN: %kfmt --check %S/Expected/blank_after_closer.k
//
// Rule 14.4 (decided 2026-11-08): after a line holding only closers
// (`}`, `)`, `]`, then at most a `;` or `,`) one blank line comes before the
// next statement, unless that line also starts with a closer. Statement
// level only: a `),` line inside a broken argument list gets none. Never
// more than one added, none if a blank line is there already, none at the
// end of a block or the file; a comment line after the closer gets it too.

fn main() -> i32 {
    kairo::Logger::set_dump_path(dump_directory_for_this_run, file_name_of_the_dump, opts);
    kairo::Logger::dump_to_file();
    outer(inner_call_with_a_long_name(first_argument_value, second_argument_value, third_one), last);
    if a {
        if b {
            g()
        }
    }
    // a comment line after a closer
    h()
    while c {
        step()
    }

    done()
    var xs = [first_element_value, second_element_value, third_element_value, fourth_value, fifth_value];
    return 0
}

fn tail() {
    if a {
        g()
    }
}
