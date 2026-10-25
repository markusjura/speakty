// The version Speakty reports and updates by. Release builds use Cargo.toml's; linux/scripts/package.sh
// sets SPEAKTY_VERSION for builds between releases, such as 0.1.0-dev.gabc1234, which sort below 0.1.0.
fn main() {
    println!("cargo:rerun-if-env-changed=SPEAKTY_VERSION");
    let version = std::env::var("SPEAKTY_VERSION").unwrap_or_else(|_| std::env::var("CARGO_PKG_VERSION").unwrap());
    println!("cargo:rustc-env=SPEAKTY_VERSION={version}");
}
