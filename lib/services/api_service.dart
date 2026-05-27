import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;
import 'auth_service.dart';

class ApiService {
  static const String baseUrl = 'https://devapp.iotcom.io';

  // Central logger
  static void _log(String tag, String message, {Object? data}) {
    final timestamp = DateTime.now().toIso8601String();
    final log = data != null
        ? '[$timestamp] [$tag] $message | data: $data'
        : '[$timestamp] [$tag] $message';
    developer.log(log, name: 'Samvaad');
    print(log);
  }

  // Get auth headers
  static Future<Map<String, String>> _getHeaders() async {
    final token = await AuthService.getToken();
    final username = await AuthService.getUsername();
    _log(
      'HEADERS',
      'Building headers',
      data: {'hasToken': token != null, 'username': username},
    );
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
      'X-User-ID': ?username,
    };
  }

  // User Ready
  static Future<Map<String, dynamic>> userReady() async {
    try {
      final username = await AuthService.getUsername();
      if (username == null) {
        _log('USER_READY', 'ERROR: No username found');
        return {'success': false, 'message': 'No username found'};
      }

      _log('USER_READY', 'POST /userready/$username/Web');

      final response = await http.post(
        Uri.parse('$baseUrl/userready/$username/Web'),
        headers: await _getHeaders(),
        body: jsonEncode({}),
      );

      _log(
        'USER_READY',
        'Response ${response.statusCode}',
        data: response.body,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final success = data['message'] == 'success';
        _log(
          'USER_READY',
          success ? 'Agent is READY' : 'Agent NOT ready',
          data: data,
        );
        return {'success': success, 'message': data['message'], 'data': data};
      }

      _log(
        'USER_READY',
        'Failed with status ${response.statusCode}',
        data: response.body,
      );
      return {'success': false, 'message': 'Failed: ${response.statusCode}'};
    } catch (e) {
      _log('USER_READY', 'EXCEPTION: $e');
      return {'success': false, 'message': 'Error: $e'};
    }
  }

  // User Connection
  static Future<Map<String, dynamic>> userConnection() async {
    try {
      final username = await AuthService.getUsername();
      if (username == null) {
        _log('USER_CONNECTION', 'ERROR: No username found');
        return {'success': false, 'message': 'No username found'};
      }

      _log('USER_CONNECTION', 'POST /userconnection', data: {'user': username});

      final response = await http.post(
        Uri.parse('$baseUrl/userconnection'),
        headers: await _getHeaders(),
        body: jsonEncode({'user': username}),
      );

      _log(
        'USER_CONNECTION',
        'Response ${response.statusCode}',
        data: response.body,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _log(
          'USER_CONNECTION',
          'Status: ${data['message']} | agentStatus: ${data['status']}',
        );
        return {'success': true, 'data': data};
      }

      if (response.statusCode == 401) {
        _log('USER_CONNECTION', 'UNAUTHORIZED - session expired');
        return {
          'success': false,
          'message': 'Session expired',
          'statusCode': 401,
        };
      }

      _log(
        'USER_CONNECTION',
        'Failed with status ${response.statusCode}',
        data: response.body,
      );
      return {'success': false, 'message': 'Failed: ${response.statusCode}'};
    } catch (e) {
      _log('USER_CONNECTION', 'EXCEPTION: $e');
      return {'success': false, 'message': 'Error: $e'};
    }
  }

  // Dial Number
  static Future<Map<String, dynamic>> dialNumber(String phoneNumber) async {
    try {
      _log('DIAL', 'POST /dialnumber', data: {'receiver': phoneNumber});

      final headers = await _getHeaders();
      _log(
        'DIAL',
        'Headers',
        data: headers.map(
          (k, v) => MapEntry(k, k == 'Authorization' ? 'Bearer ***' : v),
        ),
      );

      final response = await http.post(
        Uri.parse('$baseUrl/dialnumber'),
        headers: headers,
        body: jsonEncode({'receiver': phoneNumber}),
      );

      _log('DIAL', 'Response ${response.statusCode}', data: response.body);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        if (data.containsKey('success') && data['success'] == false) {
          _log('DIAL', 'API returned failure', data: data);
          return {
            'success': false,
            'message': data['message'] ?? 'Failed to dial',
          };
        }

        _log('DIAL', 'Call initiated successfully', data: data);
        return {'success': true, 'message': 'Call initiated', 'data': data};
      }

      _log(
        'DIAL',
        'Failed with status ${response.statusCode}',
        data: response.body,
      );
      return {
        'success': false,
        'message': 'Failed: ${response.statusCode} - ${response.body}',
      };
    } catch (e) {
      _log('DIAL', 'EXCEPTION: $e');
      return {'success': false, 'message': 'Error: $e'};
    }
  }

  // User On Call
  static Future<Map<String, dynamic>> userOnCall() async {
    try {
      final username = await AuthService.getUsername();
      if (username == null) {
        _log('USER_ON_CALL', 'ERROR: No username found');
        return {'success': false, 'message': 'No username found'};
      }

      _log('USER_ON_CALL', 'POST /useroncall/$username');

      final response = await http.post(
        Uri.parse('$baseUrl/useroncall/$username'),
        headers: await _getHeaders(),
        body: jsonEncode({}),
      );

      _log(
        'USER_ON_CALL',
        'Response ${response.statusCode}',
        data: response.body,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _log(
          'USER_ON_CALL',
          'bridgeID: ${data['currentcalldata']?['bridgeID']}',
        );
        return {'success': true, 'data': data};
      }

      _log('USER_ON_CALL', 'Failed with status ${response.statusCode}');
      return {'success': false, 'message': 'Failed: ${response.statusCode}'};
    } catch (e) {
      _log('USER_ON_CALL', 'EXCEPTION: $e');
      return {'success': false, 'message': 'Error: $e'};
    }
  }

  // Call Ended
  static Future<Map<String, dynamic>> callEnded() async {
    try {
      final username = await AuthService.getUsername();
      if (username == null) {
        _log('CALL_ENDED', 'ERROR: No username found');
        return {'success': false, 'message': 'No username found'};
      }

      _log('CALL_ENDED', 'POST /user/callended$username');

      final response = await http.post(
        Uri.parse('$baseUrl/user/callended$username'),
        headers: await _getHeaders(),
        body: jsonEncode({}),
      );

      _log(
        'CALL_ENDED',
        'Response ${response.statusCode}',
        data: response.body,
      );

      if (response.statusCode == 200) {
        _log('CALL_ENDED', 'Call ended successfully');
        return {'success': true};
      }

      _log('CALL_ENDED', 'Failed with status ${response.statusCode}');
      return {'success': false, 'message': 'Failed: ${response.statusCode}'};
    } catch (e) {
      _log('CALL_ENDED', 'EXCEPTION: $e');
      return {'success': false, 'message': 'Error: $e'};
    }
  }

  // Hold
  static Future<Map<String, dynamic>> reqHold() async {
    try {
      final username = await AuthService.getUsername();
      if (username == null) return {'success': false, 'message': 'No username'};
      _log('REQ_HOLD', 'POST /reqHold/$username');
      final response = await http.post(
        Uri.parse('$baseUrl/reqHold/$username'),
        headers: await _getHeaders(),
      );
      _log('REQ_HOLD', 'Response ${response.statusCode}', data: response.body);
      return {'success': response.statusCode == 200};
    } catch (e) {
      _log('REQ_HOLD', 'EXCEPTION: $e');
      return {'success': false, 'message': 'Error: $e'};
    }
  }

  // Unhold
  static Future<Map<String, dynamic>> reqUnHold() async {
    try {
      final username = await AuthService.getUsername();
      if (username == null) return {'success': false, 'message': 'No username'};
      _log('REQ_UNHOLD', 'POST /reqUnHold/$username');
      final response = await http.post(
        Uri.parse('$baseUrl/reqUnHold/$username'),
        headers: await _getHeaders(),
      );
      _log('REQ_UNHOLD', 'Response ${response.statusCode}', data: response.body);
      return {'success': response.statusCode == 200};
    } catch (e) {
      _log('REQ_UNHOLD', 'EXCEPTION: $e');
      return {'success': false, 'message': 'Error: $e'};
    }
  }

  // Conference / Add Call
  static Future<Map<String, dynamic>> reqConf(
    String confNumber, {
    String bridgeID = '',
  }) async {
    try {
      final username = await AuthService.getUsername();
      if (username == null) return {'success': false, 'message': 'No username'};
      _log('REQ_CONF', 'POST /reqConf/$username', data: {
        'confNumber': confNumber,
        'bridgeID': bridgeID,
      });
      final response = await http.post(
        Uri.parse('$baseUrl/reqConf/$username'),
        headers: await _getHeaders(),
        body: jsonEncode({'confNumber': confNumber, 'bridgeID': bridgeID}),
      );
      _log('REQ_CONF', 'Response ${response.statusCode}', data: response.body);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return {'success': true, 'data': data};
      }
      return {'success': false, 'message': 'Failed: ${response.statusCode}'};
    } catch (e) {
      _log('REQ_CONF', 'EXCEPTION: $e');
      return {'success': false, 'message': 'Error: $e'};
    }
  }

  // Hangup Conference
  static Future<Map<String, dynamic>> hangupConference(
    String hostNumber,
  ) async {
    try {
      final username = await AuthService.getUsername();
      if (username == null) return {'success': false, 'message': 'No username'};
      _log('HANGUP_CONF', 'POST /hangup/hostChannel/Conf', data: {
        'hostNumber': hostNumber,
      });
      final response = await http.post(
        Uri.parse('$baseUrl/hangup/hostChannel/Conf'),
        headers: await _getHeaders(),
        body: jsonEncode({'user': username, 'hostNumber': hostNumber}),
      );
      _log('HANGUP_CONF', 'Response ${response.statusCode}', data: response.body);
      return {'success': response.statusCode == 200};
    } catch (e) {
      _log('HANGUP_CONF', 'EXCEPTION: $e');
      return {'success': false, 'message': 'Error: $e'};
    }
  }

  // Transfer
  static Future<Map<String, dynamic>> reqTransfer(String bridgeID) async {
    try {
      final username = await AuthService.getUsername();
      if (username == null) return {'success': false, 'message': 'No username'};
      _log('REQ_TRANSFER', 'POST /reqTransfer/$username', data: {'bridgeID': bridgeID});
      final response = await http.post(
        Uri.parse('$baseUrl/reqTransfer/$username'),
        headers: await _getHeaders(),
        body: jsonEncode({'bridgeID': bridgeID}),
      );
      _log('REQ_TRANSFER', 'Response ${response.statusCode}', data: response.body);
      return {'success': response.statusCode == 200};
    } catch (e) {
      _log('REQ_TRANSFER', 'EXCEPTION: $e');
      return {'success': false, 'message': 'Error: $e'};
    }
  }

  // Disposition
  static Future<Map<String, dynamic>> submitDisposition(
    String bridgeID,
    String disposition,
  ) async {
    try {
      final username = await AuthService.getUsername();
      if (username == null) {
        _log('DISPOSITION', 'ERROR: No username found');
        return {'success': false, 'message': 'No username found'};
      }

      _log(
        'DISPOSITION',
        'POST /user/disposition$username',
        data: {'bridgeID': bridgeID, 'Disposition': disposition},
      );

      final response = await http.post(
        Uri.parse('$baseUrl/user/disposition$username'),
        headers: await _getHeaders(),
        body: jsonEncode({
          'bridgeID': bridgeID,
          'Disposition': disposition,
          'autoDialDisabled': false,
        }),
      );

      _log(
        'DISPOSITION',
        'Response ${response.statusCode}',
        data: response.body,
      );

      if (response.statusCode == 200) {
        _log('DISPOSITION', 'Disposition submitted successfully');
        return {'success': true};
      }

      _log('DISPOSITION', 'Failed with status ${response.statusCode}');
      return {'success': false, 'message': 'Failed: ${response.statusCode}'};
    } catch (e) {
      _log('DISPOSITION', 'EXCEPTION: $e');
      return {'success': false, 'message': 'Error: $e'};
    }
  }
}
