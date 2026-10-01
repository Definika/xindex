use risc0_build::{embed_methods_with_options, GuestOptionsBuilder};
use std::collections::HashMap;

fn main() {
    // Methods built for Sepolia build the guest for Sepolia: the network's constants decide the image id.
    let features = if std::env::var_os("CARGO_FEATURE_SEPOLIA").is_some() {
        vec!["sepolia".to_string()]
    } else {
        Vec::new()
    };
    let options = GuestOptionsBuilder::default()
        .features(features)
        .build()
        .expect("guest options");
    embed_methods_with_options(HashMap::from([("xindex-p2-guest", options)]));
}
