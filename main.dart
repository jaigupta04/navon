// main.dart
import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:http/http.dart' as http;

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PDR + Virtual Route Test',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const PdrRoutePage(),
    );
  }
}

class PdrRoutePage extends StatefulWidget {
  const PdrRoutePage({super.key});
  @override
  State<PdrRoutePage> createState() => _PdrRoutePageState();
}

class _PdrRoutePageState extends State<PdrRoutePage> {
  // ---------- PDR fixed parameters (tuned for general phone) ----------
  double stepThreshold = 1.05; // accel magnitude threshold (g units)
  int refractoryMs = 300; // minimum ms between detected steps
  double stepLengthMeters = 0.72; // step length fixed

  // ---------- ESP endpoints (static IPs you set on each ESP) ----------
  final String leftEsp = 'http://10.77.49.146';
  final String rightEsp = 'http://10.77.49.147';

  // ---------- PDR runtime ----------
  StreamSubscription<AccelerometerEvent>? _accSub;
  StreamSubscription<CompassEvent>? _compSub;
  double _filteredMag = 0.0;
  final double _alpha = 0.9;
  bool _isPeak = false;
  int _lastStepTime = 0;
  int _steps = 0;
  double _distance = 0.0; // total meters moved
  double _heading = 0.0; // degrees (0..360)
  bool _tracking = false;

  // ---------- ESP connection status ----------
  bool _leftConnected = false;
  bool _rightConnected = false;
  String _leftStatus = 'Unknown';
  String _rightStatus = 'Unknown';

  // ---------- Virtual route presets ----------
  // Each route is a List<Map<String, dynamic>> like your working code
  final Map<String, List<Map<String, dynamic>>> _presets = {
    'Map A (demo)': [
      {'dist': 10.0, 'action': 'right'},
      {'dist': 2.0, 'action': 'left'},
      {'dist': 5.0, 'action': 'uturn'},
      {'dist': 10.0, 'action': 'stop'},
    ],
    'Map B (short loop)': [
      {'dist': 8.0, 'action': 'right'},
      {'dist': 3.0, 'action': 'left'},
      {'dist': 6.0, 'action': 'uturn'},
      {'dist': 8.0, 'action': 'stop'},
    ],
    'Map C (alt demo)': [
      {'dist': 9.0, 'action': 'left'},
      {'dist': 2.5, 'action': 'right'},
      {'dist': 5.5, 'action': 'uturn'},
      {'dist': 9.0, 'action': 'stop'},
    ],
  };

  String _selectedMapName = 'Map A (demo)';

  // active route used during simulation (copied from preset on Start)
  late List<Map<String, dynamic>> _route;

  int _currentLeg = 0;
  double _legAccum = 0.0;
  String _routeStatus = 'Idle';

  // thresholds for detecting completion of a turn (degrees)
  final double _turnDetectDeg = 40.0; // heading change for left/right (approx)
  final double _uturnDetectDeg = 150.0; // for u-turn (~180 deg)

  // for turn detection we store the heading at turn-start
  double? _turnStartHeading;

  @override
  void initState() {
    super.initState();
    // initialize active route with default preset
    _route = List<Map<String, dynamic>>.from(_presets[_selectedMapName]!);
  }

  // ------------------- PDR: start / stop -------------------
  Future<void> _startTracking() async {
    if (_tracking) return;

    // copy preset into active route so we can mutate leg progress
    _route = List<Map<String, dynamic>>.from(_presets[_selectedMapName]!);

    _steps = 0;
    _distance = 0.0;
    _legAccum = 0.0;
    _currentLeg = 0;
    _routeStatus = 'Running route - waiting...';

    // compass
    _compSub = FlutterCompass.events?.listen((CompassEvent ev) {
      if (ev.heading != null) {
        setState(() => _heading = ev.heading!.toDouble());
      }
    });

    // accelerometer step detection
    _accSub = accelerometerEvents.listen((AccelerometerEvent ev) {
      final now = DateTime.now().millisecondsSinceEpoch;
      // convert accel (m/s^2) -> g units
      final ax = ev.x / 9.80665;
      final ay = ev.y / 9.80665;
      final az = ev.z / 9.80665;
      final mag = sqrt(ax * ax + ay * ay + az * az);
      _filteredMag = _alpha * _filteredMag + (1 - _alpha) * mag;

      // peak detection
      if (!_isPeak && _filteredMag > stepThreshold) {
        if (now - _lastStepTime > refractoryMs) {
          _registerStep(now);
        }
        _isPeak = true;
      } else if (_filteredMag < stepThreshold * 0.9) {
        _isPeak = false;
      }
    });

    setState(() {
      _tracking = true;
      _routeStatus = 'Route started';
    });
  }

