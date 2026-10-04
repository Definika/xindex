//! Sections for SP1's cycle tracker, as `proofs/finality` marks its own: in the zkVM each mark is a line on standard
//! output, which SP1's executor adds up by label; natively the marks do nothing.

#[inline(always)]
pub fn start(_label: &str) {
    #[cfg(target_os = "zkvm")]
    println!("cycle-tracker-report-start: {_label}");
}

#[inline(always)]
pub fn end(_label: &str) {
    #[cfg(target_os = "zkvm")]
    println!("cycle-tracker-report-end: {_label}");
}
