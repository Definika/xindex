// SPDX-License-Identifier: BUSL-1.1
//! The settlement arithmetic against the EVM's exact model: every vector of `test/vectors/settlement.json`, which
//! `test/WeightedMath.vectors.t.sol` replays against `src/WeightedMath.sol`, replayed here against `settlement.rs`, at
//! the EVM's share unit (1e18) and largest units (2^96 − 1). The program runs the same functions at its own share
//! unit, so a vector that holds here holds for the arithmetic the program settles with.

use ethnum::U256;
use serde_json::Value;
use xindex::settlement::{
    bar_at, oracle_tolerance_at, settlement, value_floor, Refusal, AUCTION_DURATION, WAD,
};

const EVM_SHARE_UNIT: u128 = WAD;
const UINT96_MAX: u128 = (1 << 96) - 1;
const EVM_MAX_UNITS: U256 = U256::from_words(0, UINT96_MAX);

fn file() -> Value {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../test/vectors/settlement.json"
    );
    serde_json::from_str(&std::fs::read_to_string(path).expect("the vectors")).expect("their JSON")
}

fn wide(v: &Value) -> U256 {
    U256::from_str_radix(&v.to_string(), 10).expect("a decimal")
}

fn u(v: &Value) -> u128 {
    v.to_string().parse().expect("a u128")
}

fn i(v: &Value) -> i128 {
    v.to_string().parse().expect("an i128")
}

fn list(v: &Value) -> Vec<U256> {
    v.as_array().expect("a list").iter().map(wide).collect()
}

fn narrow(v: &Value) -> Vec<u128> {
    v.as_array().expect("a list").iter().map(u).collect()
}

/// Seconds into the auction; a count past `u64` is past the auction as surely as `u64::MAX` is.
fn seconds(v: &Value) -> u64 {
    u64::try_from(u(v)).unwrap_or(u64::MAX)
}

fn weights(v: &Value) -> Vec<u16> {
    narrow(v).into_iter().map(|w| w as u16).collect()
}

/// Every settlement vector: the arithmetic settles or refuses exactly as the model says, with its bar, gain and
/// amounts, or its refusal and the refusal's fields.
#[test]
fn every_vector_settles_as_the_exact_model_says() {
    let json = file();
    let vectors = json["vectors"].as_array().unwrap();
    assert_eq!(vectors.len() as u128, u(&json["count"]));
    let mut met = [0usize; 7];
    for (k, v) in vectors.iter().enumerate() {
        let keep = U256::from_str_radix(&v["keepMask"].to_string(), 10).unwrap();
        let outcome = u(&v["outcome"]) as usize;
        met[outcome] += 1;
        let got = settlement(
            seconds(&v["elapsed"]),
            wide(&v["supply"]),
            u(&v["scale"]),
            &list(&v["units"]),
            &list(&v["newUnits"]),
            &weights(&v["weights"]),
            |leg| (keep >> leg as u32) & U256::ONE == U256::ONE,
            EVM_SHARE_UNIT,
            EVM_MAX_UNITS,
        );
        let at = format!("vector {k} ({})", v["kind"]);
        match outcome {
            0 => {
                let s =
                    got.unwrap_or_else(|e| panic!("{at}: refused {e:?} where the model settles"));
                assert_eq!(s.bar, u(&v["bar"]), "{at}: bar");
                assert_eq!(s.gain, i(&v["gain"]), "{at}: gain");
                let out: Vec<U256> = v["amountsOut"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(wide)
                    .collect();
                let inn: Vec<U256> = v["amountsIn"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(wide)
                    .collect();
                assert_eq!(s.amounts_out, out, "{at}: amounts out");
                assert_eq!(s.amounts_in, inn, "{at}: amounts in");
                assert_eq!(bar_at(seconds(&v["elapsed"])), Some(s.bar), "{at}: bar_at");
            }
            refused => {
                let want = match refused {
                    1 => Refusal::NothingToRebalance,
                    2 => Refusal::LegOutOfBounds {
                        leg: u(&v["badLeg"]) as usize,
                        next: wide(&v["badUnits"]),
                        lowest: wide(&v["lowest"]),
                        highest: wide(&v["highest"]),
                    },
                    3 => Refusal::UnitsOverflow {
                        next: wide(&v["badUnits"]),
                    },
                    4 => Refusal::GainBelowBar {
                        gain: i(&v["gain"]),
                        bar: u(&v["bar"]),
                    },
                    5 => Refusal::LengthMismatch,
                    6 => Refusal::AuctionOver,
                    other => panic!("{at}: outcome {other}"),
                };
                assert_eq!(got, Err(want), "{at}: refusal");
            }
        }
    }
    assert!(
        met.iter().all(|m| *m > 0),
        "the vectors reach every outcome: {met:?}"
    );
}

/// The quote's check: it holds where the model's quote holds, and where it does not, its value in and floor are the
/// model's, to the unit.
#[test]
fn every_quote_holds_or_fails_as_the_exact_model_says() {
    let json = file();
    let quotes = json["quotes"].as_array().unwrap();
    assert_eq!(quotes.len(), 77);
    let mut held = 0;
    for (k, q) in quotes.iter().enumerate() {
        let (units, next, prices) = (
            list(&q["units"]),
            list(&q["newUnits"]),
            narrow(&q["prices"]),
        );
        let moves = (0..units.len()).map(|i| (units[i], next[i], prices[i]));
        let (value_in, floor) = value_floor(moves, u(&q["tolerance"]));
        assert_eq!(value_in, wide(&q["valueIn"]), "quote {k}: value in");
        assert_eq!(floor, wide(&q["floor"]), "quote {k}: floor");
        assert_eq!(value_in >= floor, u(&q["holds"]) == 1, "quote {k}: holds");
        held += (value_in >= floor) as usize;
    }
    assert!(held >= 15 && quotes.len() - held >= 15);
}

/// Pyth's check and its tolerance: where the model's floor holds the check holds, under it the value in and floor
/// are the model's, and past the auction there is no tolerance.
#[test]
fn every_oracle_check_holds_or_fails_as_the_exact_model_says() {
    let json = file();
    let oracles = json["oracles"].as_array().unwrap();
    assert_eq!(oracles.len(), 85);
    let mut met = [0usize; 3];
    for (k, o) in oracles.iter().enumerate() {
        let outcome = u(&o["outcome"]) as usize;
        met[outcome] += 1;
        let elapsed = seconds(&o["elapsed"]);
        if outcome == 2 {
            assert!(elapsed > AUCTION_DURATION, "oracle {k}");
            assert_eq!(oracle_tolerance_at(elapsed), None, "oracle {k}");
            continue;
        }
        let tolerance = oracle_tolerance_at(elapsed).unwrap();
        assert_eq!(tolerance, u(&o["tolerance"]), "oracle {k}: tolerance");
        let (units, next, values) = (
            list(&o["units"]),
            list(&o["newUnits"]),
            narrow(&o["values"]),
        );
        let moves = (0..units.len()).map(|i| (units[i], next[i], values[i]));
        let (value_in, floor) = value_floor(moves, tolerance);
        assert_eq!(value_in, wide(&o["valueIn"]), "oracle {k}: value in");
        assert_eq!(floor, wide(&o["floor"]), "oracle {k}: floor");
        assert_eq!(value_in >= floor, outcome == 0, "oracle {k}: holds");
    }
    assert!(met[0] >= 15 && met[1] >= 15 && met[2] >= 3, "{met:?}");
}
