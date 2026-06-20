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

/// MIS-03 [ASSUMED]: minimum confidence (0..1) for a label to count as a match.
/// Lower than the default model (0.70) because the CUSTOM ImageNet classifier's
/// softmax spreads probability across 1000 classes, so a correct top label often
/// sits ~0.3-0.6. Device-calibrated under SC-4; pinned by object_match_test.dart.
const double kObjectConfidence = 0.40;

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

/// MIS-03: curated target key → accepted CUSTOM-MODEL (ImageNet) label strings.
/// Keys are AppStrings lookup suffixes (`object_<key>`) + the Turkish object name;
/// values are EXACT ImageNet class strings the bundled classifier emits (English;
/// matching is case-insensitive — see [hasMatch]). The custom ImageNet model was
/// adopted because the default ML Kit model is too coarse for kitchen items
/// (fork→"Wheel", banana→"Insect/Bird" on the Redmi Note 9S). This is the FIRST
/// CANDIDATE set, drawn from ImageNet-1000 classes that cover common HOUSEHOLD /
/// KITCHEN items; DEVICE-VERIFIED + finalized under SC-4 — the live debug readout
/// collects the real emitted label strings per target, then this table is pinned.
/// DEVICE-VERIFIED set (Redmi Note 9S, ImageNet model): these everyday household
/// items the model recognizes RELIABLY. Items that did NOT work on device are
/// deliberately excluded: plate/bowl/cutlery (not ImageNet classes for table
/// items), book (reads poorly), key (no ImageNet class). 'fruit' GENERALIZES
/// across ImageNet fruit classes (user request). Drinkware collapses espresso/
/// coffee-mug/cup/mug into one 'mug' target. Matching is case-insensitive.
const Map<String, Set<String>> kObjectTargets = {
  'mug': {'espresso', 'coffee mug', 'cup'}, // bardak/kupa
  'bottle': {'water bottle', 'pop bottle', 'beer bottle', 'wine bottle'}, // şişe
  'pillow': {'pillow'}, // yastık
  'fruit': {
    'banana', 'orange', 'lemon', 'pineapple', 'strawberry', 'fig',
    'pomegranate', 'Granny Smith', // muz/elma/portakal... (meyve genel)
  },
  'shoe': {'running shoe', 'sandal', 'Loafer', 'clog'}, // ayakkabı
  'laptop': {'laptop', 'notebook'}, // dizüstü
  'lighter': {'lighter'}, // çakmak
  'paper': {'paper towel', 'toilet tissue', 'bath towel'}, // havlu/peçete/rulo
  'clock': {'analog clock', 'digital clock', 'wall clock'}, // saat
  'remote': {'remote control'}, // kumanda
  'backpack': {'backpack'}, // sırt çantası
  'keyboard': {'computer keyboard'}, // klavye
};

/// MIS-03: CONCEPT AGGREGATION — sums the confidences of ALL returned labels that
/// belong to [accepted] (case-insensitive) and matches iff the SUM is `>= floor`.
/// Device finding: the ImageNet model is fine-grained, so one real object spreads
/// probability across several specific classes (a cup → `cup` 0.40 + `coffee mug`
/// 0.30 + `espresso` …), each individually below the floor but together clearly
/// the target. Summing within a concept-coherent accepted set generalizes those
/// specifics back into one target (a cup is a cup whether the top label is `cup`
/// or `coffee mug`). Pure + ML-Kit-FREE (plain `(String, double)` records, NOT
/// `ImageLabel`) — the calibratable/unit-testable seam. Do NOT import `google_mlkit_*`.
bool hasMatch(List<(String label, double confidence)> labels,
    Set<String> accepted, double floor) {
  final lower = accepted.map((e) => e.toLowerCase()).toSet();
  double sum = 0;
  for (final l in labels) {
    if (lower.contains(l.$1.toLowerCase())) sum += l.$2;
  }
  return sum >= floor;
}

/// MIS-03 / D-02 analog: pure sustained-hold accumulator (NOT cumulative). Adds
/// [dtMs] to [heldMs] while [matched]; a single non-matching throttled tick
/// RESETS to 0 (mirrors [accumulateHold] / [accumulateColorHold]).
int accumulateObjectHold(int heldMs, bool matched, int dtMs) =>
    matched ? heldMs + dtMs : 0;

/// MIS-03: the object mission is complete once accumulated [heldMs] reaches
/// [kObjectHoldMs].
bool objectComplete(int heldMs) => heldMs >= kObjectHoldMs;

