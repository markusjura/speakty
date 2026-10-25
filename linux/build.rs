// The version Speakty reports and updates by: MARKETING_VERSION in ../Version.xcconfig, which the macOS
// app shares, or SPEAKTY_VERSION when set. scripts/package.sh sets it for builds between releases, such as
// 0.2.0+dev.gabc1234, which the 0.2.0 release doesn't replace but 0.2.1 does.
fn main() {
    println!("cargo:rerun-if-env-changed=SPEAKTY_VERSION");
    println!("cargo:rerun-if-changed=../Version.xcconfig");
    let version = std::env::var("SPEAKTY_VERSION").unwrap_or_else(|_| {
        let config = std::fs::read_to_string("../Version.xcconfig").expect("../Version.xcconfig");
        let line = config.lines().find_map(|line| line.strip_prefix("MARKETING_VERSION = ")).expect("MARKETING_VERSION");
        line.trim().to_string()
    });
    println!("cargo:rustc-env=SPEAKTY_VERSION={version}");
}
