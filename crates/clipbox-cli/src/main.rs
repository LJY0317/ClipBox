use std::env;

fn print_help() {
    println!("ClipBox");
    println!();
    println!("Foundation CLI. Download, sync, history, and adapter commands will be added incrementally.");
    println!();
    println!("Usage:");
    println!("  clipbox --version");
    println!("  clipbox help");
}

fn main() {
    let argument = env::args().nth(1);
    match argument.as_deref() {
        Some("--version" | "-V" | "version") => {
            println!("{} {}", clipbox_core::APP_NAME, env!("CARGO_PKG_VERSION"));
        }
        Some("help" | "--help" | "-h") | None => print_help(),
        Some(command) => {
            eprintln!("Unknown command: {command}");
            print_help();
            std::process::exit(2);
        }
    }
}
