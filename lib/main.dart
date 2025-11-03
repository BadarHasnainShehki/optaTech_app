import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ESP32 Audio Communicator',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        cardTheme: CardThemeData(
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const BluetoothCommunicatorScreen(),
    );
  }
}

class BluetoothCommunicatorScreen extends StatefulWidget {
  const BluetoothCommunicatorScreen({super.key});

  @override
  State<BluetoothCommunicatorScreen> createState() =>
      _BluetoothCommunicatorScreenState();
}

class _BluetoothCommunicatorScreenState
    extends State<BluetoothCommunicatorScreen>
    with TickerProviderStateMixin {
  BluetoothConnection? _connection;
  String? _connectedDeviceAddress;
  String? _connectedDeviceName;
  bool _isDiscovering = false;
  bool _isConnecting = false;
  bool _isConnected = false;
  String _status = 'Disconnected';
  List<String> _log = [];
  StreamSubscription<BluetoothDiscoveryResult>? _discoveryStream;
  List<BluetoothDevice> _discoveredDevices = [];
  String? _micAudioPath;
  bool _isRecordingOnEsp = false;
  final AudioPlayer _audioPlayer = AudioPlayer();
  File? _micFile;
  int _recordedBytes = 0;
  int _recordedPackets = 0;
  late AnimationController _recordingAnimationController;
  late Animation<double> _recordingAnimation;
  final ScrollController _logScrollController = ScrollController();
  int _selectedIndex = 0;

  // Audio buffering for smooth recording
  final List<Uint8List> _audioBuffer = [];
  Timer? _bufferFlushTimer;
  static const int _bufferFlushInterval = 100; // ms
  static const int _expectedChunkSize = 256; // bytes per chunk
  int _droppedPackets = 0;

  // GPS data
  String _lastGpsData = 'No GPS data';

  // Connection quality
  int _packetsReceived = 0;
  DateTime? _recordingStartTime;

  @override
  void initState() {
    super.initState();
    _recordingAnimationController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    _recordingAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(
        parent: _recordingAnimationController,
        curve: Curves.easeInOut,
      ),
    );
    _requestPermissions();
    _addToLog('App initialized. Ready to connect.');
  }

  @override
  void dispose() {
    _recordingAnimationController.dispose();
    _bufferFlushTimer?.cancel();
    try {
      _connection?.finish();
    } catch (_) {}
    _discoveryStream?.cancel();
    _audioPlayer.dispose();
    _logScrollController.dispose();
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    final statuses = await [
      Permission.bluetooth,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.microphone,
      Permission.manageExternalStorage,
    ].request();

    bool allGranted = statuses.values.every((status) => status.isGranted);
    if (allGranted) {
      _addToLog('✅ All permissions granted');
    } else {
      _addToLog('⚠️ Some permissions denied - app may not work correctly');
    }
  }

  void _addToLog(String message) {
    setState(() {
      final timestamp = DateTime.now().toString().substring(11, 19);
      _log.insert(0, '$timestamp: $message'); // Insert at top for newest first
      if (_log.length > 200) _log.removeLast(); // Limit log size
    });
  }

  Future<void> _startDiscovery() async {
    setState(() {
      _isDiscovering = true;
      _discoveredDevices.clear();
    });
    _addToLog('🔍 Scanning for ESP32 devices...');

    try {
      _discoveryStream = FlutterBluetoothSerial.instance.startDiscovery().listen(
        (BluetoothDiscoveryResult r) {
          if (r.device.name?.toUpperCase().contains('ESP32') == true) {
            setState(() {
              if (!_discoveredDevices.any(
                (d) => d.address == r.device.address,
              )) {
                _discoveredDevices.add(r.device);
                _addToLog(
                  '📱 Found: ${r.device.name ?? 'Unknown'} (${r.device.address})',
                );
              }
            });
          }
        },
        onDone: () {
          setState(() => _isDiscovering = false);
          _addToLog(
            '✅ Scan complete. ${_discoveredDevices.length} device(s) found.',
          );
        },
        onError: (e) {
          setState(() => _isDiscovering = false);
          _addToLog('❌ Scan error: $e');
        },
      );
    } catch (e) {
      setState(() => _isDiscovering = false);
      _addToLog('❌ Failed to start scan: $e');
    }
  }

  void _stopDiscovery() {
    _discoveryStream?.cancel();
    setState(() => _isDiscovering = false);
    _addToLog('⏹️ Scan stopped');
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    setState(() => _isConnecting = true);
    _addToLog('🔗 Connecting to ${device.name ?? 'ESP32'}...');

    try {
      final connection = await BluetoothConnection.toAddress(device.address);
      _connection = connection;
      _connectedDeviceAddress = device.address;
      _connectedDeviceName = device.name ?? 'ESP32';

      // Listen for incoming data with proper buffering
      _connection!.input!.listen(
        _onDataReceived,
        onDone: () {
          setState(() {
            _isConnected = false;
            _status = 'Disconnected';
            _connectedDeviceAddress = null;
            _connectedDeviceName = null;
          });
          _addToLog('⚠️ Connection lost');
          if (_isRecordingOnEsp) {
            _handleRecordingStop();
          }
        },
        onError: (error) {
          _addToLog('❌ Connection error: $error');
        },
      );

      setState(() {
        _isConnected = true;
        _status = 'Connected';
      });
      _addToLog('✅ Connected successfully!');

      // Send ping to verify connection
      Future.delayed(const Duration(milliseconds: 500), () {
        _sendCommand('PING');
      });
    } catch (e) {
      _addToLog('❌ Connection failed: $e');
      _connection = null;
      _connectedDeviceAddress = null;
      _connectedDeviceName = null;
    } finally {
      setState(() => _isConnecting = false);
    }
  }

  void _disconnect() async {
    try {
      if (_isRecordingOnEsp) {
        _handleRecordingStop();
      }
      await _connection?.finish();
      setState(() {
        _isConnected = false;
        _status = 'Disconnected';
        _connection = null;
        _connectedDeviceAddress = null;
        _connectedDeviceName = null;
      });
      _addToLog('👋 Disconnected');
    } catch (e) {
      _addToLog('❌ Disconnect error: $e');
    }
  }

  void _onDataReceived(Uint8List data) {
    // Detect if data is text command or binary audio
    bool isLikelyText =
        data.length < 100 &&
        data.every(
          (byte) => (byte >= 32 && byte <= 126) || byte == 10 || byte == 13,
        );

    if (isLikelyText) {
      String receivedText = utf8.decode(data, allowMalformed: true).trim();
      if (receivedText.isEmpty) return;

      _handleTextCommand(receivedText);
    } else if (_isRecordingOnEsp) {
      // Binary audio data - add to buffer
      _handleAudioData(data);
    }
  }

  void _handleTextCommand(String command) {
    _addToLog('📨 Cmd: $command');

    if (command == 'PONG') {
      _addToLog('✅ Ping response OK');
    } else if (command.startsWith('REC_START')) {
      _handleRecordingStart();
    } else if (command.startsWith('REC_STOP')) {
      _handleRecordingStop();
    } else if (command.startsWith('GPS:')) {
      _handleGPSData(command);
    } else if (command.startsWith('INST_PLAY_START')) {
      _addToLog('🔊 Instruction playback started');
    } else if (command.startsWith('INST_PLAY_STOP')) {
      _addToLog('⏹️ Instruction playback stopped');
    } else if (command == 'RECEIVED') {
      _addToLog('✅ ESP32 confirmed instruction audio');
    }
  }

  void _handleRecordingStart() {
    setState(() {
      _isRecordingOnEsp = true;
      _recordedBytes = 0;
      _recordedPackets = 0;
      _droppedPackets = 0;
      _packetsReceived = 0;
      _recordingStartTime = DateTime.now();
    });

    _audioBuffer.clear();
    _startSavingMicAudio();
    _recordingAnimationController.repeat(reverse: true);

    // Start buffer flush timer for smooth file writing
    _bufferFlushTimer = Timer.periodic(
      Duration(milliseconds: _bufferFlushInterval),
      (_) => _flushAudioBuffer(),
    );

    _addToLog('🎤 Recording started');
  }

  void _handleRecordingStop() {
    setState(() => _isRecordingOnEsp = false);
    _bufferFlushTimer?.cancel();
    _flushAudioBuffer(); // Flush remaining data
    _stopSavingMicAudio();
    _recordingAnimationController.stop();

    final duration = _recordingStartTime != null
        ? DateTime.now().difference(_recordingStartTime!).inSeconds
        : 0;

    _addToLog('⏹️ Recording stopped');
    _addToLog(
      '📊 Stats: ${_recordedPackets} packets, ${(_recordedBytes / 1024).toStringAsFixed(1)} KB, ${duration}s',
    );
    if (_droppedPackets > 0) {
      _addToLog('⚠️ Dropped packets: $_droppedPackets');
    }
  }

  void _handleGPSData(String gpsCommand) {
    final parts = gpsCommand.substring(4).split(',');
    if (parts.length >= 4) {
      final lat = double.tryParse(parts[0]) ?? 0.0;
      final lng = double.tryParse(parts[1]) ?? 0.0;
      final alt = double.tryParse(parts[2]) ?? 0.0;
      final speed = double.tryParse(parts[3]) ?? 0.0;

      setState(() {
        _lastGpsData =
            '${lat.toStringAsFixed(6)}°N, ${lng.toStringAsFixed(6)}°E\n'
            'Alt: ${alt.toStringAsFixed(1)}m, Speed: ${speed.toStringAsFixed(1)}km/h';
      });
      _addToLog('📍 GPS updated');
    } else if (gpsCommand == 'GPS:NO_FIX') {
      setState(() => _lastGpsData = 'No GPS fix');
      _addToLog('📍 GPS: No signal');
    }
  }

  void _handleAudioData(Uint8List data) {
    _packetsReceived++;
    _recordedPackets++;
    _recordedBytes += data.length;

    // Validate chunk size (expected 256 bytes)
    if (data.length != _expectedChunkSize) {
      _droppedPackets++;
      _addToLog(
        '⚠️ Invalid chunk size: ${data.length} bytes (expected $_expectedChunkSize)',
      );
      return;
    }

    // Add to buffer
    _audioBuffer.add(Uint8List.fromList(data));

    setState(() {}); // Update UI with new byte count
  }

  void _flushAudioBuffer() {
    if (_audioBuffer.isEmpty || _micFile == null) return;

    try {
      // Write all buffered chunks at once
      for (var chunk in _audioBuffer) {
        _micFile!.writeAsBytesSync(chunk, mode: FileMode.append, flush: false);
      }
      // Ensure data is flushed to disk by opening a RandomAccessFile and flushing
      final raf = _micFile!.openSync(mode: FileMode.append);
      try {
        raf.flushSync();
      } finally {
        raf.closeSync();
      }
      _audioBuffer.clear();
    } catch (e) {
      _addToLog('❌ Buffer flush error: $e');
    }
  }

  void _sendCommand(String command) {
    if (!_isConnected || _connection == null) {
      _addToLog('❌ Not connected');
      return;
    }
    try {
      _connection!.output.add(Uint8List.fromList(utf8.encode('$command\n')));
      _addToLog('📤 Sent: $command');
    } catch (e) {
      _addToLog('❌ Send failed: $e');
    }
  }

  Future<void> _sendTestInstructionAudio() async {
    if (!_isConnected || _connection == null) {
      _addToLog('❌ Not connected');
      return;
    }

    _addToLog('🎵 Generating test tone...');

    const sampleRate = 16000;
    const duration = 3.0;
    const frequency = 440.0;
    final samples = <int>[];

    for (int i = 0; i < (sampleRate * duration).toInt(); i++) {
      final time = i / sampleRate;
      final sample = sin(2 * pi * frequency * time);
      final intSample = (sample * 16000).round().clamp(
        -32768,
        32767,
      ); // Reduced amplitude
      samples.add(intSample);
    }

    final byteData = ByteData(samples.length * 2);
    for (int i = 0; i < samples.length; i++) {
      byteData.setInt16(i * 2, samples[i], Endian.little);
    }
    final audioBytes = byteData.buffer.asUint8List();

    final size = audioBytes.length;
    _sendCommand('INSTRUCTION:$size');
    await Future.delayed(const Duration(milliseconds: 300));

    try {
      _connection!.output.add(audioBytes);
      await _connection!.output.allSent;
      _addToLog('✅ Sent ${(size / 1024).toStringAsFixed(1)} KB test tone');
    } catch (e) {
      _addToLog('❌ Audio send failed: $e');
    }
  }

  Future<String?> _getDownloadsPath() async {
    if (Platform.isAndroid) {
      return '/storage/emulated/0/Download';
    } else {
      final dir = await getApplicationDocumentsDirectory();
      return dir.path;
    }
  }

  void _startSavingMicAudio() async {
    try {
      final downloadsPath = await _getDownloadsPath();
      final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      _micAudioPath = '$downloadsPath/esp32_mic_$timestamp.pcm';
      _micFile = File(_micAudioPath!);
      await _micFile!.create(recursive: true);
      setState(() => _recordedBytes = 0);
      _addToLog('💾 Saving to: esp32_mic_$timestamp.pcm');
    } catch (e) {
      _addToLog('❌ File create error: $e');
    }
  }

  void _stopSavingMicAudio() async {
    if (_micFile == null) return;

    try {
      _flushAudioBuffer(); // Final flush
      final fileSize = await _micFile!.length();
      _addToLog('✅ Saved: ${(fileSize / 1024).toStringAsFixed(1)} KB');
      _addToLog('📝 Format: 16-bit PCM, 16kHz mono');
      _addToLog('💡 Use Audacity: Import Raw Data');
      _micFile = null;
    } catch (e) {
      _addToLog('❌ File close error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(Icons.headset, size: 24),
            SizedBox(width: 8),
            Text('ESP32 Audio/GPS'),
          ],
        ),
        actions: [
          if (_selectedIndex == 0)
            IconButton(
              icon: Icon(_isDiscovering ? Icons.stop : Icons.search),
              onPressed: _isDiscovering ? _stopDiscovery : _startDiscovery,
              tooltip: _isDiscovering ? 'Stop Scan' : 'Scan',
            ),
        ],
      ),
      body: Column(
        children: [
          // Connection Status Card
          _buildConnectionStatus(),

          // Recording Status (if active)
          if (_isRecordingOnEsp) _buildRecordingStatus(),

          // Main Content
          Expanded(
            child: IndexedStack(
              index: _selectedIndex,
              children: [
                _buildDevicesTab(),
                _buildControlsTab(),
                _buildLogTab(),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (index) => setState(() => _selectedIndex = index),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.devices), label: 'Devices'),
          BottomNavigationBarItem(
            icon: Icon(Icons.control_camera),
            label: 'Controls',
          ),
          BottomNavigationBarItem(icon: Icon(Icons.list_alt), label: 'Log'),
        ],
      ),
    );
  }

  Widget _buildConnectionStatus() {
    return Container(
      margin: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _isConnected ? Colors.green.shade50 : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _isConnected ? Colors.green : Colors.grey,
          width: 2,
        ),
      ),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              _isConnected
                  ? Icons.bluetooth_connected
                  : Icons.bluetooth_disabled,
              color: _isConnected ? Colors.green : Colors.grey,
              size: 32,
            ),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _isConnected
                        ? _connectedDeviceName ?? 'Connected'
                        : 'Not Connected',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  if (_connectedDeviceAddress != null)
                    Text(
                      _connectedDeviceAddress!,
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                ],
              ),
            ),
            if (_isConnected)
              IconButton(
                icon: Icon(Icons.close, color: Colors.red),
                onPressed: _disconnect,
                tooltip: 'Disconnect',
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecordingStatus() {
    return Container(
      margin: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red, width: 2),
      ),
      child: Row(
        children: [
          AnimatedBuilder(
            animation: _recordingAnimation,
            builder: (context, child) {
              return Transform.scale(
                scale: _recordingAnimation.value,
                child: Icon(
                  Icons.fiber_manual_record,
                  color: Colors.red,
                  size: 32,
                ),
              );
            },
          ),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'RECORDING',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.red,
                    fontSize: 16,
                  ),
                ),
                Text(
                  '${(_recordedBytes / 1024).toStringAsFixed(1)} KB • $_recordedPackets packets',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          ElevatedButton.icon(
            onPressed: () => _sendCommand('STOP_REC'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            icon: Icon(Icons.stop),
            label: Text('Stop'),
          ),
        ],
      ),
    );
  }

  Widget _buildDevicesTab() {
    return Card(
      margin: EdgeInsets.all(12),
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(Icons.devices, color: Colors.blue),
                SizedBox(width: 8),
                Text(
                  'Available Devices',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                Spacer(),
                if (_isDiscovering)
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),
          Divider(height: 1),
          Expanded(
            child: _discoveredDevices.isEmpty && !_isDiscovering
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.bluetooth_searching,
                          size: 64,
                          color: Colors.grey,
                        ),
                        SizedBox(height: 16),
                        Text('No devices found'),
                        SizedBox(height: 8),
                        ElevatedButton.icon(
                          onPressed: _startDiscovery,
                          icon: Icon(Icons.search),
                          label: Text('Start Scan'),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: _discoveredDevices.length,
                    itemBuilder: (context, index) {
                      final device = _discoveredDevices[index];
                      final isConnected =
                          _connectedDeviceAddress == device.address;
                      return Card(
                        margin: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        elevation: isConnected ? 4 : 1,
                        child: ListTile(
                          leading: Icon(
                            isConnected
                                ? Icons.bluetooth_connected
                                : Icons.bluetooth,
                            color: isConnected ? Colors.green : Colors.blue,
                            size: 32,
                          ),
                          title: Text(
                            device.name ?? 'ESP32 Device',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text(device.address),
                          trailing: isConnected
                              ? Chip(
                                  label: Text('Connected'),
                                  backgroundColor: Colors.green,
                                  labelStyle: TextStyle(color: Colors.white),
                                )
                              : ElevatedButton(
                                  onPressed: _isConnecting
                                      ? null
                                      : () => _connectToDevice(device),
                                  child: Text('Connect'),
                                ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildControlsTab() {
    return SingleChildScrollView(
      padding: EdgeInsets.all(16),
      child: Column(
        children: [
          // GPS Info Card
          Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    children: [
                      Icon(Icons.location_on, color: Colors.red),
                      SizedBox(width: 8),
                      Text(
                        'GPS Location',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _lastGpsData,
                      style: TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                  SizedBox(height: 12),
                  ElevatedButton.icon(
                    onPressed: _isConnected
                        ? () => _addToLog('Press GPS button on ESP32')
                        : null,
                    icon: Icon(Icons.refresh),
                    label: Text('Request GPS Update'),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: 16),

          // Control Buttons Grid
          Text(
            'Quick Actions',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.5,
            children: [
              _buildActionCard(
                icon: Icons.wifi_tethering,
                title: 'Ping',
                subtitle: 'Test connection',
                onTap: _isConnected ? () => _sendCommand('PING') : null,
                color: Colors.blue,
              ),
              _buildActionCard(
                icon: Icons.music_note,
                title: 'Test Audio',
                subtitle: 'Send tone',
                onTap: _isConnected ? _sendTestInstructionAudio : null,
                color: Colors.purple,
              ),
              _buildActionCard(
                icon: Icons.mic,
                title: 'Record',
                subtitle: 'Use ESP32 button',
                onTap: () => _addToLog('Press button on ESP32'),
                color: _isRecordingOnEsp ? Colors.red : Colors.orange,
              ),
              _buildActionCard(
                icon: Icons.folder_open,
                title: 'Recordings',
                subtitle: 'View saved files',
                onTap: _micAudioPath != null
                    ? () => _showRecordingInfo()
                    : null,
                color: Colors.teal,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActionCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback? onTap,
    required Color color,
  }) {
    return Card(
      elevation: onTap != null ? 2 : 0,
      color: onTap != null ? null : Colors.grey.shade200,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 36, color: onTap != null ? color : Colors.grey),
              SizedBox(height: 8),
              Text(
                title,
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                textAlign: TextAlign.center,
              ),
              Text(
                subtitle,
                style: TextStyle(fontSize: 11, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLogTab() {
    return Card(
      margin: EdgeInsets.all(12),
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(Icons.list_alt, color: Colors.blue),
                SizedBox(width: 8),
                Text(
                  'Activity Log',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                Spacer(),
                IconButton(
                  icon: Icon(Icons.clear_all),
                  onPressed: () => setState(() => _log.clear()),
                  tooltip: 'Clear log',
                ),
              ],
            ),
          ),
          Divider(height: 1),
          Expanded(
            child: _log.isEmpty
                ? Center(
                    child: Text(
                      'No activity yet',
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    itemCount: _log.length,
                    itemBuilder: (context, index) {
                      final logEntry = _log[index];
                      IconData? icon;
                      Color? iconColor;

                      // Add icons based on log content
                      if (logEntry.contains('✅')) {
                        icon = Icons.check_circle;
                        iconColor = Colors.green;
                      } else if (logEntry.contains('❌')) {
                        icon = Icons.error;
                        iconColor = Colors.red;
                      } else if (logEntry.contains('⚠️')) {
                        icon = Icons.warning;
                        iconColor = Colors.orange;
                      } else if (logEntry.contains('🎤')) {
                        icon = Icons.mic;
                        iconColor = Colors.red;
                      } else if (logEntry.contains('📍')) {
                        icon = Icons.location_on;
                        iconColor = Colors.blue;
                      } else if (logEntry.contains('🔊') ||
                          logEntry.contains('🔇')) {
                        icon = Icons.volume_up;
                        iconColor = Colors.purple;
                      }

                      return ListTile(
                        dense: true,
                        leading: icon != null
                            ? Icon(icon, size: 18, color: iconColor)
                            : null,
                        title: Text(
                          logEntry,
                          style: TextStyle(
                            fontSize: 12,
                            fontFamily: 'monospace',
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  void _showRecordingInfo() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.audio_file, color: Colors.blue),
            SizedBox(width: 8),
            Text('Recording Info'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('File Location:'),
            SizedBox(height: 4),
            Container(
              padding: EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _micAudioPath ?? 'No recording',
                style: TextStyle(fontSize: 11, fontFamily: 'monospace'),
              ),
            ),
            SizedBox(height: 12),
            Text('Format: 16-bit PCM'),
            Text('Sample Rate: 16 kHz'),
            Text('Channels: Mono'),
            SizedBox(height: 12),
            Text(
              'Open in Audacity:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            Text('1. File → Import → Raw Data'),
            Text('2. Set: 16-bit PCM, 16000 Hz, 1 channel'),
            Text('3. Little-endian'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Close'),
          ),
        ],
      ),
    );
  }
}
