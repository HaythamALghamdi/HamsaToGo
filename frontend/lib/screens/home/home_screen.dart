import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme.dart';
import '../../core/router.dart';
import '../../providers/auth_provider.dart';
import '../../providers/cart_provider.dart';
import '../../providers/locale_provider.dart';
import '../../providers/menu_provider.dart';
import '../../providers/settings_provider.dart';
import '../../models/menu_item.dart';
import '../../widgets/menu_item_card.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _scrollController = ScrollController();
  bool _collapsed = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(() {
      final collapsed = _scrollController.offset > 60;
      if (collapsed != _collapsed) {
        setState(() => _collapsed = collapsed);
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  // ── Account bottom sheet (sign out + delete account) ─────────
  Future<void> _showAccountSheet(bool isAr) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: HamsaColors.bgSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetCtx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Grabber
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 20),
                    decoration: BoxDecoration(
                      color: HamsaColors.borderStrong,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Text(
                  isAr ? 'الحساب' : 'Account',
                  style: HamsaText.heading(size: 20),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                _AccountSheetTile(
                  icon: Icons.description_outlined,
                  label: isAr ? 'السياسات والشروط' : 'Policies & Terms',
                  color: HamsaColors.cream,
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    context.push(AppRoutes.legal);
                  },
                ),
                const SizedBox(height: 12),
                _AccountSheetTile(
                  icon: Icons.logout_rounded,
                  label: isAr ? 'تسجيل الخروج' : 'Sign out',
                  color: HamsaColors.cream,
                  onTap: () async {
                    Navigator.of(sheetCtx).pop();
                    await ref.read(authProvider.notifier).logout();
                  },
                ),
                const SizedBox(height: 12),
                _AccountSheetTile(
                  icon: Icons.delete_outline_rounded,
                  label: isAr ? 'حذف الحساب' : 'Delete account',
                  color: HamsaColors.error,
                  onTap: () async {
                    Navigator.of(sheetCtx).pop();
                    await _confirmDeleteAccount(isAr);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _confirmDeleteAccount(bool isAr) async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) {
        return AlertDialog(
          backgroundColor: HamsaColors.bgSurface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Text(
            isAr ? 'حذف الحساب؟' : 'Delete account?',
            style: HamsaText.heading(size: 20),
            textAlign: isAr ? TextAlign.right : TextAlign.left,
          ),
          content: Text(
            isAr
                ? 'سيتم حذف حسابك وبياناتك نهائياً. لا يمكن التراجع عن هذا الإجراء.'
                : 'Your account and personal data will be permanently '
                    'deleted. This action cannot be undone.',
            style: HamsaText.body(size: 14, color: HamsaColors.muted),
            textAlign: isAr ? TextAlign.right : TextAlign.left,
          ),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(false),
              child: Text(
                isAr ? 'إلغاء' : 'Cancel',
                style: HamsaText.body(size: 14, color: HamsaColors.cream),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(true),
              child: Text(
                isAr ? 'حذف' : 'Delete',
                style: HamsaText.body(
                  size: 14,
                  weight: FontWeight.w700,
                  color: HamsaColors.error,
                ),
              ),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    // Mint a fresh Firebase ID token to prove ownership. The stored token
    // may be expired, so we force-refresh from the device's Firebase session.
    String? idToken;
    final fbUser = FirebaseAuth.instance.currentUser;
    if (fbUser != null) {
      try {
        idToken = await fbUser.getIdToken(true);
      } catch (_) {
        idToken = null;
      }
    }

    if (!mounted) return;
    if (idToken == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: HamsaColors.bgElevated,
          content: Text(
            isAr
                ? 'انتهت الجلسة. الرجاء تسجيل الدخول مرة أخرى قبل حذف الحساب.'
                : 'Your session expired. Please sign in again before '
                    'deleting your account.',
            style: HamsaText.body(size: 14, color: HamsaColors.cream),
          ),
        ),
      );
      return;
    }

    final ok = await ref.read(authProvider.notifier).deleteAccount(idToken);
    if (ok) {
      // Clear the device's Firebase session too (the server account is gone).
      try {
        await FirebaseAuth.instance.signOut();
      } catch (_) {}
      return; // auth state cleared → router redirects to login
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: HamsaColors.bgElevated,
        content: Text(
          isAr
              ? 'تعذر حذف الحساب. حاول مرة أخرى.'
              : 'Could not delete account. Please try again.',
          style: HamsaText.body(size: 14, color: HamsaColors.cream),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final locale = ref.watch(localeProvider).languageCode;
    final isAr = locale == 'ar';
    final selectedCat = ref.watch(selectedCategoryProvider);
    final categoriesAsync = ref.watch(categoriesProvider);
    final itemsAsync = ref.watch(menuItemsProvider(selectedCat));
    final cartCount = ref.watch(cartCountProvider);
    final busy = ref.watch(cafeBusyProvider).valueOrNull ?? false;

    return Scaffold(
      backgroundColor: HamsaColors.bgDeep,
      body: Stack(
        children: [
          CustomScrollView(
            controller: _scrollController,
            slivers: [
              // ── Header ──────────────────────────────────────
              SliverPersistentHeader(
                pinned: true,
                delegate: _HomeHeaderDelegate(
                  collapsed: _collapsed,
                  userName: auth.user?.fullName ?? '',
                  isAr: isAr,
                  topPadding: MediaQuery.of(context).padding.top,
                  onOrdersTap: () => context.push(AppRoutes.myOrders),
                  onToggleLocale: () {
                    final next = isAr ? 'en' : 'ar';
                    ref.read(localeProvider.notifier).setLocale(next);
                    ref.read(authProvider.notifier).updateLanguage(next);
                  },
                  onAccountTap: () => _showAccountSheet(isAr),
                ),
              ),

              // ── Busy banner ──────────────────────────────────
              if (busy)
                SliverToBoxAdapter(
                  child: _HomeBusyBanner(isAr: isAr),
                ),

              // ── Category Chips ───────────────────────────────
              SliverToBoxAdapter(
                child: categoriesAsync.when(
                  data: (cats) => _CategoryRow(
                    categories: cats,
                    selected: selectedCat,
                    locale: locale,
                    onSelect: (id) => ref
                        .read(selectedCategoryProvider.notifier)
                        .state = id,
                  ),
                  loading: () => const SizedBox(height: 60),
                  error: (_, __) => const SizedBox(height: 60),
                ),
              ),

              const SliverToBoxAdapter(child: SizedBox(height: 8)),

              // ── Menu Items ───────────────────────────────────
              itemsAsync.when(
                data: (items) => SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 120),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (ctx, i) => MenuItemCard(
                        item: items[i],
                        locale: locale,
                        index: i,
                      ).animate(delay: Duration(milliseconds: i * 60))
                          .fadeIn(duration: 400.ms)
                          .slideY(begin: 0.25, end: 0),
                      childCount: items.length,
                    ),
                  ),
                ),
                loading: () => SliverToBoxAdapter(
                  child: Column(
                    children: List.generate(
                      4,
                      (i) => _SkeletonCard()
                          .animate(delay: Duration(milliseconds: i * 80))
                          .shimmer(duration: 1200.ms),
                    ),
                  ),
                ),
                error: (e, _) => SliverToBoxAdapter(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(40),
                      child: Text(
                        isAr
                            ? 'تعذر تحميل القائمة'
                            : 'Failed to load menu',
                        style: HamsaText.body(color: HamsaColors.muted),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),

          // ── Floating Cart Button ─────────────────────────────
          if (cartCount > 0)
            Positioned(
              bottom: 32,
              left: 28,
              right: 28,
              child: _CartFAB(count: cartCount, isAr: isAr),
            ),
        ],
      ),
    );
  }
}

// ─── Home Busy Banner ────────────────────────────────────────
// Shown at the top of the menu when staff have paused ordering, so
// customers know before building a cart. Checkout is also disabled.
class _HomeBusyBanner extends StatelessWidget {
  final bool isAr;
  const _HomeBusyBanner({required this.isAr});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: HamsaColors.error.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: HamsaColors.error.withValues(alpha: 0.35)),
      ),
      child: Row(
        textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.pause_circle_filled_rounded,
              color: HamsaColors.error, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              isAr
                  ? 'المقهى مشغول حالياً، لا يمكن استقبال الطلبات في الوقت الحالي. نعتذر، حاول لاحقاً 🙏'
                  : 'The cafe is busy right now and can\'t take new orders. Sorry — please try again later 🙏',
              style: HamsaText.body(size: 13, color: HamsaColors.cream),
              textAlign: isAr ? TextAlign.right : TextAlign.left,
              textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 300.ms);
  }
}

// ─── Header Delegate ─────────────────────────────────────────
class _HomeHeaderDelegate extends SliverPersistentHeaderDelegate {
  final bool collapsed;
  final String userName;
  final bool isAr;
  final VoidCallback onOrdersTap;
  final VoidCallback onToggleLocale;
  final VoidCallback onAccountTap;

  /// Status-bar height. The SafeArea inside the header consumes this from
  /// the sliver's extent, so it must be added on top of the design heights —
  /// otherwise the content area shrinks per-device and overflows by a few
  /// pixels on phones with tall status bars.
  final double topPadding;

  const _HomeHeaderDelegate({
    required this.collapsed,
    required this.userName,
    required this.isAr,
    required this.onOrdersTap,
    required this.onToggleLocale,
    required this.onAccountTap,
    required this.topPadding,
  });

  @override
  double get minExtent => 80 + topPadding;
  @override
  double get maxExtent => 180 + topPadding;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    final progress = (shrinkOffset / (maxExtent - minExtent)).clamp(0.0, 1.0);

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            HamsaColors.bgDeep,
            HamsaColors.bgDeep.withValues(alpha: progress > 0.5 ? 1 : 0),
          ],
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment:
                isAr ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // In Arabic: buttons on left, greeting on right
                  // In English: greeting on left, buttons on right
                  if (!isAr) ...[
                    // Greeting (left in EN)
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (progress < 0.5) ...[
                            Text(
                              'Hello,',
                              style: HamsaText.body(size: 13, color: HamsaColors.muted),
                            ),
                            Text(
                              userName.isNotEmpty ? userName.split(' ').first : 'Guest',
                              style: HamsaText.heading(size: 24, color: HamsaColors.cream),
                            ),
                          ] else
                            Text('Hamsa Coffee',
                                style: HamsaText.heading(size: 18, color: HamsaColors.cream)),
                        ],
                      ),
                    ),
                    // Buttons (right in EN)
                    _ActionButtons(isAr: isAr, onToggleLocale: onToggleLocale, onOrdersTap: onOrdersTap, onAccountTap: onAccountTap),
                  ] else ...[
                    // Buttons (left in AR)
                    _ActionButtons(isAr: isAr, onToggleLocale: onToggleLocale, onOrdersTap: onOrdersTap, onAccountTap: onAccountTap),
                    // Greeting (right in AR)
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          if (progress < 0.5) ...[
                            Text(
                              'مرحباً،',
                              style: HamsaText.arabic(size: 13, color: HamsaColors.muted),
                              textDirection: TextDirection.rtl,
                            ),
                            Text(
                              userName.isNotEmpty ? userName.split(' ').first : 'ضيف',
                              style: HamsaText.heading(size: 24, color: HamsaColors.cream),
                              textDirection: TextDirection.rtl,
                            ),
                          ] else
                            Text('Hamsa Coffee',
                                style: HamsaText.heading(size: 18, color: HamsaColors.cream),
                                textDirection: TextDirection.rtl),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_HomeHeaderDelegate old) =>
      old.collapsed != collapsed ||
      old.userName != userName ||
      old.isAr != isAr ||
      old.topPadding != topPadding;
}

