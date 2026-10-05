import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user.dart';
import '../services/api_service.dart';
import '../services/fcm_service.dart';
import '../core/constants.dart';

final apiServiceProvider = Provider<ApiService>((ref) => ApiService());

// ─── Auth State ───────────────────────────────────────────────
class AuthState {
  final UserModel? user;
  final bool isAdmin;
  final bool isLoading;
  final String? error;

  const AuthState({
    this.user,
    this.isAdmin = false,
    this.isLoading = false,
    this.error,
  });

  bool get isAuthenticated => user != null || isAdmin;

  AuthState copyWith({
    UserModel? user,
    bool? isAdmin,
    bool? isLoading,
    String? error,
  }) =>
      AuthState(
        user: user ?? this.user,
        isAdmin: isAdmin ?? this.isAdmin,
        isLoading: isLoading ?? this.isLoading,
        error: error,
      );
}

class AuthNotifier extends StateNotifier<AuthState> {
  final ApiService _api;
  final _storage = const FlutterSecureStorage();

  AuthNotifier(this._api) : super(const AuthState(isLoading: true)) {
    _tryRestoreSession();
  }

  Future<void> _tryRestoreSession() async {
    try {
      final isAdmin = await _storage.read(key: StorageKeys.isAdmin);
      final userId = await _storage.read(key: StorageKeys.userId);

      // Nothing stored → not logged in; don't wait on Firebase at all (so a
      // fresh/logged-out user hits the login screen with no delay).
      if (isAdmin != 'true' && userId == null) {
        state = const AuthState();
        return;
      }

      // We have a stored session. On cold start Firebase restores its saved
      // session from disk asynchronously: currentUser is null until it
      // finishes, and the FIRST authStateChanges event can be a momentary
      // null before the session loads. Wait for the actual restored user (not
      // that first event), so a slow device — e.g. the cafe tablet — isn't
      // wrongly treated as logged out.
      User? fbUser = FirebaseAuth.instance.currentUser;
      if (fbUser == null) {
        try {
          fbUser = await FirebaseAuth.instance
              .authStateChanges()
              .firstWhere((u) => u != null)
              .timeout(const Duration(seconds: 8));
        } catch (_) {
          fbUser = FirebaseAuth.instance.currentUser; // genuinely signed out
        }
      }

      if (isAdmin == 'true' && fbUser != null) {
        state = const AuthState(isAdmin: true);
        // Re-register the device for new-order alerts (tokens rotate).
        FcmService.registerStaffToken(_api);
        return;
      }
      if (userId != null && fbUser != null) {
        final user = await _api.getUser(userId);
        state = AuthState(user: user);
        return;
      }
      // Stored session but Firebase couldn't restore a user: fall through to
      // the logged-out state below WITHOUT wiping storage — a null here is
      // often just a restore that didn't finish, and the next launch can
      // recover. A real sign-out (logout()/deleteAccount()) still clears it.
    } catch (_) {}
    state = const AuthState();
  }

  /// Called after Firebase phone OTP is verified on device.
  /// [idToken] = Firebase ID token.
  /// [fullName] = provided only on the register screen (new users).
  Future<void> completePhoneAuth({
    required String idToken,
    String? fullName,
  }) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      // Send the device's chosen language so order notifications are localized.
      final prefs = await SharedPreferences.getInstance();
      final lang = prefs.getString(StorageKeys.locale) ?? 'en';
      final data = await _api.phoneVerify(
        idToken: idToken,
        fullName: fullName,
        lang: lang,
      );
      final user = UserModel.fromJson(data['user'] as Map<String, dynamic>);
      final token = data['token'] as String?;

      await _storage.write(key: StorageKeys.userId, value: user.id);
      if (token != null) {
        await _storage.write(key: StorageKeys.authToken, value: token);
      }

