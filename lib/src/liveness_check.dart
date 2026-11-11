import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:face_detection_tflite/face_detection_tflite.dart';
import 'package:flutter/material.dart';
import 'package:flutter_litert/flutter_litert.dart';
import 'package:http/http.dart' as http;
import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'strings.dart';

enum LivenessStatus {
  /// Photos were uploaded. Ask your backend for the verdict.
  completed,

  /// The user ran out of time before all photos were captured.
  timedOut,

  /// Camera could not be opened (no permission, no front camera).
  cameraError,

  /// The upload failed (network, expired or already-used session).
  uploadError,
}

class LivenessOutcome {
  final LivenessStatus status;

  /// Extra detail for logs, e.g. the server's error code. Not for showing to users.
  final String? detail;
  const LivenessOutcome(this.status, [this.detail]);
}

/// Full-screen capture flow. Push it as a route; it calls [onDone] exactly once.
///
/// The face is shown in a circle with a ring around it. For each step the ring shows
/// where to turn and fills up as the head moves; when it is full the photo is taken
/// automatically.
class LivenessCheck extends StatefulWidget {
  /// Base URL of the liveness server, e.g. `https://liveness.bank.mn`.
  final String serverUrl;
  final String sessionId;
  final String sessionToken;

  /// The turns returned by the server when the session was created, in order.
  final List<String> turns;

  /// Seconds the user has, counted from when this widget opens. Keep it a little
  /// below the server's `expires_in_s`, because the session clock started earlier.
  final int timeLimitSeconds;

  final ValueChanged<LivenessOutcome> onDone;
  final LivenessStrings strings;

  /// Flip these if, on a test phone, turning left is read as right (or up as down).
  final bool invertYaw;
  final bool invertPitch;

  /// How far the head must turn, in degrees, measured from the front photo.
  /// Kept a little above the server's thresholds (15 and 10) so captures pass there.
  final double minYawDegrees;
  final double minPitchDegrees;

  /// If a pose is not recognised automatically within this time, a "take photo" button
  /// appears so the user can continue. The server still decides. Null turns this off.
  final Duration? manualCaptureAfter;

  /// Shows the head angles the phone is reading and prints them to the log, for testing.
  final bool showDebug;

  /// Colour of the progress ring.
  final Color accentColor;

  /// Also upload a short burst of small frames taken during each head turn, so the server can
  /// check that the head really moved through the turn (still photos shown one after another
  /// fail that check). Leave on unless the server is an old version.
  final bool sendMotion;

  const LivenessCheck({
    super.key,
    required this.serverUrl,
    required this.sessionId,
    required this.sessionToken,
    required this.turns,
    required this.onDone,
    this.timeLimitSeconds = 18,
    this.strings = const LivenessStrings(),
    this.invertYaw = false,
    this.invertPitch = false,
    this.minYawDegrees = 17,
    this.minPitchDegrees = 11,
    this.manualCaptureAfter = const Duration(seconds: 6),
    this.showDebug = false,
    this.accentColor = const Color(0xFF2EBD85),
    this.sendMotion = true,
  });

  @override
  State<LivenessCheck> createState() => _LivenessCheckState();
}

class _LivenessCheckState extends State<LivenessCheck> {
  static const _holdFrames = 3; // pose must hold this many frames before a photo is taken
  static const _frontMaxYaw = 12.0;
  static const _frontMaxPitch = 20.0;

  CameraController? _cam;
  FaceDetector? _detector;
  Timer? _ticker;

  late final List<String> _steps = ['front', ...widget.turns];
  final List<Uint8List> _photos = [];
  int _step = 0;
  int _hold = 0;
  int _frameNo = 0;
  double _frontYaw = 0, _frontPitch = 0;

  // Motion burst: what the camera saw on the way to the current pose, and the bursts already chosen.
  static const _seenEvery = Duration(milliseconds: 90);
  static const _seenMax = 24;
  final List<_Seen> _seen = [];
  final List<List<Uint8List>> _motion = [];
  DateTime _lastSeen = DateTime.fromMillisecondsSinceEpoch(0);
  double _prevYaw = 0, _prevPitch = 0;