// ─── Action Buttons (language + orders + signout) ────────────
class _ActionButtons extends StatelessWidget {
  final bool isAr;
  final VoidCallback onToggleLocale;
  final VoidCallback onOrdersTap;
  final VoidCallback onAccountTap;

  const _ActionButtons({
    required this.isAr,
    required this.onToggleLocale,
    required this.onOrdersTap,
    required this.onAccountTap,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _HeaderIconBtn(
          onTap: onToggleLocale,
          child: Text(
            isAr ? 'EN' : 'ع',
            style: HamsaText.body(size: 13, weight: FontWeight.w700, color: HamsaColors.gold),
          ),
        ),
        const SizedBox(width: 8),
        _HeaderIconBtn(
          onTap: onOrdersTap,
          child: const Icon(Icons.receipt_long_outlined, color: HamsaColors.cream, size: 20),
        ),
        const SizedBox(width: 8),
        _HeaderIconBtn(
          onTap: onAccountTap,
          child: const Icon(Icons.person_outline_rounded, color: HamsaColors.cream, size: 20),
        ),
      ],
    );
  }
}

// ─── Account Sheet Tile ──────────────────────────────────────
class _AccountSheetTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _AccountSheetTile({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        decoration: BoxDecoration(
          color: HamsaColors.bgCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: HamsaColors.border),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(width: 14),
            Text(
              label,
              style: HamsaText.body(size: 15, weight: FontWeight.w600, color: color),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Header Icon Button ──────────────────────────────────────
class _HeaderIconBtn extends StatelessWidget {
  final VoidCallback onTap;
  final Widget child;

  const _HeaderIconBtn({required this.onTap, required this.child});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: HamsaColors.bgCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: HamsaColors.border),
        ),
        child: Center(child: child),
      ),
    );
  }
}

