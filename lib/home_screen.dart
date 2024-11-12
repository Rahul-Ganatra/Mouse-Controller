import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'dart:convert';
import 'dart:async';

class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);

  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  WebSocketChannel? _channel;
  bool _isConnected = false;
  bool _isConnecting = false;
  final MobileScannerController controller = MobileScannerController();
  final TextEditingController ipController = TextEditingController();
  bool _showingChoiceDialog = false;
  bool _usingWhiteboard = false;
  Offset? lastPoint;
  bool _isMovementActive = false;
  StreamSubscription<AccelerometerEvent>? _accelerometerSubscription;

  @override
  void dispose() {
    _accelerometerSubscription?.cancel();
    controller.dispose();
    ipController.dispose();
    _channel?.sink.close();
    super.dispose();
  }

  void _connectToServer(String url) {
    print("Attempting to connect to: $url");
    setState(() {
      _isConnecting = true;
    });
    try {
      _channel = WebSocketChannel.connect(Uri.parse(url));
      _channel?.stream.listen(
        (message) {
          if (message == 'ping') {
            _channel?.sink.add('pong');
            return;
          }
          try {
            final data = jsonDecode(message);
            if (data['type'] == 'connection_status' &&
                data['status'] == 'connected') {
              setState(() {
                _isConnected = true;
                _showingChoiceDialog = true;
              });
            }
          } catch (e) {
            print('Error processing message: $e');
          }
        },
        onDone: () {
          print('WebSocket connection closed');
          setState(() {
            _isConnected = false;
            _isConnecting = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Server disconnected'),
              backgroundColor: Colors.orange,
            ),
          );
        },
        onError: (error) {
          print('WebSocket error: $error');
          setState(() {
            _isConnected = false;
            _isConnecting = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Failed to connect to server'),
              backgroundColor: Colors.red,
            ),
          );
        },
      );
    } catch (e) {
      print('Connection error: $e');
      setState(() {
        _isConnecting = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to connect to server'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _setupSensorsListener() {
    // Only setup when explicitly chosen by user
    if (!_usingWhiteboard) {
      accelerometerEvents.listen((AccelerometerEvent event) {
        if (_isConnected && !_usingWhiteboard) {
          _sendSensorData('accelerometer', event.x, event.y, event.z);
        }
      });

      gyroscopeEvents.listen((GyroscopeEvent event) {
        if (_isConnected && !_usingWhiteboard) {
          _sendSensorData('gyroscope', event.x, event.y, event.z);
        }
      });
    }
  }

  void _sendSensorData(String type, double x, double y, double z) {
    if (_channel != null) {
      final data = {
        'type': type,
        'x': x,
        'y': y,
        'z': z,
      };
      _channel?.sink.add(jsonEncode(data));
    }
  }

  void _disconnect() {
    if (_channel != null) {
      // Send disconnect message to server
      final data = {'type': 'disconnect'};
      _channel!.sink.add(jsonEncode(data));

      // Stop any ongoing sensor listeners
      accelerometerEvents.drain();
      gyroscopeEvents.drain();

      // Close the WebSocket connection
      _channel!.sink.close();
      _channel = null;

      // Reset all state variables
      setState(() {
        _isConnected = false;
        _isConnecting = false;
        _showingChoiceDialog = false;
        _usingWhiteboard = false;
      });

      // Restart the QR scanner
      controller.start();

      // Show success message
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Disconnected successfully'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  void _connectViaIP() {
    final ip = ipController.text.trim();
    if (ip.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter an IP address'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    final url = 'ws://$ip:8766';
    _connectToServer(url);
  }

  void _selectControlMode(String mode) {
    if (_channel != null) {
      final data = {'type': 'mode_select', 'mode': mode};
      _channel?.sink.add(jsonEncode(data));

      setState(() {
        _showingChoiceDialog = false;
        _usingWhiteboard = mode == 'whiteboard';
      });
    }
  }

  Widget _buildConnectedContent() {
    if (_showingChoiceDialog) {
      return Center(
        child: Card(
          margin: const EdgeInsets.all(16.0),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Choose Control Method',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: () => _selectControlMode('mobile_movement'),
                  child: const Text('Use Mobile Movement'),
                ),
                const SizedBox(height: 10),
                ElevatedButton(
                  onPressed: () => _selectControlMode('whiteboard'),
                  child: const Text('Use Whiteboard'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return _usingWhiteboard ? _buildWhiteboard() : _buildMobileContent();
  }

  Widget _buildWhiteboard() {
    return Column(
      children: [
        // Mouse movement area
        Expanded(
          flex: 6,
          child: GestureDetector(
            onPanUpdate: (details) {
              if (_channel != null) {
                final dx = details.delta.dx * 3.0;
                final dy = details.delta.dy * 3.0;

                final data = {
                  'type': 'whiteboard',
                  'dx': dx,
                  'dy': dy,
                };
                _channel?.sink.add(jsonEncode(data));
              }
            },
            child: Container(
              color: Colors.grey[200],
              child: const Center(
                child: Text('Move mouse here'),
              ),
            ),
          ),
        ),
        // Click areas
        Expanded(
          flex: 4,
          child: Row(
            children: [
              // Left click area
              Expanded(
                child: Material(
                  child: InkWell(
                    // Changed from GestureDetector to InkWell
                    onTap: () {
                      print("Left click executed"); // Debug print
                      if (_channel != null) {
                        final data = {
                          'type': 'mouse_click',
                          'button': 'left',
                          'action': 'click'
                        };
                        print("Sending left click: $data"); // Debug print
                        _channel?.sink.add(jsonEncode(data));
                      }
                    },
                    onDoubleTap: () {
                      print("Double click executed"); // Debug print
                      if (_channel != null) {
                        final data = {
                          'type': 'mouse_click',
                          'button': 'left',
                          'action': 'double'
                        };
                        print("Sending double click: $data"); // Debug print
                        _channel?.sink.add(jsonEncode(data));
                      }
                    },
                    child: Container(
                      color: Colors.blue[100],
                      child: const Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              'Left Click',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            SizedBox(height: 8),
                            Text(
                              'Tap: Click\nDouble Tap: Double Click',
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // Right click area
              Expanded(
                child: Material(
                  child: InkWell(
                    // Changed from GestureDetector to InkWell
                    onTap: () {
                      print("Right click executed"); // Debug print
                      if (_channel != null) {
                        final data = {
                          'type': 'mouse_click',
                          'button': 'right',
                          'action': 'click'
                        };
                        print("Sending right click: $data"); // Debug print
                        _channel?.sink.add(jsonEncode(data));
                      }
                    },
                    child: Container(
                      color: Colors.red[100],
                      child: const Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              'Right Click',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            SizedBox(height: 8),
                            Text(
                              'Tap for Right Click',
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        // Add disconnect button
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: ElevatedButton(
            onPressed: _disconnect,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              minimumSize: const Size(double.infinity, 48),
            ),
            child: const Text(
              'Disconnect',
              style: TextStyle(
                fontSize: 16,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mouse Controller'),
      ),
      body: _buildContent(),
    );
  }

  Widget _buildContent() {
    if (_isConnected) {
      return _buildConnectedContent();
    }

    return Column(
      children: [
        Expanded(
          flex: 5,
          child: MobileScanner(
            controller: controller,
            onDetect: (capture) {
              final List<Barcode> barcodes = capture.barcodes;
              for (final barcode in barcodes) {
                if (barcode.rawValue != null) {
                  _connectToServer(barcode.rawValue!);
                }
              }
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: ipController,
                  decoration: const InputDecoration(
                    hintText: 'Enter server IP',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _connectViaIP,
                child: const Text('Connect'),
              ),
            ],
          ),
        ),
        const Expanded(
          flex: 1,
          child: Center(
            child: Text('Scan QR or enter IP to connect'),
          ),
        ),
      ],
    );
  }

  Widget _buildMobileContent() {
    return Column(
      children: [
        // Guidelines Container
        Container(
          margin: const EdgeInsets.all(16.0),
          padding: const EdgeInsets.all(16.0),
          decoration: BoxDecoration(
            color: Colors.blue.withOpacity(0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.blue.withOpacity(0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Text(
                'How to Control the Cursor:',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.blue,
                ),
              ),
              SizedBox(height: 12),
              Text(
                '• Tap and hold the circle to activate cursor control\n'
                '• Tilt phone forward → Move cursor up\n'
                '• Tilt phone backward → Move cursor down\n'
                '• Tilt phone left → Move cursor left\n'
                '• Tilt phone right → Move cursor right\n'
                '• Release to stop cursor movement',
                style: TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  color: Colors.black87,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          flex: 6,
          child: Container(
            color: Colors.grey[200],
            child: Center(
              child: GestureDetector(
                onTapDown: (_) {
                  setState(() {
                    _isMovementActive = true;
                  });
                  if (_channel != null) {
                    final data = {'type': 'mobile_movement', 'action': 'start'};
                    _channel?.sink.add(jsonEncode(data));
                  }
                },
                onTapUp: (_) {
                  setState(() {
                    _isMovementActive = false;
                  });
                  if (_channel != null) {
                    final data = {'type': 'mobile_movement', 'action': 'stop'};
                    _channel?.sink.add(jsonEncode(data));
                  }
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isMovementActive ? Colors.green : Colors.red,
                    border: Border.all(
                      color: Colors.white,
                      width: 3,
                    ),
                  ),
                  child: const Center(
                    child: Text(
                      'Tap to Start\nTracking',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        // Keep the existing click areas
        Expanded(
          flex: 4,
          child: Row(
            children: [
              // Left click area
              Expanded(
                child: GestureDetector(
                  onTap: () {
                    if (_channel != null) {
                      final data = {
                        'type': 'mouse_click',
                        'button': 'left',
                        'action': 'click'
                      };
                      _channel?.sink.add(jsonEncode(data));
                    }
                  },
                  child: Container(
                    color: Colors.blue[100],
                    child: const Center(
                      child: Text('Left Click'),
                    ),
                  ),
                ),
              ),
              // Right click area
              Expanded(
                child: GestureDetector(
                  onTap: () {
                    if (_channel != null) {
                      final data = {
                        'type': 'mouse_click',
                        'button': 'right',
                        'action': 'click'
                      };
                      _channel?.sink.add(jsonEncode(data));
                    }
                  },
                  child: Container(
                    color: Colors.red[100],
                    child: const Center(
                      child: Text('Right Click'),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        // Add disconnect button
        _buildDisconnectButton(),
      ],
    );
  }

  Widget _buildDisconnectButton() {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: ElevatedButton(
        onPressed: _disconnect,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.red,
          minimumSize: const Size(double.infinity, 48),
        ),
        child: const Text(
          'Disconnect',
          style: TextStyle(
            fontSize: 16,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

class ControlPanel extends StatelessWidget {
  final bool isConnected;
  final Function() onDisconnect;

  const ControlPanel({
    Key? key,
    required this.isConnected,
    required this.onDisconnect,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                isConnected ? 'Connected' : 'Disconnected',
                style: TextStyle(
                  color: isConnected ? Colors.green : Colors.red,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (isConnected)
                ElevatedButton(
                  onPressed: onDisconnect,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                  ),
                  child: const Text('Disconnect'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class WhiteboardPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.blue.withOpacity(0.5)
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset.zero, Offset(size.width, size.height), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return false;
  }
}
