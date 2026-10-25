use speakty::{app, identity, install};

const USAGE: &str = "Usage: speakty [command]

Without a command, starts Speakty, or opens Settings when it already runs.

Commands for the running Speakty:
  settings [pane]  Open Settings, on a pane such as transcript
  start            Start dictating
  stop             Stop and paste
  toggle           Start, or stop and paste
  cancel           Discard the dictation
  status           Print what Speakty is doing
  update           Check for an update, and install it at once
  quit             Quit Speakty

Commands that run on their own:
  install              Install this binary for the current user and restart the service
  install --rollback   Go back to the previous installed version
  version              Print the version";

fn main() -> std::process::ExitCode {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).format_timestamp(None).init();
    let arguments: Vec<String> = std::env::args().collect();
    let result = match arguments.get(1).map(String::as_str) {
        Some("install") if arguments.get(2).map(String::as_str) == Some("--rollback") => install::rollback().and_then(|version| {
            install::systemctl(&["restart", identity::SERVICE])?;
            println!("Rolled back to Speakty {version}.");
            Ok(())
        }),
        Some("install") => install::install_self(),
        Some("version" | "--version") => {
            println!("{} {}", identity::NAME, identity::VERSION);
            Ok(())
        }
        Some("help" | "--help" | "-h") => {
            println!("{USAGE}");
            Ok(())
        }
        _ => return std::process::ExitCode::from(u8::from(app::run(arguments))),
    };
    match result {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{error}");
            std::process::ExitCode::FAILURE
        }
    }
}