  // Some phones deliver camera frames lying on their side or upside down, whatever the camera
  // plugin reports. While no face is found, the other rotations are tried in turn and the one
  // that works is kept. On iOS the preview shows the same frames, so it is turned the same way.
  static const _rotations = <CameraFrameRotation?>[
    null,
    CameraFrameRotation.cw90,
    CameraFrameRotation.cw180,
    CameraFrameRotation.cw270,
  ];
  int? _rotIndex; // rotation in use; null = what the camera plugin reports
  bool _rotLocked = false;
  int _noFaceFrames = 0;
  int _previewTurns = 0; // quarter turns clockwise applied to the preview (iOS only)
  double _frameAspect = 4 / 3; // width / height of the frames as delivered
  bool _busy = false;
  bool _finished = false;
  bool _uploading = false;
  bool _manualRequested = false;
  DateTime _stepStarted = DateTime.now();
  String? _hint;
  late int _secondsLeft = widget.timeLimitSeconds;

  /// 0..1: how close the head is to the pose being asked for. Drives the ring.
  final ValueNotifier<double> _progress = ValueNotifier(0);
  final ValueNotifier<String> _debug = ValueNotifier('');

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final cameras = await availableCameras();
      final front = cameras.firstWhere((c) => c.lensDirection == CameraLensDirection.front);
      final cam = CameraController(
        front,
        ResolutionPreset.medium,
        enableAudio: false,
        // YUV on both platforms. The face tracker cannot read the camera plugin's BGRA frames on iOS
        // (the plugin leaves out the bytes-per-pixel value it needs) and silently reports no face.
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await cam.initialize();
      final detector = await FaceDetector.create(model: FaceDetectionModel.frontCamera);
      if (!mounted) {
        await cam.dispose();
        await detector.dispose();
        return;
      }
      _cam = cam;
      _detector = detector;
      await cam.startImageStream(_onFrame);
      _stepStarted = DateTime.now();
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_finished || _uploading) return;
        setState(() => _secondsLeft--);
        if (_secondsLeft <= 0) _finish(const LivenessOutcome(LivenessStatus.timedOut));
      });
      setState(() {});
    } catch (e) {
      _finish(LivenessOutcome(LivenessStatus.cameraError, e.toString()));
    }
  }

  Future<void> _onFrame(CameraImage image) async {
    final cam = _cam, detector = _detector;
    if (_busy || _finished || _uploading || cam == null || detector == null) return;
    _busy = true;
    try {
      final reported = rotationForFrame(
        width: image.width,
        height: image.height,
        sensorOrientation: cam.description.sensorOrientation,
        isFrontCamera: true,
        deviceOrientation: cam.value.deviceOrientation,
      );
      final rotation = _rotIndex == null ? reported : _rotations[_rotIndex!];
      // "standard" mode is the cheapest one that reports yaw and pitch.
      final faces = await detector.detectFacesFromCameraImage(
        image,
        rotation: rotation,
        mode: FaceDetectionMode.standard,
        maxDim: 640,
      );
      if (!mounted || _finished) return;

      // Settle which way up the frames are.
      if (faces.isNotEmpty) {
        _noFaceFrames = 0;
        if (!_rotLocked) {
          _rotLocked = true;
          final turns = Platform.isIOS ? _rotations.indexOf(rotation) : 0;
          if (turns != _previewTurns || _frameAspect != image.width / image.height) {
            setState(() {
              _previewTurns = turns;
              _frameAspect = image.width / image.height;
            });
          }
        }
      } else if (!_rotLocked && ++_noFaceFrames >= 4) {
        _noFaceFrames = 0;
        _rotIndex = ((_rotIndex ?? _rotations.indexOf(reported)) + 1) % _rotations.length;
      }

      final step = _steps[_step];
      double yaw = 0, pitch = 0, target = 0;
      if (faces.length == 1) {
        final face = faces.first;
        // Confirmed against the server on saved photos: the tracker's positive yaw is the user's left.
        yaw = (face.headEulerAngleY ?? 0) * (widget.invertYaw ? -1 : 1); // + = user's left
        pitch = (face.headEulerAngleX ?? 0) * (widget.invertPitch ? -1 : 1); // + = up
        target = _towardsTarget(step, yaw, pitch);
        // Turning clearly the opposite way gets a hint instead of silence.
        _setHint(target < -0.6 ? widget.strings.otherWay : null);
      } else {
        _setHint(faces.isEmpty ? widget.strings.noFace : widget.strings.oneFaceOnly);
      }
      // Remember this frame for the motion burst (turn steps only).
      if (widget.sendMotion && step != 'front' && DateTime.now().difference(_lastSeen) >= _seenEvery) {
        final frame = prepareCameraFrameFromImage(image, rotation: rotation);
        if (frame != null) {
          _lastSeen = DateTime.now();
          _seen.add(_Seen(frame, yaw, pitch, faces.length == 1));
          if (_seen.length > _seenMax) _seen.removeAt(0);
        }
      }

      // Smooth the ring a little so it glides instead of jumping.
      final p = target.clamp(0.0, 1.0);
      _progress.value = 0.5 * _progress.value + 0.5 * p;

      if (widget.showDebug) {
        final dy = (yaw - _frontYaw).toStringAsFixed(0), dp = (pitch - _frontPitch).toStringAsFixed(0);
        _debug.value = '${faces.length == 1 ? 'left/right $dy°   up/down $dp°' : 'faces seen: ${faces.length}'}\n'
            'frame ${image.width}x${image.height}  sensor ${cam.description.sensorOrientation}  '
            '${cam.value.deviceOrientation.name}\n'
            'plugin says ${reported?.name ?? 'none'}  using ${rotation?.name ?? 'none'}'
            '${_rotLocked ? '' : ' (searching)'}  preview turns $_previewTurns';
        if (_frameNo++ % 4 == 0) {
          debugPrint('LV step=$step faces=${faces.length} yaw=${yaw.toStringAsFixed(1)} '
              'pitch=${pitch.toStringAsFixed(1)} dyaw=$dy dpitch=$dp target=${target.toStringAsFixed(2)} '
              'img=${image.width}x${image.height} sensor=${cam.description.sensorOrientation}');
        }
      }

      // The user may press the button when a pose is not picked up automatically.
      final manual = _manualRequested;
      _manualRequested = false;
      if (!manual) {
        if (faces.length != 1 || target < 1.0) {
          _hold = 0;
          return;
        }
        if (++_hold < _holdFrames) return;
      }

      // Pose reached: take the photo that will be uploaded.
      _progress.value = 1;
      final file = await cam.takePicture();
      final bytes = await file.readAsBytes();
      unawaited(File(file.path).delete().catchError((_) => File(file.path)));
      if (!mounted || _finished) return;
      if (widget.showDebug) debugPrint('LV captured step=$step manual=$manual bytes=${bytes.length}');

      _photos.add(bytes);
      if (step == 'front') {
        _frontYaw = yaw;
        _frontPitch = pitch;
      } else if (widget.sendMotion) {
        _motion.add(_pickMotion(yaw, pitch));
      }
      _prevYaw = yaw;
      _prevPitch = pitch;
      _seen.clear();
      _hold = 0;
      _stepStarted = DateTime.now();
      if (_step + 1 < _steps.length) {
        setState(() => _step++);
        _progress.value = 0;
      } else {
        await _upload();
      }
    } catch (e) {
      // A dropped frame or a failed capture is not fatal; the next frame retries.
      _hold = 0;
      if (widget.showDebug) debugPrint('LV frame error: $e');
    } finally {
      _busy = false;
    }
  }

  /// How far towards the asked pose the head is: 0 = not at all, 1 = reached, below 0 = the other way.
  double _towardsTarget(String step, double yaw, double pitch) {
    final dYaw = yaw - _frontYaw, dPitch = pitch - _frontPitch;
    switch (step) {
      case 'front':
        // 1 when looking straight, falling off as the head turns away.
        final off = math.max(yaw.abs() / _frontMaxYaw, pitch.abs() / _frontMaxPitch);
        return off <= 1 ? 1 : math.max(0.0, 2 - off);
      case 'left':
        return dYaw / widget.minYawDegrees;
      case 'right':
        return -dYaw / widget.minYawDegrees;
      case 'up':
        return dPitch / widget.minPitchDegrees;
      case 'down':
        return -dPitch / widget.minPitchDegrees;
    }
    return 0;
  }

  /// From everything seen during this turn, up to four frames spread along the way from the
  /// previous pose to the new one, as small JPEGs.
  List<Uint8List> _pickMotion(double yaw, double pitch) {
    final vy = yaw - _prevYaw, vp = pitch - _prevPitch, d2 = vy * vy + vp * vp;
    final picks = <_Seen>[];
    if (d2 > 0) {
      double along(_Seen s) => ((s.yaw - _prevYaw) * vy + (s.pitch - _prevPitch) * vp) / d2;
      for (final t in const [0.2, 0.4, 0.6, 0.8]) {
        _Seen? best;
        for (final s in _seen) {
          if (!s.oneFace || (along(s) - t).abs() > 0.15) continue;
          if (best == null || (along(s) - t).abs() < (along(best) - t).abs()) best = s;
        }
        if (best != null && !picks.contains(best)) picks.add(best);
      }
      picks.sort((a, b) => along(a).compareTo(along(b)));
    }
    if (picks.length < 2) {
      // Tracking gave too little (for example a manual capture): spread evenly in time instead.
      picks.clear();
      for (var j = 1; j <= 4 && _seen.isNotEmpty; j++) {
        final s = _seen[math.min(_seen.length - 1, _seen.length * j ~/ 5)];
        if (!picks.contains(s)) picks.add(s);
      }
    }
    final out = <Uint8List>[];
    for (final s in picks) {
      final jpeg = _toJpeg(s.frame);
      if (jpeg != null) out.add(jpeg);
    }
    if (widget.showDebug) debugPrint('LV motion frames=${out.length} of ${_seen.length} seen');
    return out;
  }

  /// A camera frame as an upright JPEG with its longest side at most 480 pixels, or null if it
  /// cannot be converted. Mirrors the decoding the face tracker itself does.
  static Uint8List? _toJpeg(CameraFrame frame) {
    try {
      final plan = frame.decodePlan();
      final layout = plan.sourceLayout;
      final src = cv.Mat.create(
        rows: layout.rows,
        cols: layout.cols,
        type: layout.channels == 4 ? cv.MatType.CV_8UC4 : cv.MatType.CV_8UC1,
      );
      layout.copyTo(src.data, frame.bytes);
      final code = switch (plan.conversion) {
        CameraFrameConversion.bgra2bgr => cv.COLOR_BGRA2BGR,
        CameraFrameConversion.rgba2bgr => cv.COLOR_RGBA2BGR,
        CameraFrameConversion.yuv2bgrNv12 => cv.COLOR_YUV2BGR_NV12,
        CameraFrameConversion.yuv2bgrNv21 => cv.COLOR_YUV2BGR_NV21,
        CameraFrameConversion.yuv2bgrI420 => cv.COLOR_YUV2BGR_I420,
      };
      var cur = cv.cvtColor(src, code);
      src.dispose();
      if (plan.hasStridePadding) {
        final cropped = cur.region(cv.Rect(0, 0, plan.visibleWidth, plan.visibleHeight)).clone();
        cur.dispose();
        cur = cropped;
      }
      final longest = math.max(cur.cols, cur.rows);
      if (longest > 480) {
        final k = 480 / longest;
        final small = cv.resize(cur, ((cur.cols * k).toInt(), (cur.rows * k).toInt()), interpolation: cv.INTER_LINEAR);
        cur.dispose();
        cur = small;
      }
      final flag = switch (plan.rotation) {
        CameraFrameRotation.cw90 => cv.ROTATE_90_CLOCKWISE,
        CameraFrameRotation.cw180 => cv.ROTATE_180,
        CameraFrameRotation.cw270 => cv.ROTATE_90_COUNTERCLOCKWISE,
        null => null,
      };
      if (flag != null) {
        final turned = cv.rotate(cur, flag);
        cur.dispose();
        cur = turned;
      }
      final (ok, bytes) = cv.imencode('.jpg', cur);
      cur.dispose();
      return ok ? bytes : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _upload() async {
    setState(() => _uploading = true);
    try {
      await _cam?.stopImageStream();
    } catch (_) {}
    try {
      final base = widget.serverUrl.replaceAll(RegExp(r'/+$'), '');
      final res = await http
          .post(
            Uri.parse('$base/v1/sessions/${widget.sessionId}/frames'),
            headers: {
              'Authorization': 'Bearer ${widget.sessionToken}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'frames': _photos.map(base64Encode).toList(),
              if (widget.sendMotion) 'motion': [for (final burst in _motion) burst.map(base64Encode).toList()],
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode == 200) {
        _finish(const LivenessOutcome(LivenessStatus.completed));
      } else {
        _finish(LivenessOutcome(LivenessStatus.uploadError, 'HTTP ${res.statusCode} ${res.body}'));
      }
    } catch (e) {
      _finish(LivenessOutcome(LivenessStatus.uploadError, e.toString()));
    }
  }

  void _setHint(String? hint) {
    if (hint != _hint && mounted) setState(() => _hint = hint);
  }

  void _finish(LivenessOutcome outcome) {
    if (_finished) return;
    _finished = true;
    _photos.clear();
    _seen.clear();
    _motion.clear();
    _ticker?.cancel();
    if (mounted) widget.onDone(outcome);
  }

  @override
  void dispose() {
    _finished = true;
    _ticker?.cancel();
    _photos.clear();
    final cam = _cam, detector = _detector;
    _cam = null;
    _detector = null;
    () async {
      try {
        if (cam != null && cam.value.isStreamingImages) await cam.stopImageStream();
      } catch (_) {}
      await cam?.dispose();
      await detector?.dispose();
    }();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cam = _cam;
    final s = widget.strings;
    final ready = cam != null && cam.value.isInitialized;
    final step = _steps[_step];
    final prompt = !ready ? s.starting : (_uploading ? s.uploading : s.forStep(step));
    final showManual = ready &&
        !_uploading &&
        widget.manualCaptureAfter != null &&
        DateTime.now().difference(_stepStarted) > widget.manualCaptureAfter!;

    return Scaffold(
      backgroundColor: const Color(0xFF0B0E11),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) {
            final size = math.min(box.maxWidth * 0.78, box.maxHeight * 0.5);
            return Column(
              children: [
                const SizedBox(height: 28),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    prompt,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 24,
                  child: Text(
                    ready && !_uploading ? (_hint ?? '') : '',
                    style: const TextStyle(color: Colors.amber, fontSize: 16),
                  ),
                ),
                const SizedBox(height: 16),
                // Camera in a circle, with the progress ring around it.
                SizedBox(
                  width: size + 72,
                  height: size + 72,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      ClipOval(
                        child: SizedBox(
                          width: size,
                          height: size,
                          child: ready
                              ? FittedBox(
                                  fit: BoxFit.cover,
                                  clipBehavior: Clip.hardEdge,
                                  child: SizedBox(
                                    width: size,
                                    child: _previewTurns == 0
                                        ? CameraPreview(cam)
                                        // The frames arrive turned; show them the way the tracker reads them.
                                        : RotatedBox(
                                            quarterTurns: _previewTurns,
                                            child: AspectRatio(aspectRatio: _frameAspect, child: cam.buildPreview()),
                                          ),
                                  ),
                                )
                              : const ColoredBox(color: Colors.black),
                        ),
                      ),
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _RingPainter(
                            progress: _progress,
                            step: step,
                            done: _steps.sublist(1, math.max(1, _step)),
                            accent: widget.accentColor,
                            busy: _uploading,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                // Step dots and time left
                if (_uploading)
                  CircularProgressIndicator(color: widget.accentColor)
                else
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < _steps.length; i++)
                        Container(
                          width: i == _step ? 22 : 10,
                          height: 10,
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(5),
                            color: i < _step
                                ? widget.accentColor
                                : (i == _step ? Colors.white : Colors.white24),
                          ),
                        ),
                    ],
                  ),
                const SizedBox(height: 10),
                if (ready && !_uploading)
                  Text('$_secondsLeft', style: const TextStyle(color: Colors.white54, fontSize: 16)),
                if (ready && !_uploading && widget.showDebug)
                  ValueListenableBuilder<String>(
                    valueListenable: _debug,
                    builder: (_, v, __) => Text(
                      v,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.amber, fontSize: 12),
                    ),
                  ),
                if (showManual)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white54),
                      ),
                      onPressed: () => _manualRequested = true,
                      child: Text(s.takePhoto),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// One camera frame remembered during a head turn, with the head angles the tracker read in it.
class _Seen {
  final CameraFrame frame;
  final double yaw, pitch;
  final bool oneFace;
  const _Seen(this.frame, this.yaw, this.pitch, this.oneFace);
}

/// The ring around the camera circle.
///
/// The ring is made of short tick marks.
/// - front step: the ticks light up all the way round as the face settles straight.
/// - turn steps: the ticks on the side to turn towards light up from the middle outwards,
///   with a small arrow; finished directions stay lit.
class _RingPainter extends CustomPainter {
  final ValueNotifier<double> progress;
  final String step;
  final List<String> done;
  final Color accent;
  final bool busy;

  _RingPainter({
    required this.progress,
    required this.step,
    required this.done,
    required this.accent,
    required this.busy,
  }) : super(repaint: progress);

  // Screen angle of each direction. The preview is a mirror, so the user's left is the screen's left.
  static const _angle = {'right': 0.0, 'down': math.pi / 2, 'left': math.pi, 'up': -math.pi / 2};
  static const _span = math.pi / 2.6; // width of one direction's arc

  static const _ticks = 72;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 20; // inner end of the tick marks
    final p = progress.value.clamp(0.0, 1.0);
    final target = _angle[step];

    // Smallest distance between two angles, 0..pi.
    double apart(double x, double y) {
      final d = (x - y).abs() % (2 * math.pi);
      return d > math.pi ? 2 * math.pi - d : d;
    }

    for (var i = 0; i < _ticks; i++) {
      final a = -math.pi / 2 + 2 * math.pi * i / _ticks; // start at the top, go clockwise
      var color = Colors.white24;
      var length = 10.0;
      var width = 2.0;

      if (busy) {
        color = accent;
        length = 14;
      } else if (step == 'front') {
        if (i < p * _ticks) {
          color = accent;
          length = 14;
        }
      } else {
        for (final d in done) {
          final da = _angle[d];
          if (d != step && da != null && apart(a, da) <= _span / 2) color = accent.withValues(alpha: 0.6);
        }
        if (target != null) {
          final dist = apart(a, target);
          if (dist <= _span / 2) {
            // Inside the asked direction: bright track, filling outwards from its middle.
            color = Colors.white70;
            length = 16;
            width = 2.5;
            if (p > 0.02 && dist <= _span * p / 2) {
              color = accent;
              length = 20;
              width = 3;
            }
          }
        }
      }
      final dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(
        c + dir * r,
        c + dir * (r + length),
        Paint()
          ..color = color
          ..strokeWidth = width
          ..strokeCap = StrokeCap.round,
      );
    }

    // Arrow outside the ring, pointing the way to turn.
    if (!busy && target != null) {
      final dir = Offset(math.cos(target), math.sin(target));
      final side = Offset(-dir.dy, dir.dx);
      final tip = c + dir * (r + 40);
      final l = tip - dir * 12 + side * 9, rr = tip - dir * 12 - side * 9;
      final arrow = Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo(l.dx, l.dy)
        ..lineTo(rr.dx, rr.dy)
        ..close();
      canvas.drawPath(arrow, Paint()..color = p >= 1 ? accent : Colors.white);
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.step != step || old.busy != busy || old.done.length != done.length || old.accent != accent;
}
