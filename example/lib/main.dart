// Test app for the SDK on a real phone.
//
// It talks to the hosted liveness server's test endpoints (/demo/...), the same ones the
// web test page uses. The tester types the access code; no API key is in the app.
// The reference photo is the one saved through the web test page, if any.
//
// The server address is given when building:
//   flutter run --dart-define=SERVER=https://YOUR-LIVENESS-SERVER
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:liveness_sdk/liveness_sdk.dart';

const server = String.fromEnvironment('SERVER');

void main() => runApp(const MaterialApp(home: Home()));

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final _code = TextEditingController();
  String _result = 'Not run yet';
  String _reference = '';
  bool _busy = false;
  bool _mn = false, _debug = true;

  Map<String, String> get _headers => {'X-Demo-Passcode': _code.text.trim(), 'Content-Type': 'application/json'};

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  String _explain(int status, String body) {
    if (status == 401) return 'Wrong access code.';
    if (status == 404) return 'The test page is switched off on the server.';
    if (status == 429) return 'Too many tries. Wait a minute.';
    return 'HTTP $status $body';
  }

  Future<void> _checkReference() async {
    try {
      final res = await http.get(Uri.parse('$server/demo/status'), headers: _headers);
      if (res.statusCode != 200) {
        setState(() => _reference = _explain(res.statusCode, res.body));
        return;
      }
      final saved = (jsonDecode(res.body) as Map<String, dynamic>)['reference_saved'] == true;
      setState(() => _reference = saved
          ? 'Reference photo: saved. Your face will be matched against it.'
          : 'Reference photo: none saved. Only liveness will be checked.');
    } catch (e) {
      setState(() => _reference = 'Could not reach the server: $e');
    }
  }

  Future<void> _uploadReference() async {
    if (_code.text.trim().isEmpty) {
      setState(() => _reference = 'Type the access code first.');
      return;
    }
    try {
      // Resizing also turns iPhone HEIC photos into JPEG.
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1280, maxHeight: 1280, imageQuality: 90);
      if (picked == null) return;
      setState(() => _reference = 'Uploading reference photo…');
      final res = await http.post(Uri.parse('$server/demo/reference'),
          headers: _headers, body: jsonEncode({'photo': base64Encode(await picked.readAsBytes())}));
      if (res.statusCode >= 300) {
        setState(() => _reference = res.body.contains('reference_no_single_face')
            ? 'That photo must show exactly one face.'
            : _explain(res.statusCode, res.body));
        return;
      }
      await _checkReference();
    } catch (e) {
      setState(() => _reference = 'Could not upload: $e');
    }
  }

  Future<void> _run() async {
    if (server.isEmpty) {
      setState(() => _result = 'This build has no server address. Build with --dart-define=SERVER=...');
      return;
    }
    if (_code.text.trim().isEmpty) {
      setState(() => _result = 'Type the access code first.');
      return;
    }
    setState(() {
      _busy = true;
      _result = 'Creating session…';
    });
    try {
      await _checkReference();
      final started = DateTime.now();
      final res = await http.post(Uri.parse('$server/demo/start'), headers: _headers);
      if (res.statusCode != 201) throw _explain(res.statusCode, res.body);
      final s = jsonDecode(res.body) as Map<String, dynamic>;
      final turns = (s['turns'] as List).cast<String>();
      if (!mounted) return;

      final outcome = await Navigator.of(context).push<LivenessOutcome>(
        MaterialPageRoute(
          builder: (ctx) => LivenessCheck(
            serverUrl: server,
            sessionId: s['session_id'] as String,
            sessionToken: s['session_token'] as String,
            turns: turns,
            timeLimitSeconds: (s['expires_in_s'] as num).toInt() - 3,
            strings: _mn ? LivenessStrings.mn : const LivenessStrings(),
            showDebug: _debug,
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

      // The server may still be analysing for a moment.
      Map<String, dynamic> v = {};
      for (var i = 0; i < 20; i++) {
        final verdict = await http.get(Uri.parse('$server/demo/result/${s['session_id']}'), headers: _headers);
        if (verdict.statusCode != 200) throw _explain(verdict.statusCode, verdict.body);
        v = jsonDecode(verdict.body) as Map<String, dynamic>;
        if (v['status'] == 'live' || v['status'] == 'not_live') break;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      final score = v['face_match_score'];
      final seconds = DateTime.now().difference(started).inMilliseconds / 1000;
      setState(() => _result = '${v['status'] == 'live' ? 'LIVE' : 'NOT LIVE'}\n'
          'Reason: ${v['reason']}\n'
          'Turns asked: ${turns.join(', ')}\n'
          'Match with reference: ${score == null ? 'not checked' : '${(score as num).toStringAsFixed(2)} (needs ${v['face_match_threshold']})'}\n'
          'Time taken: ${seconds.toStringAsFixed(1)} s');
    } catch (e) {
      setState(() => _result = 'Error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Liveness SDK test')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _code,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: 'Access code', border: OutlineInputBorder()),
                onSubmitted: (_) => _checkReference(),
              ),
              if (_reference.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_reference)),
              const SizedBox(height: 8),
              OutlinedButton(onPressed: _busy ? null : _uploadReference, child: const Text('Choose reference (ID) photo')),
              const SizedBox(height: 8),
              SwitchListTile(title: const Text('Mongolian prompts'), value: _mn, onChanged: (v) => setState(() => _mn = v)),
              SwitchListTile(title: const Text('Show tracking numbers'), value: _debug, onChanged: (v) => setState(() => _debug = v)),
              const SizedBox(height: 8),
              FilledButton(onPressed: _busy ? null : _run, child: const Text('Start liveness check')),
              const SizedBox(height: 20),
              Text(_result, style: const TextStyle(fontSize: 18)),
              const SizedBox(height: 12),
              const Text('SDK 0.2.3 (motion bursts)', style: TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
        ),
      );
}