      state = AuthState(user: user);
      // Register FCM token so push notifications reach this device
      FcmService.registerToken(_api, user.id);
    } catch (e) {
      state = state.copyWith(isLoading: false, error: _parseError(e));
    }
  }

  /// Complete customer sign-in/registration from a backend OTP verification
  /// (Twilio). The backend already created/fetched the user and returned a
  /// Firebase custom token + the user record; we sign in with the custom token
  /// so the rest of the app has a normal Firebase session (same uid as before).
  Future<void> completeOtpAuth({
    required String customToken,
    required Map<String, dynamic> userJson,
  }) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      await FirebaseAuth.instance.signInWithCustomToken(customToken);
      final user = UserModel.fromJson(userJson);
      await _storage.write(key: StorageKeys.userId, value: user.id);
      state = AuthState(user: user);
      FcmService.registerToken(_api, user.id);
    } catch (e) {
      state = state.copyWith(isLoading: false, error: _parseError(e));
    }
  }

  /// Complete staff sign-in from a backend OTP verification (Twilio).
  Future<bool> completeAdminOtpAuth(String customToken) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      await FirebaseAuth.instance.signInWithCustomToken(customToken);
      await _storage.write(key: StorageKeys.isAdmin, value: 'true');
      state = const AuthState(isAdmin: true);
      FcmService.registerStaffToken(_api);
      return true;
    } catch (e) {
      state = state.copyWith(isLoading: false, error: _parseError(e));
      return false;
    }
  }

  /// Staff login via Firebase phone OTP.
  /// [idToken] = Firebase ID token from a verified phone sign-in.
  Future<bool> loginAdminPhone(String idToken) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final valid = await _api.verifyAdminPhone(idToken);
      if (valid) {
        await _storage.write(key: StorageKeys.isAdmin, value: 'true');
        state = const AuthState(isAdmin: true);
        // Register this device for new-order push alerts.
        FcmService.registerStaffToken(_api);
        return true;
      } else {
        state = state.copyWith(isLoading: false, error: 'Not authorized');
        return false;
      }
    } catch (e) {
      state = state.copyWith(isLoading: false, error: _parseError(e));
      return false;
    }
  }

  /// Persist the customer's language choice so order notifications match it.
  /// Best-effort — a failure here shouldn't disrupt the UI language switch.
  Future<void> updateLanguage(String lang) async {
    final user = state.user;
    if (user == null) return;
    try {
      await _api.updateLanguage(user.id, lang);
      state = state.copyWith(user: UserModel(
        id: user.id,
        phone: user.phone,
        fullName: user.fullName,
        fcmToken: user.fcmToken,
        lang: lang,
        createdAt: user.createdAt,
      ));
    } catch (_) {}
  }

  Future<void> logout() async {
    // Clear the Firebase session too — otherwise it leaks into the next login
    // (e.g. switching between a customer and staff on the same device), and
    // Firestore security rules would run against the wrong user's token.
    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {}
    await _storage.deleteAll();
    state = const AuthState();
  }

  /// Permanently delete the signed-in customer's account, then sign out.
  /// [idToken] = a freshly-minted Firebase ID token proving ownership.
  /// Returns true on success; on failure leaves the session intact and
  /// surfaces the error via state.error.
  Future<bool> deleteAccount(String idToken) async {
    final user = state.user;
    if (user == null) return false;
    state = state.copyWith(isLoading: true, error: null);
    try {
      await _api.deleteAccount(user.id, idToken);
      await _storage.deleteAll();
      state = const AuthState();
      return true;
    } catch (e) {
      state = state.copyWith(isLoading: false, error: _parseError(e));
      return false;
    }
  }

  String _parseError(dynamic e) {
    if (e is DioException) {
      final detail = e.response?.data?['detail'];
      if (detail != null) return detail.toString();
    }
    final msg = e.toString();
    if (msg.contains('NO_ACCOUNT')) return 'NO_ACCOUNT';
    return msg.replaceAll('Exception: ', '');
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>(
  (ref) => AuthNotifier(ref.watch(apiServiceProvider)),
);