// ─── Category Row ────────────────────────────────────────────
class _CategoryRow extends StatelessWidget {
  final List<Category> categories;
  final String? selected;
  final String locale;
  final void Function(String?) onSelect;

  const _CategoryRow({
    required this.categories,
    required this.selected,
    required this.locale,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        scrollDirection: Axis.horizontal,
        children: [
          // "All" chip
          _CategoryChip(
            label: locale == 'ar' ? 'الكل' : 'All',
            isSelected: selected == null,
            onTap: () => onSelect(null),
          ),
          ...categories.map(
            (cat) => _CategoryChip(
              label: cat.name(locale),
              icon: cat.icon,
              isSelected: selected == cat.id,
              onTap: () => onSelect(cat.id),
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  final String label;
  final String? icon;
  final bool isSelected;
  final VoidCallback onTap;

  const _CategoryChip({
    required this.label,
    this.icon,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            color: isSelected
                ? HamsaColors.greenAccent
                : HamsaColors.bgElevated,
            borderRadius: BorderRadius.circular(100),
            border: Border.all(
              color: isSelected
                  ? Colors.transparent
                  : HamsaColors.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Text(icon!, style: const TextStyle(fontSize: 14)),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: HamsaText.body(
                  size: 15,
                  weight: FontWeight.w500,
                  color: isSelected
                      ? HamsaColors.bgDeep
                      : HamsaColors.offWhite,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Floating Cart ───────────────────────────────────────────
class _CartFAB extends ConsumerWidget {
  final int count;
  final bool isAr;

  const _CartFAB({required this.count, required this.isAr});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final total = ref.watch(cartTotalProvider);

    return GestureDetector(
      onTap: () => context.push(AppRoutes.cart),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        decoration: BoxDecoration(
          color: HamsaColors.greenAccent,
          borderRadius: BorderRadius.circular(100),
          boxShadow: [
            BoxShadow(
              color: HamsaColors.greenAccent.withValues(alpha: 0.4),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: HamsaColors.bgDeep.withValues(alpha: 0.25),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  '$count',
                  style: HamsaText.body(
                    size: 12,
                    weight: FontWeight.w700,
                    color: HamsaColors.bgDeep,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                isAr ? 'عرض السلة' : 'View Cart',
                style: HamsaText.body(
                  size: 14,
                  weight: FontWeight.w600,
                  color: HamsaColors.bgDeep,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            Text(
              'SAR ${total.toStringAsFixed(2)}',
              style: HamsaText.body(
                size: 14,
                weight: FontWeight.w700,
                color: HamsaColors.bgDeep,
              ),
            ),
          ],
        ),
      ),
    )
        .animate()
        .slideY(begin: 1.5, end: 0, duration: 400.ms, curve: Curves.easeOutCubic)
        .fadeIn(duration: 300.ms);
  }
}

// ─── Skeleton Card ───────────────────────────────────────────
class _SkeletonCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Container(
        height: 100,
        decoration: BoxDecoration(
          color: HamsaColors.bgCard,
          borderRadius: BorderRadius.circular(20),
        ),
      ),
    );
  }
}
