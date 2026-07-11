import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'IMU & GPS Recorder',
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.deepPurple,
        scaffoldBackgroundColor: const Color(0xFF121212),
      ),
      home: const TrackerHome(),
    );
  }
}

class TrackerHome extends StatefulWidget {
  const TrackerHome({super.key});

  @override
  State<TrackerHome> createState() => _TrackerHomeState();
}

class _TrackerHomeState extends State<TrackerHome> {
  bool _isRecording = false;
  int _lineCount = 0;
  Timer? _timer;
  int _secondsElapsed = 0;

  // Podgląd tekstowy na UI
  String _accelerometerData = "X: 0.0, Y: 0.0, Z: 0.0";
  String _gyroscopeData = "X: 0.0, Y: 0.0, Z: 0.0";
  String _gpsData = "Lat: 0.0, Lon: 0.0, Alt: 0.0, Speed: 0.0";
  String _barometerData = "1013.25 hPa (Domyślne)";

  final List<StreamSubscription> _streamSubscriptions = [];
  
  // Ostatni znany stan czujników do tworzenia struktury wiersza
  double _curAccX = 0.0;
  double _curAccY = 0.0;
  double _curAccZ = 0.0;
  
  double _curGyroX = 0.0;
  double _curGyroY = 0.0;
  double _curGyroZ = 0.0;
  
  String _curLat = "";
  String _curLon = "";
  String _curAlt = "";

  // Bufor zapisu do pliku CSV
  final List<String> _csvRows = [];

  @override
  void initState() {
    super.initState();
    _initLivePreviews();
  }

  // Podgląd i asynchroniczna aktualizacja stanu
  void _initLivePreviews() {
    _streamSubscriptions.add(
      accelerometerEventStream(samplingPeriod: const Duration(milliseconds: 10)).listen((event) {
        if (mounted) {
          setState(() {
            _accelerometerData = "X: ${event.x.toStringAsFixed(2)}, Y: ${event.y.toStringAsFixed(2)}, Z: ${event.z.toStringAsFixed(2)}";
          });
        }
        
        _curAccX = event.x;
        _curAccY = event.y;
        _curAccZ = event.z;
        
        if (_isRecording) _recordCurrentState();
      }),
    );

    _streamSubscriptions.add(
      gyroscopeEventStream(samplingPeriod: const Duration(milliseconds: 10)).listen((event) {
        if (mounted) {
          setState(() {
            _gyroscopeData = "X: ${event.x.toStringAsFixed(2)}, Y: ${event.y.toStringAsFixed(2)}, Z: ${event.z.toStringAsFixed(2)}";
          });
        }
        
        _curGyroX = event.x;
        _curGyroY = event.y;
        _curGyroZ = event.z;
        
        if (_isRecording) _recordCurrentState();
      }),
    );

    try {
      _streamSubscriptions.add(
        barometerEventStream(samplingPeriod: const Duration(milliseconds: 20)).listen((event) {
          if (mounted) {
            setState(() {
              _barometerData = "${event.pressure.toStringAsFixed(2)} hPa";
            });
          }
        }),
      );
    } catch (_) {}
  }

  // Budowanie zunifikowanego wiersza CSV (rozdzielanego przecinkami)
  void _recordCurrentState() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    
    // Format: ts,accX,accY,accZ,gyroX,gyroY,gyroZ,lat,lon,alt
    final row = "$timestamp,$_curAccX,$_curAccY,$_curAccZ,$_curGyroX,$_curGyroY,$_curGyroZ,$_curLat,$_curLon,$_curAlt";
    
    _csvRows.add(row);
    
