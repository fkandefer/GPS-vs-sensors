import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

void main() => runApp(const MaterialApp(home: SensorRecorder()));

class SensorRecorder extends StatefulWidget {
  const SensorRecorder({super.key});
  @override
  _SensorRecorderState createState() => _SensorRecorderState();
}

class _SensorRecorderState extends State<SensorRecorder> {
  bool _isRecording = false;
  IOSink? _fileSink;
  Timer? _samplingTimer;
  
  StreamSubscription? _accelSub;
  StreamSubscription? _gyroSub;
  StreamSubscription? _baroSub;
  StreamSubscription? _gpsSub;

  // Cache na dane
  double _ax = 0, _ay = 0, _az = 0;
  double _gx = 0, _gy = 0, _gz = 0;
  double _pressure = 0; 
  double? _lat, _lon, _alt;
  
  int _linesCount = 0;
  String _filePath = "Brak aktywnego zapisu";
  int? _lastTs;

  List<FileSystemEntity> _savedFiles = [];

  @override
  void initState() {
    super.initState();
    _loadSavedFiles();
  }

  Future<void> _loadSavedFiles() async {
    final directory = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    if (await directory.exists()) {
      final files = directory.listSync();
      final csvFiles = files.where((file) => file.path.endsWith('.csv') && file.path.contains('research_sync_')).toList();
      
      csvFiles.sort((a, b) => b.path.compareTo(a.path));

      setState(() {
        _savedFiles = csvFiles;
      });
    }
  }

  Future<void> _startRecording() async {
    await [Permission.location, Permission.sensors].request();
    
    final directory = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    final String timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final File file = File('${directory.path}/research_sync_$timestamp.csv');
    
    _fileSink = file.openWrite();
    _fileSink?.writeln("ts,accX,accY,accZ,gyroX,gyroY,gyroZ,pressure,lat,lon,alt");

    setState(() {
      _isRecording = true;
      _filePath = file.path;
      _linesCount = 0;
    });

    _accelSub = accelerometerEventStream(samplingPeriod: SensorInterval.fastestInterval).listen((e) {
      _ax = e.x; _ay = e.y; _az = e.z;
    });

    _gyroSub = gyroscopeEventStream(samplingPeriod: SensorInterval.fastestInterval).listen((e) {
      _gx = e.x; _gy = e.y; _gz = e.z;
    });

    // W pełni zabezpieczone asynchroniczne nasłuchiwanie barometru
    try {
      _baroSub = barometerEventStream(samplingPeriod: SensorInterval.fastestInterval).listen(
        (e) {
          _pressure = e.pressure;
        },
        onError: (error) {
          // Tutaj łapiemy błąd, który leciał asynchronicznie w strumieniu
          debugPrint("Barometr niedostępny (error w strumieniu): $error");
          setState(() {
            _pressure = -1.0; 
          });
        },
        cancelOnError: false,
      );
    } catch (e) {
      // Awaryjny catch synchroniczny
      debugPrint("Barometr błąd inicjalizacji: $e");
      _pressure = -1.0; 
    }

    _gpsSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.best)
    ).listen((p) {
      _lat = p.latitude; _lon = p.longitude; _alt = p.altitude;
    });

    // Sampler 100Hz (zapis co 10ms)
    _samplingTimer = Timer.periodic(const Duration(milliseconds: 10), (timer) {
      final int ts = DateTime.now().millisecondsSinceEpoch;
      if (ts == _lastTs) return;
      _lastTs = ts;

      final String row = "$ts,$_ax,$_ay,$_az,$_gx,$_gy,$_gz,$_pressure,${_lat ?? ''},${_lon ?? ''},${_alt ?? ''}";
      _fileSink?.writeln(row);
      
      _linesCount++;

      if (_linesCount % 10 == 0) {
        setState(() {});
      }
    });
  }

  Future<void> _stopRecording() async {
    await _accelSub?.cancel();
    await _gyroSub?.cancel();
    await _baroSub?.cancel(); 
    await _gpsSub?.cancel();
    _samplingTimer?.cancel();
    
    await _fileSink?.flush();
    await _fileSink?.close();
    
    setState(() {
      _isRecording = false;
    });

    await _loadSavedFiles();
  }

  void _shareFile(String path) {
    Share.shareXFiles([XFile(path)], text: 'Moje dane z czujników IMU/Baro/GPS');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("IMU Live Debug (100Hz)"),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _debugCard("Akcelerometr [m/s²]", "X: ${_ax.toStringAsFixed(2)}, Y: ${_ay.toStringAsFixed(2)}, Z: ${_az.toStringAsFixed(2)}", Colors.blue),
              _debugCard("Żyroskop [rad/s]", "X: ${_gx.toStringAsFixed(2)}, Y: ${_gy.toStringAsFixed(2)}, Z: ${_gz.toStringAsFixed(2)}", Colors.green),
              _debugCard(
                "Barometr", 
                _pressure == -1.0 ? "Sensor niedostępny" : "${_pressure.toStringAsFixed(2)} hPa", 
                Colors.purple
              ), 
              _debugCard("GPS", _lat != null ? "Lat: ${_lat!.toStringAsFixed(4)}, Lon: ${_lon!.toStringAsFixed(4)}" : "Szukanie sygnału...", Colors.orange),
              const Divider(height: 30),
              Center(
                child: Column(
                  children: [
                    Text("Linii w pliku: $_linesCount", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                    const SizedBox(height: 10),
                    SelectableText(_filePath, style: const TextStyle(fontSize: 10, color: Colors.grey), textAlign: TextAlign.center),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      height: 60,
                      child: ElevatedButton(
                        onPressed: _isRecording ? _stopRecording : _startRecording,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _isRecording ? Colors.red : Colors.green[700],
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))
                        ),
                        child: Text(
                          _isRecording ? "STOP I ZAPISZ" : "START NAGRYWANIA",
                          style: const TextStyle(fontSize: 18, color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 30, bottom: 10),
                child: Text("Zapisane sesje (Najnowsze wyżej):", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ),
              _savedFiles.isEmpty
                  ? const Text("Brak zapisanych plików.", style: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic))
                  : ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _savedFiles.length,
                      itemBuilder: (context, index) {
                        final file = _savedFiles[index];
                        final fileName = file.path.split('/').last;
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            leading: const Icon(Icons.insert_drive_file, color: Colors.indigo),
                            title: Text(fileName, style: const TextStyle(fontSize: 12)),
                            trailing: IconButton(
                              icon: const Icon(Icons.share, color: Colors.blue),
                              onPressed: () => _shareFile(file.path),
                              tooltip: 'Udostępnij plik',
                            ),
                          ),
                        );
                      },
                    ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _debugCard(String title, String data, Color color) {
    return Card(
      elevation: 4,
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: CircleAvatar(backgroundColor: color, radius: 10),
        title: Text(title, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        subtitle: Text(
          data, 
          style: const TextStyle(
            fontSize: 18, 
            fontFamily: 'monospace', 
            fontWeight: FontWeight.bold, 
            color: Colors.black
          )
        ),
      ),
    );
  }
}