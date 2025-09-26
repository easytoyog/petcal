// main.dart

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_fonts/google_fonts.dart';

// Screens
import 'package:inthepark/screens/profile_screen.dart';
import 'package:inthepark/screens/signup_screen.dart';
import 'package:inthepark/screens/account_creation_screen.dart';
import 'package:inthepark/screens/owner_detail_screen.dart';
import 'package:inthepark/screens/pet_detail_screen.dart';
import 'package:inthepark/screens/location_service_choice.dart';
import 'package:inthepark/screens/allsetup.dart';
import 'package:inthepark/screens/forgot_password_screen.dart';
import 'package:inthepark/screens/wait_screen.dart';

// Google Mobile Ads: keep SDK import separate to avoid UMP symbol clashes
import 'package:google_mobile_ads/google_mobile_ads.dart' as gma
    show MobileAds, RequestConfiguration, MaxAdContentRating;

// UMP (User Messaging Platform) classes (same package, but un-aliased)
import 'package:google_mobile_ads/google_mobile_ads.dart'
    show
        ConsentInformation,
        ConsentRequestParameters,
        ConsentForm,
        ConsentDebugSettings,
        DebugGeography;

import 'dart:async';
import 'package:google_mobile_ads/google_mobile_ads.dart'
    show ConsentInformation, ConsentRequestParameters, ConsentForm;

bool _appCheckActivated = false;

/// Configure Mobile Ads (test devices in debug, content rating, etc.)
Future<void> _configureMobileAds() async {
  await gma.MobileAds.instance.updateRequestConfiguration(
    gma.RequestConfiguration(
      testDeviceIds: kReleaseMode ? const <String>[] : const <String>[],
      maxAdContentRating: gma.MaxAdContentRating.pg,
      // Optionally set child-directed flags here if applicable.
    ),
  );
}

