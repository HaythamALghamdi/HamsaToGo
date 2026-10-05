import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme.dart';
import '../../core/router.dart';
import '../../providers/auth_provider.dart';
import '../../providers/locale_provider.dart';
import '../../widgets/hamsa_button.dart';
import '../../widgets/hamsa_logo.dart';
import '../../widgets/lang_toggle_button.dart';

class AdminLoginScreen extends ConsumerStatefulWidget {
  const AdminLoginScreen({super.key});

  @override
  ConsumerState<AdminLoginScreen> createState() => _AdminLoginScreenState();
}

class _AdminLoginScreenState extends ConsumerState<AdminLoginScreen> {
  final _phoneCtrl = TextEditingController();
  final _otpCtrl = TextEditingController();

  bool _step2 = false; // true = showing OTP field
  bool _sending = false; // waiting for SMS
  bool _verifying = false; // waiting for backend

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _otpCtrl.dispose();
    super.dispose();
  }

  String get _fullPhone {
    final raw = _phoneCtrl.text.trim();
    if (raw.startsWith('+')) return raw;
    final digits = raw.startsWith('0') ? raw.substring(1) : raw;
    return '+966$digits';
  }

  bool get _isAr => ref.read(localeProvider).languageCode == 'ar';

  // ── Send OTP (backend + Twilio Verify) ───────────────────────
  Future<void> _sendCode() async {
    final phone = _fullPhone;
    if (phone.length < 10) {
      _showError(_isAr ? 'أدخل رقم جوال صحيح' : 'Please enter a valid phone number');
      return;
    }
    setState(() => _sending = true);
    try {
      await ref.read(apiServiceProvider).sendOtp(phone);
      if (!mounted) return;
      setState(() {
        _sending = false;
        _step2 = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      _showError(_otpSendError(e));
    }
  }

  // ── Verify OTP ───────────────────────────────────────────────
  Future<void> _verifyCode() async {
    final code = _otpCtrl.text.trim();
    if (code.length != 6) {
      _showError(_isAr ? 'أدخل الرمز المكوّن من 6 أرقام' : 'Enter the 6-digit code');
      return;
    }
    setState(() => _verifying = true);
    try {
      final data = await ref
          .read(apiServiceProvider)
          .adminVerifyOtp(phone: _fullPhone, code: code);
      final ok = await ref
          .read(authProvider.notifier)
          .completeAdminOtpAuth(data['custom_token'] as String);
      if (!mounted) return;
      if (!ok) {
        setState(() => _verifying = false);
        _showError(_isAr
            ? 'تعذّر التحقق. حاول مجدداً.'
            : 'Could not verify staff access. Please try again.');
      }
      // On success the router redirects to the admin dashboard automatically.
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() => _verifying = false);
      final status = e.response?.statusCode;
      if (status == 403) {
        _showError(_isAr
            ? 'هذا الرقم غير مصرّح له بالدخول.'
            : 'This number is not authorized for staff access.');
      } else if (status == 400) {
        _showError(_isAr
            ? 'الرمز غير صحيح أو انتهت صلاحيته.'
            : 'The code is incorrect or has expired.');
      } else {
        _showError(_isAr
            ? 'تعذّر التحقق من الرمز. حاول مرة أخرى.'
            : 'Could not verify the code. Please try again.');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _verifying = false);
      _showError(_isAr ? 'حدث خطأ. حاول مجدداً.' : 'Something went wrong. Try again.');
    }
  }

  // Maps a send-OTP failure to a friendly message (429 = rate limited).
  String _otpSendError(Object e) {
    if (e is DioException && e.response?.statusCode == 429) {
      return _isAr
          ? 'محاولات كثيرة. الرجاء الانتظار قليلاً ثم المحاولة مجدداً.'
          : 'Too many attempts. Please wait a bit and try again.';
    }
    return _isAr
        ? 'تعذّر إرسال الرمز. حاول مرة أخرى.'
        : 'Could not send the code. Please try again.';
  }


  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: HamsaText.body(size: 13)),
        backgroundColor: HamsaColors.error.withValues(alpha: 0.9),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isBusy = _sending || _verifying;
    final isAr = ref.watch(localeProvider).languageCode == 'ar';

    return Scaffold(
      backgroundColor: HamsaColors.bgDeep,
      body: Stack(
        children: [
          // Dark vignette background
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment.topCenter,
                  radius: 1.2,
                  colors: [
                    HamsaColors.greenBrand.withValues(alpha: 0.15),
                    HamsaColors.bgDeep,
                  ],
                ),
              ),
            ),
          ),

          SafeArea(
            // Scrolls only when the keyboard (or a short screen) squeezes
            // the content; otherwise the Spacers keep the original layout.
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 36),
                child: ConstrainedBox(
                  constraints:
                      BoxConstraints(minHeight: constraints.maxHeight),
                  child: IntrinsicHeight(
                    child: Column(
                children: [
                  const SizedBox(height: 24),

                  // Back
                  Align(
                    alignment: Alignment.centerLeft,
                    child: GestureDetector(
                      onTap: () {
                        if (_step2) {
                          setState(() {
                            _step2 = false;
                            _otpCtrl.clear();
                          });
                        } else {
                          context.go(AppRoutes.login);
                        }
                      },
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.arrow_back_ios_new_rounded,
                              size: 16, color: HamsaColors.muted),
                          const SizedBox(width: 4),
                          Text(isAr ? 'رجوع' : 'Back',
                              style: HamsaText.body(
                                  size: 13, color: HamsaColors.muted)),
                        ],
                      ),
                    ),
                  ),

                  const Spacer(),

                  // Lock icon
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: HamsaColors.bgCard,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: HamsaColors.borderStrong),
                    ),
                    child: const Center(
                      child: Icon(
                        Icons.lock_outline_rounded,
                        color: HamsaColors.cream,
                        size: 32,
                      ),
                    ),
                  )
                      .animate()
                      .fadeIn(duration: 400.ms)
                      .scale(begin: const Offset(0.8, 0.8)),

                  const SizedBox(height: 24),

                  Text(
                    isAr ? 'دخول الموظفين' : 'Staff Access',
                    style:
                        HamsaText.display(size: 34, color: HamsaColors.cream),
                  ).animate(delay: 100.ms).fadeIn(duration: 400.ms),

                  const SizedBox(height: 6),

                  Text(
                    _step2
                        ? (isAr ? 'أدخل الرمز المرسل إلى $_fullPhone' : 'Enter the 6-digit code sent to $_fullPhone')
                        : (isAr ? 'سجّل الدخول برقم جوال الموظف المعتمد' : 'Sign in with the authorized staff phone number'),
                    style: HamsaText.body(size: 13, color: HamsaColors.muted),
                    textAlign: TextAlign.center,
                  ).animate(delay: 200.ms).fadeIn(duration: 400.ms),

                  const SizedBox(height: 48),

                  // Phone or OTP input
                  if (!_step2)
                    _PhoneField(controller: _phoneCtrl)
                        .animate(delay: 300.ms)
                        .fadeIn(duration: 400.ms)
                        .slideY(begin: 0.2, end: 0)
                  else
                    _OtpField(controller: _otpCtrl, onSubmit: _verifyCode)
                        .animate()
                        .fadeIn(duration: 400.ms)
                        .slideY(begin: 0.2, end: 0),

                  const SizedBox(height: 24),

                  HamsaButton(
                    label: _step2
                        ? (isAr ? 'تحقق والدخول' : 'Verify & Enter')
                        : (isAr ? 'إرسال الرمز' : 'Send Code'),
                    onTap: isBusy ? null : (_step2 ? _verifyCode : _sendCode),
                    isLoading: isBusy,
                    style: HamsaButtonStyle.gold,
                  ).animate(delay: 400.ms).fadeIn(duration: 400.ms),

                  const Spacer(flex: 2),

                  // Hamsa branding
                  const HamsaLogo(size: 32)
                      .animate(delay: 500.ms)
                      .fadeIn(duration: 400.ms),

                  const SizedBox(height: 12),

                  Text(
                    'Hamsa Coffee Roasters',
                    style: HamsaText.caption(
                        size: 11, color: HamsaColors.subtle),
                  ).animate(delay: 600.ms).fadeIn(duration: 400.ms),

                  const SizedBox(height: 32),
                ],
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Language toggle — last so it sits on top
          const SafeArea(
            child: Padding(
              padding: EdgeInsets.only(top: 12, right: 16),
              child: Align(
                alignment: Alignment.topRight,
                child: LangToggleButton(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Phone input with +966 prefix ─────────────────────────────
class _PhoneField extends StatefulWidget {
  final TextEditingController controller;
  const _PhoneField({required this.controller});

  @override
  State<_PhoneField> createState() => _PhoneFieldState();
}

class _PhoneFieldState extends State<_PhoneField> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (v) => setState(() => _focused = v),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: HamsaColors.inputBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _focused
                ? HamsaColors.gold.withValues(alpha: 0.8)
                : HamsaColors.border,
            width: _focused ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              decoration: const BoxDecoration(
                border: Border(right: BorderSide(color: HamsaColors.border)),
              ),
              child: Text('+966',
                  style: HamsaText.body(
                      size: 15,
                      color: HamsaColors.cream,
                      weight: FontWeight.w600)),
            ),
            Expanded(
              child: TextField(
                controller: widget.controller,
                autofocus: true,
                keyboardType: TextInputType.phone,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: HamsaText.body(size: 16, color: HamsaColors.cream),
                decoration: InputDecoration(
                  hintText: '5XX XXX XXXX',
                  hintStyle:
                      HamsaText.body(size: 15, color: HamsaColors.subtle),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── OTP input field ──────────────────────────────────────────
class _OtpField extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSubmit;
  const _OtpField({required this.controller, required this.onSubmit});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: HamsaColors.inputBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: HamsaColors.border),
      ),
      child: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(6),
        ],
        textAlign: TextAlign.center,
        style: HamsaText.body(
            size: 28,
            color: HamsaColors.cream,
            weight: FontWeight.w700,
            letterSpacing: 8),
        decoration: const InputDecoration(
          hintText: '------',
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        ),
        onSubmitted: (_) => onSubmit(),
      ),
    );
  }
}
