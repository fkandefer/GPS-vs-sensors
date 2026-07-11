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
  // Status nagrywania i licznik danych
  bool _isRecording = false;
  int _lineCount = 0;
  Timer? _timer;
  int _secondsElapsed = 0;

  // Przechowywanie bieżących wartości sensorów
  String _accelerometerData = "X: 0.0, Y: 0.0, Z: 0.0";
  String _gyroscopeData = "X: 0.0, Y: 0.0, Z: 0.0";
  String _gpsData = "Lat: 0.0, Lon: 0.0, Alt: 0.0, Speed: 0.0";
  String _barometerData = "1013.25 hPa (Domyślne)";

  // Strumienie i subskrypcje
  final List<StreamSubscription> _streamSubscriptions = [];
  Position? _currentPosition;
  
  // Bufor zapisu do pliku CSV
  final List<String> _csvRows = [];

  @override
  void initState() {
    super.initState();
    _initLivePreviews();
  }

  // Stały podgląd danych na ekranie (niezależny od nagrywania)
  void _initLivePreviews() {
    _streamSubscriptions.add(
      accelerometerEventStream(samplingPeriod: const Duration(milliseconds: 10)).listen((event) {
        if (mounted) {
          setState(() {
            _accelerometerData = "X: ${event.x.toStringAsFixed(2)}, Y: ${event.y.toStringAsFixed(2)}, Z: ${event.z.toStringAsFixed(2)}";
          });
          if (_isRecording) _recordRow("ACC", "${event.x};${event.y};${event.z}");
        }
      }),
    );

    _streamSubscriptions.add(
      gyroscopeEventStream(samplingPeriod: const Duration(milliseconds: 10)).listen((event) {
        if (mounted) {
          setState(() {
            _gyroscopeData = "X: ${event.x.toStringAsFixed(2)}, Y: ${event.y.toStringAsFixed(2)}, Z: ${event.z.toStringAsFixed(2)}";
          });
          if (_isRecording) _recordRow("GYRO", "${event.x};${event.y};${event.z}");
        }
      }),
    );

    try {
      _streamSubscriptions.add(
        barometerEventStream(samplingPeriod: const Duration(milliseconds: 20)).listen((event) {
          if (mounted) {
            setState(() {
              _barometerData = "${event.pressure.toStringAsFixed(2)} hPa";
            });
            if (_isRecording) _recordRow("BARO", "${event.pressure}");
          }
        }),
      );
    } catch (_) {}
  }

  // Metoda żądania uprawnień
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
      if (!serviceEnabled) {
        return false;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      
      return permission == LocationPermission.whileInUse || 
             permission == LocationPermission.always;
    }
    return false;
  }

  // Główna funkcja przycisku START / STOP
  void _toggleRecording() async {
    if (_isRecording) {
      // STOP NAGRYWANIA
      _timer?.cancel();
      setState(() {
        _isRecording = false;
      });
      _saveAndShareCSV();
    } else {
      // START NAGRYWANIA
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
      _csvRows.add("Timestamp_ms;Sensor_Type;Data_Fields");
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
      _currentPosition = position;
      if (mounted) {
        setState(() {
          _gpsData = "Lat: ${position.latitude.toStringAsFixed(5)}, Lon: ${position.longitude.toStringAsFixed(5)}, Alt: ${position.altitude.toStringAsFixed(1)}, Spd: ${position.speed.toStringAsFixed(2)}";
        });
      }
      _recordRow("GPS", "${position.latitude};${position.longitude};${position.altitude};${position.speed};${position.accuracy}");
    });
  }

  void _recordRow(String sensorType, String dataFields) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    _csvRows.add("$timestamp;$sensorType;$dataFields");
    if (mounted) {
      setState(() {
        _lineCount++;
      });
    }
  }

  // Bezpieczne zapisywanie i wywoływanie Share Sheet z pozycjonowaniem origin pod iOS
  void _saveAndShareCSV() async {
    if (_csvRows.length <= 1) return;

    try {
      final directory = await getTemporaryDirectory();
      final filename = "imu_log_${DateTime.now().millisecondsSinceEpoch}.csv";
      final file = File('${directory.path}/$filename');

      await file.writeAsString(_csvRows.join('\n'));

      // Pobieramy kontekst geometrii ekranu dla iOS Share Sheet Anchor
      final box = context.findRenderObject() as RenderBox?;
      final position = box != null 
          ? box.localToGlobal(Offset.zero) & box.size 
          : Rect.fromLTWH(0, 0, 10, 10);

      // Wywołanie okna udostępniania
      await Share.shareXFiles(
        [XFile(file.path)], 
        text: 'Mój log pomiarowy CSV z czujników IMU i GPS.',
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
                            const Text("Czas trwania", style: TextStyle(color: Colors.grey)),
                            Text(_formatTime(_secondsElapsed), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                          ],
                        ),
                        Column(
                          children: [
                            const Text("Zapisane linie", style: TextStyle(color: Colors.grey)),
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
                  _buildSensorCard("Akcelerometr (IMU)", _accelerometerData, Icons.import_export, Colors.blueAccent),
                  _buildSensorCard("Żyroskop (IMU)", _gyroscopeData, Icons.sync, Colors.tealAccent),
                  _buildSensorCard("Lokalizacja (GPS)", _gpsData, Icons.gps_fixed, Colors.greenAccent),
                  _buildSensorCard("Barometr (Ciśnienie)", _barometerData, Icons.compress, Colors.purpleAccent),
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
                _isRecording ? "STOP I UDOSTĘPNIJ PLIK" : "START NAGRYWANIA",
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