import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Status robot -> menentukan ekspresi mata.
enum RobotState { idle, scanning, detected, sorting, done, error }

class RobotEyes extends StatelessWidget {
  final RobotState state;

  /// Arah pandang saat sorting: -1 (paling kiri) .. 1 (paling kanan).
  /// Isi sesuai posisi tempat sampah tujuan.
  final double lookX;

  const RobotEyes({super.key, required this.state, this.lookX = 0});

  @override
  Widget build(BuildContext context) {
    return _EyesAnimator(state: state, lookX: lookX);
  }
}

class _EyesAnimator extends StatefulWidget {
  final RobotState state;
  final double lookX;
  const _EyesAnimator({required this.state, required this.lookX});

  @override
  State<_EyesAnimator> createState() => _EyesAnimatorState();
}

class _EyesAnimatorState extends State<_EyesAnimator>
    with SingleTickerProviderStateMixin {
  // Satu siklus 4 detik, diulang terus (untuk kedip & gerakan mata).
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: TweenAnimationBuilder<double>(
        // Transisi halus saat arah pandang berubah.
        tween: Tween(begin: 0, end: widget.lookX),
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
        builder: (_, lookX, __) => AnimatedBuilder(
          animation: _c,
          builder: (_, __) => CustomPaint(
            size: Size.infinite,
            painter: _EyesPainter(_c.value, widget.state, lookX),
          ),
        ),
      ),
    );
  }
}

class _EyesPainter extends CustomPainter {
  final double t; // 0..1 dalam satu siklus
  final RobotState state;
  final double lookX;

  _EyesPainter(this.t, this.state, this.lookX);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final eyeW = w * 0.28;
    final baseH = h * 0.45;
    final gap = w * 0.12;
    final cy = h / 2;

    // Kedip di 90%-96% siklus.
    double blink = 0;
    if (t > 0.90 && t < 0.96) {
      blink = math.sin((t - 0.90) / 0.06 * math.pi);
    }

    double dx = 0, dy = 0, scale = 1;
    Color color = const Color(0xFF4FC3F7);

    switch (state) {
      case RobotState.idle:
        dx = math.sin(t * 2 * math.pi) * 0.25; // melirik pelan
        break;
      case RobotState.scanning:
        dx = math.sin(t * 2 * math.pi * 3) * 0.9; // menyapu kiri-kanan
        dy = -0.1;
        break;
      case RobotState.detected:
        scale = 1.2; // mata membesar
        color = Colors.amber;
        break;
      case RobotState.sorting:
        dx = lookX;
        color = Colors.greenAccent;
        break;
      case RobotState.done:
        color = Colors.greenAccent;
        break;
      case RobotState.error:
        color = Colors.redAccent;
        break;
    }

    final fill = Paint()..color = color;
    final glow = Paint()
      ..color = color.withOpacity(0.5)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 24);

    for (final side in [-1, 1]) {
      final cx = w / 2 + side * (eyeW / 2 + gap / 2) + dx * eyeW * 0.25;
      final cyy = cy + dy * baseH * 0.2;

      if (state == RobotState.done) {
        // Mata senang: bentuk ^ ^
        final rect = Rect.fromCenter(
          center: Offset(cx, cyy + baseH * 0.15),
          width: eyeW * 0.8,
          height: baseH * 0.7,
        );
        final stroke = Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = eyeW * 0.16
          ..strokeCap = StrokeCap.round;
        canvas.drawArc(rect, math.pi, math.pi, false, stroke);
        continue;
      }

      final eyeH = baseH * scale * (1 - blink * 0.95);
      final rrect = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(cx, cyy),
          width: eyeW * scale,
          height: eyeH,
        ),
        Radius.circular(eyeW * 0.3),
      );
      canvas.drawRRect(rrect, glow);
      canvas.drawRRect(rrect, fill);

      if (state == RobotState.error) {
        // Kelopak miring (marah/error): sisi dalam turun.
        final r = rrect.outerRect;
        final inner = side == -1 ? r.right : r.left;
        final outer = side == -1 ? r.left : r.right;
        final lid = Path()
          ..moveTo(outer, r.top - 2)
          ..lineTo(inner, r.top - 2)
          ..lineTo(inner, r.top + r.height * 0.5)
          ..close();
        canvas.drawPath(lid, Paint()..color = Colors.black);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _EyesPainter old) =>
      old.t != t || old.state != state || old.lookX != lookX;
}

// ---------------------------------------------------------------
// Contoh pemakaian di halaman utama (landscape, layar tetap menyala):
//
// RobotState _state = RobotState.idle;
// double _look = 0;
//
// // di build():
// Scaffold(body: RobotEyes(state: _state, lookX: _look));
//
// // di alur deteksi:
// setState(() => _state = RobotState.scanning);   // mulai mencari benda
// setState(() => _state = RobotState.detected);   // label ditemukan
// setState(() { _state = RobotState.sorting; _look = -1; }); // arm bekerja
// setState(() => _state = RobotState.done);       // ESP32 balas "done"
//
// Pemetaan label -> lookX contoh (sesuaikan urutan tong di robot):
// const binLook = {'kertas': -1.0, 'organik': -0.33, 'plastik': 0.33, 'residu': 1.0};
//
// Paket tambahan: wakelock_plus (layar tidak mati) dan
// SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft]).
// ---------------------------------------------------------------