  Future<void> _stopTracking() async {
    await _accSub?.cancel();
    await _compSub?.cancel();
    _accSub = null;
    _compSub = null;
    setState(() => _tracking = false);
  }

  void _resetAll() {
    _stopTracking();
    setState(() {
      _steps = 0;
      _distance = 0.0;
      _legAccum = 0.0;
      _currentLeg = 0;
      _routeStatus = 'Idle';
      _turnStartHeading = null;
    });
  }

  // called when a step is detected
  Future<void> _registerStep(int timestampMs) async {
    _lastStepTime = timestampMs;
    _steps += 1;
    _distance += stepLengthMeters;
    _legAccum += stepLengthMeters;

    // check route progress
    if (_currentLeg < _route.length) {
      final legTarget = _route[_currentLeg]['dist'] as double;
      if (_legAccum >= legTarget) {
        // reached the waypoint - trigger action
        final action = _route[_currentLeg]['action'] as String;
        await _triggerAction(action);
        // for turns we will wait for heading change to declare completion
        // for stop we may end simulation
        if (action == 'right' || action == 'left' || action == 'uturn') {
          // store start heading so we can detect change
          _turnStartHeading = _heading;
        } else {
          // stop or other immediate actions: reset leg accumulation and move on
          _legAccum = 0.0;
          _currentLeg += 1;
        }
      }
    }

    setState(() {});
    // small safety: cap distance
    if (_distance > 10000) _distance = 10000;
  }

