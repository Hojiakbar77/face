import 'dart:async';
import 'dart:io';
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
      minFaceSize: 0.3,
      performanceMode: FaceDetectorMode.fast,
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

  bool _hasShownSmileWarning = false;

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

      cameraController = CameraController(
        frontCamera,
        ResolutionPreset.high,
        enableAudio: false,
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
      final WriteBuffer allBytes = WriteBuffer();
      for (var plane in image.planes) {
        allBytes.putUint8List(plane.bytes);
      }
      final bytes = allBytes.done().buffer.asUint8List();

      final format = InputImageFormat.nv21;
      final rotation = Platform.isIOS
          ? InputImageRotation.rotation0deg
          : InputImageRotation.rotation270deg;

      final metadata = InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: image.planes.first.bytesPerRow,
      );

      metadataNotifier.value = metadata;

      final inputImage = InputImage.fromBytes(
        bytes: bytes,
        metadata: metadata,
      );

      final faces = await faceDetector.processImage(inputImage);
      if (!mounted) return;

      _handleFaceInFrameAndVertical(faces: faces, metadata: metadata);
    } catch (e) {
      debugPrint('Face detection error: $e');
    }
  }

  void _handleFaceInFrameAndVertical({
    required List<Face> faces,
    required InputImageMetadata metadata,
  }) {
    if (faces.isEmpty) {
      isFaceInCorrectPosition.value = false;
      _validationTimer?.cancel();
      _validationTimer = null;
      return;
    }

    final face = faces.first;
    const threshold = 8.0;

    final angleY = face.headEulerAngleY ?? 0;
    final angleX = face.headEulerAngleX ?? 0;
    final angleZ = face.headEulerAngleZ ?? 0;

    final isFacingForward = angleY.abs() < threshold;
    final isNotLookingUpOrDown = angleX.abs() < threshold;
    final isHeadUpright = angleZ.abs() < threshold;

    final imageWidth = metadata.size.width;
    final imageHeight = metadata.size.height;

    final detectionCircle = Rect.fromCircle(
      center: Offset(imageWidth / 2, imageHeight * 0.3),
      radius: imageWidth * 0.25,
    );

    final faceCenter = face.boundingBox.center;
    final isInsideCircle = detectionCircle.contains(faceCenter);

    final smilingProbability = face.smilingProbability ?? 0.0;
    final isSmiling = smilingProbability > 0.3;

    if (isSmiling) {
      _validationTimer?.cancel();
      _validationTimer = null;

      if (!_hasShownSmileWarning) {
        _hasShownSmileWarning = true;
        warningText.value = 'Please do not smile';
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) warningText.value = null;
        });
      }

      isFaceInCorrectPosition.value = false;
      return;
    } else {
      _hasShownSmileWarning = false;
    }

    final isValid = isFacingForward && isNotLookingUpOrDown && isHeadUpright && isInsideCircle;
    isFaceInCorrectPosition.value = isValid;

    if (!isValid) {
      _validationTimer?.cancel();
      _validationTimer = null;
      return;
    }

    _validationTimer ??= Timer(const Duration(seconds: 2), () async {
      isVerified.value = true;
      await Future.delayed(const Duration(milliseconds: 500));

      if (Platform.isIOS) await cameraController.pausePreview();
      final XFile image = await cameraController.takePicture();
      if (Platform.isIOS) await cameraController.resumePreview();

      if (mounted) Navigator.pop(context, image.path);
    });
  }

  @override
  void dispose() {
    cameraController.stopImageStream();
    faceDetector.close();
    cameraController.dispose();
    _validationTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: isCameraInitialized
          ? Stack(
        children: [
          Positioned.fill(child: CameraPreview(cameraController)),
          ValueListenableBuilder(
            valueListenable: metadataNotifier,
            builder: (_, meta, __) {
              if (meta == null) return const SizedBox();
              return ValueListenableBuilder(
                valueListenable: isFaceInCorrectPosition,
                builder: (_, isValid, __) {
                  return CustomPaint(
                    painter: HeadMaskPainter(metadata: meta, isValid: isValid),
                    child: Container(),
                  );
                },
              );
            },
          ),
          Positioned(
            top: kToolbarHeight,
            child: const BackButton(color: Colors.white),
          ),
          Positioned(
            top: kToolbarHeight * 2,
            left: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  ValueListenableBuilder(
                    valueListenable: isVerified,
                    builder: (_, verified, __) => Text(
                      verified ? 'Face Verified' : 'Position your face in the circle',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  ValueListenableBuilder(
                    valueListenable: warningText,
                    builder: (_, text, __) {
                      if (text == null) return const SizedBox();
                      return Text(
                        text,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 16,
                          color: Colors.red,
                        ),
                      );
                    },
                  ),
                  ValueListenableBuilder(
                    valueListenable: isVerified,
                    builder: (_, verified, __) {
                      return verified
                          ? const CircularProgressIndicator()
                          : const SizedBox.shrink();
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      )
          : const Center(child: CircularProgressIndicator()),
    );
  }
}

class HeadMaskPainter extends CustomPainter {
  final InputImageMetadata metadata;
  final bool isValid;

  HeadMaskPainter({required this.metadata, required this.isValid});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black.withAlpha(130)

      ..style = PaintingStyle.fill;

    final center = Offset(size.width / 2, size.height * 0.4);
    final radius = size.width * 0.4;

    final path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addOval(Rect.fromCircle(center: center, radius: radius))
      ..fillType = PathFillType.evenOdd;

    canvas.drawPath(path, paint);

    final borderPaint = Paint()
      ..color = isValid ? Colors.blue : Colors.red
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0;

    canvas.drawCircle(center, radius, borderPaint);
  }

  @override
  bool shouldRepaint(covariant HeadMaskPainter oldDelegate) {
    return oldDelegate.isValid != isValid;
  }
}