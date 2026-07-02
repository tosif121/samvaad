import 'package:shared_preferences/shared_preferences.dart';

class AuthService {
  // Save credentials for SIP registration only (no API dependency)
  static Future<void> saveCredentials(
    String username,
    String password,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('savedUsername', username);
    await prefs.setString('savedPassword', password);
    await prefs.remove('userLoggedOut');
  }

  // Check if user has saved credentials
  static Future<bool> hasCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString('savedUsername');
    final password = prefs.getString('savedPassword');
    final userLoggedOut = prefs.getBool('userLoggedOut') ?? false;
    return username != null && password != null && !userLoggedOut;
  }

  // Get saved username for SIP registration
  static Future<String?> getSavedUsername() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('savedUsername');
  }

  // Get saved password for SIP registration
  static Future<String?> getSavedPassword() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('savedPassword');
  }

  // Logout — clears all stored credentials
  static Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('savedUsername');
    await prefs.remove('savedPassword');
    await prefs.setBool('userLoggedOut', true);
  }

  // Clear all auth data
  static Future<void> clearAuthData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('savedUsername');
    await prefs.remove('savedPassword');
    await prefs.remove('userLoggedOut');
  }
}
