import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Koneksi WebSocket ke ESP32 (mode Access Point: ws://192.168.4.1:81).
///
/// Pesan dari robot: "STATE:IDLE|SEARCH|DRIVE|PICKING|PLACING|DONE|ERROR",
/// "NEAR" (benda sudah dalam jangkauan lengan), "BUSY", "ERR:KATEGORI".
class RobotLink extends ChangeNotifier {
  WebSocketChannel? _channel;
  final _controller = StreamController<String>.broadcast();

  bool connected = false;
  String? error;

  Stream<String> get messages => _controller.stream;

  Future<bool> connect([String host = '192.168.4.1']) async {
    final old = _channel;
    _channel = null;
    connected = false;
    await old?.sink.close();

    WebSocketChannel? ch;
    try {
      ch = WebSocketChannel.connect(Uri.parse('ws://$host:81'));
      await ch.ready.timeout(const Duration(seconds: 4));
      _channel = ch;
      error = null;
      connected = true;
      notifyListeners();
      final c = ch;
      c.stream.listen(
        (m) => _controller.add(m.toString()),
        onDone: () => _lost(c),
        onError: (_) => _lost(c),
      );
      return true;
    } catch (e) {
      ch?.sink.close();
      error = e.toString();
      connected = false;
      notifyListeners();
      return false;
    }
  }

  void _lost(WebSocketChannel ch) {
    if (_channel != ch) return;
    _channel = null;
    connected = false;
    notifyListeners();
  }

  void _send(String s) => _channel?.sink.add(s);

  void stop() => _send('STOP');
  void home() => _send('HOME');
  void search(bool on) => _send('SEARCH:${on ? 1 : 0}');
  void drive(int left, int right) => _send('DRIVE:$left,$right');

  /// kategori: kertas | organik | plastik | residu
  void pick(String kategori) => _send('PICK:$kategori');

  /// Kalibrasi: 0 base, 1 bahu, 2 siku, 3 gripper.
  void servo(int channel, int angle) => _send('SERVO:$channel,$angle');

  /// Arahkan robot ke benda berdasarkan pusat bounding box.
  /// [cx] = titik tengah bbox, 0..1 (0 = tepi kiri frame).
  /// Panggil tiap hasil deteksi; kalau berhenti dipanggil, ESP32 berhenti
  /// sendiri dalam 0,6 detik (failsafe). Robot melambat saat benda jauh
  /// ke samping. Kalau robot belok menjauhi benda, set [invert] = true.
  void steerTo(
    double cx, {
    bool invert = false,
    int speed = 130,
    int gain = 110,
  }) {
    var steer = (cx - 0.5) * 2; // -1 (kiri) .. 1 (kanan)
    if (invert) steer = -steer;
    final fwd = speed * (1 - 0.6 * steer.abs());
    final l = (fwd + gain * steer).round().clamp(-255, 255).toInt();
    final r = (fwd - gain * steer).round().clamp(-255, 255).toInt();
    drive(l, r);
  }

  @override
  void dispose() {
    _channel?.sink.close();
    _controller.close();
    super.dispose();
  }
}
