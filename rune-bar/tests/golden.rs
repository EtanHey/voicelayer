use voicebar_rune::band::*;
include!("support/golden_dump.rs");
#[test]
fn incremental_matches_independent_61d019d2_golden() {
    let expected = include_str!("../docs/replays/band-golden.sha256");
    for name in REPLAYS {
        for reduced in [false, true] {
            let mut cursor = 0;
            let hash = dump(name, reduced, |s, t| {
                while cursor < s.replay.0.len() && s.replay.0[cursor]["t"].as_f64().unwrap() <= t {
                    let e = s.replay.0[cursor].clone();
                    s.apply(&e, e["t"].as_f64().unwrap());
                    cursor += 1;
                }
                s.advance(t);
            });
            let row = format!("{hash}  {name} reduced={reduced}");
            let suffix = format!("  {name} reduced={reduced}");
            let oracle = expected
                .lines()
                .find(|line| line.ends_with(&suffix))
                .unwrap();
            assert_eq!(
                row, oracle,
                "independent replay oracle: {name} reduced={reduced}"
            );
        }
    }
}
