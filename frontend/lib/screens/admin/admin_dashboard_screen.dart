import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme.dart';
import '../../core/router.dart';
import '../../models/order.dart';
import '../../providers/auth_provider.dart';
import '../../providers/locale_provider.dart';
import '../../providers/order_provider.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/lang_toggle_button.dart';

class AdminDashboardScreen extends ConsumerStatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  ConsumerState<AdminDashboardScreen> createState() =>
      _AdminDashboardScreenState();
}

class _AdminDashboardScreenState
    extends ConsumerState<AdminDashboardScreen> {

  @override
  Widget build(BuildContext context) {
    final ordersAsync = ref.watch(activeOrdersProvider);
    final isAr = ref.watch(localeProvider).languageCode == 'ar';

    return Scaffold(
      backgroundColor: HamsaColors.bgDeep,
      body: CustomScrollView(
        slivers: [
          // Header
          SliverToBoxAdapter(
            child: SafeArea(
              child: Padding(
                padding:
                    const EdgeInsets.fromLTRB(24, 20, 24, 0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // Expanded so the title never collides with the nav
                    // icons on narrow screens (long Arabic titles overflow
                    // otherwise).
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              isAr ? 'لوحة التحكم' : 'Dashboard',
                              maxLines: 1,
                              style: HamsaText.display(
                                  size: 32, color: HamsaColors.cream),
                            ),
                          ),
                          Text(
                            isAr
                                ? 'قائمة الطلبات المباشرة'
                                : 'Live order queue',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: HamsaText.body(
                                size: 13, color: HamsaColors.muted),
                          ),
                        ],
                      ).animate().fadeIn(duration: 400.ms),
                    ),
                    const SizedBox(width: 12),

                    // Nav icons
                    Row(
                      children: [
                        const LangToggleButton(),
                        const SizedBox(width: 8),
                        _NavIcon(
                          icon: Icons.menu_book_outlined,
                          label: 'Menu',
                          onTap: () => context.push(AppRoutes.menuManager),
                        ),
                        const SizedBox(width: 8),
                        _NavIcon(
                          icon: Icons.history_rounded,
                          label: 'History',
                          onTap: () => context.push(AppRoutes.history),
                        ),
                        const SizedBox(width: 8),
                        _NavIcon(
                          icon: Icons.assessment_outlined,
                          label: 'Reports',
                          onTap: () => context.push(AppRoutes.reports),
                        ),
                        const SizedBox(width: 8),
                        _NavIcon(
                          icon: Icons.logout_rounded,
                          label: 'Logout',
                          onTap: () => ref
                              .read(authProvider.notifier)
                              .logout(),
                        ),
                      ],
                    ).animate(delay: 100.ms).fadeIn(duration: 400.ms),
                  ],
                ),
              ),
            ),
          ),

          // Busy toggle — pause / resume customer ordering
          SliverToBoxAdapter(
            child: const _BusyToggleCard()
                .animate(delay: 150.ms)
                .fadeIn(duration: 400.ms),
          ),

          // Stats row
          SliverToBoxAdapter(
            child: ordersAsync.when(
              data: (orders) => _StatsRow(orders: orders, isAr: isAr)
                  .animate(delay: 200.ms)
                  .fadeIn(duration: 400.ms),
              loading: () => const SizedBox(height: 80),
              error: (_, __) => const SizedBox(height: 80),
            ),
          ),

          // Section title
          SliverToBoxAdapter(
            child: Padding(
              padding:
                  const EdgeInsets.fromLTRB(24, 8, 24, 12),
              child: Text(
                isAr ? 'الطلبات النشطة' : 'ACTIVE ORDERS',
                style: HamsaText.caption(
                    size: 11, color: HamsaColors.muted),
              ),
            ),
          ),

          // Orders list
          ordersAsync.when(
            data: (orders) {
              if (orders.isEmpty) {
                return SliverToBoxAdapter(
                  child: _EmptyQueue(isAr: isAr)
                      .animate(delay: 300.ms)
                      .fadeIn(duration: 400.ms),
                );
              }

              return SliverPadding(
                padding:
                    const EdgeInsets.fromLTRB(20, 0, 20, 80),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (_, i) => AdminOrderCard(
                      order: orders[i],
                      index: i,
                    )
                        .animate(
                          delay: Duration(
                              milliseconds: 300 + i * 70),
                        )
                        .fadeIn(duration: 350.ms)
                        .slideY(begin: 0.15, end: 0),
                    childCount: orders.length,
                  ),
                ),
              );
            },
            loading: () => SliverToBoxAdapter(
              child: Column(
                children: List.generate(
                  3,
                  (i) => Container(
                    margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    height: 90,
                    decoration: BoxDecoration(
                      color: HamsaColors.bgCard,
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ).animate(delay: Duration(milliseconds: i * 80))
                      .shimmer(duration: 1200.ms),
                ),
              ),
            ),
            error: (e, _) => SliverToBoxAdapter(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    isAr ? 'تعذّر تحميل الطلبات' : 'Failed to load orders',
                    style: HamsaText.body(color: HamsaColors.muted),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),

    );
  }
}

