class SipCredentials {
  final String serverUrl;
  final String sipUri;
  final String username;
  final String password;
  final String displayName;

  const SipCredentials({
    required this.serverUrl,
    required this.sipUri,
    required this.username,
    required this.password,
    required this.displayName,
  });

  Map<String, dynamic> toJson() => {
    'serverUrl': serverUrl,
    'sipUri': sipUri,
    'username': username,
    'password': password,
    'displayName': displayName,
  };

  factory SipCredentials.fromJson(Map<String, dynamic> json) => SipCredentials(
    serverUrl: json['serverUrl'] as String,
    sipUri: json['sipUri'] as String,
    username: json['username'] as String,
    password: json['password'] as String,
    displayName: json['displayName'] as String,
  );
}
