import 'dart:typed_data';
import 'dart:js_interop';
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:revengi/utils/dartinfo.dart';
import 'package:revengi/utils/dio.dart';
import 'package:shared_preferences/shared_preferences.dart'
    show SharedPreferences;
import 'package:web/web.dart' as web;

class BlutterAnalysisScreen extends StatefulWidget {
  const BlutterAnalysisScreen({super.key});

  @override
  State<BlutterAnalysisScreen> createState() => _BlutterAnalysisScreenState();
}

class _BlutterAnalysisScreenState extends State<BlutterAnalysisScreen> {
  bool _isAnalyzing = false;
  String? _error;
  String? _successMessage;
  String? _fileName;
  List<int> _fileBytes = [];
  List<int> _libappBytes = [];
  List<int> _libflutterBytes = [];
  late double _uploadProgress;
  late double _downloadProgress;

  Future<void> _pickApkFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip', 'apk'],
    );

    if (result != null) {
      setState(() {
        _fileName = result.files.first.name;
        _fileBytes = result.files.first.bytes!;
        _error = null;
        _successMessage = null;
      });

      if (_fileName!.endsWith('.zip') || _fileName!.endsWith('.apk')) {
        await _extractFiles();
      }
    }
  }

  Future<void> _extractFiles() async {
    if (_fileBytes.isEmpty) return;
    String fileEnd = "arm64-v8a/libapp.so";
    if (_fileName!.endsWith('.zip')) {
      fileEnd = "libapp.so";
    }
    try {
      final archive = ZipDecoder().decodeBytes(_fileBytes);

      for (final file in archive) {
        if (file.isFile && file.name.endsWith(fileEnd)) {
          _libappBytes = file.content as List<int>;
        } else if (file.isFile && file.name.endsWith('libflutter.so')) {
          _libflutterBytes = file.content as List<int>;
        }
      }

      if (_libappBytes.isEmpty || _libflutterBytes.isEmpty) {
        throw Exception('libapp.so or libflutter.so not found in the archive');
      }

      setState(() {
        _error = null;
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to extract files from ZIP: $e';
      });
    }
  }

  Future<void> _analyzeFiles() async {
    if (_fileBytes.isEmpty) return;

    setState(() {
      _isAnalyzing = true;
      _error = null;
      _successMessage = null;
      _uploadProgress = 0;
      _downloadProgress = 0;
    });

    try {
      final elfParser = ElfParser(
        flutterLibBytes: Uint8List.fromList(_libflutterBytes),
      );
      final rodataInfo = elfParser.extractRodataInfo();
      String? dartVersion = rodataInfo?.$2;
      if (dartVersion == null && rodataInfo != null) {
        final sdkInfo = await elfParser.getSdkInfo();
        dartVersion = sdkInfo?.dartVersion;
      }
      if (dartVersion!.endsWith('.dev') || dartVersion.endsWith('.beta')) {
        _error =
            'Currently RevEngi only supports dart stable channel\n\nCurrent Dart Version: $dartVersion';
        return;
      }
      final formData = FormData.fromMap({
        'libapp': MultipartFile.fromBytes(_libappBytes, filename: 'libapp.so'),
      });

      final response = await dio.post(
        '/blutter',
        data: formData,
        options: Options(responseType: ResponseType.bytes),
        onSendProgress: (int sent, int total) {
          setState(() {
            _uploadProgress = sent / total;
          });
        },
        onReceiveProgress: (int received, int total) {
          if (total != -1) {
            setState(() {
              _downloadProgress = received / total;
            });
          }
        },
      );
      String? filename;
      final contentDisposition = response.headers['content-disposition']?.first;
      if (contentDisposition != null) {
        final regexExtended = RegExp(r"filename\*=([^']*)''([^;\n]+)");
        final regexStandard = RegExp(r'filename="?([^";\n]+)"?');
        final matchExtended = regexExtended.firstMatch(contentDisposition);
        if (matchExtended != null) {
          filename = Uri.decodeFull(matchExtended.group(2)!);
        } else {
          final matchStandard = regexStandard.firstMatch(contentDisposition);
          if (matchStandard != null) {
            filename = matchStandard.group(1);
          }
        }
      }
      filename ??= 'blutter_output.zip';
      final bytes = Uint8List.fromList(response.data);
      String url = web.URL.createObjectURL(
        web.Blob(
          <JSUint8Array>[bytes.toJS].toJS,
          web.BlobPropertyBag(type: ResponseType.bytes.toString()),
        ),
      );
      web.Document htmlDocument = web.document;
      web.HTMLAnchorElement anchor =
          htmlDocument.createElement('a') as web.HTMLAnchorElement;
      anchor.href = url;
      anchor.style.display = filename;
      anchor.download = filename;
      web.document.body!.add(anchor);
      anchor.click();
      anchor.remove();

      setState(() {
        _successMessage = 'Download started...';
      });
    } on DioException catch (e) {
      final prefs = await SharedPreferences.getInstance();
      final username = prefs.getString('username');
      setState(() {
        if (username == "guest") {
          _error = "Guest users cannot use this feature";
        } else if (e.response?.data != null &&
            e.response?.data is Map &&
            e.response?.data['detail'] != null) {
          _error =
              e.response?.data?['detail'] ??
              'An error occurred during analysis';
        } else if (e.type == DioExceptionType.connectionTimeout) {
          _error = 'Connection timeout';
        } else if (e.type == DioExceptionType.connectionError) {
          _error = 'No internet connection';
        } else {
          _error =
              'An error occurred during analysis, please make sure you\'ve selected the correct files';
        }
      });
    } finally {
      setState(() {
        _isAnalyzing = false;
        _uploadProgress = 0;
        _downloadProgress = 0;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Blutter Analysis')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Select APK/Zip File',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    ListTile(
                      leading: const Icon(Icons.android),
                      title: const Text('APK/Zip File'),
                      subtitle:
                          (_fileBytes.isNotEmpty)
                              ? Text(
                                _fileName!,
                                style: const TextStyle(color: Colors.green),
                              )
                              : const Text('No file selected'),
                      trailing: ElevatedButton(
                        onPressed: _isAnalyzing ? null : _pickApkFile,
                        child: const Text('Choose File'),
                      ),
                    ),
                    const SizedBox(height: 16),
                    RichText(
                      text: TextSpan(
                        children: [
                          TextSpan(
                            text: 'Note: ',
                            style: const TextStyle(
                              fontSize: 14,
                              color: Colors.orange,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          TextSpan(
                            text:
                                '\nAPK: The app will directly handle APK files.\n'
                                '\nZIP: Ensure ZIP files contain only the `libapp.so` for arm64 architecture. Failure to comply may result in errors.',
                            style: const TextStyle(
                              fontSize: 14,
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed:
                            (_fileBytes.isEmpty) || _isAnalyzing
                                ? null
                                : _analyzeFiles,
                        icon: const Icon(Icons.analytics),
                        label: Text(_isAnalyzing ? 'Analyzing...' : 'Analyze'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (_isAnalyzing) ...[
              if (_uploadProgress > 0 && _uploadProgress < 1)
                Column(
                  children: [
                    const Text('Uploading...'),
                    LinearProgressIndicator(value: _uploadProgress),
                    const SizedBox(height: 8),
                  ],
                ),
              if (_downloadProgress > 0 && _downloadProgress < 1)
                Column(
                  children: [
                    const Text('Downloading...'),
                    LinearProgressIndicator(value: _downloadProgress),
                    const SizedBox(height: 8),
                  ],
                ),
              if (_uploadProgress == 0 && _downloadProgress == 0)
                const Center(child: CircularProgressIndicator()),
            ] else if (_error != null)
              Card(
                color: Colors.red[100],
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _error!,
                    style: TextStyle(color: Colors.red[900]),
                  ),
                ),
              )
            else if (_successMessage != null)
              Card(
                color: Colors.green[100],
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _successMessage!,
                    style: TextStyle(color: Colors.green[900]),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
