import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
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

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kDebugMode, kReleaseMode;

// Ads SDK — hide UMP symbols to avoid name clashes with the standalone UMP package
import 'package:google_mobile_ads/google_mobile_ads.dart' as gma
    show MobileAds, RequestConfiguration, MaxAdContentRating;

import 'package:google_mobile_ads/google_mobile_ads.dart'
    show
        ConsentInformation,
        ConsentRequestParameters,
        ConsentForm,
        ConsentDebugSettings,
        DebugGeography,
        PrivacyOptionsRequirementStatus;

bool _appCheckActivated = false;

/// Ask/refresh user consent and show the UMP form when required (EEA/UK, etc.)
Future<void> _gatherConsentIfNeeded() async {
  final params = ConsentRequestParameters(
      // consentDebugSettings: ConsentDebugSettings(
      //   debugGeography: DebugGeography.debugGeographyEea,
      //   testIdentifiers: const ['YOUR-TEST-DEVICE-HASHED-ID'],
      // ),
      );

  ConsentInformation.instance.requestConsentInfoUpdate(
    params,
    () async {
      // Loads & shows a form if required; callback runs after dismissal
      ConsentForm.loadAndShowConsentFormIfRequired((formError) async {
        if (formError != null) {
          debugPrint(
              'UMP form error: ${formError.errorCode}: ${formError.message}');
        }
        final canRequest = await ConsentInformation.instance.canRequestAds();
        if (canRequest) {
          await _configureMobileAds();
          await gma.MobileAds.instance.initialize();
        }
      });
    },
    (err) async {
      debugPrint('Consent update error: ${err.errorCode}: ${err.message}');
      // Even on error, prior consent may allow ads:
      final canRequest = await ConsentInformation.instance.canRequestAds();
      if (canRequest) {
        await _configureMobileAds();
        await gma.MobileAds.instance.initialize();
      }
    },
  );
}

/// Configure Mobile Ads (test devices in debug, content rating, etc.)
Future<void> _configureMobileAds() async {
  await gma.MobileAds.instance.updateRequestConfiguration(
    gma.RequestConfiguration(
      testDeviceIds: kReleaseMode ? const <String>[] : const <String>[],
      maxAdContentRating: gma.MaxAdContentRating.pg,
      // Optionally set tagForChildDirectedTreatment / tagForUnderAgeOfConsent here if needed.
    ),
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await dotenv.load(fileName: '.env');

    await Firebase.initializeApp();

    // ✅ App Check: real in release, debug in dev/emulators
    if (!_appCheckActivated) {
      await FirebaseAppCheck.instance.activate(
        androidProvider: kReleaseMode
            ? AndroidProvider.playIntegrity
            : AndroidProvider.debug,
        // appleProvider: AppleProvider.appAttest, // if you also ship iOS
      );
      _appCheckActivated = true;
    }

    // Notifications permission (iOS prompt; Android no-op)
    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission();

    // ✅ Get consent BEFORE initializing ads
    await _gatherConsentIfNeeded();

    await _configureMobileAds();
    await gma.MobileAds.instance.initialize();
  } catch (e, stack) {
    // Don’t block app startup if anything above fails
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
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          if (snapshot.hasData) {
            final user = snapshot.data!;
            if (!user.emailVerified) {
              return WaitForEmailVerificationScreen(user: user);
            }
            return FutureBuilder<DocumentSnapshot>(
              future: FirebaseFirestore.instance
                  .collection('owners')
                  .doc(user.uid)
                  .get(),
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const Scaffold(
                      body: Center(child: CircularProgressIndicator()));
                }
                final doc = snap.data!;
                final data = doc.data() as Map<String, dynamic>? ?? {};
                final missingProfile = !doc.exists ||
                    !(data.containsKey('firstName') &&
                        data['firstName'] != null &&
                        data['firstName'].toString().trim().isNotEmpty) ||
                    !(data.containsKey('lastName') &&
                        data['lastName'] != null &&
                        data['lastName'].toString().trim().isNotEmpty);

                if (missingProfile) {
                  return OwnerDetailsScreen();
                }
                return const HomeScreen();
              },
            );
          }
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

  Future<void> saveUserFcmToken(User user) async {
    final messaging = FirebaseMessaging.instance;
    final settings = await messaging.requestPermission();
    if (settings.authorizationStatus == AuthorizationStatus.authorized) {
      // Listen for token refresh (also fires with current token once)
      messaging.onTokenRefresh.listen((token) async {
        await FirebaseFirestore.instance.collection('owners').doc(user.uid).set(
          {'fcmToken': token},
          SetOptions(merge: true),
        );
      });

      try {
        final token = await messaging.getToken();
        if (token != null) {
          await FirebaseFirestore.instance
              .collection('owners')
              .doc(user.uid)
              .set(
            {'fcmToken': token},
            SetOptions(merge: true),
          );
        }
      } catch (e) {
        debugPrint('FCM token error: $e');
      }
    } else {
      debugPrint('User declined or has not accepted notification permission');
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
      UserCredential userCredential = await auth.signInWithEmailAndPassword(
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
        if (data.containsKey('active') && data['active'] == false) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                "Your account has been deactivated. Please contact support .",
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
      if (e.code == "user-not-found") {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("No user found with this email.")),
        );
      } else if (e.code == "wrong-password") {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Incorrect password.")),
        );
      } else {
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
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: passwordController,
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
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: GestureDetector(
                    onTap: () async {
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
                    onPressed: () async {
                      await loginUsingEmailPassword(
                        email: emailController.text,
                        password: passwordController.text,
                        context: context,
                      );
                    },
                    child: const Text("Log in", style: TextStyle(fontSize: 18)),
                  ),
                ),
                const SizedBox(height: 15),
                const SizedBox(height: 15),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    // Social buttons (if you re-enable later)
                  ],
                ),
                const SizedBox(height: 20),
                GestureDetector(
                  onTap: () {
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
    );
  }
}
