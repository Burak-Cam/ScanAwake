/// FIX-04 / D-07: the camera/vibration restart cooldown after a RESTART
/// dismiss. Safe-side 2.5s value (RLS-05) — pinned by cooldown_value_test.dart.
const int kCameraRestartCooldownMs = 2500;

/// D-01: the maximum number of dismissal barcodes a user may register
/// (CLAUDE.md "barcode CRUD max 3"). Both `_HomeScreenState` barcode guards
/// (length >= [kMaxBarcodes] / length < [kMaxBarcodes]) reference this.
const int kMaxBarcodes = 3;

/// MIS-01 / D-03: the average-luminance threshold (avg-Y on a 0..255 scale)
/// a camera frame must reach to count as "bright enough" for the Lümen
/// mission. Device-calibrated on the Redmi Note 9S (Plan 03 checkpoint): with
/// AUTO-exposure the frame average is pinned to ~mid-gray (~110) no matter how
/// bright the scene, so LumenMission now LOCKS exposure (see lumen_mission.dart)
/// to make the average track real brightness. With exposure locked, 140 sits
/// above the locked ambient baseline so the user must point at a genuinely
/// bright light. Pinned by lumen_hold_test.dart so a regression is caught.
const double kLumenThreshold = 140;

/// MIS-01 / D-02: how long (ms) average luminance must be SUSTAINED at/above
/// [kLumenThreshold] to complete the Lümen mission (~2-3s sustained, NOT
/// cumulative — any drop resets). [ASSUMED] starting value, device-calibrated
/// in Plan 03. Pinned by lumen_hold_test.dart.
const int kLumenHoldMs = 2500;

/// MIS-01 / D-02: pure sustained-hold accumulator. Adds [dtMs] to [heldMs] when
/// the frame's [avgY] is at/above [kLumenThreshold]; otherwise RESETS to 0 (a
/// single below-threshold frame wipes progress — sustained, not cumulative).
int accumulateHold(int heldMs, double avgY, int dtMs) =>
    avgY >= kLumenThreshold ? heldMs + dtMs : 0;

/// MIS-01 / D-02: the Lümen mission is complete once accumulated [heldMs]
/// reaches [kLumenHoldMs].
bool lumenComplete(int heldMs) => heldMs >= kLumenHoldMs;

/// MIS-02 [ASSUMED]: hue match tolerance in degrees (±20°). A sampled frame's
/// hue must be within this circular distance of the target hue to count as a
/// match. Device-calibrated under SC-4 (Plan 02 checkpoint); pinned by
/// color_match_test.dart so calibration is a one-line const change + test
/// update (the Lümen [kLumenThreshold] precedent).
const double kColorHueTolerance = 26;

/// MIS-02: minimum saturation (0..1) a frame must have. SC-4 device calibration
/// found this is the LOAD-BEARING discriminator that rejects EARTH TONES
/// (brown/wood/skin) — they are dull (low-sat) versions of red/orange whose hue
/// sits within tolerance. Measured on the Redmi Note 9S: light brown reads
/// S≈0.40-0.41 while genuine red S≈0.52 and (even a dark) green S≈0.57; 0.46
/// cleanly separates them. (Earlier attempts to gate on VALUE failed because a
/// dark-but-saturated real green reads V≈0.22 — lower than brown's V≈0.37 — so
/// value cannot separate them; saturation can.) Pinned by color_match_test.dart.
const double kColorMinSat = 0.46;

/// MIS-02: minimum value/brightness (0..1) — now only rejects near-BLACK frames
/// where hue is unstable. SC-4: kept LOW (0.15) so dark-but-saturated real
/// objects pass (a petrol/dark green reads V≈0.21-0.22 on the Redmi Note 9S);
/// earth-tone rejection is handled by [kColorMinSat], NOT by value. Pinned by
/// color_match_test.dart.
const double kColorMinVal = 0.15;

/// MIS-02 [ASSUMED]: how long (ms) a matching frame must be SUSTAINED to
/// complete the color mission (~1s, NOT cumulative — any non-matching frame
/// resets). Device-calibrated under SC-4; pinned by color_match_test.dart.
const int kColorHoldMs = 1000;

/// MIS-02: the 6 target hues (degrees) — red 0, orange 30, yellow 60, green
/// 120, blue 220, purple 280. Spaced ~60° apart so the ±[kColorHueTolerance]
/// windows of the green/blue/purple trio never overlap; the warm trio
/// (red/orange/yellow) abuts at the boundary (acceptable — the slot picks ONE
/// target, so a sample only needs to be within tolerance of THAT target).
/// Achromatic colors are excluded by decision. Pinned by color_match_test.dart.
const List<double> kColorPaletteHues = [0, 30, 60, 120, 220, 280];

/// MIS-02: minimal circular hue distance on the 0..360 circle (handles the
/// 0/360 wraparound — e.g. red at 0° vs 350° is 10°, not 350°).
double hueDistance(double a, double b) {
  final d = (a - b).abs() % 360;
  return d > 180 ? 360 - d : d;
}

