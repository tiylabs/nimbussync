use std::{env, path::PathBuf, process::Command};

fn main() {
    let command = env::args().nth(1).unwrap_or_else(|| "help".into());
    match command.as_str() {
        "build-xcframework" => build_xcframework(),
        "help" => println!("usage: cargo xtask build-xcframework"),
        other => {
            eprintln!("unknown xtask command: {other}");
            std::process::exit(2);
        }
    }
}

fn build_xcframework() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .to_path_buf();
    let script = root.join("../Scripts/xtask/build-xcframework.sh");
    let status = Command::new("sh")
        .arg(script)
        .status()
        .expect("failed to run XCFramework builder");
    if !status.success() {
        std::process::exit(status.code().unwrap_or(1));
    }
}
