import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:googleapis_auth/googleapis_auth.dart' as auth;

/// Service for handling Google OAuth authentication
class AuthService {
  static const List<String> _scopes = [
    'https://www.googleapis.com/auth/youtube.readonly',
  ];

  final GoogleSignIn _googleSignIn = GoogleSignIn(scopes: _scopes);

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  GoogleSignInAccount? _currentUser;

  /// Get current signed-in user
  GoogleSignInAccount? get currentUser => _currentUser;

  /// Check if user is signed in
  bool get isSignedIn => _currentUser != null;

  /// Initialize auth service and try silent sign-in
  Future<bool> initialize() async {
    try {
      // Try to sign in silently (if user was previously signed in)
      _currentUser = await _googleSignIn.signInSilently();
      return isSignedIn;
    } catch (e) {
      print('AuthService: Silent sign-in failed: $e');
      return false;
    }
  }

  /// Sign in with Google
  Future<GoogleSignInAccount?> signIn() async {
    try {
      _currentUser = await _googleSignIn.signIn();

      if (_currentUser != null) {
        // Store user email for reference
        await _secureStorage.write(
          key: 'user_email',
          value: _currentUser!.email,
        );
      }

      return _currentUser;
    } catch (e) {
      print('AuthService: Sign-in failed: $e');
      rethrow;
    }
  }

  /// Sign out
  Future<void> signOut() async {
    try {
      await _googleSignIn.signOut();
      await _secureStorage.delete(key: 'user_email');
      _currentUser = null;
    } catch (e) {
      print('AuthService: Sign-out failed: $e');
      rethrow;
    }
  }

  /// Get authenticated HTTP client for API calls
  Future<auth.AuthClient?> getAuthClient() async {
    if (_currentUser == null) {
      // Try silent sign-in first
      await initialize();
      if (_currentUser == null) return null;
    }

    try {
      // This automatically handles token refresh
      final httpClient = await _googleSignIn.authenticatedClient();
      return httpClient;
    } catch (e) {
      print('AuthService: Failed to get auth client: $e');
      return null;
    }
  }

  /// Get current access token (for debugging)
  Future<String?> getAccessToken() async {
    final auth = await _currentUser?.authentication;
    return auth?.accessToken;
  }

  /// Listen to auth state changes
  Stream<GoogleSignInAccount?> get onAuthStateChanged {
    return _googleSignIn.onCurrentUserChanged;
  }
}
