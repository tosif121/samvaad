import 'dart:io';
import 'dart:async';
import 'dart:developer' as developer;
import 'package:path_provider/path_provider.dart';

class LogService {
  static final LogService _instance = LogService._();
  factory LogService() => _instance;
  LogService._();

  static const int _maxLogSize = 5 * 1024 * 1024; // 5MB
  static const int _truncateTo = 2 * 1024 * 1024; // 2MB after truncation

  File? _logFile;
  IOSink? _sink;
  StreamController<String>? _liveController;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    final dir = await getApplicationDocumentsDirectory();
    _logFile = File('${dir.path}/samvaad_logs.txt');
    if (await _logFile!.exists()) {
      final len = await _logFile!.length();
      if (len > _maxLogSize) {
        final bytes = await _logFile!.readAsBytes();
        await _logFile!.writeAsBytes(bytes.sublist(len - _truncateTo));
      }
    }
    _sink = _logFile!.openWrite(mode: FileMode.append);
    _liveController = StreamController<String>.broadcast();
    _initialized = true;
  }

  Stream<String> get liveStream => _liveController!.stream;

  void write(String tag, String message, {Object? data}) {
    final ts = DateTime.now().toIso8601String();
    final log = data != null
        ? '[$ts] [$tag] $message | $data'
        : '[$ts] [$tag] $message';
    developer.log(log, name: 'Samvaad');
    _sink?.writeln(log);
    _liveController?.add('$log\n');
  }

  Future<String> readLogs() async {
    if (_logFile == null || !await _logFile!.exists()) return '';
    return await _logFile!.readAsString();
  }

  Future<void> clearLogs() async {
    await _sink?.flush();
    _sink?.close();
    _sink = null;
    if (_logFile != null && await _logFile!.exists()) {
      await _logFile!.delete();
    }
    _sink = _logFile!.openWrite(mode: FileMode.append);
  }

  Future<String> get logFilePath async {
    if (_logFile == null) return '';
    return _logFile!.path;
  }

  Future<void> dispose() async {
    await _sink?.flush();
    await _sink?.close();
    await _liveController?.close();
    _initialized = false;
  }
}
