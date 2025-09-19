import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:permission_handler/permission_handler.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Capture',
      theme: ThemeData(useMaterial3: true),
      home: const ObjectCapturePage(),
    );
  }
}

class ObjectCapturePage extends StatefulWidget {
  const ObjectCapturePage({super.key});

  @override
  State<ObjectCapturePage> createState() => _ObjectCapturePageState();
}

class _ObjectCapturePageState extends State<ObjectCapturePage> {
  CameraController? _controller;
  late final ObjectDetector _detector;
  late final BarcodeScanner _barcodeScanner;
  bool _isStreaming = false;
  bool _isRunningDetection = false;
  bool _showPreview = false; // open preview only when we detect an object
  XFile? _capturedFile;
  String _status = 'Scanning for objects...';
  CameraDescription? _cameraDescription;

  @override
  void initState() {
    super.initState();

    // Streaming mode = optimized for live video.
    final options = ObjectDetectorOptions(
      mode: DetectionMode.stream,
      classifyObjects: true,
      multipleObjects: true,
    );
    _detector = ObjectDetector(options: options);

    // QR-only barcode scanner
    _barcodeScanner = BarcodeScanner(formats: [BarcodeFormat.qrCode]);

    _initCamera();
  }

  Future<void> _initCamera() async {
    // Request camera permission first (important for iOS)
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      setState(() {
        _status = 'Camera permission denied. Please enable it in Settings.';
      });
      return;
    }

    // Enumerate available cameras after permission is granted
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() {
          _status = 'No camera found on this device.';
        });
        return;
      }
      _cameraDescription = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
    } catch (e) {
      setState(() {
        _status = 'Failed to access cameras: $e';
      });
      return;
    }

    final controller = CameraController(
      _cameraDescription!,
      ResolutionPreset.medium,
      enableAudio: false,
      // iOS streams best with BGRA8888; Android uses YUV420/NV21
      imageFormatGroup: Platform.isIOS
          ? ImageFormatGroup.bgra8888
          : ImageFormatGroup.nv21,
    );

    await controller.initialize();
    setState(() => _controller = controller);

    // Start image stream but keep preview visually hidden.
    await controller.startImageStream(_processCameraImage);
    _isStreaming = true;
  }

  // Convert CameraImage -> InputImage for ML Kit
  InputImage _toInputImage(CameraImage image, CameraDescription description) {
    final WriteBuffer allBytes = WriteBuffer();
    for (final plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();

    final Size imageSize = Size(
      image.width.toDouble(),
      image.height.toDouble(),
    );

    final cameraRotation =
        InputImageRotationValue.fromRawValue(description.sensorOrientation) ??
        InputImageRotation.rotation0deg;

    // Prefer explicit formats per platform for correctness
    final inputImageFormat = Platform.isIOS
        ? InputImageFormat.bgra8888
        : InputImageFormat.nv21;

    final metadata = InputImageMetadata(
      size: imageSize,
      rotation: cameraRotation,
      format: inputImageFormat,
      // For iOS (BGRA8888) and simple cases, first plane's bytesPerRow works.
      bytesPerRow: image.planes.first.bytesPerRow,
    );

    return InputImage.fromBytes(bytes: bytes, metadata: metadata);
  }

  Future<void> _processCameraImage(CameraImage image) async {
    if (_isRunningDetection ||
        _controller == null ||
        _cameraDescription == null) {
      return;
    }
    _isRunningDetection = true;

    try {
      final input = _toInputImage(image, _cameraDescription!);
      // Detect generic objects
      final objects = await _detector.processImage(input);
      if (kDebugMode) {
        debugPrint('Detected objects: ${objects.length}');
      }

      if (objects.isEmpty) {
        setState(() {
          _showPreview = false; // hide camera when no object detected
          _status = 'Move an object into view...';
        });
      } else {
        // When an object is present, also check for QR codes
        final barcodes = await _barcodeScanner.processImage(input);
        final qrCodes = barcodes.where((b) => b.format == BarcodeFormat.qrCode);

        // Show preview since object exists (even if QR missing), so user can align a QR
        bool shouldCapture = false;
        if (qrCodes.isNotEmpty) {
          // If any QR overlaps any detected object, allow capture
          for (final obj in objects) {
            final objRect = obj.boundingBox;
            for (final qr in qrCodes) {
              final qrRect = qr.boundingBox;
              if (_rectsIntersect(objRect, qrRect)) {
                shouldCapture = true;
                break;
              }
            }
            if (shouldCapture) break;
          }
        }

        if (shouldCapture) {
          setState(() {
            _showPreview = true;
            _status = 'Object with QR detected. Capturing...';
          });
          await _captureOnce();
        } else {
          setState(() {
            _showPreview = true;
            _status = qrCodes.isEmpty
                ? 'QR code not found. Show a QR on the object.'
                : 'Align the QR with the object.';
          });
        }
      }
    } catch (e) {
      // swallow occasional frame errors
    } finally {
      _isRunningDetection = false;
    }
  }

  bool _rectsIntersect(Rect a, Rect b) {
    return a.overlaps(b);
  }

  Future<void> _captureOnce() async {
    // Avoid multiple captures
    if (!_isStreaming || _controller == null) return;
    _isStreaming = false;

    try {
      await _controller!.stopImageStream();

      // Take a high-res stillDak
      final shot = await _controller!.takePicture();

      setState(() {
        _capturedFile = shot;
        _status = 'Captured!';
      });

      // After capture, hide preview and auto-restart scanning shortly
      setState(() => _showPreview = false);
      _restartStreamAfterCapture();
    } catch (e) {
      setState(() => _status = 'Capture failed: $e');
    }
  }

  Future<void> _restartStreamAfterCapture() async {
    if (_controller == null) return;
    // Brief pause to avoid overloading the pipeline
    await Future.delayed(const Duration(milliseconds: 800));
    try {
      if (!_controller!.value.isStreamingImages) {
        await _controller!.startImageStream(_processCameraImage);
      }
      setState(() {
        _status = 'Scanning for objects...';
        _isStreaming = true;
      });
    } catch (_) {
      // ignore
    }
  }

  // Future<void> _resetAndRescan() async {
  //   if (_controller == null) return;
  //   setState(() {
  //     _capturedFile = null;
  //     _status = 'Scanning for objects...';
  //   });

  //   if (!_controller!.value.isStreamingImages) {
  //     await _controller!.startImageStream(_processCameraImage);
  //   }
  //   _isStreaming = true;
  // }

  @override
  void dispose() {
    _detector.close();
    _barcodeScanner.close();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final preview = (_controller != null && _controller!.value.isInitialized)
        ? CameraPreview(_controller!)
        : const Center(child: CircularProgressIndicator());

    return Scaffold(
      appBar: AppBar(title: const Text('Smart Object Capture')),
      body: Column(
        children: [
          // Status / instructions
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _status,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),

          // Camera area: open preview only when object is detected
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (_showPreview) preview,
                if (!_showPreview)
                  const Center(
                    child: Text(
                      'Camera closed. Move an object into view...',
                      style: TextStyle(
                        fontSize: 14,
                        fontStyle: FontStyle.italic,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
              ],
            ),
          ),

          // Captured image preview (no button; scanning restarts automatically)
          if (_capturedFile != null)
            Container(
              padding: const EdgeInsets.all(12),
              height: 220,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(File(_capturedFile!.path), fit: BoxFit.cover),
              ),
            ),
        ],
      ),
    );
  }
}
