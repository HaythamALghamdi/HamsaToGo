import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'auth_provider.dart';

final _fs = FirebaseFirestore.instance;

/// Real-time cafe "busy" flag. Staff flip it from the dashboard; customers
/// and staff both listen so the "we're busy, can't take orders" banner and
/// the disabled checkout button react instantly.
///
/// Missing doc → `false` (open). On a stream error the AsyncValue is in its
/// error state; consumers read it as `.valueOrNull ?? false` so a transient
/// read failure never wrongly blocks ordering. autoDispose + a watch on the
/// signed-in user so the listener is rebuilt fresh under the current auth
/// (Firestore rules require a signed-in user).
final cafeBusyProvider = StreamProvider.autoDispose<bool>((ref) {
  final userId = ref.watch(authProvider).user?.id;
  final isAdmin = ref.watch(authProvider).isAdmin;
  if (userId == null && !isAdmin) return Stream.value(false);

  return _fs
      .collection('settings')
      .doc('status')
      .snapshots()
      .map((snap) => (snap.data()?['is_busy'] as bool?) ?? false);
});