// ─── Busy Toggle Card ────────────────────────────────────────
// Staff pause / resume customer ordering. The switch reflects the live
// Firestore `settings/status` flag; toggling it asks for confirmation, then
// writes through the backend (which also refunds any order caught mid-pay).
class _BusyToggleCard extends ConsumerStatefulWidget {
  const _BusyToggleCard();

  @override
  ConsumerState<_BusyToggleCard> createState() => _BusyToggleCardState();
}

class _BusyToggleCardState extends ConsumerState<_BusyToggleCard> {
  bool _saving = false;

  Future<void> _toggle(bool current, bool isAr) async {
    final turningOn = !current;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: HamsaColors.bgCard,
        title: Text(
          turningOn
              ? (isAr ? 'إيقاف استقبال الطلبات؟' : 'Pause ordering?')
              : (isAr ? 'استئناف استقبال الطلبات؟' : 'Resume ordering?'),
          style: HamsaText.heading(size: 16, color: HamsaColors.cream),
          textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
        ),
        content: Text(
          turningOn
              ? (isAr
                  ? 'لن يتمكن العملاء من إرسال طلبات جديدة حتى تعيد التفعيل.'
                  : 'Customers won\'t be able to place new orders until you resume.')
              : (isAr
                  ? 'سيتمكن العملاء من إرسال الطلبات مرة أخرى.'
                  : 'Customers will be able to place orders again.'),
          style: HamsaText.body(size: 13, color: HamsaColors.creamMuted),
          textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: Text(isAr ? 'إلغاء' : 'Cancel',
                style: HamsaText.body(size: 13, color: HamsaColors.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: Text(
              turningOn
                  ? (isAr ? 'إيقاف' : 'Pause')
                  : (isAr ? 'استئناف' : 'Resume'),
              style: HamsaText.body(
                size: 13,
                weight: FontWeight.w700,
                color: turningOn ? HamsaColors.error : HamsaColors.greenAccent,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _saving = true);
    try {
      await ref.read(apiServiceProvider).setCafeBusy(turningOn);
      // The Firestore stream drives the UI — nothing else to do on success.
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(isAr
                ? 'تعذّر تحديث الحالة. حاول مرة أخرى.'
                : 'Could not update status. Please try again.'),
            backgroundColor: HamsaColors.error.withValues(alpha: 0.9),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAr = ref.watch(localeProvider).languageCode == 'ar';
    final busy = ref.watch(cafeBusyProvider).valueOrNull ?? false;
    final color =
        busy ? HamsaColors.error : HamsaColors.greenAccent;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
          children: [
            Icon(
              busy ? Icons.pause_circle_filled_rounded : Icons.storefront_rounded,
              color: color,
              size: 26,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment:
                    isAr ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                children: [
                  Text(
                    busy
                        ? (isAr ? 'المقهى مشغول' : 'Cafe is busy')
                        : (isAr ? 'المقهى مفتوح' : 'Cafe is open'),
                    style: HamsaText.body(
                      size: 15,
                      weight: FontWeight.w700,
                      color: HamsaColors.cream,
                    ),
                    textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    busy
                        ? (isAr ? 'الطلبات متوقفة مؤقتاً' : 'Ordering paused')
                        : (isAr ? 'استقبال الطلبات فعّال' : 'Accepting orders'),
                    style: HamsaText.body(size: 11, color: HamsaColors.muted),
                    textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
                  ),
                ],
              ),
            ),
            if (_saving)
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: HamsaColors.creamMuted,
                ),
              )
            else
              Switch(
                value: busy,
                onChanged: (_) => _toggle(busy, isAr),
                activeThumbColor: HamsaColors.cream,
                activeTrackColor: HamsaColors.error,
                inactiveThumbColor: HamsaColors.cream,
                inactiveTrackColor: HamsaColors.greenAccent.withValues(alpha: 0.5),
              ),
          ],
        ),
      ),
    );
  }
}

// ─── Stats Row ───────────────────────────────────────────────
class _StatsRow extends StatelessWidget {
  final List<Order> orders;
  final bool isAr;
  const _StatsRow({required this.orders, required this.isAr});

