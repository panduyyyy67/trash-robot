import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

import 'detector.dart';
import 'robot_eyes.dart';
import 'robot_link.dart';

/// Arah pandang mata (-1 kiri .. 1 kanan) saat memasukkan ke tiap tong.
/// Urutkan sesuai posisi tong di robot.
const kLookX = <String, double>{
  'kertas': -1.0,
  'organik': -0.33,
  'plastik': 0.33,
  'residu': 1.0,
};

enum AutoPhase { off, searching, approaching, picking }

/// Otak aplikasi: kamera -> deteksi -> perintah ke ESP32 -> animasi mata.
class TrashBot extends ChangeNotifier {
  final link = RobotLink();
  Detector? _detector;
  CameraController? _cam;
  StreamSubscription<String>? _sub;

  // ---- status (dibaca UI) ----
  AutoPhase phase = AutoPhase.off;
  RobotState eyes = RobotState.idle;
  double lookX = 0;
  String status = 'Memuat model...';
  String lastLabel = '-';
  int sortedCount = 0;
  int inferenceMs = 0;

  // ---- pengaturan (diubah dari panel kontrol) ----
  double confidence = 0.5;
  bool invertSteer = false;
  bool useFrontCamera = true;
  int driveSpeed = 130;

  // ---- internal ----
  bool _busy = false;
  bool _disposed = false;
  bool _wasConnected = false;
  DateTime _lastRun = DateTime(0);
  DateTime _lastSeen = DateTime(0);
  int _hits = 0;
  String _picking = '';
  final List<String> _votes = [];