Future<void> _gatherConsentIfNeeded() async {
  final completer = Completer<void>();
  final consentInfo = ConsentInformation.instance;

  // ✅ Your API version: callback-based and returns void
  consentInfo.requestConsentInfoUpdate(
    ConsentRequestParameters(
        // consentDebugSettings: ConsentDebugSettings(
        //   debugGeography: DebugGeography.debugGeographyEea,
        //   testIdentifiers: ['YOUR-TEST-DEVICE-HASHED-ID'],
        // ),
        ),
    () async {
      // Success: now load & show if required (also callback-style)
      ConsentForm.loadAndShowConsentFormIfRequired((formError) async {
        if (formError != null) {
          debugPrint(
              'UMP form error: ${formError.errorCode}: ${formError.message}');
        }
        final canRequest = await consentInfo.canRequestAds();
        if (canRequest) {
          await _configureMobileAds();
          await gma.MobileAds.instance.initialize();
        }
        if (!completer.isCompleted) completer.complete();
      });
    },
    (err) async {
      // Failure path: you might still be allowed to request ads from prior consent
      debugPrint('Consent update error: ${err.errorCode}: ${err.message}');
      final canRequest = await consentInfo.canRequestAds();
      if (canRequest) {
        await _configureMobileAds();
        await gma.MobileAds.instance.initialize();
      }
      if (!completer.isCompleted) completer.complete();
    },
  );

  return completer.future;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    // dotenv is optional — tolerate missing file in release
    await dotenv.load(fileName: '.env').catchError((_) {});

    await Firebase.initializeApp();

    // ✅ App Check
    if (!_appCheckActivated) {
      await FirebaseAppCheck.instance.activate(
        androidProvider: kReleaseMode
            ? AndroidProvider.playIntegrity
            : AndroidProvider.debug,
        appleProvider: kReleaseMode
            ? AppleProvider.appAttestWithDeviceCheckFallback
            : AppleProvider.debug,
      );
      _appCheckActivated = true;
    }

    // ✅ Notifications permission (iOS prompt; Android no-op)
    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission();
    await messaging.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    // ✅ Gather consent first; if allowed, this will init Mobile Ads inside
    await _gatherConsentIfNeeded();
  } catch (e, stack) {
    // Don’t block startup if anything above fails
    debugPrint("🔥 Startup error: $e");
    debugPrint("$stack");
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    debugPrint("✅ MyApp is building...");
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primaryColor: const Color(0xFF567D46),
        colorScheme: ColorScheme.fromSwatch().copyWith(
          primary: const Color(0xFF567D46),
          secondary: const Color(0xFF365A38),
        ),
        textTheme: GoogleFonts.nunitoTextTheme(),
      ),
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          // Auth stream booting
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          // Logged in
          if (snapshot.hasData) {
            final user = snapshot.data!;
            if (!user.emailVerified) {
              return WaitForEmailVerificationScreen(user: user);
            }
            // Load profile minimal fields before home
            return FutureBuilder<DocumentSnapshot>(
              future: FirebaseFirestore.instance
                  .collection('owners')
                  .doc(user.uid)
                  .get(),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Scaffold(
                      body: Center(child: CircularProgressIndicator()));
                }
                if (snap.hasError) {
                  return const Scaffold(
                    body: Center(
                      child: Text(
                        'Oops—failed to load your profile. Please try again.',
                      ),
                    ),
                  );
                }
                final doc = snap.data;
                final data = (doc?.data() as Map<String, dynamic>?) ?? {};
                final hasFirst =
                    (data['firstName'] ?? '').toString().trim().isNotEmpty;
                final hasLast =
                    (data['lastName'] ?? '').toString().trim().isNotEmpty;
                final missingProfile =
                    (doc == null || !doc.exists) || !(hasFirst && hasLast);

                if (missingProfile) {
                  return OwnerDetailsScreen();
                }
                return const HomeScreen();
              },
            );
          }
          // Logged out
          return const ModernLoginScreen();
        },
      ),
      routes: {
        '/login': (context) => const ModernLoginScreen(),
        '/signup': (context) => SignupScreen(),
        '/profile': (context) => const HomeScreen(),
        '/accountCreation': (context) => AccountCreationScreen(),
        '/ownerDetails': (context) => OwnerDetailsScreen(),
        '/petDetails': (context) => AddPetScreen(),
        '/locationServiceChoice': (context) => LocationServiceChoiceScreen(),
        '/allsetup': (context) => AllSetUpScreen(),
        '/forgotPassword': (context) {
          final email = ModalRoute.of(context)?.settings.arguments as String?;
          return ForgotPasswordScreen(initialEmail: email);
        },
      },
    );
  }
}

class ModernLoginScreen extends StatefulWidget {
  const ModernLoginScreen({Key? key}) : super(key: key);

  @override
  State<ModernLoginScreen> createState() => _ModernLoginScreenState();
}

class _ModernLoginScreenState extends State<ModernLoginScreen> {
  final TextEditingController emailController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  StreamSubscription<String>? _tokenSub;

  bool _isLoading = false;

  @override
  void dispose() {
    _tokenSub?.cancel();
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  Future<void> _attemptLogin() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);