/// MIS-02: a single frame matches [targetHue] iff it is within
/// [kColorHueTolerance] degrees AND colorful enough ([kColorMinSat]) AND bright
/// enough ([kColorMinVal]) for the hue to be trustworthy.
bool hsvMatches(double h, double s, double v, double targetHue) =>
    s >= kColorMinSat &&
    v >= kColorMinVal &&
    hueDistance(h, targetHue) <= kColorHueTolerance;

/// MIS-02 / D-02 analog: pure sustained-hold accumulator (NOT cumulative). Adds
/// [dtMs] to [heldMs] while the frame matches [targetHue]; a single
/// non-matching frame RESETS to 0 (mirrors [accumulateHold]).
int accumulateColorHold(
        int heldMs, double h, double s, double v, double targetHue, int dtMs) =>
    hsvMatches(h, s, v, targetHue) ? heldMs + dtMs : 0;

/// MIS-02: the color mission is complete once accumulated [heldMs] reaches
/// [kColorHoldMs].
bool colorComplete(int heldMs) => heldMs >= kColorHoldMs;

/// MIS-03 [ASSUMED]: minimum ML Kit label confidence (0..1) for a label to count
/// as a match. Device-calibrated under SC-4 (Plan 02 checkpoint); pinned by
/// object_match_test.dart so calibration is a one-line const change + test
/// update (the Lümen [kLumenThreshold] / Renk [kColorMinSat] precedent).
const double kObjectConfidence = 0.70;

/// MIS-03 [ASSUMED]: how long (ms) a matching detection must be SUSTAINED to
/// complete the object mission (~0.8-1s, NOT cumulative — a non-matching
/// throttled tick RESETS to 0). Kept `>= 2 * kObjectThrottleMs` so at least two
/// independent throttled detections are always required (noise robustness — a
/// single false-positive label can never complete the mission). Device-calibrated
/// under SC-4; pinned by object_match_test.dart.
const int kObjectHoldMs = 1000;

/// MIS-03 [ASSUMED]: minimum gap (ms) between ML Kit inferences (throttle).
/// ~300-500ms avoids per-frame jank (CONTEXT decision; Pitfall 4). The sustained-
/// hold cadence is measured between throttled ticks, so [kObjectHoldMs] is kept
/// `>= 2 *` this value. Device-tuned under SC-4; pinned by object_match_test.dart.
const int kObjectThrottleMs = 400;

/// MIS-03: curated target key → accepted ML Kit base-model label strings.
/// Keys are AppStrings lookup suffixes (`object_<key>`); values are EXACT
/// base-model labels (English) — ML Kit labels stay English, the internal map
/// translates. This is the FIRST CANDIDATE set, drawn ONLY from confirmed-present
/// labels in the official ML Kit base-model label map (RESEARCH State of the Art:
/// Bottle/Mug/Plate/Book are ABSENT from the model and deliberately avoided).
/// DEVICE-VERIFIED + finalized under SC-4 (Plan 02) — the live debug readout
/// collects the real emitted labels per target, then this table is pinned.
/// Matching is case-insensitive (see [hasMatch]).
const Map<String, Set<String>> kObjectTargets = {
  'cup': {'Cup', 'Tableware', 'Coffee'}, // Bottle/Mug ABSENT → cup is the drinkware proxy
  'glasses': {'Glasses'}, // eyewear — distinctive
  'phone': {'Mobile phone'}, // very reliable
  'shoe': {'Shoe', 'Sneakers'}, // footwear
  'plant': {'Plant', 'Flower'}, // a houseplant / flower
  'bag': {'Bag', 'Handbag'}, // a bag / backpack-as-handbag
};

/// MIS-03: true iff any returned label is in [accepted] (case-insensitive) AND
/// its confidence is `>= floor`. Pure + ML-Kit-FREE — testable without ML Kit:
/// takes plain `(String label, double confidence)` records, NOT `ImageLabel`, so
/// this is the calibratable/unit-testable seam (the caller maps `ImageLabel` →
/// tuples). Do NOT import `google_mlkit_*` here.
bool hasMatch(List<(String label, double confidence)> labels,
    Set<String> accepted, double floor) {
  final lower = accepted.map((e) => e.toLowerCase()).toSet();
  for (final l in labels) {
    if (l.$2 >= floor && lower.contains(l.$1.toLowerCase())) return true;
  }
  return false;
}

/// MIS-03 / D-02 analog: pure sustained-hold accumulator (NOT cumulative). Adds
/// [dtMs] to [heldMs] while [matched]; a single non-matching throttled tick
/// RESETS to 0 (mirrors [accumulateHold] / [accumulateColorHold]).
int accumulateObjectHold(int heldMs, bool matched, int dtMs) =>
    matched ? heldMs + dtMs : 0;

/// MIS-03: the object mission is complete once accumulated [heldMs] reaches
/// [kObjectHoldMs].
bool objectComplete(int heldMs) => heldMs >= kObjectHoldMs;
