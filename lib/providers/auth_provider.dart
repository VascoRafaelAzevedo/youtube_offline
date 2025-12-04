import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'service_providers.dart';

/// Auth state
class AuthState {
  final bool isLoading;
  final bool isAuthenticated;
  final GoogleSignInAccount? user;
  final String? error;

  const AuthState({
    this.isLoading = false,
    this.isAuthenticated = false,
    this.user,
    this.error,
  });

  AuthState copyWith({
    bool? isLoading,
    bool? isAuthenticated,
    GoogleSignInAccount? user,
    String? error,
  }) {
    return AuthState(
      isLoading: isLoading ?? this.isLoading,
      isAuthenticated: isAuthenticated ?? this.isAuthenticated,
      user: user ?? this.user,
      error: error,
    );
  }
}

/// Auth state notifier
class AuthNotifier extends StateNotifier<AuthState> {
  final Ref _ref;

  AuthNotifier(this._ref) : super(const AuthState());

  /// Initialize and try silent sign-in
  Future<void> initialize() async {
    state = state.copyWith(isLoading: true);

    try {
      final authService = _ref.read(authServiceProvider);
      final signedIn = await authService.initialize();

      state = AuthState(
        isAuthenticated: signedIn,
        user: authService.currentUser,
      );
    } catch (e) {
      state = AuthState(error: e.toString());
    }
  }

  /// Sign in with Google
  Future<bool> signIn() async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final authService = _ref.read(authServiceProvider);
      final user = await authService.signIn();

      if (user != null) {
        state = AuthState(isAuthenticated: true, user: user);
        return true;
      } else {
        state = const AuthState(error: 'Sign in cancelled');
        return false;
      }
    } catch (e) {
      state = AuthState(error: e.toString());
      return false;
    }
  }

  /// Sign out
  Future<void> signOut() async {
    state = state.copyWith(isLoading: true);

    try {
      final authService = _ref.read(authServiceProvider);
      final youtubeApi = _ref.read(youtubeApiServiceProvider);

      await authService.signOut();
      youtubeApi.clearCache();

      state = const AuthState();
    } catch (e) {
      state = AuthState(error: e.toString());
    }
  }
}

/// Auth provider
final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier(ref);
});
