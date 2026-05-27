import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class AuthService {
  static const String baseUrl = 'https://devapp.iotcom.io';

  // Login method matching the webphone implementation
  static Future<Map<String, dynamic>> login(
    String username,
    String password,
  ) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/userlogin/$username'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'username': username, 'password': password}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        print('HTTP LOGIN RESPONSE DATA: $data');

        // Check for various error messages
        if (data['message'] == 'wrong login info') {
          return {
            'success': false,
            'message': 'Incorrect username or password',
          };
        }

        if (data['message'] == 'User already login somewhere else') {
          return {
            'success': false,
            'message': 'User already logged in somewhere else',
            'conflict': true,
          };
        }

        if (data['message'] == 'Request failed') {
          return {
            'success': false,
            'message': 'Login request failed. Please try again.',
          };
        }

        // Check if userData exists
        if (data['userData'] == null) {
          return {'success': false, 'message': 'Invalid user data received'};
        }

        // Check subscription expiry
        final userData = data['userData'];
        if (userData['ExpiryDate'] != null) {
          final expiryDate = DateTime.parse(userData['ExpiryDate']);
          final currentDate = DateTime.now();
          final differenceInDays = expiryDate.difference(currentDate).inDays;

          if (differenceInDays < -5) {
            return {
              'success': false,
              'message':
                  'Your subscription has expired. Please renew to continue.',
              'expired': true,
            };
          }

          // Store subscription info for later use
          data['subscriptionDaysRemaining'] = differenceInDays;
        }

        // Save token and credentials
        await _saveAuthData(data, username, password);

        return {'success': true, 'data': data, 'message': 'Login successful'};
      } else {
        return {
          'success': false,
          'message': 'Server error. Please try again later.',
        };
      }
    } catch (e) {
      return {'success': false, 'message': 'Network error: ${e.toString()}'};
    }
  }

  // Save authentication data
  static Future<void> _saveAuthData(
    Map<String, dynamic> data,
    String username,
    String password,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('token', jsonEncode(data));
    await prefs.setString('savedUsername', username);
    await prefs.setString('savedPassword', password);
    await prefs.remove('userLoggedOut');
  }

  // Get stored token
  static Future<Map<String, dynamic>?> getStoredToken() async {
    final prefs = await SharedPreferences.getInstance();
    final tokenString = prefs.getString('token');
    if (tokenString != null) {
      return jsonDecode(tokenString);
    }
    return null;
  }

  // Get user data from stored token
  static Future<Map<String, dynamic>?> getUserData() async {
    final token = await getStoredToken();
    return token?['userData'];
  }

  // Check if user is logged in
  static Future<bool> isLoggedIn() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');
    final userLoggedOut = prefs.getBool('userLoggedOut') ?? false;
    return token != null && !userLoggedOut;
  }

  // Auto login with saved credentials
  static Future<Map<String, dynamic>?> autoLogin() async {
    final prefs = await SharedPreferences.getInstance();
    final savedUsername = prefs.getString('savedUsername');
    final savedPassword = prefs.getString('savedPassword');
    final userLoggedOut = prefs.getBool('userLoggedOut') ?? false;

    if (savedUsername != null && savedPassword != null && !userLoggedOut) {
      return await login(savedUsername, savedPassword);
    }
    return null;
  }

  // Logout
  static Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('userLoggedOut', true);
    // Keep savedUsername and savedPassword for potential re-login
  }

  // Clear all auth data
  static Future<void> clearAuthData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
    await prefs.remove('savedUsername');
    await prefs.remove('savedPassword');
    await prefs.remove('userLoggedOut');
  }

  // Get username from stored token
  static Future<String?> getUsername() async {
    final userData = await getUserData();
    return userData?['userid'] ?? userData?['username'];
  }

  // Get token string
  static Future<String?> getToken() async {
    final token = await getStoredToken();
    return token?['token'];
  }

  // Get saved password for SIP registration
  static Future<String?> getSavedPassword() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('savedPassword');
  }
}
