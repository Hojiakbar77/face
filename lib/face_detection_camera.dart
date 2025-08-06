import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:permission_handler/permission_handler.dart';

class FaceDetectionCamera extends StatefulWidget {
  const FaceDetectionCamera({super.key});

  @override
  State<FaceDetectionCamera> createState() => _FaceDetectionCameraState();
}

class _FaceDetectionCameraState extends State<FaceDetectionCamera> {
  final FaceDetector faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableContours: true,
      enableClassification: true,
      enableLandmarks: true,
      enableTracking: true,
      minFaceSize: 0.15, // Reduced minimum face size for better detection
      performanceMode: FaceDetectorMode.accurate, // Changed to accurate mode
    ),
  );

  late CameraController cameraController;
  bool isCameraInitialized = false;
  bool isDetecting = false;

  Timer? _validationTimer;

  final ValueNotifier<bool> isFaceInCorrectPosition = ValueNotifier(false);
  final ValueNotifier<bool> isVerified = ValueNotifier(false);
  final ValueNotifier<String?> warningText = ValueNotifier(null);
  final ValueNotifier<InputImageMetadata?> metadataNotifier = ValueNotifier(null);
  final ValueNotifier<List<Face>> facesNotifier = ValueNotifier([]);

  bool _hasShownSmileWarning = false;
  Size? _screenSize;
  CameraLensDirection _lensDirection = CameraLensDirection.front;

  @override
  void initState() {
    super.initState();
    _requestCameraPermission();
  }

  Future<void> _requestCameraPermission() async {
    var status = await Permission.camera.status;
    if (!status.isGranted) {
      status = await Permission.camera.request();
    }

    if (status.isGranted) {
      initializeCamera();
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Camera permission is required')),
        );
        Navigator.pop(context);
      }
    }
  }

  Future<void> initializeCamera() async {
    try {
      final cameras = await availableCameras();
      final frontCamera = cameras.firstWhere(
            (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      _lensDirection = frontCamera.lensDirection;

      cameraController = CameraController(
        frontCamera,
        ResolutionPreset.medium, // Changed to medium for better performance
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.nv21
            : ImageFormatGroup.bgra8888,
      );

      await cameraController.initialize();
      if (!mounted) return;
      setState(() {
        isCameraInitialized = true;
      });
      startFaceDetection();
    } catch (e) {
      debugPrint('Camera initialization error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to initialize camera: $e')),
        );
        Navigator.pop(context);
      }
    }
  }

  void startFaceDetection() {
    cameraController.startImageStream((CameraImage image) {
      if (!isDetecting) {
        isDetecting = true;
        detectFaces(image).then((_) {
          isDetecting = false;
        });
      }
    });
  }

  Future<void> detectFaces(CameraImage image) async {
    try {
      final inputImage = _inputImageFromCameraImage(image);
      if (inputImage == null) return;

      final faces = await faceDetector.processImage(inputImage);
      if (!mounted) return;

      facesNotifier.value = faces;
      _handleFaceInFrameAndVertical(faces: faces, image: image);
    } catch (e) {
      debugPrint('Face detection error: $e');
    }
  }

  InputImage? _inputImageFromCameraImage(CameraImage image) {
    final camera = cameraController.description;
    final sensorOrientation = camera.sensorOrientation;
    
    InputImageRotation? rotation;
    if (Platform.isIOS) {
      rotation = InputImageRotationValue.fromRawValue(sensorOrientation);
    } else if (Platform.isAndroid) {
      var rotationCompensation =
          _orientations[cameraController.value.deviceOrientation];
      if (rotationCompensation == null) return null;
      if (camera.lensDirection == CameraLensDirection.front) {
        rotationCompensation = (sensorOrientation + rotationCompensation) % 360;
      } else {
        rotationCompensation =
            (sensorOrientation - rotationCompensation + 360) % 360;
      }
      rotation = InputImageRotationValue.fromRawValue(rotationCompensation);
    }
    if (rotation == null) return null;

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null ||
        (Platform.isAndroid && format != InputImageFormat.nv21) ||
        (Platform.isIOS && format != InputImageFormat.bgra8888)) return null;

    if (image.planes.length != 1) return null;
    final plane = image.planes.first;

    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  final _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  void _handleFaceInFrameAndVertical({
    required List<Face> faces,
    required CameraImage image,
  }) {
    // Clear previous warning text when no face is detected
    if (faces.isEmpty) {
      isFaceInCorrectPosition.value = false;
      warningText.value = 'Position your face in the circle';
      _validationTimer?.cancel();
      _validationTimer = null;
      _hasShownSmileWarning = false;
      return;
    }

    final face = faces.first;
    
    // More lenient angle thresholds for better user experience
    const angleThreshold = 15.0;
    const tiltThreshold = 20.0;

    final angleY = face.headEulerAngleY ?? 0;
    final angleX = face.headEulerAngleX ?? 0;
    final angleZ = face.headEulerAngleZ ?? 0;

    final isFacingForward = angleY.abs() < angleThreshold;
    final isNotLookingUpOrDown = angleX.abs() < angleThreshold;
    final isHeadUpright = angleZ.abs() < tiltThreshold;

    // Get screen size for coordinate transformation
    _screenSize = MediaQuery.of(context).size;
    
    // Transform face coordinates to screen coordinates
    final faceRect = _scaleRect(
      rect: face.boundingBox,
      imageSize: Size(image.width.toDouble(), image.height.toDouble()),
      screenSize: _screenSize!,
      rotation: _lensDirection == CameraLensDirection.front ? -90 : 90,
    );

    // Define detection area (circle in the upper part of screen)
    final detectionCenter = Offset(_screenSize!.width / 2, _screenSize!.height * 0.35);
    final detectionRadius = _screenSize!.width * 0.3;
    
    final faceCenter = faceRect.center;
    final distanceFromCenter = (faceCenter - detectionCenter).distance;
    final isInsideCircle = distanceFromCenter <= detectionRadius;

    // Check face size - should be reasonable size in the circle
    final faceSize = (faceRect.width + faceRect.height) / 2;
    final idealFaceSize = detectionRadius * 1.2; // Face should fill most of the circle
    final minFaceSize = detectionRadius * 0.6;
    final isGoodSize = faceSize >= minFaceSize && faceSize <= idealFaceSize;

    // Smile detection
    final smilingProbability = face.smilingProbability ?? 0.0;
    final isSmiling = smilingProbability > 0.4;

    // Handle warnings and validation
    String? currentWarning;
    
    if (isSmiling) {
      if (!_hasShownSmileWarning) {
        _hasShownSmileWarning = true;
        currentWarning = 'Please maintain a neutral expression';
        _resetValidationTimer();
      }
    } else {
      _hasShownSmileWarning = false;
      
      if (!isInsideCircle) {
        currentWarning = 'Move your face into the circle';
        _resetValidationTimer();
      } else if (!isGoodSize) {
        if (faceSize < minFaceSize) {
          currentWarning = 'Move closer to the camera';
        } else {
          currentWarning = 'Move further from the camera';
        }
        _resetValidationTimer();
      } else if (!isFacingForward) {
        currentWarning = 'Look straight ahead';
        _resetValidationTimer();
      } else if (!isNotLookingUpOrDown) {
        currentWarning = 'Keep your head level';
        _resetValidationTimer();
      } else if (!isHeadUpright) {
        currentWarning = 'Keep your head straight';
        _resetValidationTimer();
      }
    }

    warningText.value = currentWarning;

    final isValid = !isSmiling && 
                   isFacingForward && 
                   isNotLookingUpOrDown && 
                   isHeadUpright && 
                   isInsideCircle && 
                   isGoodSize;
    
    isFaceInCorrectPosition.value = isValid;

    if (!isValid) {
      _resetValidationTimer();
      return;
    }

    // Start validation timer only when all conditions are met
    _validationTimer ??= Timer(const Duration(seconds: 3), () async {
      isVerified.value = true;
      warningText.value = 'Capturing photo...';
      await Future.delayed(const Duration(milliseconds: 800));

      try {
        await cameraController.stopImageStream();
        final XFile image = await cameraController.takePicture();
        if (mounted) Navigator.pop(context, image.path);
      } catch (e) {
        debugPrint('Error taking picture: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to capture photo: $e')),
          );
        }
        _resetValidationTimer();
        isVerified.value = false;
        startFaceDetection();
      }
    });
  }

  void _resetValidationTimer() {
    _validationTimer?.cancel();
    _validationTimer = null;
  }

  Rect _scaleRect({
    required Rect rect,
    required Size imageSize,
    required Size screenSize,
    required int rotation,
  }) {
    final scaleX = screenSize.width / imageSize.width;
    final scaleY = screenSize.height / imageSize.height;
    
    if (_lensDirection == CameraLensDirection.front) {
      return Rect.fromLTRB(
        screenSize.width - rect.right * scaleX,
        rect.top * scaleY,
        screenSize.width - rect.left * scaleX,
        rect.bottom * scaleY,
      );
    } else {
      return Rect.fromLTRB(
        rect.left * scaleX,
        rect.top * scaleY,
        rect.right * scaleX,
        rect.bottom * scaleY,
      );
    }
  }

  @override
  void dispose() {
    if (isCameraInitialized) {
      cameraController.stopImageStream();
    }
    faceDetector.close();
    cameraController.dispose();
    _validationTimer?.cancel();
    isFaceInCorrectPosition.dispose();
    isVerified.dispose();
    warningText.dispose();
    metadataNotifier.dispose();
    facesNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: isCameraInitialized
          ? Stack(
        children: [
          // Camera Preview
          Positioned.fill(
            child: CameraPreview(cameraController),
          ),
          
          // Face detection overlay
          Positioned.fill(
            child: ValueListenableBuilder<bool>(
              valueListenable: isFaceInCorrectPosition,
              builder: (context, isValid, child) {
                return CustomPaint(
                  painter: FaceDetectionOverlayPainter(
                    isValid: isValid,
                    screenSize: MediaQuery.of(context).size,
                  ),
                );
              },
            ),
          ),

          // Back button
          Positioned(
            top: MediaQuery.of(context).padding.top + 10,
            left: 16,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(20),
              ),
              child: IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ),

          // Instructions and status
          Positioned(
            top: MediaQuery.of(context).padding.top + 80,
            left: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.7),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: [
                  ValueListenableBuilder<bool>(
                    valueListenable: isVerified,
                    builder: (context, verified, child) {
                      return Text(
                        verified ? 'Face Verified ✓' : 'Face Detection',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: verified ? Colors.green : Colors.white,
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  ValueListenableBuilder<String?>(
                    valueListenable: warningText,
                    builder: (context, text, child) {
                      return AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        child: text != null
                            ? Text(
                                text,
                                key: ValueKey(text),
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 16,
                                  color: text.contains('Capturing') 
                                      ? Colors.green 
                                      : Colors.orange,
                                ),
                              )
                            : Text(
                                'Keep your face in the circle',
                                key: const ValueKey('default'),
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 16,
                                  color: Colors.grey[300],
                                ),
                              ),
                      );
                    },
                  ),
                  ValueListenableBuilder<bool>(
                    valueListenable: isVerified,
                    builder: (context, verified, child) {
                      return verified
                          ? const Padding(
                              padding: EdgeInsets.only(top: 12),
                              child: CircularProgressIndicator(
                                valueColor: AlwaysStoppedAnimation<Color>(Colors.green),
                              ),
                            )
                          : const SizedBox.shrink();
                    },
                  ),
                ],
              ),
            ),
          ),

          // Progress indicator at bottom
          Positioned(
            bottom: MediaQuery.of(context).padding.bottom + 60,
            left: 16,
            right: 16,
            child: ValueListenableBuilder<bool>(
              valueListenable: isFaceInCorrectPosition,
              builder: (context, isValid, child) {
                return AnimatedOpacity(
                  opacity: isValid ? 1.0 : 0.3,
                  duration: const Duration(milliseconds: 300),
                  child: Container(
                    height: 6,
                    decoration: BoxDecoration(
                      color: isValid ? Colors.green : Colors.grey,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      )
          : Container(
              color: Colors.black,
              child: const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 16),
                    Text(
                      'Initializing camera...',
                      style: TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

class FaceDetectionOverlayPainter extends CustomPainter {
  final bool isValid;
  final Size screenSize;

  FaceDetectionOverlayPainter({
    required this.isValid,
    required this.screenSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Create overlay with hole
    final overlayPaint = Paint()
      ..color = Colors.black.withOpacity(0.6)
      ..style = PaintingStyle.fill;

    final center = Offset(size.width / 2, size.height * 0.35);
    final radius = size.width * 0.3;

    // Create path for overlay with circular hole
    final path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addOval(Rect.fromCircle(center: center, radius: radius))
      ..fillType = PathFillType.evenOdd;

    canvas.drawPath(path, overlayPaint);

    // Draw circle border
    final borderPaint = Paint()
      ..color = isValid ? Colors.green : Colors.red
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0;

    canvas.drawCircle(center, radius, borderPaint);

    // Draw animated pulse effect when valid
    if (isValid) {
      final pulsePaint = Paint()
        ..color = Colors.green.withOpacity(0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      
      canvas.drawCircle(center, radius + 8, pulsePaint);
    }
  }

  @override
  bool shouldRepaint(covariant FaceDetectionOverlayPainter oldDelegate) {
    return oldDelegate.isValid != isValid;
  }
}