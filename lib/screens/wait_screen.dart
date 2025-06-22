import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:inthepark/screens/owner_detail_screen.dart';
// Or your next screen

class WaitForEmailVerificationScreen extends StatefulWidget {
  final User user;
  const WaitForEmailVerificationScreen({Key? key, required this.user})
      : super(key: key);

  @override
  State<WaitForEmailVerificationScreen> createState() =>
      _WaitForEmailVerificationScreenState();
}

class _WaitForEmailVerificationScreenState
    extends State<WaitForEmailVerificationScreen> {
  Timer? _timer;
  Timer? _resendTimer;
  bool _isVerified = false;
  int _resendCooldown = 0;

  @override
  void initState() {
    super.initState();
    _startVerificationCheck();
  }

  void _startVerificationCheck() {
    _timer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      await widget.user.reload();
      final refreshedUser = FirebaseAuth.instance.currentUser;
      if (refreshedUser != null && refreshedUser.emailVerified) {
        setState(() {
          _isVerified = true;
        });
        _timer?.cancel();
        // Navigate to the sign up screen
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => OwnerDetailsScreen(),
          ),
        );
      }
    });
  }

  void _startResendCooldown() {
    setState(() {
      _resendCooldown = 30;
    });
    _resendTimer?.cancel();
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_resendCooldown > 0) {
        setState(() {
          _resendCooldown--;
        });
      } else {
        _resendTimer?.cancel();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _resendTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Verify Your Email")),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.email, size: 80, color: Colors.tealAccent),
              const SizedBox(height: 24),
              Text(
                "A verification link has been sent to:\n\n"
                "${widget.user.email}\n\n"
                "Please click the link in your email to verify your account.",
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18),
              ),
              const SizedBox(height: 24),
              if (!_isVerified) const CircularProgressIndicator(),
              if (!_isVerified) const SizedBox(height: 16),
              if (!_isVerified)
                const Text(
                  "Waiting for verification...",
                  style: TextStyle(color: Colors.white70),
                ),
              if (_isVerified)
                const Text(
                  "Email verified! Redirecting...",
                  style: TextStyle(color: Colors.greenAccent),
                ),
              const SizedBox(height: 24),
              TextButton(
                onPressed: (_resendCooldown > 0)
                    ? null
                    : () async {
                        await widget.user.sendEmailVerification();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text("Verification email resent.")),
                        );
                        _startResendCooldown();
                      },
                child: (_resendCooldown > 0)
                    ? Text("Resend in $_resendCooldown s")
                    : const Text("Resend Verification Email"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
