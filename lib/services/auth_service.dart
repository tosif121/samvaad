class AuthService {
  static const String _hardcodedUsername = 'demo@surya';
  static const String _hardcodedPassword = 'Demo@123';

  static Future<bool> isLoggedIn() async => true;

  static Future<String?> getUsername() async => _hardcodedUsername;

  static Future<String?> getSavedPassword() async => _hardcodedPassword;
}
