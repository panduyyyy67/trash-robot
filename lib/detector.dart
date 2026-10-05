import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:tflite_flutter/tflite_flutter.dart';

/// Urutan HARUS sama dengan `names:` di data.yaml saat training.
/// Nama ini juga yang dikirim ke ESP32 (PICK:<nama>).
const kClassNames = ['kertas', 'organik', 'plastik', 'residu'];

class Detection {
  final int classId;
  final double score;

  /// Kotak deteksi, dinormalisasi 0..1 terhadap frame kamera.
  final Rect box;

  Detection(this.classId, this.score, this.box);

  String get label =>
      classId < kClassNames.length ? kClassNames[classId] : 'class$classId';
  double get cx => box.center.dx;
  double get area => box.width * box.height;
}

/// Membungkus model YOLO (hasil `yolo export format=tflite`) yang berjalan
/// sepenuhnya di isolate lain, sehingga UI dan animasi mata tidak tersendat.
class Detector {
  Detector._(this._isolate, this._toWorker, this._from, this.inputSize,
      this.numClasses);

  final Isolate _isolate;
  final SendPort _toWorker;
  final ReceivePort _from;
  final int inputSize;
  final int numClasses;
  Completer<List<Detection>>? _pending;

  static Future<Detector> create(String asset, {int threads = 4}) async {
    final data = await rootBundle.load(asset);
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);

    final from = ReceivePort();
    final ready = Completer<_Ready>();
    Detector? self;

    from.listen((msg) {
      if (msg is _Ready) {
        ready.complete(msg);
      } else if (msg is Float64List) {
        self?._finish(_parse(msg));
      } else if (msg is String) {
        debugPrint('Detector: $msg');
        if (!ready.isCompleted) {
          ready.completeError(msg);
        } else {
          self?._finish(<Detection>[]);
        }
      }
    });

    final iso =
        await Isolate.spawn(_worker, _Init(from.sendPort, bytes, threads));
    final r = await ready.future;
    final d = Detector._(iso, r.port, from, r.size, r.numClasses);
    self = d;
    return d;
  }

  void _finish(List<Detection> d) {
    final p = _pending;
    _pending = null;
    p?.complete(d);
  }

  static List<Detection> _parse(Float64List f) => [
        for (var i = 0; i + 5 < f.length; i += 6)
          Detection(f[i].toInt(), f[i + 1],
              Rect.fromLTRB(f[i + 2], f[i + 3], f[i + 4], f[i + 5])),
      ];

  /// Satu frame per panggilan. Panggil lagi hanya setelah Future selesai.
  Future<List<Detection>> detect(CameraImage img, {double conf = 0.5}) {
    final p = img.planes;
    if (p.length < 3 || _pending != null) {
      return Future.value(<Detection>[]);
    }
    final c = _pending = Completer<List<Detection>>();
    _toWorker.send(_Frame(
      p[0].bytes,
      p[1].bytes,
      p[2].bytes,
      img.width,
      img.height,
      p[0].bytesPerRow,
      p[1].bytesPerRow,
      p[1].bytesPerPixel ?? 1,
      conf,
    ));
    return c.future;
  }

  void dispose() {
    _from.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}

// ======================= ISOLATE WORKER =======================

class _Init {
  final SendPort reply;
  final Uint8List model;
  final int threads;
  _Init(this.reply, this.model, this.threads);
}

class _Ready {
  final SendPort port;
  final int size;
  final int numClasses;
  _Ready(this.port, this.size, this.numClasses);
}

class _Frame {
  final Uint8List y, u, v;
  final int w, h, yStride, uvStride, uvPixel;
  final double conf;
  _Frame(this.y, this.u, this.v, this.w, this.h, this.yStride, this.uvStride,
      this.uvPixel, this.conf);
}

class _LB {
  final int padX, padY, nw, nh;
  _LB(this.padX, this.padY, this.nw, this.nh);
}

class _Cand {
  final double cx, cy, w, h, score;
  final int cls;
  double x1 = 0, y1 = 0, x2 = 0, y2 = 0;
  _Cand(this.cx, this.cy, this.w, this.h, this.score, this.cls);
}

void _worker(_Init init) {
  try {
    final interp = Interpreter.fromBuffer(
      init.model,
      options: InterpreterOptions()..threads = init.threads,
    );
    final inShape = interp.getInputTensor(0).shape; // [1, S, S, 3]
    final outShape = interp.getOutputTensor(0).shape; // [1, 4+nc, N] atau [1, N, 4+nc]
    final size = inShape[1];
    final chFirst = outShape[1] < outShape[2];
    final c = chFirst ? outShape[1] : outShape[2];
    final n = chFirst ? outShape[2] : outShape[1];

    final input = Float32List(size * size * 3);
    final output = List.generate(
      1,
      (_) => List.generate(outShape[1], (_) => List.filled(outShape[2], 0.0)),
    );

    final port = ReceivePort();
    init.reply.send(_Ready(port.sendPort, size, c - 4));

    port.listen((msg) {
      if (msg is! _Frame) return;
      try {
        final lb = _letterbox(input, msg, size);
        // Input dikirim sebagai byte mentah float32. Kalau muncul error soal
        // shape, ganti dengan: input.reshape([1, size, size, 3])
        interp.run(input.buffer.asUint8List(), output);
        init.reply.send(_decode(output[0], chFirst, c, n, msg.conf, size, lb));
      } catch (e) {
        init.reply.send('ERR: $e');
      }
    });
  } catch (e) {
    init.reply.send('ERR: $e');
  }
}

