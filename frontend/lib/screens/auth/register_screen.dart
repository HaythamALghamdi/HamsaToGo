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
import '../../widgets/lang_toggle_button.dart';

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _nameCtrl  = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _otpCtrl   = TextEditingController();

  bool _step2    = false;
  bool _sending  = false;
  bool _verifying = false;

  bool get _isAr => ref.read(localeProvider).languageCode == 'ar';

  @override
  void dispose() {
    _nameCtrl.dispose();
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

  // ── Send OTP (backend + Twilio Verify) ───────────────────────
  Future<void> _sendCode() async {
    final name = _nameCtrl.text.trim();
    if (name.length < 2) {
      _showError(_isAr ? 'الرجاء إدخال الاسم الكامل' : 'Please enter your full name');
      return;
    }

    final phone = _fullPhone;
    if (phone.length < 10) {
      _showError(_isAr
          ? 'الرجاء إدخال رقم جوال صحيح'
          : 'Please enter a valid phone number');
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
      _showError(_isAr
          ? 'أدخل الرمز المكوّن من 6 أرقام'
          : 'Enter the 6-digit code');
      return;
    }

    setState(() => _verifying = true);
    try {
      final data = await ref.read(apiServiceProvider).verifyOtp(
            phone: _fullPhone,
            code: code,
            fullName: _nameCtrl.text.trim(),
            lang: ref.read(localeProvider).languageCode,
          );
      await ref.read(authProvider.notifier).completeOtpAuth(
            customToken: data['custom_token'] as String,
            userJson: data['user'] as Map<String, dynamic>,
          );
      if (!mounted) return;
      if (ref.read(authProvider).error != null) {
        setState(() => _verifying = false);
        _showError(_isAr
            ? 'تعذّر إنشاء الحساب. حاول مرة أخرى.'
            : 'Could not create the account. Please try again.');
      }
      // On success the router redirects to home automatically.
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() => _verifying = false);
      if (e.response?.statusCode == 400) {
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
      _showError(_isAr
          ? 'حدث خطأ. حاول مجدداً.'
          : 'Something went wrong. Try again.');
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: HamsaText.body(size: 14, color: HamsaColors.bgDeep)),
      backgroundColor: HamsaColors.error,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ));
  }

  /// The login route, carrying through any pending return target so a user
  /// who started at checkout still lands back there after signing in.
  String get _loginRoute {
    final from = returnTargetOf(GoRouterState.of(context));
    return from == null
        ? AppRoutes.login
        : '${AppRoutes.login}?from=${Uri.encodeComponent(from)}';
  }

  @override
  Widget build(BuildContext context) {
    final isAr = ref.watch(localeProvider).languageCode == 'ar';
    final isBusy = _sending || _verifying;

    return Scaffold(
      backgroundColor: HamsaColors.bgDeep,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: HamsaColors.muted, size: 20),
          onPressed: () {
            if (_step2) {
              setState(() { _step2 = false; _otpCtrl.clear(); });
            } else {
              context.go(_loginRoute);
            }
          },
        ),
        actions: const [
          LangToggleButton(),
          SizedBox(width: 8),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),

            Text(
              isAr ? 'إنشاء حساب' : 'Create Account',
              style: HamsaText.display(size: 38, color: HamsaColors.cream),
            ).animate().fadeIn(duration: 400.ms).slideX(begin: -0.15, end: 0),

            const SizedBox(height: 8),

            Text(
              isAr ? 'انضم إلى مجتمع حمصة' : 'Join the Hamsa community',
              style: HamsaText.body(size: 15, color: HamsaColors.creamMuted),
            ).animate(delay: 100.ms).fadeIn(),

            const SizedBox(height: 40),

            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: _step2
                  ? _Step2(
                      key: const ValueKey('otp'),
                      isAr: isAr,
                      phone: _fullPhone,
                      otpCtrl: _otpCtrl,
                      isBusy: isBusy,
                      onVerify: _verifyCode,
                    )
                  : _Step1(
                      key: const ValueKey('form'),
                      isAr: isAr,
                      nameCtrl: _nameCtrl,
                      phoneCtrl: _phoneCtrl,
                      isBusy: isBusy,
                      onSend: _sendCode,
                    ),
            ).animate(delay: 200.ms).fadeIn(duration: 400.ms).slideY(begin: 0.2, end: 0),

            const SizedBox(height: 24),

            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  isAr ? 'لديك حساب؟ ' : 'Already have an account? ',
                  style: HamsaText.body(size: 13, color: HamsaColors.muted),
                ),
                GestureDetector(
                  onTap: () => context.go(_loginRoute),
                  child: Text(
                    isAr ? 'تسجيل الدخول' : 'Sign In',
                    style: HamsaText.body(size: 13, color: HamsaColors.greenAccent, weight: FontWeight.w600),
                  ),
                ),
              ],
            ).animate(delay: 400.ms).fadeIn(),

            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}