  // ------------------- ESP helper functions -------------------
  Future<bool> _ping(String baseUrl) async {
    try {
      final r = await http.get(Uri.parse('$baseUrl/')).timeout(const Duration(seconds: 2));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<void> _pingBoth() async {
    setState(() => _routeStatus = 'Checking ESPs...');
    final leftOk = await _ping(leftEsp);
    final rightOk = await _ping(rightEsp);
    setState(() {
      _leftConnected = leftOk;
      _rightConnected = rightOk;
      _leftStatus = leftOk ? 'Connected' : 'Not reachable';
      _rightStatus = rightOk ? 'Connected' : 'Not reachable';
      _routeStatus = 'ESP check done';
    });
  }

  Future<void> _send(String baseUrl, String path) async {
    try {
      await http.get(Uri.parse('$baseUrl$path')).timeout(const Duration(seconds: 2));
    } catch (e) {
      // ignore; ping function will show status
    }
  }

  // action mapping (keeps same behavior as your working test code)
  Future<void> _triggerAction(String action) async {
    setState(() => _routeStatus = 'Triggered: $action');
    if (action == 'right') {
      // start right ESP continuous blue / vibration
      await _send(rightEsp, '/startBlue');
    } else if (action == 'left') {
      await _send(leftEsp, '/startBlue');
    } else if (action == 'uturn') {
      // both blink/ vibrate
      await _send(leftEsp, '/startBlue');
      await _send(rightEsp, '/startBlue');
    } else if (action == 'stop') {
      // start alternate on both
      await _send(leftEsp, '/startAlt');
      await _send(rightEsp, '/startAlt');
      // schedule stop after a short time
      Future.delayed(const Duration(seconds: 4), () async {
        await _send(leftEsp, '/stopBlink');
        await _send(rightEsp, '/stopBlink');
        setState(() => _routeStatus = 'Route ended (stop)');
      });
      return;
    }
    // For turn-type actions we wait for detection of heading change
    _monitorTurnDetection(action);
  }

  Timer? _turnTimer;
  void _monitorTurnDetection(String action) {
    _turnTimer?.cancel();
    final started = DateTime.now();
    _turnTimer = Timer.periodic(const Duration(milliseconds: 300), (t) {
      final startH = _turnStartHeading ?? _heading;
      double diff = (_heading - startH).abs();
      if (diff > 180) diff = 360 - diff;
      if (action == 'uturn') {
        if (diff >= _uturnDetectDeg) {
          _completeTurn(action);
        }
      } else {
        if (diff >= _turnDetectDeg) {
          _completeTurn(action);
        }
      }
      if (DateTime.now().difference(started).inSeconds > 60) {
        _completeTurn(action, timeout: true);
      }
    });
  }

  Future<void> _completeTurn(String action, {bool timeout = false}) async {
    _turnTimer?.cancel();
    _turnStartHeading = null;
    if (action == 'right') {
      await _send(rightEsp, '/stopBlink');
    } else if (action == 'left') {
      await _send(leftEsp, '/stopBlink');
    } else if (action == 'uturn') {
      await _send(leftEsp, '/stopBlink');
      await _send(rightEsp, '/stopBlink');
    }
    // advance to next leg
    _legAccum = 0.0;
    _currentLeg += 1;
    setState(() {
      _routeStatus = timeout ? 'Turn timeout - moved on' : 'Turn detected - completed';
    });
  }

  // ------------------- UI -------------------
  Widget _buildEspStatusRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        Column(children: [
          Icon(_leftConnected ? Icons.wifi : Icons.wifi_off, color: _leftConnected ? Colors.green : Colors.red),
          const SizedBox(height: 4),
          Text('Left ESP\n$_leftStatus', textAlign: TextAlign.center),
        ]),
        Column(children: [
          Icon(_rightConnected ? Icons.wifi : Icons.wifi_off, color: _rightConnected ? Colors.green : Colors.red),
          const SizedBox(height: 4),
          Text('Right ESP\n$_rightStatus', textAlign: TextAlign.center),
        ]),
        ElevatedButton(onPressed: _pingBoth, child: const Text('Check Connection')),
      ],
    );
  }

  @override
  void dispose() {
    _accSub?.cancel();
    _compSub?.cancel();
    _turnTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentLegText = _currentLeg < _route.length ? '${_route[_currentLeg]['action']} (${_route[_currentLeg]['dist']} m)' : 'None';
    return Scaffold(
      appBar: AppBar(title: const Text('Navon — PDR + Virtual Routes')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: ListView(
          children: [
            // Route selector
            Row(
              children: [
                const Text('Choose map: '),
                const SizedBox(width: 8),
                DropdownButton<String>(
                  value: _selectedMapName,
                  items: _presets.keys.map((k) => DropdownMenuItem(value: k, child: Text(k))).toList(),
                  onChanged: _tracking
                      ? null
                      : (v) {
                          if (v == null) return;
                          setState(() {
                            _selectedMapName = v;
                            // do not start route automatically; copy on Start
                          });
                        },
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: _tracking ? null : () {
                    // optional quick preview: replace active route with selection
                    setState(() {
                      _route = List<Map<String, dynamic>>.from(_presets[_selectedMapName]!);
                      _routeStatus = 'Selected $_selectedMapName';
                    });
                  },
                  child: const Text('Load Map'),
                ),
              ],
            ),

            const SizedBox(height: 12),
            _buildEspStatusRow(),
            const Divider(),
            Text('Selected map: $_selectedMapName'),
            const SizedBox(height: 8),
            Text('Route status: $_routeStatus'),
            Text('Current leg: $currentLegText'),
            const SizedBox(height: 12),
            Text('Steps: $_steps', style: const TextStyle(fontSize: 18)),
            Text('Distance: ${_distance.toStringAsFixed(2)} m', style: const TextStyle(fontSize: 18)),
            Text('Heading: ${_heading.toStringAsFixed(1)}°', style: const TextStyle(fontSize: 18)),
            const SizedBox(height: 12),
            Row(
              children: [
                ElevatedButton(onPressed: _tracking ? null : _startTracking, child: const Text('Start Simulation')),
                const SizedBox(width: 12),
                ElevatedButton(onPressed: _tracking ? _stopTracking : null, child: const Text('Stop')),
                const SizedBox(width: 12),
                ElevatedButton(onPressed: _resetAll, child: const Text('Reset')),
              ],
            ),
            const SizedBox(height: 12),
            const Text('Notes:'),
            const Text('- Walk naturally carrying the phone.'),
            const Text('- When a leg completes the configured distance, an action fires (right/left/uturn/stop).'),
            const Text('- For turns, app waits until heading changes to consider the turn taken.'),
          ],
        ),
      ),
    );
  }
}
