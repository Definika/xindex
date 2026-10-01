//! Sections for SP1's cycle tracker. In the zkVM each mark is a line on standard output, which SP1's executor reads and
//! adds up by label in its report; natively the marks do nothing. They cost a few thousand instructions each, so they
//! mark whole steps and aggregates, never single validators.

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
