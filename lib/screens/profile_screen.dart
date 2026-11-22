import 'dart:io';

import 'package:flutter/material.dart';

import '../services/profile_settings.dart';

/// The driver's own settings: their PSN ID, the nickname Boxington calls
/// them by now and then, their strategy style, how much Boxington says,
/// and the connections (the PS5's address, the HUD reader's port). Saved
/// as they're changed.
class ProfileScreen extends StatefulWidget {
  /// Told the new settings each time they're saved.
  final ValueChanged<ProfileSettings>? onChanged;

  /// The .env's CONSOLE_IP, used when none is entered here.
  final String? envConsoleIp;

  /// This device's addresses on the network, for the HUD reader to send
  /// to (overridable for tests).
  final Future<List<String>> Function() deviceAddresses;

  const ProfileScreen({super.key, this.onChanged, this.envConsoleIp, this.deviceAddresses = localAddresses});

  /// This device's IPv4 addresses on Wi-Fi / Ethernet.
  static Future<List<String>> localAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
      return [for (final i in interfaces) for (final a in i.addresses) a.address];
    } catch (_) {
      return const [];
    }
  }

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _start = ProfileSettings.current;
  late final _psn = TextEditingController(text: _start.psnId);
  late final _nickname = TextEditingController(text: _start.nickname ?? '');
  late final _console = TextEditingController(text: _start.consoleIp ?? '');
  late final _hudPort = TextEditingController(text: '${_start.hudPort}');
  late StrategyStyle _style = _start.strategyStyle;
  late TalkLevel _talk = _start.talkLevel;
  late bool _hudReader = _start.hudReader;
  late final Future<List<String>> _addresses = widget.deviceAddresses();

  @override
  void dispose() {
    _psn.dispose();
    _nickname.dispose();
    _console.dispose();
    _hudPort.dispose();
    super.dispose();
  }

  /// The console address typed, if it's one (blank: the .env's).
  String? get _consoleError {
    final text = _console.text.trim();
    return text.isEmpty || ProfileSettings.isValidIp(text) ? null : 'An address like 192.168.1.20';
  }

  String? get _portError {
    final port = int.tryParse(_hudPort.text.trim());
    return port != null && ProfileSettings.isValidPort(port) ? null : 'A port from 1024 to 65535';
  }

  Future<void> _save() async {
    setState(() {}); // the fields' errors
    final psn = _psn.text.trim();
    final nickname = _nickname.text.trim();
    final console = _console.text.trim();
    final current = ProfileSettings.current;
    final settings = ProfileSettings(
      psnId: psn.isEmpty ? ProfileSettings.defaultPsnId : psn,
      nickname: nickname.isEmpty ? null : nickname,
      strategyStyle: _style,
      talkLevel: _talk,
      hudReader: _hudReader,
      // A half-typed address or port keeps the one in use.
      consoleIp: _consoleError != null ? current.consoleIp : (console.isEmpty ? null : console),
      hudPort: _portError != null ? current.hudPort : int.parse(_hudPort.text.trim()),
    );
    await ProfileSettings.save(settings);
    widget.onChanged?.call(settings);
  }

  InputDecoration _decoration(String label, String hint, {String? error}) => InputDecoration(
    labelText: label,
    hintText: hint,
    errorText: error,
    border: const OutlineInputBorder(),
  );

  Widget _section(String title, String help) => Padding(
    padding: const EdgeInsets.only(top: 28, bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: TextStyle(color: Colors.grey.shade400, fontSize: 14, fontWeight: FontWeight.w900, letterSpacing: 1.5)),
        const SizedBox(height: 4),
        Text(help, style: TextStyle(color: Colors.grey.shade500, fontSize: 14)),
      ],
    ),
  );

  Widget _choice<T>(T value, T group, String label, String description, ValueChanged<T> onPick) => RadioListTile<T>(
    value: value,
    groupValue: group,
    contentPadding: EdgeInsets.zero,
    title: Text(label, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
    subtitle: Text(description),
    onChanged: (picked) {
      if (picked == null) return;
      onPick(picked);
      _save();
    },
  );

  @override
  Widget build(BuildContext context) {
    final envConsole = widget.envConsoleIp;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: const Text('PROFILE')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        children: [
          _section('PSN ID', 'Your name on the leaderboard and the HUD -- how the app and Boxington tell your car from the rest.'),
          TextField(
            key: const Key('profile_psn'),
            controller: _psn,
            autocorrect: false,
            decoration: _decoration('PSN ID', ProfileSettings.defaultPsnId),
            onChanged: (_) => _save(),
          ),
          _section('NICKNAME', 'What Boxington calls you -- now and then, not on every call. Blank: never by name.'),
          TextField(
            key: const Key('profile_nickname'),
            controller: _nickname,
            decoration: _decoration('Nickname', 'e.g. Willy'),
            onChanged: (_) => _save(),
          ),
          _section('TALK LEVEL', 'How much Boxington says without being asked. He always answers when you talk to him.'),
          for (final level in TalkLevel.values)
            _choice(level, _talk, level.label, level.description, (v) => setState(() => _talk = v)),
          _section('STRATEGY STYLE', 'Which tyre the race plan starts on.'),
          for (final style in StrategyStyle.values)
            _choice(style, _style, style.label, style.description, (v) => setState(() => _style = v)),
          if (_style != _start.strategyStyle)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Open the Race Brief and Generate again to plan with it.',
                style: TextStyle(color: Colors.amber.shade300, fontSize: 14),
              ),
            ),
          _section(
            'PS5',
            'Your PS5\'s address on the network, for GT7\'s telemetry (PS5: Settings > Network > Connection Status). '
                '${envConsole == null ? '' : 'Blank: the one in the app\'s settings file. '}Changes reconnect straight away.',
          ),
          TextField(
            key: const Key('profile_console_ip'),
            controller: _console,
            autocorrect: false,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: _decoration('PS5 address', envConsole ?? '192.168.1.20', error: _consoleError),
            onChanged: (_) => _save(),
          ),
          _section('SETUP', 'What you race with. Telemetry only needs nothing but the PS5 on the same network.'),
          _choice(
            true,
            _hudReader,
            'Telemetry + HUD reader',
            'An HDMI splitter and a laptop reading GT7\'s screen: position, gaps, rivals, other cars\' stops, '
                'tyre wear, the tyre fitted and the water gauge.',
            (v) => setState(() => _hudReader = v),
          ),
          _choice(
            false,
            _hudReader,
            'Telemetry only',
            'No splitter: speed, fuel, lap times, tyre temperatures and the plan. You pick the tyre you\'re on; '
                'tyre wear is estimated, not measured.',
            (v) => setState(() => _hudReader = v),
          ),
          if (_hudReader) ...[
          _section('HUD READER', 'The laptop that reads the HUD sends to this iPad, on this port. Changes reconnect straight away.'),
          FutureBuilder<List<String>>(
            future: _addresses,
            builder: (context, snapshot) {
              final addresses = snapshot.data ?? const [];
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  addresses.isEmpty
                      ? 'This iPad\'s address: not on a network'
                      : 'Send to this iPad at ${addresses.join(' or ')}, port ${_portError == null ? _hudPort.text.trim() : ProfileSettings.current.hudPort}',
                  key: const Key('profile_device_address'),
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                ),
              );
            },
          ),
          TextField(
            key: const Key('profile_hud_port'),
            controller: _hudPort,
            keyboardType: TextInputType.number,
            decoration: _decoration('HUD port', '${ProfileSettings.defaultHudPort}', error: _portError),
            onChanged: (_) => _save(),
          ),
          ],
        ],
      ),
    );
  }
}
