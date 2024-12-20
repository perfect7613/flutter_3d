import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_3d_controller/flutter_3d_controller.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:uploadcare_client/uploadcare_client.dart';
import 'package:path_provider/path_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");
  runApp(const ModelViewerApp());
}

class ModelViewerApp extends StatelessWidget {
  const ModelViewerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Image to 3D Model',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const Image3DModelView(),
    );
  }
}

class Image3DModelView extends StatefulWidget {
  const Image3DModelView({Key? key}) : super(key: key);

  @override
  State<Image3DModelView> createState() => _Image3DModelViewState();
}

class _Image3DModelViewState extends State<Image3DModelView> {
  final Flutter3DController _controller = Flutter3DController();
  final ImagePicker _picker = ImagePicker();
  UploadcareClient? _uploadcareClient;
  
  String? _localModelPath;
  bool _isGenerating = false;
  bool _isUploading = false;
  bool _isDownloading = false;
  String? _error;
  double _uploadProgress = 0.0;

  @override
  void initState() {
    super.initState();
    _initializeServices();
  }

  Future<void> _initializeServices() async {
    try {
      final uploadcareKey = dotenv.env['UPLOADCARE_PUBLIC_KEY'];
      if (uploadcareKey == null || uploadcareKey.isEmpty) {
        throw Exception('Uploadcare public key not found in environment variables');
      }

      setState(() {
        _uploadcareClient = UploadcareClient.withSimpleAuth(
          publicKey: uploadcareKey,
          apiVersion: 'v0.7',
        );
      });
      debugPrint('Uploadcare client initialized successfully');
    } catch (e) {
      debugPrint('Error initializing services: $e');
      setState(() {
        _error = 'Failed to initialize services: $e';
      });
    }
  }

  String? _getReplicateToken() {
    try {
      final token = dotenv.env['REPLICATE_API_TOKEN'];
      if (token == null || token.isEmpty) {
        throw Exception('Replicate API token not found in environment variables');
      }
      debugPrint('Replicate token retrieved successfully');
      return token;
    } catch (e) {
      debugPrint('Error getting Replicate token: $e');
      setState(() {
        _error = 'Failed to get Replicate token: $e';
      });
      return null;
    }
  }

