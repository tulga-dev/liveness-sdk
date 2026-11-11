// Test app. It talks to two servers on the computer running the emulator:
//   BACKEND  the stand-in for the NBFI's backend (demo_nbfi_backend.py, port 8001).
//            It holds the API key and the customer's government photo.
//   SERVER   the liveness server (port 8000). The app only uploads photos to it.
// The app never holds an API key and never sees the government photo.
//
// On an Android emulator the defaults work as they are (10.0.2.2 = the host computer).
// On a real phone:
//   flutter run --dart-define=SERVER=http://<pc-ip>:8000 --dart-define=BACKEND=http://<pc-ip>:8001
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:liveness_sdk/liveness_sdk.dart';

const server = String.fromEnvironment('SERVER', defaultValue: 'http://10.0.2.2:8000');
const backend = String.fromEnvironment('BACKEND', defaultValue: 'http://10.0.2.2:8001');

void main() => runApp(const MaterialApp(home: Home()));

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  String _result = 'Not run yet';
  bool _mn = false, _invertYaw = false, _invertPitch = false;

  Future<void> _run() async {
    setState(() => _result = 'Creating session…');
    try {
      final res = await http.post(Uri.parse('$backend/start'));
      if (res.statusCode != 201) throw 'start: HTTP ${res.statusCode} ${res.body}';
      final s = jsonDecode(res.body) as Map<String, dynamic>;
      if (!mounted) return;

      final outcome = await Navigator.of(context).push<LivenessOutcome>(
        MaterialPageRoute(
          builder: (ctx) => LivenessCheck(
            serverUrl: server,
            sessionId: s['session_id'] as String,
            sessionToken: s['session_token'] as String,
            turns: (s['turns'] as List).cast<String>(),
            timeLimitSeconds: (s['expires_in_s'] as num).toInt() - 3,
            strings: _mn ? LivenessStrings.mn : const LivenessStrings(),
            invertYaw: _invertYaw,
            invertPitch: _invertPitch,
            showDebug: true,
            onDone: (o) => Navigator.of(ctx).pop(o),
          ),
        ),
      );
      if (outcome == null) {
        setState(() => _result = 'Cancelled');
        return;
      }
      if (outcome.status != LivenessStatus.completed) {
        setState(() => _result = '${outcome.status.name}: ${outcome.detail ?? ''}');
        return;
      }

      final verdict = await http.get(Uri.parse('$backend/result/${s['session_id']}'));
      final v = jsonDecode(verdict.body) as Map<String, dynamic>;
      final score = v['face_match_score'];
      setState(() => _result = 'Turns asked: ${(s['turns'] as List).join(', ')}\n'
          'Result: ${v['status']}\n'
          'Reason: ${v['reason']}\n'
          'Match with government photo: ${score == null ? 'not checked' : (score as num).toStringAsFixed(2)}'
          '${score == null ? '' : ' (needs ${v['face_match_threshold']})'}');
    } catch (e) {
      setState(() => _result = 'Error: $e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Liveness test')),
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SwitchListTile(title: const Text('Mongolian prompts'), value: _mn, onChanged: (v) => setState(() => _mn = v)),
              SwitchListTile(title: const Text('Invert left/right'), value: _invertYaw, onChanged: (v) => setState(() => _invertYaw = v)),
              SwitchListTile(title: const Text('Invert up/down'), value: _invertPitch, onChanged: (v) => setState(() => _invertPitch = v)),
              FilledButton(onPressed: _run, child: const Text('Start liveness check')),
              const SizedBox(height: 20),
              Text(_result, style: const TextStyle(fontSize: 18)),
            ],
          ),
        ),
      );
}
