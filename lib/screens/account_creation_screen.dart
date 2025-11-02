// lib/screens/account_creation_screen.dart
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import 'package:flutter_html/flutter_html.dart';

import 'package:inthepark/legal/terms_conditions.dart';
import 'package:inthepark/legal/privacy_policy.dart';
import 'package:inthepark/screens/wait_screen.dart';

class AccountCreationScreen extends StatefulWidget {
  const AccountCreationScreen({Key? key}) : super(key: key);

  @override
  State<AccountCreationScreen> createState() => _AccountCreationScreenState();
}

class _AccountCreationScreenState extends State<AccountCreationScreen> {
  // --- Controllers & Focus ---
  final _emailCtl = TextEditingController();
  final _emailFocus = FocusNode();
  final _passCtl = TextEditingController();
  final _pass2Ctl = TextEditingController();

  // --- Form state ---
  final _formKey = GlobalKey<FormState>();
  bool _submitting = false;
  bool _obscure = true;
  bool _obscure2 = true;

  @override
  void initState() {
    super.initState();
    // Auto-focus after first frame
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _emailFocus.requestFocus());
  }

  @override
  void dispose() {
    _emailCtl.dispose();
    _emailFocus.dispose();
    _passCtl.dispose();
    _pass2Ctl.dispose();
    super.dispose();
  }

  // --------------- Helpers ---------------
  String _normalizeEmail(String raw) => raw.trim().toLowerCase();

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _createAccount() async {
    if (_submitting) return; // debounce
    final form = _formKey.currentState;
    if (form == null) return;
    if (!form.validate()) return;

    setState(() => _submitting = true);
    final auth = FirebaseAuth.instance;

    // Normalize inputs
    final email = _normalizeEmail(_emailCtl.text);
    final pass = _passCtl.text;

    try {
      // If user is anonymous, LINK instead of creating a new account (keeps same UID)
      final cred = EmailAuthProvider.credential(email: email, password: pass);

      UserCredential userCred;
      if (auth.currentUser?.isAnonymous == true) {
        userCred = await auth.currentUser!.linkWithCredential(cred);
      } else {
        userCred = await auth.createUserWithEmailAndPassword(
          email: email,
          password: pass,
        );
      }

      // Send verification (best effort)
      final user = userCred.user ?? auth.currentUser;
      if (user != null && !user.emailVerified) {
        await user.sendEmailVerification();
      }

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
            builder: (_) => WaitForEmailVerificationScreen(user: user!)),
      );
    } on FirebaseAuthException catch (e) {
      // Strong handling for common cases
      switch (e.code) {
        case 'email-already-in-use':
          // In case user previously signed up with password or other provider
          // Give a helpful message without leaking details
          _toast(
              'That email is already in use. Try signing in, or use “Forgot password”.');
          break;
        case 'invalid-email':
          _toast('Please enter a valid email address.');
          break;
        case 'weak-password':
          _toast('Please choose a stronger password (at least 6 characters).');
          break;
        case 'operation-not-allowed':
          _toast('Email sign up is disabled. Please contact support.');
          break;
        case 'credential-already-in-use':
          _toast('This credential is already linked to another account.');
          break;
        default:
          _toast(e.message ?? 'Auth error. Please try again.');
      }
    } catch (e) {
      _toast('Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _showDoc(String title, String htmlContent) async {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(child: Html(data: htmlContent)),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close')),
        ],
      ),
    );
  }

  // --------------- UI ---------------
  @override
  Widget build(BuildContext context) {
    final themeGreen = const Color(0xFF567D46);
    final accentGreen = const Color(0xFF365A38);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Create New Account'),
        backgroundColor: themeGreen,
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [themeGreen, accentGreen],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding:
                const EdgeInsets.symmetric(horizontal: 24.0, vertical: 32.0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Form(
                key: _formKey,
                child: Column(
                  children: [
                    const Icon(Icons.pets, size: 100, color: Colors.tealAccent),
                    const SizedBox(height: 10),
                    const Text(
                      "Let's create your account!",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 30),

                    // Email
                    TextFormField(
                      controller: _emailCtl,
                      focusNode: _emailFocus,
                      textInputAction: TextInputAction.next,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      style: const TextStyle(color: Colors.white),
                      cursorColor: Colors.tealAccent,
                      inputFormatters: [
                        FilteringTextInputFormatter.deny(
                            RegExp(r"\s")), // no spaces
                      ],
                      decoration: _inputDecoration(
                        hint: 'Email',
                        icon: Icons.mail,
                      ),
                      validator: (v) {
                        final value = (v ?? '').trim();
                        if (value.isEmpty) return 'Email is required';
                        // Simple email sanity check
                        if (!RegExp(r"^[^\s@]+@[^\s@]+\.[^\s@]+$")
                            .hasMatch(value)) {
                          return 'Enter a valid email';
                        }
                        return null;
                      },
                      onFieldSubmitted: (_) =>
                          FocusScope.of(context).nextFocus(),
                    ),
                    const SizedBox(height: 20),

                    // Password
                    TextFormField(
                      controller: _passCtl,
                      obscureText: _obscure,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.newPassword],
                      style: const TextStyle(color: Colors.white),
                      cursorColor: Colors.tealAccent,
                      decoration: _inputDecoration(
                        hint: 'Password',
                        icon: Icons.lock,
                        trailing: IconButton(
                          splashRadius: 20,
                          onPressed: () => setState(() => _obscure = !_obscure),
                          icon: Icon(
                              _obscure
                                  ? Icons.visibility
                                  : Icons.visibility_off,
                              color: Colors.white),
                        ),
                      ),
                      validator: (v) {
                        final value = v ?? '';
                        if (value.isEmpty) return 'Password is required';
                        if (value.length < 6) {
                          return 'Use at least 6 characters';
                        }
                        return null;
                      },
                      onFieldSubmitted: (_) =>
                          FocusScope.of(context).nextFocus(),
                    ),
                    const SizedBox(height: 20),

                    // Confirm password
                    TextFormField(
                      controller: _pass2Ctl,
                      obscureText: _obscure2,
                      textInputAction: TextInputAction.done,
                      autofillHints: const [AutofillHints.newPassword],
                      style: const TextStyle(color: Colors.white),
                      cursorColor: Colors.tealAccent,
                      decoration: _inputDecoration(
                        hint: 'Confirm Password',
                        icon: Icons.lock_outline,
                        trailing: IconButton(
                          splashRadius: 20,
                          onPressed: () =>
                              setState(() => _obscure2 = !_obscure2),
                          icon: Icon(
                              _obscure2
                                  ? Icons.visibility
                                  : Icons.visibility_off,
                              color: Colors.white),
                        ),
                      ),
                      validator: (v) {
                        final value = v ?? '';
                        if (value.isEmpty)
                          return 'Please confirm your password';
                        if (value != _passCtl.text)
                          return 'Passwords do not match';
                        return null;
                      },
                      onFieldSubmitted: (_) => _createAccount(),
                    ),
                    const SizedBox(height: 24),

                    // Submit
                    SizedBox(
                      width: MediaQuery.of(context).size.width / 2,
                      child: ElevatedButton(
                        onPressed: _submitting ? null : _createAccount,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.tealAccent,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 16.0),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: _submitting
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('Create Account',
                                style: TextStyle(fontSize: 18)),
                      ),
                    ),

                    const SizedBox(height: 24),

                    // Terms / Privacy
                    RichText(
                      textAlign: TextAlign.center,
                      text: TextSpan(
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 14),
                        children: [
                          const TextSpan(
                              text:
                                  'By creating an account, you agree to our '),
                          TextSpan(
                            text: 'Terms',
                            style: const TextStyle(
                              decoration: TextDecoration.underline,
                              color: Colors.tealAccent,
                            ),
                            recognizer: TapGestureRecognizer()
                              ..onTap = () => _showDoc(
                                  'Terms and Conditions', termsConditionsHtml),
                          ),
                          const TextSpan(text: ' and '),
                          TextSpan(
                            text: 'Privacy',
                            style: const TextStyle(
                              decoration: TextDecoration.underline,
                              color: Colors.tealAccent,
                            ),
                            recognizer: TapGestureRecognizer()
                              ..onTap = () =>
                                  _showDoc('Privacy Policy', privacyPolicyHtml),
                          ),
                          const TextSpan(text: ' document.'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Shared input decoration for a consistent look
  InputDecoration _inputDecoration({
    required String hint,
    required IconData icon,
    Widget? trailing,
  }) {
    return InputDecoration(
      filled: true,
      fillColor: Colors.white.withOpacity(0.1),
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.white70),
      prefixIcon: Icon(icon, color: Colors.white),
      suffixIcon: trailing,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.tealAccent, width: 2),
      ),
    );
  }
}
