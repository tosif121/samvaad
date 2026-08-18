import 'dart:developer';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

class PermissionService {
  static final PermissionService _instance = PermissionService._internal();
  factory PermissionService() => _instance;
  PermissionService._internal();

  /// Requests Notifications and Microphone permissions sequentially on app launch.
  Future<void> requestAppPermissions() async {
    try {
      // 1. Notification permission
      final notifStatus = await Permission.notification.status;
      if (!notifStatus.isGranted) {
        log('[PERMISSION_SERVICE] Prompting Notification permission...');
        final res = await Permission.notification.request();
        log('[PERMISSION_SERVICE] Notification permission result: $res');
      }

      // Small delay between permission dialogs on iOS so the OS can transition
      if (Platform.isIOS) {
        await Future.delayed(const Duration(milliseconds: 300));
      }

      // 2. Microphone permission (critical for calls)
      final micStatus = await Permission.microphone.status;
      if (!micStatus.isGranted) {
        log('[PERMISSION_SERVICE] Prompting Microphone permission...');
        final res = await Permission.microphone.request();
        log('[PERMISSION_SERVICE] Microphone permission result: $res');
      }

      // 3. Android specific
      if (Platform.isAndroid) {
        if (!await Permission.systemAlertWindow.isGranted) {
          await Permission.systemAlertWindow.request();
        }
      }
    } catch (e) {
      log('[PERMISSION_SERVICE] Error requesting permissions: $e');
    }
  }

  /// Check and request microphone permission before calls, showing settings dialog if permanently denied.
  Future<bool> ensureMicrophonePermission(BuildContext? context) async {
    try {
      final status = await Permission.microphone.status;
      if (status.isGranted) return true;

      final result = await Permission.microphone.request();
      if (result.isGranted) return true;

      if (result.isPermanentlyDenied || result.isRestricted) {
        if (context != null && context.mounted) {
          showPermissionSettingsDialog(
            context,
            title: 'Microphone Permission Required',
            message:
                'Microphone access is required to make and receive calls. Please enable it in your device settings.',
          );
        }
        return false;
      }

      return result.isGranted;
    } catch (e) {
      log('[PERMISSION_SERVICE] Error in ensureMicrophonePermission: $e');
      return true;
    }
  }

  /// Shows an alert dialog asking the user to open settings to grant permission
  void showPermissionSettingsDialog(
    BuildContext context, {
    required String title,
    required String message,
  }) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              openAppSettings();
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }
}
