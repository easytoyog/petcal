import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:pet_calendar/legal/terms_conditions.dart';
import 'package:pet_calendar/legal/privacy_policy.dart';

class AccountCreationScreen extends StatefulWidget {
  const AccountCreationScreen({Key? key}) : super(key: key);

  @override
  _AccountCreationScreenState createState() => _AccountCreationScreenState();
}

class _AccountCreationScreenState extends State<AccountCreationScreen> {
  final TextEditingController emailController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  final TextEditingController confirmPasswordController = TextEditingController();

  Future<void> createAccountWithEmailPassword(BuildContext context) async {
  if (passwordController.text != confirmPasswordController.text) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Passwords do not match")),
    );
    return;
  }

  try {
    // Create the user in Firebase Authentication
    final UserCredential userCredential = await FirebaseAuth.instance
        .createUserWithEmailAndPassword(
      email: emailController.text.trim(),
      password: passwordController.text.trim(),
    );

    final String uid = userCredential.user!.uid;

    print("User created with UID: $uid");

    // Attempt to create the Firestore document
    try {
      await FirebaseFirestore.instance.collection('owners').doc(uid).set({
        'email': emailController.text.trim(),
        'firstName': '', // Placeholder
        'lastName': '',  // Placeholder
        'address': {},   // Placeholder
        'phone': '',     // Placeholder
        'createdAt': FieldValue.serverTimestamp(),
      });
      print("Firestore record created successfully for UID: $uid");
    } catch (firestoreError) {
      print("Error writing Firestore document: $firestoreError");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Firestore error: $firestoreError")),
      );
    }

    // Navigate to the next screen
    Navigator.pushNamed(context, '/ownerDetails');
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


  Future<void> createAccountWithGoogle(BuildContext context) async {
    try {
      final GoogleSignIn googleSignIn = GoogleSignIn();
      final GoogleSignInAccount? googleUser = await googleSignIn.signIn();
      if (googleUser != null) {
        final GoogleSignInAuthentication googleAuth =
            await googleUser.authentication;
        final credential = GoogleAuthProvider.credential(
          accessToken: googleAuth.accessToken,
          idToken: googleAuth.idToken,
        );
        final userCredential =
            await FirebaseAuth.instance.signInWithCredential(credential);
        if (userCredential.user != null) {
          Navigator.pushNamed(context, '/ownerDetails'); // Navigate to the next step
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error: $e")),
      );
    }
  }

  Future<void> createAccountWithApple(BuildContext context) async {
    try {
      final appleCredential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
      );
      final credential = OAuthProvider("apple.com").credential(
        idToken: appleCredential.identityToken,
        accessToken: appleCredential.authorizationCode,
      );
      final userCredential =
          await FirebaseAuth.instance.signInWithCredential(credential);
      if (userCredential.user != null) {
        Navigator.pushNamed(context, '/ownerDetails'); // Navigate to the next step
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error: $e")),
      );
    }
  }

  void showDocumentHtml(BuildContext context, String title, String htmlContent) {
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
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Icon(Icons.pets, size: 100, color: Colors.tealAccent), // Centered Icon
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
                style: const TextStyle(color: Colors.white),
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
                ),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: passwordController,
                obscureText: true,
                style: const TextStyle(color: Colors.white),
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
                ),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: confirmPasswordController,
                obscureText: true,
                style: const TextStyle(color: Colors.white),
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
                  onPressed: () => createAccountWithEmailPassword(context),
                  child: const Text("Create Account", style: TextStyle(fontSize: 18)),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                "Or sign up with",
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton.icon(
                    onPressed: () => createAccountWithGoogle(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 10.0, horizontal: 20.0),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    icon: const FaIcon(FontAwesomeIcons.google, color: Colors.red, size: 20),
                    label: const Text("Google"),
                  ),
                  const SizedBox(width: 10),
                  ElevatedButton.icon(
                    onPressed: () => createAccountWithApple(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.black,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 10.0, horizontal: 20.0),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    icon: const Icon(Icons.apple, color: Colors.white),
                    label: const Text("Apple"),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              RichText(
                textAlign: TextAlign.center,
                text: TextSpan(
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                  children: [
                    const TextSpan(text: "By creating an account, you agree to our "),
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
    );
  }
}
