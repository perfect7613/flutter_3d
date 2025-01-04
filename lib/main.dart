import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:uploadcare_client/uploadcare_client.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';

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
  final ImagePicker _picker = ImagePicker();
  UploadcareClient? _uploadcareClient;
  
  String? _modelUrl;
  bool _isGenerating = false;
  bool _isUploading = false;
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
      return token;
    } catch (e) {
      debugPrint('Error getting Replicate token: $e');
      setState(() {
        _error = 'Failed to get Replicate token: $e';
      });
      return null;
    }
  }

  Future<void> pickAndUploadImage(ImageSource source) async {
    if (_uploadcareClient == null) {
      setState(() {
        _error = 'Upload client not initialized';
      });
      return;
    }

    try {
      final XFile? image = await _picker.pickImage(
        source: source,
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

  Future<void> _uploadImage(File imageFile) async {
    setState(() {
      _isUploading = true;
      _isGenerating = false;
      _error = null;
      _uploadProgress = 0.0;
      _modelUrl = null;
    });

    try {
      if (!imageFile.existsSync()) {
        throw Exception('Image file not found');
      }

      final fileId = await _uploadcareClient!.upload.auto(
        UCFile(imageFile),
        onProgress: (progress) {
          if (mounted) {
            setState(() {
              _uploadProgress = progress.value;
            });
          }
        },
      );

      final cdnUrl = 'https://ucarecdn.com/$fileId/';
      setState(() {
        _isUploading = false;
      });
      
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

  Future<void> generateModelFromImage(String imageUrl) async {
    final replicateToken = _getReplicateToken();
    if (replicateToken == null) return;

    if (!mounted) return;
    setState(() {
      _isGenerating = true;
      _error = null;
    });

    try {
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
        throw Exception('Failed to create prediction: ${response.body}');
      }

      final predictionData = jsonDecode(response.body);
      final String predictionId = predictionData['id'];

      int retryCount = 0;
      while (mounted && retryCount < 60) {
        final statusResponse = await http.get(
          Uri.parse('https://api.replicate.com/v1/predictions/$predictionId'),
          headers: {
            'Authorization': 'Bearer $replicateToken',
          },
        );

        if (!mounted) return;

        if (statusResponse.statusCode != 200) {
          throw Exception('Failed to check prediction status');
        }

        final statusData = jsonDecode(statusResponse.body);
        final status = statusData['status'] as String;

        if (status == 'succeeded') {
          final output = statusData['output'] as Map<String, dynamic>?;
          final modelFile = output?['model_file'] as String?;
          
          if (modelFile == null) {
            throw Exception('No model file in response');
          }
          
          setState(() {
            _modelUrl = modelFile;
            _isGenerating = false;
          });
          return;
        } else if (status == 'failed') {
          throw Exception('Model generation failed: ${statusData['error']}');
        } else if (status == 'canceled') {
          throw Exception('Model generation was canceled');
        }

        retryCount++;
        await Future.delayed(const Duration(seconds: 2));
      }

      throw Exception('Generation timed out after 2 minutes');
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
                        : () => pickAndUploadImage(ImageSource.gallery),
                      icon: const Icon(Icons.photo_library),
                      label: const Text('Gallery'),
                    ),
                    const SizedBox(width: 16),
                    FilledButton.icon(
                      onPressed: _isUploading || _isGenerating 
                        ? null 
                        : () => pickAndUploadImage(ImageSource.camera),
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
                  });
                },
                child: const Text('Try Again'),
              ),
            ],
          ),
        ),
      );
    }

    if (_modelUrl != null) {
      return ModelViewer(
        backgroundColor: const Color(0xFFEEEEEE),
        src: _modelUrl!,
        alt: 'A 3D model generated from your image',
        ar: true,
        autoRotate: true,
        cameraControls: true,
        disableZoom: false,
      );
    }

    return const Center(
      child: Text(
        'Select an image to generate a 3D model',
        style: TextStyle(fontSize: 16),
      ),
    );
  }
}