  void update(VoidCallback fn) {
    fn();
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  // =================== INIT ===================
  Future<void> init() async {
    link.addListener(_onLink);
    _sub = link.messages.listen(_onRobot);
    try {
      _detector = await Detector.create('assets/models/trash.tflite');
      await _startCamera();
      status = 'Siap. Sambungkan ke Wi-Fi robot lalu tekan Hubungkan.';
    } catch (e) {
      status = 'Gagal inisialisasi: $e';
      eyes = RobotState.error;
    }
    notifyListeners();
  }

  Future<void> _startCamera() async {
    final cams = await availableCameras();
    final want =
        useFrontCamera ? CameraLensDirection.front : CameraLensDirection.back;
    final desc = cams.firstWhere(
      (c) => c.lensDirection == want,
      orElse: () => cams.first,
    );
    final cam = CameraController(
      desc,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    await cam.initialize();
    await cam.startImageStream(_onFrame);
    _cam = cam;
  }

  Future<void> _stopCamera() async {
    final cam = _cam;
    _cam = null;
    if (cam == null) return;
    if (cam.value.isStreamingImages) await cam.stopImageStream();
    await cam.dispose();
  }

  Future<void> setFrontCamera(bool v) async {
    useFrontCamera = v;
    notifyListeners();
    await _stopCamera();
    await _startCamera();
  }

  Future<void> connect(String host) async {
    status = 'Menghubungkan...';
    notifyListeners();
    final ok = await link.connect(host);
    status = ok ? 'Terhubung ke robot' : 'Gagal terhubung: ${link.error}';
    notifyListeners();
  }

  // =================== MODE OTOMATIS ===================
  void startAuto() {
    if (!link.connected) {
      status = 'Belum terhubung ke robot';
      notifyListeners();
      return;
    }
    phase = AutoPhase.searching;
    _votes.clear();
    _hits = 0;
    status = 'Mencari sampah';
    link.search(true);
    notifyListeners();
  }

  void stopAuto() {
    phase = AutoPhase.off;
    link.stop();
    status = 'Dihentikan';
    notifyListeners();
  }

  // =================== FRAME KAMERA ===================
  Future<void> _onFrame(CameraImage img) async {
    final det = _detector;
    if (det == null || _busy || _disposed) return;
    final now = DateTime.now();
    if (now.difference(_lastRun).inMilliseconds < 120) return;
    _busy = true;
    _lastRun = now;
    try {
      final sw = Stopwatch()..start();
      final dets = await det.detect(img, conf: confidence);
      inferenceMs = sw.elapsedMilliseconds;
      _handle(dets);
    } catch (e) {
      debugPrint('Frame error: $e');
    } finally {
      _busy = false;
    }
    notifyListeners();
  }

  /// Pilih benda terbaik: skor tinggi dan ukuran besar (biasanya lebih dekat).
  Detection? _best(List<Detection> ds) {
    Detection? best;
    var bs = 0.0;
    for (final d in ds) {
      final s = d.score * (0.2 + d.area);
      if (s > bs) {
        bs = s;
        best = d;
      }
    }
    return best;
  }

  String get _stableLabel {
    final counts = <String, int>{};
    for (final v in _votes) {
      counts[v] = (counts[v] ?? 0) + 1;
    }
    return counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  }

  void _handle(List<Detection> ds) {
    final d = _best(ds);
    if (phase != AutoPhase.searching && phase != AutoPhase.approaching) {
      if (d != null) lastLabel = d.label; // supaya deteksi bisa dites tanpa robot
      return;
    }
    final now = DateTime.now();

    if (d != null) {
      _lastSeen = now;
      _hits++;
      _votes.add(d.label);
      if (_votes.length > 7) _votes.removeAt(0);
      lastLabel = _stableLabel;

      // Butuh 2 frame berturut-turut agar tidak tertipu deteksi sesaat.
      if (phase == AutoPhase.searching && _hits >= 2) {
        phase = AutoPhase.approaching;
        status = 'Mendekati $lastLabel';
      }
      if (phase == AutoPhase.approaching) {
        link.steerTo(d.cx, invert: invertSteer, speed: driveSpeed);
      }
    } else {
      _hits = 0;
      if (phase == AutoPhase.approaching &&
          now.difference(_lastSeen).inMilliseconds > 1500) {
        phase = AutoPhase.searching;
        _votes.clear();
        status = 'Benda hilang, mencari lagi';
        link.search(true);
      }
    }
  }

  // =================== PESAN DARI ESP32 ===================
  void _startPick() {
    final label = _votes.isNotEmpty ? _stableLabel : lastLabel;
    if (!kLookX.containsKey(label)) {
      phase = AutoPhase.searching;
      link.search(true);
      return;
    }
    phase = AutoPhase.picking;
    _picking = label;
    status = 'Memilah $label';
    link.pick(label);
  }

  void _onRobot(String m) {
    switch (m) {
      case 'STATE:SEARCH':
        eyes = RobotState.scanning;
        break;
      case 'STATE:DRIVE':
        eyes = RobotState.detected;
        break;
      case 'STATE:PICKING':
        eyes = RobotState.sorting;
        lookX = 0;
        break;
      case 'STATE:PLACING':
        eyes = RobotState.sorting;
        lookX = kLookX[_picking] ?? 0;
        break;
      case 'STATE:DONE':
        eyes = RobotState.done;
        lookX = 0;
        sortedCount++;
        status = '$_picking masuk tong. Total: $sortedCount';
        _votes.clear();
        _hits = 0;
        Future.delayed(const Duration(milliseconds: 1500), () {
          if (phase == AutoPhase.picking) {
            phase = AutoPhase.searching;
            status = 'Mencari sampah';
            link.search(true);
            notifyListeners();
          }
        });
        break;
      case 'STATE:IDLE':
        eyes = RobotState.idle;
        break;
      case 'STATE:ERROR':
        eyes = RobotState.error;
        phase = AutoPhase.off;
        status = 'Gerakan lengan dibatalkan. Kirim HOME dari panel.';
        break;
      case 'NEAR':
        if (phase == AutoPhase.approaching) _startPick();
        break;
    }
    notifyListeners();
  }

  void _onLink() {
    if (link.connected == _wasConnected) return;
    _wasConnected = link.connected;
    if (link.connected) {
      eyes = RobotState.idle;
    } else {
      phase = AutoPhase.off;
      eyes = RobotState.error;
      status = 'Koneksi robot terputus';
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    link.removeListener(_onLink);
    link.dispose();
    _detector?.dispose();
    _stopCamera();
    super.dispose();
  }
}
