use sp1_build::{build_program_with_args, BuildArgs};

fn main() {
    // A host built for Sepolia embeds the program built for Sepolia: the network's constants decide the program's key.
    let features = if std::env::var_os("CARGO_FEATURE_SEPOLIA").is_some() {
        vec!["sepolia".to_string()]
    } else {
        Vec::new()
    };
    build_program_with_args(
        "../p1-program",
        BuildArgs {
            features,
            ..Default::default()
        },
    )
}