    try {
      await loginUsingEmailPassword(
        email: emailController.text.trim(),
        password: passwordController.text,
        context: context,
      );
      // If login navigates away, the setState below won't run (that's fine).
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> saveUserFcmToken(User user) async {
    final messaging = FirebaseMessaging.instance;
    try {
      final settings = await messaging.getNotificationSettings();
      if (settings.authorizationStatus.name == 'authorized' ||
          settings.authorizationStatus.name == 'provisional') {
        _tokenSub = messaging.onTokenRefresh.listen((token) async {
          await FirebaseFirestore.instance
              .collection('owners')
              .doc(user.uid)
              .set({'fcmToken': token}, SetOptions(merge: true));
        });

        final token = await messaging.getToken();
        if (token != null) {
          await FirebaseFirestore.instance
              .collection('owners')
              .doc(user.uid)
              .set({'fcmToken': token}, SetOptions(merge: true));
        }
      } else {
        debugPrint('User declined or has not accepted notification permission');
      }
    } catch (e) {
      debugPrint('FCM token error: $e');
    }
  }

  Future<User?> loginUsingEmailPassword({
    required String email,
    required String password,
    required BuildContext context,
  }) async {
    FirebaseAuth auth = FirebaseAuth.instance;
    User? user;
    try {
      final userCredential = await auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      user = userCredential.user;

      if (user != null) {
        await user.reload();
        if (!user.emailVerified) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Please verify your email before logging in."),
            ),
          );
          await FirebaseAuth.instance.signOut();
          return null;
        }

        final doc = await FirebaseFirestore.instance
            .collection('owners')
            .doc(user.uid)
            .get();
        final data = doc.data() ?? {};
        if (data['active'] == false) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                "Your account has been deactivated. Please contact support.",
              ),
            ),
          );
          await FirebaseAuth.instance.signOut();
          return null;
        }

        await saveUserFcmToken(user);

        if (!mounted) return user;
        Navigator.of(context).pushReplacementNamed('/profile');
      }
    } on FirebaseAuthException catch (e) {
      switch (e.code) {
        case "user-not-found":
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("No user found with this email.")),
          );
          break;
        case "wrong-password":
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Incorrect password.")),
          );
          break;
        default:
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Login error: ${e.message}")),
          );
      }
    }
    return user;
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    debugPrint("✅ ModernLoginScreen is building...");
    return Scaffold(
      body: Stack(
        children: [
          // Main content
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF567D46), Color(0xFF365A38)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Image.asset(
                      "assets/images/home_icon.png",
                      width: screenWidth / 3,
                    ),
                    const SizedBox(height: 20),
                    Text(
                      "Pet Calendar",
                      style: GoogleFonts.nunito(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 40),
                    TextField(
                      controller: emailController,
                      enabled: !_isLoading,
                      cursorColor: Colors.tealAccent,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: Colors.white.withOpacity(0.15),
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
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: passwordController,
                      enabled: !_isLoading,
                      obscureText: true,
                      cursorColor: Colors.tealAccent,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: Colors.white.withOpacity(0.15),
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
                      onSubmitted: (_) => _attemptLogin(), // enter-to-login
                      textInputAction: TextInputAction.done,
                    ),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerRight,
                      child: GestureDetector(
                        onTap: _isLoading
                            ? null
                            : () async {
                                final result = await Navigator.pushNamed(
                                  context,
                                  '/forgotPassword',
                                  arguments: emailController.text.trim(),
                                );
                                if (result is String && result.isNotEmpty) {
                                  setState(() {
                                    emailController.text = result;
                                  });
                                }
                              },
                        child: Text(
                          "Forgot password?",
                          style: GoogleFonts.nunito(
                            color: Colors.lightBlueAccent,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 30),
                    SizedBox(
                      width: MediaQuery.of(context).size.width / 2,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16.0),
                          backgroundColor: Colors.tealAccent,
                          foregroundColor: Colors.black,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          elevation: 5,
                        ),
                        onPressed: _isLoading ? null : _attemptLogin,
                        child: _isLoading
                            ? const SizedBox(
                                height: 22,
                                width: 22,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text("Log in",
                                style: TextStyle(fontSize: 18)),
                      ),
                    ),
                    const SizedBox(height: 20),
                    GestureDetector(
                      onTap: _isLoading
                          ? null
                          : () {
                              Navigator.pushNamed(context, '/accountCreation');
                            },
                      child: Text(
                        "Create New Account",
                        style: GoogleFonts.nunito(
                          fontSize: 16,
                          color: Colors.tealAccent,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Loading overlay
          if (_isLoading) ...[
            const ModalBarrier(dismissible: false, color: Colors.black38),
            const Center(child: CircularProgressIndicator()),
          ],
        ],
      ),
    );
  }
}
