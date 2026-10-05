import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'robot_eyes.dart';
import 'trash_bot.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  await WakelockPlus.enable(); // layar tidak boleh mati saat robot bekerja
  runApp(const TrashBotApp());
}

class TrashBotApp extends StatelessWidget {
  const TrashBotApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true),
        home: const HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final bot = TrashBot();

  @override
  void initState() {
    super.initState();
    bot.init();
  }

  @override
  void dispose() {
    bot.dispose();
    super.dispose();
  }

  void _openPanel() => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => ControlSheet(bot: bot),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: ListenableBuilder(
        listenable: bot,
        builder: (context, _) {
          final running = bot.phase != AutoPhase.off;
          return Stack(children: [
            Positioned.fill(
              child: RobotEyes(state: bot.eyes, lookX: bot.lookX),
            ),
            Positioned(
              left: 16,
              top: 10,
              right: 56,
              child: Text(
                '${bot.link.connected ? '●' : '○'} ${bot.status}   |   '
                '${bot.lastLabel}   |   ${bot.inferenceMs} ms   |   '
                '${bot.sortedCount} terpilah',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
            Positioned(
              right: 4,
              top: 0,
              child: IconButton(
                onPressed: _openPanel,
                icon: const Icon(Icons.settings, color: Colors.white54),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 14,
              child: Center(
                child: FilledButton.icon(
                  onPressed: running ? bot.stopAuto : bot.startAuto,
                  icon: Icon(running ? Icons.stop : Icons.play_arrow),
                  label: Text(running ? 'Berhenti' : 'Mulai'),
                ),
              ),
            ),
          ]);
        },
      ),
    );
  }
}

// ======================= PANEL KONTROL =======================

class ControlSheet extends StatefulWidget {
  final TrashBot bot;
  const ControlSheet({super.key, required this.bot});

  @override
  State<ControlSheet> createState() => _ControlSheetState();
}

class _ControlSheetState extends State<ControlSheet> {
  final _host = TextEditingController(text: '192.168.4.1');
  // Sudut awal slider (samakan dengan pose HOME di firmware).
  final _angles = [90.0, 150.0, 30.0, 100.0];
  DateTime _lastSend = DateTime(0);

  TrashBot get bot => widget.bot;

  @override
  void dispose() {
    _host.dispose();
    super.dispose();
  }

  void _sendServo(int ch, double v, {bool force = false}) {
    final now = DateTime.now();
    if (force || now.difference(_lastSend).inMilliseconds > 80) {
      _lastSend = now;
      bot.link.servo(ch, v.round());
    }
  }

  Widget _title(String s) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 8),
        child: Text(s, style: Theme.of(context).textTheme.titleSmall),
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: bot,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _title('Koneksi'),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _host,
                decoration: const InputDecoration(
                    labelText: 'IP ESP32', isDense: true),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: () => bot.connect(_host.text.trim()),
              child: Text(bot.link.connected ? 'Terhubung' : 'Hubungkan'),
            ),
          ]),

          _title('Kendali manual (tahan tombol)'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _HoldButton(Icons.arrow_upward,
                () => bot.link.drive(bot.driveSpeed, bot.driveSpeed), bot.link.stop),
            _HoldButton(Icons.arrow_downward,
                () => bot.link.drive(-bot.driveSpeed, -bot.driveSpeed), bot.link.stop),
            _HoldButton(Icons.rotate_left,
                () => bot.link.drive(-bot.driveSpeed, bot.driveSpeed), bot.link.stop),
            _HoldButton(Icons.rotate_right,
                () => bot.link.drive(bot.driveSpeed, -bot.driveSpeed), bot.link.stop),
          ]),

          _title('Lengan (kalibrasi & tes)'),
          for (var i = 0; i < 4; i++)
            Row(children: [
              SizedBox(
                width: 72,
                child: Text(const ['Base', 'Bahu', 'Siku', 'Gripper'][i]),
              ),
              Expanded(
                child: Slider(
                  value: _angles[i],
                  min: 0,
                  max: 180,
                  onChanged: (v) {
                    setState(() => _angles[i] = v);
                    _sendServo(i, v);
                  },
                  onChangeEnd: (v) => _sendServo(i, v, force: true),
                ),
              ),
              SizedBox(width: 36, child: Text(_angles[i].round().toString())),
            ]),
          Wrap(spacing: 8, children: [
            ActionChip(label: const Text('HOME'), onPressed: bot.link.home),
            for (final k in kLookX.keys)
              ActionChip(
                label: Text('Tes $k'),
                onPressed: () => bot.link.pick(k),
              ),
          ]),

          _title('Deteksi & arah'),
          Text('Confidence: ${bot.confidence.toStringAsFixed(2)}'),
          Slider(
            value: bot.confidence,
            min: 0.2,
            max: 0.9,
            onChanged: (v) => bot.update(() => bot.confidence = v),
          ),
          Text('Kecepatan roda: ${bot.driveSpeed}'),
          Slider(
            value: bot.driveSpeed.toDouble(),
            min: 90,
            max: 255,
            onChanged: (v) => bot.update(() => bot.driveSpeed = v.round()),
          ),
          SwitchListTile(
            title: const Text('Balik arah belok'),
            subtitle:
                const Text('Aktifkan kalau robot belok menjauhi benda'),
            value: bot.invertSteer,
            onChanged: (v) => bot.update(() => bot.invertSteer = v),
          ),
          SwitchListTile(
            title: const Text('Pakai kamera depan'),
            value: bot.useFrontCamera,
            onChanged: bot.setFrontCamera,
          ),
        ],
      ),
    );
  }
}

/// Tombol yang mengirim perintah berulang selama ditekan, dan memanggil
/// [onRelease] saat dilepas (robot berhenti).
class _HoldButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTick;
  final VoidCallback onRelease;
  const _HoldButton(this.icon, this.onTick, this.onRelease);

  @override
  State<_HoldButton> createState() => _HoldButtonState();
}

class _HoldButtonState extends State<_HoldButton> {
  Timer? _t;

  void _start() {
    widget.onTick();
    _t = Timer.periodic(
        const Duration(milliseconds: 200), (_) => widget.onTick());
  }

  void _end() {
    _t?.cancel();
    _t = null;
    widget.onRelease();
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
        onPointerDown: (_) => _start(),
        onPointerUp: (_) => _end(),
        onPointerCancel: (_) => _end(),
        child: Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: Colors.blueGrey.shade700,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(widget.icon, color: Colors.white),
        ),
      );
}