/// MIS-04 [ASSUMED]: grouped "running water" confidence floor (0..N — the SUM of
/// the YAMNet water-class scores via [waterGroupedScore], D-05/D-06). The
/// kObjectConfidence analog but a grouped-sum, not a single-label confidence.
/// Device-calibrated under SC-4 — pulled ABOVE the alarm-only grouped baseline
/// (the alarm ringing alone must NOT clear this floor — SC-4 false-positive
/// guard). Pinned by water_match_test.dart.
const double kWaterConfidence = 0.50;

/// MIS-04 [ASSUMED]: how long (ms) running water must be SUSTAINED to complete
/// the mission (NOT cumulative — a single non-matching throttled tick RESETS to
/// 0, see [accumulateWaterHold]). Kept `>= 2 * kWaterThrottleMs` so at least two
/// independent throttled detections are always required — a single false-positive
/// tick (alarm blip) can NEVER complete the mission (D-03/D-09). Device-calibrated
/// under SC-4; pinned by water_match_test.dart.
const int kWaterHoldMs = 2500;

/// MIS-04 [ASSUMED]: minimum gap (ms) between YAMNet inferences (throttle). The
/// YAMNet window is ~0.975s, so a ~1Hz cadence is sensible; per-chunk inference
/// would jank/ANR. [kWaterHoldMs] is kept `>= 2 *` this value. Device-tuned under
/// SC-4; pinned by water_match_test.dart.
const int kWaterThrottleMs = 750;

/// MIS-04 / D-01 [ASSUMED]: soft-loop volume (0..1) WHILE the su mission is open.
/// ~0.18 instead of the default 0.5 — the alarm keeps ringing uninterrupted
/// (ENG-01) but mic bleed drops so real water more easily dominates (SC-4 #1).
/// Device-calibrated — the highest value that still eliminates the alarm-bleed
/// false-positive. Pinned by water_match_test.dart.
const double kWaterDuckVolume = 0.18;

/// MIS-04 / D-05: the "running water" YAMNet class indices (resolved from
/// yamnet_class_map.csv). PLACEHOLDER candidate set (Water, Water tap/faucet,
/// Sink, Bathtub, Stream, Pour, Trickle/dribble, Gurgling, Fill) — the FINAL set
/// is cut under SC-4 device calibration (keep classes strong on real water / weak
/// on the alarm tone; drop alarm-confusable classes). Indices are model-version
/// specific → resolved + device-verified in Plan 02. Intentionally empty here:
/// the pure helpers + tests prove the grouped-sum logic without it.
const Set<int> kWaterClassIndices = {
  // PLACEHOLDER — filled from yamnet_class_map.csv display_name mapping in Plan 02:
  // 'Water', 'Water tap, faucet', 'Sink (filling or washing)',
  // 'Bathtub (filling or washing)', 'Stream', 'Pour', 'Trickle, dribble',
  // 'Gurgling', 'Fill (with liquid)'
};

/// MIS-04 / D-05: CONCEPT AGGREGATION — sums ONLY the scores at the indices in
/// [idx] (out-of-range / out-of-set indices ignored; returns 0 for empty [idx]).
/// The grouped-sum analog of [hasMatch] for YAMNet's 521-class output: one real
/// water source spreads probability across several specific water classes, each
/// below the floor but together clearly water. Pure + TFLite-FREE (plain
/// `List<double>` / `Set<int>`, NOT a tflite_flutter Tensor) — the
/// calibratable/unit-testable seam. Do NOT import `tflite_flutter` or `record`.
double waterGroupedScore(List<double> scores, Set<int> idx) {
  double sum = 0;
  for (final i in idx) {
    if (i >= 0 && i < scores.length) sum += scores[i];
  }
  return sum;
}

/// MIS-04 / D-06: true iff the grouped water score (see [waterGroupedScore]) is
/// `>= floor`. Pure + TFLite-FREE.
bool hasWaterMatch(List<double> scores, Set<int> idx, double floor) =>
    waterGroupedScore(scores, idx) >= floor;

/// MIS-04 / D-09: pure sustained-hold accumulator (NOT cumulative). Adds [dtMs]
/// to [heldMs] while [matched]; a single non-matching throttled tick RESETS to 0
/// (mirrors [accumulateObjectHold]).
int accumulateWaterHold(int heldMs, bool matched, int dtMs) =>
    matched ? heldMs + dtMs : 0;

/// MIS-04: the water mission is complete once accumulated [heldMs] reaches
/// [kWaterHoldMs].
bool waterComplete(int heldMs) => heldMs >= kWaterHoldMs;
