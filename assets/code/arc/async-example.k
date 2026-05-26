import std::future::{Future};

async fn fetch_data() -> string {
    std::sleep(2000); // Simulate a long-running task
    return 1..10;
}

fn main() {
    var future: Future = spawn fetch_data(); // start a os-manged child process
    var data = await future;
    
    for i in data:
        print(f"{i=}", end=", ");

    print();
}