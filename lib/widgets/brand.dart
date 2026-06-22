import 'package:flutter/material.dart';

import '../constants/app_constants.dart';

/// BRAND-IN-APP: the locked "ScanAwake" wordmark (design/export/feature.html).
///
/// Two spans in genuine Montserrat (weight 700), uppercased with the brand's wide
/// tracking. "SCAN" is theme-aware so it stays legible on either themed AppBar
/// background ([kBrandCream] on dark, [kBrandDark] on light); "AWAKE" is always
/// [kBrandRed]. Single line to avoid AppBar overflow.
class ScanAwakeWordmark extends StatelessWidget {
  final double fontSize;

  const ScanAwakeWordmark({super.key, this.fontSize = 22});

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final Color scanColor = isDark ? kBrandCream : kBrandDark;

    final TextStyle base = TextStyle(
      fontFamily: 'Montserrat',
      fontWeight: FontWeight.w700,
      fontSize: fontSize,
      letterSpacing: 2,
    );

    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: 'SCAN', style: base.copyWith(color: scanColor)),
          TextSpan(text: 'AWAKE', style: base.copyWith(color: kBrandRed)),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.visible,
      textAlign: TextAlign.center,
    );
  }
}

/// BRAND-IN-APP: the locked viewfinder mark (design/export/feature.html SVG).
///
/// Four sharp red corner brackets + a filled cream center dot, reproduced from the
/// feature.html geometry on a logical 100x100 canvas scaled to [size]. [color]
/// optionally overrides the bracket color (center dot stays [kBrandCream]).
class ViewfinderMark extends StatelessWidget {
  final double size;
  final Color? color;

  const ViewfinderMark({super.key, this.size = 22, this.color});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _ViewfinderPainter(bracketColor: color ?? kBrandRed),
      size: Size.square(size),
      child: SizedBox.square(dimension: size),
    );
  }
}

class _ViewfinderPainter extends CustomPainter {
  final Color bracketColor;

  _ViewfinderPainter({required this.bracketColor});

  @override
  void paint(Canvas canvas, Size size) {
    // feature.html SVG viewBox is 0 0 100 100 — scale logical coords to `size`.
    final double scale = size.width / 100;

    final Paint brackets = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9 * scale
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = bracketColor;

    // Four corner brackets (sharp corners) — feature.html path geometry:
    // M38 24 H24 V38 / M62 24 H76 V38 / M24 62 V76 H38 / M76 62 V76 H62
    final Path path = Path()
      // top-left
      ..moveTo(38 * scale, 24 * scale)
      ..lineTo(24 * scale, 24 * scale)
      ..lineTo(24 * scale, 38 * scale)
      // top-right
      ..moveTo(62 * scale, 24 * scale)
      ..lineTo(76 * scale, 24 * scale)
      ..lineTo(76 * scale, 38 * scale)
      // bottom-left
      ..moveTo(24 * scale, 62 * scale)
      ..lineTo(24 * scale, 76 * scale)
      ..lineTo(38 * scale, 76 * scale)
      // bottom-right
      ..moveTo(76 * scale, 62 * scale)
      ..lineTo(76 * scale, 76 * scale)
      ..lineTo(62 * scale, 76 * scale);

    canvas.drawPath(path, brackets);

    // Filled cream center dot: circle cx50 cy50 r9.
    final Paint dot = Paint()
      ..style = PaintingStyle.fill
      ..color = kBrandCream;
    canvas.drawCircle(Offset(50 * scale, 50 * scale), 9 * scale, dot);
  }

  @override
  bool shouldRepaint(covariant _ViewfinderPainter oldDelegate) =>
      oldDelegate.bracketColor != bracketColor;
}
