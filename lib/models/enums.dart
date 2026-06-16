/// ARC-03 / D-03: the typed navigation contract for the four RingScreen dismiss
/// paths, replacing the stringly-typed 'RESTART'/'SNOOZE'/'SUCCESS'/'EMERGENCY'
/// sentinels. Producers (RingScreen `Navigator.pop`) and consumers (HomeScreen
/// ring-listener) are migrated together — Navigator results are `dynamic`, so a
/// half-migration would fail silently and regress the FIX-01 re-arm guarantee
/// (Pitfall 5).
///
/// EXCLUDED from this enum (separate contracts, intentionally untouched):
/// - the alarm-add dialog's `'SAVE'` sentinel
/// - the ScannerScreen's raw barcode `String` return
enum RingResult { restart, snooze, success, emergency }

/// ENG-03 / MIS-01 / D-10: the per-alarm dismissal mission. Carried via
/// [AlarmSettings.payload] alongside `kind` AND persisted in `alarms_data`
/// (mirrors [AlarmKind]). Decoded defensively: a legacy alarm with no
/// `missionType` field, or an unknown/future value (e.g. 'water'), decodes to
/// [MissionType.none] and NEVER throws (D-11 / Pitfall 5 — the core value that
/// dismiss must never crash). Use `MissionType.values.asNameMap()[x] ?? none`,
/// NEVER `byName` (byName throws on unknown).
///
/// This enum contains ONLY ready/shipped missions (D-10). `renk`, `nesne`,
/// `water` etc. are added in their own phases when their concrete [Mission]
/// implementation ships — NOT pre-declared here.
///
/// Deliberately does NOT introduce a `RingResult.missionFail` variant
/// (RESEARCH Pattern 3): a failing Lümen keeps the alarm running; the screen
/// pops only on the four existing [RingResult]s. A half-migrated result enum
/// would regress the FIX-01 re-arm guarantee.
enum MissionType { none, lumen }
