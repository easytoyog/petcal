import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
// import 'package:google_sign_in/google_sign_in.dart';
// import 'package:sign_in_with_apple/sign_in_with_apple.dart';
// import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:inthepark/legal/terms_conditions.dart';
import 'package:inthepark/legal/privacy_policy.dart';
import 'package:inthepark/screens/wait_screen.dart';

class AccountCreationScreen extends StatefulWidget {
  const AccountCreationScreen({Key? key}) : super(key: key);

  @override
  _AccountCreationScreenState createState() => _AccountCreationScreenState();
}

class _AccountCreationScreenState extends State<AccountCreationScreen> {
  final TextEditingController emailController = TextEditingController();
  final FocusNode emailFocusNode = FocusNode(); // <-- Add this line
  final TextEditingController passwordController = TextEditingController();
  final TextEditingController confirmPasswordController =
      TextEditingController();

  @override
  void initState() {
    super.initState();
    // Auto-focus after build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      emailFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    emailController.dispose();
    emailFocusNode.dispose(); // <-- Add this line
    passwordController.dispose();
    confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> createAccountWithEmailPassword(BuildContext context) async {
    if (passwordController.text != confirmPasswordController.text) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Passwords do not match")),
      );
      return;
    }

    try {
      // Create the user in Firebase Authentication
      final UserCredential userCredential =
          await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: emailController.text.trim(),
        password: passwordController.text.trim(),
      );

      final user = userCredential.user;
      final String uid = user!.uid;

      print("User created with UID: $uid");

      // Send email verification
      await user.sendEmailVerification();
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => WaitForEmailVerificationScreen(user: user),
        ),
      );

      // Optionally, navigate to a "verify email" screen or back to login
    } on FirebaseAuthException catch (authError) {
      print("Authentication error: $authError");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Auth error: ${authError.message}")),
      );
    } catch (generalError) {
      print("General error: $generalError");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error: $generalError")),
      );
    }
  }

  Future<String> loadDocument(String path) async {
    return await rootBundle.loadString(path);
  }

  // Google and Apple sign up methods are commented out
  // Future<void> createAccountWithGoogle(BuildContext context) async { ... }
  // Future<void> createAccountWithApple(BuildContext context) async { ... }

  void showDocumentHtml(
      BuildContext context, String title, String htmlContent) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Html(data: htmlContent),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text("Close"),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Create New Account"),
        backgroundColor: const Color(0xFF567D46),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF567D46), Color(0xFF365A38)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding:
                const EdgeInsets.symmetric(horizontal: 24.0, vertical: 32.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Icon(Icons.pets,
                    size: 100, color: Colors.tealAccent), // Centered Icon
                const SizedBox(height: 10),
                const Text(
                  "Let's create your account!",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 30),
                TextField(
                  controller: emailController,
                  focusNode: emailFocusNode, // <-- Add this line
                  style: const TextStyle(color: Colors.white),
                  cursorColor: Colors.tealAccent, // <-- Add this line
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: Colors.white.withOpacity(0.1),
                    hintText: "Email",
                    hintStyle: const TextStyle(color: Colors.white70),
                    prefixIcon: const Icon(Icons.mail, color: Colors.white),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(
                        color: Colors.tealAccent,
                        width: 2,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  style: const TextStyle(color: Colors.white),
                  cursorColor: Colors.tealAccent, // <-- Add this line
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: Colors.white.withOpacity(0.1),
                    hintText: "Password",
                    hintStyle: const TextStyle(color: Colors.white70),
                    prefixIcon: const Icon(Icons.lock, color: Colors.white),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(
                        color: Colors.tealAccent,
                        width: 2,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: confirmPasswordController,
                  obscureText: true,
                  style: const TextStyle(color: Colors.white),
                  cursorColor: Colors.tealAccent, // <-- Add this line
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: Colors.white.withOpacity(0.1),
                    hintText: "Confirm Password",
                    hintStyle: const TextStyle(color: Colors.white70),
                    prefixIcon: const Icon(Icons.lock, color: Colors.white),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(
                        color: Colors.tealAccent,
                        width: 2,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: MediaQuery.of(context).size.width / 2,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.tealAccent,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 16.0),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () async {
                      await createAccountWithEmailPassword(context);
                    },
                    child: const Text("Create Account",
                        style: TextStyle(fontSize: 18)),
                  ),
                ),
                const SizedBox(height: 20),
                //Text(
                //  "Or sign up with",
                //  style: const TextStyle(color: Colors.white70),
                //),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // ElevatedButton.icon(
                    //   onPressed: () => createAccountWithGoogle(context),
                    //   style: ElevatedButton.styleFrom(
                    //     backgroundColor: Colors.white,
                    //     foregroundColor: Colors.black,
                    //     padding: const EdgeInsets.symmetric(
                    //         vertical: 10.0, horizontal: 20.0),
                    //     shape: RoundedRectangleBorder(
                    //       borderRadius: BorderRadius.circular(8),
                    //     ),
                    //   ),
                    //   icon: const FaIcon(FontAwesomeIcons.google,
                    //       color: Colors.red, size: 20),
                    //   label: const Text("Google"),
                    // ),
                    // const SizedBox(width: 10),
                    // ElevatedButton.icon(
                    //   onPressed: () => createAccountWithApple(context),
                    //   style: ElevatedButton.styleFrom(
                    //     backgroundColor: Colors.black,
                    //     foregroundColor: Colors.white,
                    //     padding: const EdgeInsets.symmetric(
                    //         vertical: 10.0, horizontal: 20.0),
                    //     shape: RoundedRectangleBorder(
                    //       borderRadius: BorderRadius.circular(8),
                    //     ),
                    //   ),
                    //   icon: const Icon(Icons.apple, color: Colors.white),
                    //   label: const Text("Apple"),
                    // ),
                  ],
                ),
                const SizedBox(height: 20),
                RichText(
                  textAlign: TextAlign.center,
                  text: TextSpan(
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                    children: [
                      const TextSpan(
                          text: "By creating an account, you agree to our "),
                      TextSpan(
                        text: "Terms",
                        style: const TextStyle(
                          decoration: TextDecoration.underline,
                          color: Colors.tealAccent,
                        ),
                        recognizer: TapGestureRecognizer()
                          ..onTap = () => showDocumentHtml(
                                context,
                                "Terms and Conditions",
                                termsConditionsHtml,
                              ),
                      ),
                      const TextSpan(text: " and "),
                      TextSpan(
                        text: "Privacy",
                        style: const TextStyle(
                          decoration: TextDecoration.underline,
                          color: Colors.tealAccent,
                        ),
                        recognizer: TapGestureRecognizer()
                          ..onTap = () => showDocumentHtml(
                                context,
                                "Privacy Policy",
                                privacyPolicyHtml,
                              ),
                      ),
                      const TextSpan(text: " document."),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
