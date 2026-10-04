use xindex_core::checkpoint::{is_newer, is_recent, stall_start, stalled, Checkpoint};
use xindex_core::constants::SNAPSHOT_EXIT_DELAY;
fn main() {
    let now: i64 = 1_790_000_000; // Oct 2026
    let last = Checkpoint { block: 23_000_000, timestamp: (now - 600) as u64, state_root: [1; 32] };
    let forged = Checkpoint { block: 23_000_001, timestamp: 1u64 << 63, state_root: [2; 32] };
    println!("is_newer(forged) = {}", is_newer(&last, &forged, now));
    println!("is_recent(forged) = {}", is_recent(&forged, now));
    println!("stalled after advance = {}", stalled(forged.timestamp, now));
    let due = stall_start(forged.timestamp) + SNAPSHOT_EXIT_DELAY;
    println!("snapshot due = {} (now {}): begin_snapshot allowed = {}", due, now, now >= due);
    let honest_future = Checkpoint { block: 23_000_001, timestamp: (now + 10) as u64, state_root: [2; 32] };
    println!("is_newer(future, non-wrapping) = {}", is_newer(&last, &honest_future, now));
}
