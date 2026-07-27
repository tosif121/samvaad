import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class OemOptimizationService {
  static final OemOptimizationService _instance = OemOptimizationService._internal();
  factory OemOptimizationService() => _instance;
  OemOptimizationService._internal();

  /// Requests standard notification permissions (Android 13+ / iOS).
  Future<bool> requestNotificationPermission() async {
    final status = await Permission.notification.status;
    if (!status.isGranted) {
      final result = await Permission.notification.request();
      return result.isGranted;
    }
    return true;
  }

  /// Requests ignore battery optimization permission.
  Future<bool> requestIgnoreBatteryOptimization() async {
    if (!Platform.isAndroid) return true;
    final status = await Permission.ignoreBatteryOptimizations.status;
    if (!status.isGranted) {
      final result = await Permission.ignoreBatteryOptimizations.request();
      return result.isGranted;
    }
    return true;
  }

  /// Returns the device manufacturer string in lowercase.
  Future<String> getDeviceManufacturer() async {
    if (!Platform.isAndroid) return '';
    try {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      return androidInfo.manufacturer.toLowerCase();
    } catch (_) {
      return '';
    }
  }

  /// Checks whether autostart guidance should be shown to the user.
  Future<bool> shouldShowOemGuidance() async {
    if (!Platform.isAndroid) return false;
    final prefs = await SharedPreferences.getInstance();
    final alreadyPrompted = prefs.getBool('oem_autostart_prompted') ?? false;
    if (alreadyPrompted) return false;

    final manufacturer = await getDeviceManufacturer();
    final oemBrands = ['xiaomi', 'redmi', 'poco', 'oppo', 'realme', 'vivo', 'iqoo', 'oneplus', 'huawei', 'honor', 'motorola'];
    return oemBrands.any((brand) => manufacturer.contains(brand));
  }

  /// Marks that the guidance dialog was shown.
  Future<void> markOemGuidancePrompted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('oem_autostart_prompted', true);
  }

  /// Opens the device app settings.
  Future<void> openSettings() async {
    await openAppSettings();
  }

  /// Prompts for permissions and shows OEM autostart guidance dialog if needed.
  Future<void> checkAndShowOemGuidanceDialog(BuildContext context) async {
    if (!context.mounted) return;

    // 1. Request Notification Permission
    await requestNotificationPermission();

    // 2. Request Battery Optimization Exemption
    await requestIgnoreBatteryOptimization();

    // 3. Check if OEM autostart guidance should be shown
    if (await shouldShowOemGuidance()) {
      final manufacturer = await getDeviceManufacturer();
      final brandName = _formatBrandName(manufacturer);
      if (!context.mounted) return;

      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Row(
            children: [
              const Icon(Icons.notifications_active_rounded, color: Color(0xFF4299EB), size: 28),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Background Calls ($brandName)',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'To receive incoming call notifications reliably on $brandName phones when your app is closed:',
                style: TextStyle(fontSize: 14, color: Colors.grey.shade800),
              ),
              const SizedBox(height: 14),
              _buildStepItem('1. Enable "Autostart / Background Run" in Settings.'),
              _buildStepItem('2. Set Battery Saver to "No Restrictions".'),
              _buildStepItem('3. Allow Display over other apps / Pop-ups.'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await markOemGuidancePrompted();
                if (ctx.mounted) Navigator.of(ctx).pop();
              },
              child: const Text('Later', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4299EB),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () async {
                await markOemGuidancePrompted();
                if (ctx.mounted) Navigator.of(ctx).pop();
                await openSettings();
              },
              child: const Text('Open Settings'),
            ),
          ],
        ),
      );
    }
  }

  Widget _buildStepItem(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.check_circle_outline_rounded, size: 16, color: Color(0xFF00C853)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  String _formatBrandName(String manufacturer) {
    if (manufacturer.contains('xiaomi') || manufacturer.contains('redmi') || manufacturer.contains('poco')) {
      return 'Xiaomi / Redmi / POCO';
    } else if (manufacturer.contains('realme') || manufacturer.contains('oppo')) {
      return 'Realme / OPPO';
    } else if (manufacturer.contains('vivo') || manufacturer.contains('iqoo')) {
      return 'Vivo / iQOO';
    } else if (manufacturer.contains('oneplus')) {
      return 'OnePlus';
    } else if (manufacturer.contains('motorola')) {
      return 'Motorola';
    }
    return manufacturer.isNotEmpty ? manufacturer[0].toUpperCase() + manufacturer.substring(1) : 'Phone';
  }
}
