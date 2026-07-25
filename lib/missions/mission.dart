import 'package:flutter/widgets.dart';

/// ENG-01 / ENG-02 / MIS-01: the pluggable dismissal-mission contract rendered
/// inside RingScreen AFTER the barcode scan succeeds (Stage 2 of the two-stage
/// wake). A mission renders its own UI via [build] and signals completion by
/// invoking the supplied [onSuccess] callback; the screen then finishes the
/// dismiss. Lümen is the first concrete implementation (Plan 02); future
/// missions (Renk, Su sesi, Nesne-AI) swap in behind this same interface.
///
/// Contract copied verbatim from SPIKE 001 (the spike file is a throwaway
/// planning artifact and never ships into the app).
abstract class Mission {
  // HEALTH: dead `String get title` removed — never referenced (the host reads
  // AppStrings.get('mission_*_title', ...) directly).
  Widget build(BuildContext context, VoidCallback onSuccess);
}