// ── Step 1: Name + Phone ─────────────────────────────────────
class _Step1 extends StatelessWidget {
  final bool isAr;
  final TextEditingController nameCtrl;
  final TextEditingController phoneCtrl;
  final bool isBusy;
  final VoidCallback onSend;

  const _Step1({
    super.key,
    required this.isAr,
    required this.nameCtrl,
    required this.phoneCtrl,
    required this.isBusy,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Name field
        _LabeledField(
          label: isAr ? 'الاسم الكامل' : 'Full Name',
          child: TextField(
            controller: nameCtrl,
            textCapitalization: TextCapitalization.words,
            textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
            style: isAr
                ? HamsaText.arabic(size: 16, color: HamsaColors.cream)
                : HamsaText.body(size: 16, color: HamsaColors.cream),
            decoration: _inputDeco(isAr ? 'مثال: أحمد محمد' : 'e.g. Ahmed Mohammed'),
          ),
        ),
        const SizedBox(height: 16),

        // Phone field
        _LabeledField(
          label: isAr ? 'رقم الجوال' : 'Phone Number',
          child: _PhoneField(controller: phoneCtrl, isAr: isAr),
        ),
        const SizedBox(height: 32),

        HamsaButton(
          label: isAr ? 'إرسال رمز التحقق' : 'Send Verification Code',
          onTap: isBusy ? null : onSend,
          isLoading: isBusy,
        ),
      ],
    );
  }
}

// ── Step 2: OTP ───────────────────────────────────────────────
class _Step2 extends StatelessWidget {
  final bool isAr;
  final String phone;
  final TextEditingController otpCtrl;
  final bool isBusy;
  final VoidCallback onVerify;

  const _Step2({
    super.key,
    required this.isAr,
    required this.phone,
    required this.otpCtrl,
    required this.isBusy,
    required this.onVerify,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          isAr
              ? 'تم إرسال رمز مكون من 6 أرقام إلى $phone'
              : 'A 6-digit code was sent to $phone',
          style: HamsaText.body(size: 14, color: HamsaColors.creamMuted),
        ),
        const SizedBox(height: 24),

        _LabeledField(
          label: isAr ? 'رمز التحقق' : 'Verification Code',
          child: _OtpField(controller: otpCtrl, onSubmit: onVerify),
        ),
        const SizedBox(height: 32),

        HamsaButton(
          label: isAr ? 'إنشاء الحساب' : 'Create Account',
          onTap: isBusy ? null : onVerify,
          isLoading: isBusy,
        ),
      ],
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────
InputDecoration _inputDeco(String hint) => InputDecoration(
      hintText: hint,
      hintStyle: HamsaText.body(size: 14, color: HamsaColors.subtle),
      border: InputBorder.none,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    );

class _LabeledField extends StatelessWidget {
  final String label;
  final Widget child;
  const _LabeledField({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: HamsaText.body(size: 13, color: HamsaColors.muted, weight: FontWeight.w600)),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: HamsaColors.inputBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: HamsaColors.border),
          ),
          child: child,
        ),
      ],
    );
  }
}

class _PhoneField extends StatefulWidget {
  final TextEditingController controller;
  final bool isAr;
  const _PhoneField({required this.controller, required this.isAr});

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
            color: _focused ? HamsaColors.greenAccent.withValues(alpha: 0.8) : HamsaColors.border,
            width: _focused ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              decoration: const BoxDecoration(
                border: Border(right: BorderSide(color: HamsaColors.border)),
              ),
              child: Text('+966',
                  style: HamsaText.body(size: 15, color: HamsaColors.cream, weight: FontWeight.w600)),
            ),
            Expanded(
              child: TextField(
                controller: widget.controller,
                keyboardType: TextInputType.phone,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: HamsaText.body(size: 16, color: HamsaColors.cream),
                decoration: InputDecoration(
                  hintText: '5XX XXX XXXX',
                  hintStyle: HamsaText.body(size: 15, color: HamsaColors.subtle),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OtpField extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSubmit;
  const _OtpField({required this.controller, required this.onSubmit});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      autofocus: true,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(6),
      ],
      textAlign: TextAlign.center,
      style: HamsaText.body(size: 28, color: HamsaColors.cream, weight: FontWeight.w700, letterSpacing: 8),
      decoration: const InputDecoration(
        hintText: '------',
        border: InputBorder.none,
        contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      ),
      onSubmitted: (_) => onSubmit(),
    );
  }
}
