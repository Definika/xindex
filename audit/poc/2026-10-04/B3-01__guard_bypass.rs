// Mirrors stellar/contracts/xindex-vault/src/messages.rs:487-505 (guard on the full u32, dispatch on `kind as u8`).
const CAP_UPDATE: u8 = 5;
const FREEZER_CHANGE: u8 = 7;
const VERIFIER_ROTATION: u8 = 8;
#[derive(Debug, PartialEq)]
enum Slot { Cap, Freezer, Rotation, None }
fn guard_allows_cancel(kind: u32) -> bool { kind != FREEZER_CHANGE as u32 }   // messages.rs:490
fn pending(kind: u32) -> Slot {                                                // messages.rs:498-504
    match kind as u8 { CAP_UPDATE => Slot::Cap, FREEZER_CHANGE => Slot::Freezer, VERIFIER_ROTATION => Slot::Rotation, _ => Slot::None }
}
fn main() {
    for kind in [7u32, 263, 519, 5, 8] {
        let slot = pending(kind);
        println!("cancel_change({kind:>3}): guard passes = {:5}  resolves to {:?}", guard_allows_cancel(kind), slot);
    }
    assert!(guard_allows_cancel(263) && pending(263) == Slot::Freezer);
    println!("CONFIRMED: kind=263 passes the 'never its own replacement' guard and resolves to the freezer's pending change");
}