  Future<void> pickAndUploadImage() async {
    if (_uploadcareClient == null) {
      setState(() {
        _error = 'Upload client not initialized';
      });
      return;
    }

    try {
      final XFile? image = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 85,
      );
      if (image == null) return;

      await _uploadImage(File(image.path));
    } catch (e) {
      debugPrint('Error picking image: $e');
      setState(() {
        _error = 'Failed to pick image: $e';
        _isUploading = false;
      });
    }
  }

  Future<void> pickAndUploadCamera() async {
    if (_uploadcareClient == null) {
      setState(() {
        _error = 'Upload client not initialized';
      });
      return;
    }

    try {
      final XFile? image = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 85,
      );
      if (image == null) return;

      await _uploadImage(File(image.path));
    } catch (e) {
      debugPrint('Error capturing image: $e');
      setState(() {
        _error = 'Failed to capture image: $e';
        _isUploading = false;
      });
    }
  }

  Future<void> _uploadImage(File imageFile) async {
    setState(() {
      _isUploading = true;
      _isGenerating = false;
      _isDownloading = false;
      _error = null;
      _uploadProgress = 0.0;
    });

    try {
      if (!imageFile.existsSync()) {
        throw Exception('Image file not found');
      }

      debugPrint('Starting image upload to Uploadcare...');
      final fileId = await _uploadcareClient!.upload.auto(
        UCFile(imageFile),
        onProgress: (progress) {
          if (mounted) {
            setState(() {
              _uploadProgress = progress.value;
              debugPrint('Upload progress: ${(progress.value * 100).toStringAsFixed(1)}%');
            });
          }
        },
      );

      debugPrint('Image uploaded successfully. File ID: $fileId');
      setState(() {
        _isUploading = false;
      });
      
      final cdnUrl = 'https://ucarecdn.com/$fileId/';
      await generateModelFromImage(cdnUrl);
    } catch (e) {
      debugPrint('Error uploading image: $e');
      if (mounted) {
        setState(() {
          _error = 'Failed to upload image: $e';
          _isUploading = false;
        });
      }
    }
  }

  Future<String> _downloadModel(String url) async {
    debugPrint('Starting model download from: $url');
    setState(() {
      _isDownloading = true;
    });

    try {
      debugPrint('Sending GET request to download model...');
      final response = await http.get(Uri.parse(url));
      
      if (response.statusCode != 200) {
        throw Exception('Failed to download model: ${response.statusCode}');
      }

      debugPrint('Model download successful, checking content...');
      if (response.bodyBytes.length < 100) {
        throw Exception('Downloaded file is too small to be a valid GLB');
      }

      // Verify GLB magic number
      final header = response.bodyBytes.sublist(0, 4);
      if (header[0] != 0x67 || header[1] != 0x6C || header[2] != 0x54 || header[3] != 0x46) {
        debugPrint('Invalid GLB header: ${header.map((b) => b.toRadixString(16)).join()}');
        throw Exception('Downloaded file is not a valid GLB model');
      }

      debugPrint('File appears to be a valid GLB model');
      final directory = await getApplicationDocumentsDirectory();
      final fileName = 'model_${DateTime.now().millisecondsSinceEpoch}.glb';
      final filePath = '${directory.path}/$fileName';

      debugPrint('Saving model to: $filePath');
      final file = File(filePath);
      await file.writeAsBytes(response.bodyBytes);
      debugPrint('Model saved successfully. File size: ${response.bodyBytes.length} bytes');

      setState(() {
        _isDownloading = false;
      });

      return filePath;
    } catch (e) {
      debugPrint('Error downloading model: $e');
      setState(() {
        _isDownloading = false;
        _error = 'Failed to download model: $e';
      });
      rethrow;
    }
  }

  Future<void> generateModelFromImage(String imageUrl) async {
    final replicateToken = _getReplicateToken();
    if (replicateToken == null) return;

    if (!mounted) return;
    setState(() {
      _isGenerating = true;
      _isUploading = false;
      _error = null;
    });

    try {
      debugPrint('Starting model generation with image URL: $imageUrl');
      final response = await http.post(
        Uri.parse('https://api.replicate.com/v1/predictions'),
        headers: {
          'Authorization': 'Bearer $replicateToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'version': '4581bc11c4a0700fd7ec31e16040aa10f1a540b682d7b7b3d51ac2d6bd4ecd3a',
          'input': {
            'image': imageUrl,
            'seed': 0,
            'texture_size': 1024,
            'mesh_simplify': 0.95,
            'generate_color': true,
            'generate_model': true,
            'randomize_seed': true,
            'generate_normal': false,
            'ss_sampling_steps': 12,
            'slat_sampling_steps': 12,
            'ss_guidance_strength': 7.5,
            'slat_guidance_strength': 3,
          },
        }),
      );

      if (!mounted) return;

      if (response.statusCode != 201) {
        debugPrint('Error response from Replicate: ${response.body}');
        throw Exception('Failed to create prediction: ${response.body}');
      }

      final predictionData = jsonDecode(response.body);
      final String predictionId = predictionData['id'];
      debugPrint('Prediction created. ID: $predictionId');

      int retryCount = 0;
      while (mounted && retryCount < 60) { // 2 minutes timeout
        debugPrint('Checking prediction status... (attempt ${retryCount + 1})');
        final statusResponse = await http.get(
          Uri.parse('https://api.replicate.com/v1/predictions/$predictionId'),
          headers: {
            'Authorization': 'Bearer $replicateToken',
          },
        );

        if (!mounted) return;

        if (statusResponse.statusCode != 200) {
          debugPrint('Error checking status: ${statusResponse.body}');
          throw Exception('Failed to check prediction status');
        }

        final statusData = jsonDecode(statusResponse.body);
        final status = statusData['status'] as String;
        debugPrint('Prediction status: $status');

        switch (status) {
          case 'starting':
            debugPrint('Generation is starting...');
            break;
          case 'processing':
            debugPrint('Generation is in progress...');
            break;
          case 'succeeded':
            final output = statusData['output'] as Map<String, dynamic>?;
            final modelFile = output?['model_file'] as String?;
            
            if (modelFile == null) {
              throw Exception('No model file in response');
            }
            
            debugPrint('Received model URL: $modelFile');
            // Download the model
            _localModelPath = await _downloadModel(modelFile);
            debugPrint('Model downloaded to: $_localModelPath');
            if (mounted) {
              setState(() {
                _isGenerating = false;
              });
            }
            return;
          case 'failed':
            final error = statusData['error'] as String?;
            throw Exception('Model generation failed: ${error ?? 'Unknown error'}');
          case 'canceled':
            throw Exception('Model generation was canceled');
          default:
            debugPrint('Unknown status: $status');
        }

        retryCount++;
        await Future.delayed(const Duration(seconds: 2));
      }

      if (retryCount >= 60) {
        throw Exception('Generation timed out after 2 minutes');
      }
    } catch (e) {
      debugPrint('Error generating 3D model: $e');
      if (mounted) {
        setState(() {
          _error = 'Failed to generate 3D model: $e';
          _isGenerating = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Image to 3D Model'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Card(
              elevation: 0,
              margin: const EdgeInsets.all(16),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed: _isUploading || _isGenerating 
                        ? null 
                        : pickAndUploadImage,
                      icon: const Icon(Icons.photo_library),
                      label: const Text('Gallery'),
                    ),
                    const SizedBox(width: 16),
                    FilledButton.icon(
                      onPressed: _isUploading || _isGenerating 
                        ? null 
                        : pickAndUploadCamera,
                      icon: const Icon(Icons.camera_alt),
                      label: const Text('Camera'),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: _buildMainContent(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMainContent() {
    debugPrint('Building main content - States: isUploading: $_isUploading, isGenerating: $_isGenerating, isDownloading: $_isDownloading');
    
    if (_isUploading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(
              value: _uploadProgress,
              color: Theme.of(context).primaryColor,
            ),
            const SizedBox(height: 16),
            Text(
              'Uploading image... ${(_uploadProgress * 100).toStringAsFixed(1)}%',
              style: const TextStyle(fontSize: 16),
            ),
          ],
        ),
      );
    }

    if (_isGenerating) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text(
              'Generating 3D model...\nThis may take a few minutes',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16),
            ),
          ],
        ),
      );
    }

    if (_isDownloading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text(
              'Downloading model...',
              style: TextStyle(fontSize: 16),
            ),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 48),
              const SizedBox(height: 16),
              Text(
                'Error: $_error',
                style: const TextStyle(color: Colors.red, fontSize: 16),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _error = null;
                    _isUploading = false;
                    _isGenerating = false;
                    _isDownloading = false;
                  });
                },
                child: const Text('Try Again'),
              ),
            ],
          ),
        ),
      );
    }

    if (_localModelPath != null) {
      final modelFile = File(_localModelPath!);
      if (!modelFile.existsSync()) {
        debugPrint('Model file not found at path: $_localModelPath');
        return const Center(
          child: Text(
            'Error: Model file not found',
            style: TextStyle(color: Colors.red, fontSize: 16),
          ),
        );
      }

      debugPrint('Attempting to load model from: $_localModelPath');
      debugPrint('File exists, size: ${modelFile.lengthSync()} bytes');

      return Container(
        width: double.infinity,
        height: double.infinity,
        color: Colors.grey[200],
        child: Flutter3DViewer(
          src: _localModelPath!,
          controller: _controller,
          activeGestureInterceptor: true,
          enableTouch: true,
          progressBarColor: Colors.orange,
          onProgress: (double progressValue) {
            debugPrint('3D Model loading progress: $progressValue');
          },
          onLoad: (String modelAddress) {
            debugPrint('3D Model loaded successfully from: $modelAddress');
            if (mounted) {
              setState(() {
                _isGenerating = false;
                _isDownloading = false;
              });
            }
          },
          onError: (String error) {
            debugPrint('3D Model failed to load: $error');
            if (mounted) {
              setState(() {
                _error = error;
              });
            }
          },
        ),
      );
    }

    return const Center(
      child: Text(
        'Select an image to generate a 3D model',
        style: TextStyle(fontSize: 16),
      ),
    );
  }

  @override
  void dispose() {
    // Clean up any resources if needed in the future
    super.dispose();
  }
}