  @override
  Widget build(BuildContext context) {
    final received =
        orders.where((o) => o.status == OrderStatus.received).length;
    final inProgress =
        orders.where((o) => o.status == OrderStatus.inProgress).length;
    final ready =
        orders.where((o) => o.status == OrderStatus.ready).length;
    final total = orders.length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
      child: Row(
        children: [
          Expanded(
            child: _StatChip(
              label: isAr ? 'جديد' : 'New',
              value: '$received',
              color: HamsaColors.statusReceived,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _StatChip(
              label: isAr ? 'يُحضَّر' : 'Preparing',
              value: '$inProgress',
              color: HamsaColors.statusInProgress,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _StatChip(
              label: isAr ? 'جاهز' : 'Ready',
              value: '$ready',
              color: HamsaColors.statusReady,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _StatChip(
              label: isAr ? 'الكل' : 'Queue',
              value: '$total',
              color: HamsaColors.greenAccent,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _StatChip({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: HamsaText.display(size: 28, color: color),
          ),
          const SizedBox(height: 2),
          // FittedBox: labels like "Preparing" can exceed a quarter-width
          // chip on narrow phones — scale down instead of overflowing.
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              maxLines: 1,
              style: HamsaText.body(
                  size: 11, color: color.withValues(alpha: 0.7)),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Admin Order Card ────────────────────────────────────────
class AdminOrderCard extends ConsumerWidget {
  final Order order;
  final int index;

  const AdminOrderCard({
    super.key,
    required this.order,
    required this.index,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAr = ref.watch(localeProvider).languageCode == 'ar';
    final status = order.status;

    final statusColor = switch (status) {
      OrderStatus.received => HamsaColors.statusReceived,
      OrderStatus.inProgress => HamsaColors.statusInProgress,
      OrderStatus.ready => HamsaColors.statusReady,
      OrderStatus.pickedUp => HamsaColors.statusPickedUp,
      OrderStatus.cancelled => HamsaColors.error,
    };

    final nextStatus = status.next;

    return GestureDetector(
      onTap: () => context.push('/admin/orders/${order.id}'),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: HamsaColors.bgCard,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: HamsaColors.border),
        ),
        child: Row(
          children: [
            // Left color bar
            Container(
              width: 5,
              height: 90,
              decoration: BoxDecoration(
                color: statusColor,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(18),
                  bottomLeft: Radius.circular(18),
                ),
              ),
            ),

            // Content
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Order info
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '#${order.displayNumber}',
                            style: HamsaText.body(
                              size: 13,
                              weight: FontWeight.w700,
                              color: HamsaColors.cream,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            order.items.map((i) => '${i.quantity}× ${i.nameEn}').join(', '),
                            style: HamsaText.body(
                                size: 11, color: HamsaColors.muted),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: statusColor.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(100),
                            ),
                            child: Text(
                              status.label(isAr),
                              style: HamsaText.body(
                                size: 10,
                                color: statusColor,
                                weight: FontWeight.w600,
                              ),
                              textDirection: isAr
                                  ? TextDirection.rtl
                                  : TextDirection.ltr,
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Quick action button
                    if (nextStatus != null)
                      GestureDetector(
                        onTap: () => _updateStatus(context, ref, nextStatus),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: statusColor.withValues(alpha: 0.4)),
                          ),
                          child: Text(
                            _nextLabel(nextStatus, isAr),
                            style: HamsaText.body(
                              size: 11,
                              weight: FontWeight.w700,
                              color: statusColor,
                            ),
                            textDirection: isAr
                                ? TextDirection.rtl
                                : TextDirection.ltr,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),

            // Arrow
            const Padding(
              padding: EdgeInsets.only(right: 14),
              child: Icon(
                Icons.arrow_forward_ios_rounded,
                size: 13,
                color: HamsaColors.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _updateStatus(
      BuildContext context, WidgetRef ref, OrderStatus next) async {
    final api = ref.read(apiServiceProvider);
    try {
      await api.updateOrderStatus(order.id, next);
      // Stream auto-updates — no manual refresh needed
    } catch (e) {
      if (context.mounted) {
        final isAr = ref.read(localeProvider).languageCode == 'ar';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(isAr
                ? 'تعذّر تحديث حالة الطلب. حاول مرة أخرى.'
                : 'Could not update the order status. Please try again.'),
            backgroundColor: HamsaColors.error.withValues(alpha: 0.9),
          ),
        );
      }
    }
  }

  // Action labels — worded as the action that moves the order to `next`,
  // so they can't be mistaken for the order's current status.
  String _nextLabel(OrderStatus next, bool isAr) => switch (next) {
        OrderStatus.received => isAr ? 'تقديم' : 'Place',
        OrderStatus.inProgress => isAr ? 'بدء التحضير' : 'Start Preparing',
        OrderStatus.ready => isAr ? 'تأكيد الجاهزية' : 'Mark Ready',
        OrderStatus.pickedUp => isAr ? 'تأكيد الاستلام' : 'Mark Picked Up',
        OrderStatus.cancelled => '', // unreachable — cancelled has no "next"
      };
}

// ─── Empty Queue ─────────────────────────────────────────────
class _EmptyQueue extends StatelessWidget {
  final bool isAr;
  const _EmptyQueue({required this.isAr});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(60),
        child: Column(
          children: [
            const Text('☕', style: TextStyle(fontSize: 56)),
            const SizedBox(height: 16),
            Text(
              isAr ? 'القائمة فارغة' : 'Queue is empty',
              style: HamsaText.heading(
                  size: 20, color: HamsaColors.cream),
            ),
            const SizedBox(height: 8),
            Text(
              isAr ? 'ستظهر الطلبات الجديدة هنا' : 'New orders will appear here',
              style:
                  HamsaText.body(size: 13, color: HamsaColors.muted),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Nav Icon ────────────────────────────────────────────────
class _NavIcon extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _NavIcon({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: HamsaColors.bgCard,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: HamsaColors.border),
        ),
        child: Icon(icon, color: HamsaColors.cream, size: 18),
      ),
    );
  }
}