    if (mounted) {
      setState(() {
        _lineCount++;
      });
    }
  }

  Future<bool> _requestPermissions() async {
    if (Platform.isAndroid) {
      Map<Permission, PermissionStatus> statuses = await [
        Permission.location,
        Permission.sensors,
      ].request();
      return statuses[Permission.location] == PermissionStatus.granted &&
             statuses[Permission.sensors] == PermissionStatus.granted;
    } else if (Platform.isIOS) {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return false;

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      return permission == LocationPermission.whileInUse || 
             permission == LocationPermission.always;
    }
    return false;
  }

  void _toggleRecording() async {
    if (_isRecording) {
      _timer?.cancel();
      setState(() {
        _isRecording = false;
      });
      _saveAndShareCSV();
    } else {
      bool hasPermission = await _requestPermissions();
      if (!hasPermission) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Błąd: Nie przyznano wymaganych uprawnień do GPS!")),
          );
        }
        return;
      }

      _csvRows.clear();
      // Czystszy, standardowy nagłówek CSV rozdzielany przecinkami
      _csvRows.add("ts,accX,accY,accZ,gyroX,gyroY,gyroZ,lat,lon,alt");
      
      _curAccX = 0; _curAccY = 0; _curAccZ = 0;
      _curGyroX = 0; _curGyroY = 0; _curGyroZ = 0;
      _curLat = ""; _curLon = ""; _curAlt = "";
      
      _secondsElapsed = 0;
      _lineCount = 0;

      setState(() {
        _isRecording = true;
      });

      _startTimer();
      _startGpsTracking();
    }
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _secondsElapsed++;
        });
      }
    });
  }

  void _startGpsTracking() {
    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
      ),
    ).listen((Position position) {
      if (!_isRecording) return;
      if (mounted) {
        setState(() {
          _gpsData = "Lat: ${position.latitude.toStringAsFixed(5)}, Lon: ${position.longitude.toStringAsFixed(5)}, Alt: ${position.altitude.toStringAsFixed(1)}, Spd: ${position.speed.toStringAsFixed(2)}";
        });
      }
      
      _curLat = position.latitude.toString();
      _curLon = position.longitude.toString();
      _curAlt = position.altitude.toString();
    });
  }

  void _saveAndShareCSV() async {
    if (_csvRows.length <= 1) return;

    try {
      final directory = await getTemporaryDirectory();
      // Prawidłowe rozszerzenie .csv
      final filename = "sensor_log_${DateTime.now().millisecondsSinceEpoch}.csv";
      final file = File('${directory.path}/$filename');

      await file.writeAsString(_csvRows.join('\n'));

      final box = context.findRenderObject() as RenderBox?;
      final position = box != null 
          ? box.localToGlobal(Offset.zero) & box.size 
          : Rect.fromLTWH(0, 0, 10, 10);

      await Share.shareXFiles(
        [XFile(file.path)], 
        text: 'Mój uporządkowany log CSV (IMU + GPS).',
        sharePositionOrigin: position,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Błąd zapisu pliku: $e")),
        );
      }
    }
  }

  String _formatTime(int totalSeconds) {
    int minutes = totalSeconds ~/ 60;
    int seconds = totalSeconds % 60;
    return "${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}";
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (var sub in _streamSubscriptions) {
      sub.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('IMU & GPS CSV Recorder'),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              color: _isRecording ? Colors.red.withOpacity(0.2) : Colors.deepPurple.withOpacity(0.1),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  children: [
                    Text(
                      _isRecording ? "NAGRYWANIE AKTYWNE" : "URZĄDZENIE GOTOWE",
                      style: TextStyle(
                        fontSize: 18, 
                        fontWeight: FontWeight.bold, 
                        color: _isRecording ? Colors.redAccent : Colors.deepPurpleAccent
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        Column(
                          children: [
                            const Text("Czas", style: TextStyle(color: Colors.grey)),
                            Text(_formatTime(_secondsElapsed), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                          ],
                        ),
                        Column(
                          children: [
                            const Text("Liczba próbek", style: TextStyle(color: Colors.grey)),
                            Text("$_lineCount", style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ListView(
                children: [
                  _buildSensorCard("Akcelerometr", _accelerometerData, Icons.import_export, Colors.blueAccent),
                  _buildSensorCard("Żyroskop", _gyroscopeData, Icons.sync, Colors.tealAccent),
                  _buildSensorCard("Lokalizacja (GPS)", _gpsData, Icons.gps_fixed, Colors.greenAccent),
                  _buildSensorCard("Barometr", _barometerData, Icons.compress, Colors.purpleAccent),
                ],
              ),
            ),
            ElevatedButton(
              onPressed: _toggleRecording,
              style: ElevatedButton.styleFrom(
                backgroundColor: _isRecording ? Colors.red : Colors.deepPurple,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: Text(
                _isRecording ? "ZAKOŃCZ I EKSPORTUJ CSV" : "URUCHOM ZAPIS DANYCH",
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSensorCard(String title, String data, IconData icon, Color color) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        leading: Icon(icon, color: color, size: 30),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6.0),
          child: Text(data, style: const TextStyle(fontFamily: 'monospace', fontSize: 13, color: Colors.white)),
        ),
      ),
    );
  }
}