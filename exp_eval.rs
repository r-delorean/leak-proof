//! Experimental offline evaluator (NOT part of the original repo).
//!
//! 1. Replays the official test-data.json under several configs, FP/FN vs
//!    `expected_approved`, plus a cross-tab of what the hand-tuned
//!    `is_risky_pattern` table rescues.
//! 2. Held-out generalization: perturbs the test queries into nearby unseen
//!    transactions, computes EXACT ground truth (all-cells probe), and checks
//!    whether the table still helps on data it was not tuned on.
//!
//! Usage: exp_eval <index.bin> <test-data.json>

use rand::rngs::StdRng;
use rand::{Rng, SeedableRng};
use rinha::index::{IvfIndex, QueryOptions, RepairMode};
use rinha::{parser, vectorizer, THRESHOLD};
use serde_json::Value;
use std::fs;

/// Pure N-probe, escalation fully disabled: Bbox keeps adaptive_probe == probe,
/// repair_min > repair_max makes is_ambiguous always false.
fn no_escalation(nprobe: usize) -> QueryOptions {
    let mut o = QueryOptions::new(nprobe);
    o.repair_mode = RepairMode::Bbox;
    o.repair_min = 1;
    o.repair_max = 0;
    o
}

fn approved_under(index: &IvfIndex, v: &[f32; 16], opts: QueryOptions) -> bool {
    index.query_with_options(v, opts).1 < THRESHOLD
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: exp_eval <index.bin> <test-data.json>");
        std::process::exit(2);
    }
    let idx_bytes = fs::read(&args[1]).expect("read index");
    let index = IvfIndex::from_bytes(&idx_bytes).expect("parse index");
    let nc = index.num_centroids;
    eprintln!("[exp] index: {} vectors, {} centroids", index.num_vectors, nc);

    let raw = fs::read(&args[2]).expect("read test-data");
    let v: Value = serde_json::from_slice(&raw).expect("json");
    let entries = v["entries"].as_array().expect("entries");

    let mut queries: Vec<([f32; 16], bool)> = Vec::with_capacity(entries.len());
    for e in entries {
        let body = serde_json::to_vec(&e["request"]).unwrap();
        let expected = e["expected_approved"].as_bool().unwrap();
        let p = parser::parse(&body).expect("parse payload");
        queries.push((vectorizer::vectorize(&p), expected));
    }
    eprintln!("[exp] {} queries\n", queries.len());

    // ---- Part 1: per-config FP/FN vs expected_approved on the real test set ----
    let configs: [(&str, QueryOptions); 4] = [
        ("A  nprobe=10  Pattern (PRODUCTION)", QueryOptions::new(10)),
        ("B  nprobe=10  no-escalation", no_escalation(10)),
        ("C  nprobe=48  no-escalation", no_escalation(48)),
        ("D  nprobe=64  no-escalation", no_escalation(64)),
    ];
    println!("== test-data.json (vs expected_approved) ==");
    println!("config                                FP    FN   fails");
    for (name, opts) in configs.iter() {
        let (mut fp, mut fn_) = (0u64, 0u64);
        for (vec, expected) in &queries {
            let approved = approved_under(&index, vec, *opts);
            if approved != *expected {
                if approved { fn_ += 1; } else { fp += 1; }
            }
        }
        println!("{:<36} {:<5} {:<5} {}", name, fp, fn_, fp + fn_);
    }

    // ---- Part 2: validate EXACT (all-cells) == expected_approved ----
    let exact = no_escalation(nc); // probe every cell => brute force => exact KNN
    let mut exact_mismatch = 0u64;
    for (vec, expected) in &queries {
        if approved_under(&index, vec, exact) != *expected {
            exact_mismatch += 1;
        }
    }
    println!(
        "\nEXACT (all {} cells) vs expected_approved mismatches: {}  (confirms spec == exact KNN)",
        nc, exact_mismatch
    );

    // ---- Part 3: held-out generalization ----
    // Perturb each test query into a nearby UNSEEN transaction, take EXACT as
    // ground truth, and ask: does the hand-tuned table still help?
    let a = QueryOptions::new(10);
    let b = no_escalation(10);
    let eps = 0.03f32;
    let mut rng = StdRng::seed_from_u64(1);
    let (mut a_fail, mut b_fail, mut fires, mut rescued, mut broke) = (0u64, 0u64, 0u64, 0u64, 0u64);
    for (vec, _expected) in &queries {
        let mut p = *vec;
        for d in 0..14 {
            if p[d] >= 0.0 {
                // skip the -1 "no last transaction" sentinels
                p[d] = (p[d] + rng.gen_range(-eps..eps)).clamp(0.0, 1.0);
            }
        }
        let truth = approved_under(&index, &p, exact);
        let app_a = approved_under(&index, &p, a);
        let app_b = approved_under(&index, &p, b);
        if app_a != app_b { fires += 1; }
        if app_a != truth { a_fail += 1; }
        if app_b != truth { b_fail += 1; }
        match (app_a == truth, app_b == truth) {
            (true, false) => rescued += 1,
            (false, true) => broke += 1,
            _ => {}
        }
    }
    println!("\n== held-out (perturbed, unseen) vs EXACT ground truth ==");
    println!("queries                 : {}", queries.len());
    println!("B pure-10 failures      : {}", b_fail);
    println!("A table   failures      : {}", a_fail);
    println!("table fires (A != B)    : {}", fires);
    println!("rescued (B wrong->A ok) : {}", rescued);
    println!("broke   (B ok->A wrong) : {}", broke);
}