double _c(double v) => (v < 0 ? 0 : (v > 255 ? 255 : v)) / 255;

/// YUV420 -> RGB float [0..1], diperkecil ke size x size dengan padding
/// abu-abu (letterbox) agar rasio gambar tetap.
_LB _letterbox(Float32List out, _Frame f, int size) {
  final scale = size / math.max(f.w, f.h);
  final nw = (f.w * scale).round();
  final nh = (f.h * scale).round();
  final padX = (size - nw) ~/ 2;
  final padY = (size - nh) ~/ 2;
  final inv = 1 / scale;

  out.fillRange(0, out.length, 114 / 255);
  for (var oy = 0; oy < nh; oy++) {
    final sy = math.min(f.h - 1, (oy * inv).floor());
    final yRow = sy * f.yStride;
    final uvRow = (sy >> 1) * f.uvStride;
    var o = ((oy + padY) * size + padX) * 3;
    for (var ox = 0; ox < nw; ox++) {
      final sx = math.min(f.w - 1, (ox * inv).floor());
      final yy = f.y[yRow + sx];
      final ui = uvRow + (sx >> 1) * f.uvPixel;
      final u = f.u[ui] - 128;
      final v = f.v[ui] - 128;
      out[o++] = _c(yy + 1.402 * v);
      out[o++] = _c(yy - 0.344136 * u - 0.714136 * v);
      out[o++] = _c(yy + 1.772 * u);
    }
  }
  return _LB(padX, padY, nw, nh);
}

double _iou(_Cand a, _Cand b) {
  final iw = math.min(a.x2, b.x2) - math.max(a.x1, b.x1);
  final ih = math.min(a.y2, b.y2) - math.max(a.y1, b.y1);
  if (iw <= 0 || ih <= 0) return 0;
  final inter = iw * ih;
  final ua = (a.x2 - a.x1) * (a.y2 - a.y1) +
      (b.x2 - b.x1) * (b.y2 - b.y1) -
      inter;
  return ua <= 0 ? 0 : inter / ua;
}

/// Output YOLOv8/11: tiap kandidat = [cx, cy, w, h, skor kelas 0..nc-1].
/// Hasil: Float64List berisi [kelas, skor, x1, y1, x2, y2] per deteksi,
/// koordinat dinormalisasi terhadap frame kamera (0..1).
Float64List _decode(List<List<double>> o, bool chFirst, int c, int n,
    double conf, int size, _LB lb) {
  double at(int ch, int i) => chFirst ? o[ch][i] : o[i][ch];
  final nc = c - 4;

  final cand = <_Cand>[];
  var maxV = 0.0;
  for (var i = 0; i < n; i++) {
    var cls = 0;
    var best = 0.0;
    for (var k = 0; k < nc; k++) {
      final s = at(4 + k, i);
      if (s > best) {
        best = s;
        cls = k;
      }
    }
    if (best < conf) continue;
    final d = _Cand(at(0, i), at(1, i), at(2, i), at(3, i), best, cls);
    maxV = math.max(maxV, math.max(math.max(d.cx, d.cy), math.max(d.w, d.h)));
    cand.add(d);
  }
  if (cand.isEmpty) return Float64List(0);

  // Ekspor TFLite biasanya ternormalisasi (0..1). Kalau nilainya jelas dalam
  // piksel (>2), bagi dengan ukuran input.
  final k = (maxV > 2 ? 1.0 / size : 1.0) * size;
  double fx(double v) => ((v * k - lb.padX) / lb.nw).clamp(0.0, 1.0).toDouble();
  double fy(double v) => ((v * k - lb.padY) / lb.nh).clamp(0.0, 1.0).toDouble();
  for (final d in cand) {
    d.x1 = fx(d.cx - d.w / 2);
    d.x2 = fx(d.cx + d.w / 2);
    d.y1 = fy(d.cy - d.h / 2);
    d.y2 = fy(d.cy + d.h / 2);
  }

  // NMS tanpa memandang kelas: satu benda = satu label.
  cand.sort((a, b) => b.score.compareTo(a.score));
  final keep = <_Cand>[];
  for (final d in cand) {
    if (keep.length >= 10) break;
    if (keep.every((e) => _iou(e, d) < 0.5)) keep.add(d);
  }

  final res = Float64List(keep.length * 6);
  for (var i = 0; i < keep.length; i++) {
    final d = keep[i];
    res.setRange(i * 6, i * 6 + 6, [d.cls.toDouble(), d.score, d.x1, d.y1, d.x2, d.y2]);
  }
  return res;
}
