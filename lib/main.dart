import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
// import 'package:google_sign_in/google_sign_in.dart';
// import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:inthepark/screens/profile_screen.dart';
import 'package:inthepark/screens/signup_screen.dart';
import 'package:inthepark/screens/account_creation_screen.dart';
import 'package:inthepark/screens/owner_detail_screen.dart';
import 'package:inthepark/screens/pet_detail_screen.dart';
import 'package:inthepark/screens/location_service_choice.dart';
import 'package:inthepark/screens/allsetup.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:inthepark/screens/forgot_password_screen.dart';
import 'package:inthepark/screens/wait_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    print("🟡 Loading .env");
    await dotenv.load(fileName: '.env');

    print("🟡 Initializing Firebase");
    await Firebase.initializeApp();

    print("🟢 Firebase initialized");

    FirebaseMessaging messaging = FirebaseMessaging.instance;
    await messaging.requestPermission();
    print("🟢 Firebase messaging initialized");

    await FirebaseAppCheck.instance.activate(
      androidProvider: AndroidProvider.debug,
      appleProvider: AppleProvider.debug,
    );

    print("🟢 AppCheck initialized");

    await MobileAds.instance.initialize();
    print("🟢 Mobile Ads initialized");
  } catch (e, stack) {
    print("🔥 Firebase init failed: $e");
    print(stack);
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    print("✅ MyApp is building...");
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
      // Instead of initialRoute, we use the home property with a StreamBuilder.
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          // Show a loading indicator while waiting for auth state.
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          // If user is logged in, navigate to HomeScreen.
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
          // Otherwise, show the login screen.
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
      // Listen for token refresh (works for initial token too)
      messaging.onTokenRefresh.listen((token) async {
        await FirebaseFirestore.instance.collection('owners').doc(user.uid).set(
          {'fcmToken': token},
          SetOptions(merge: true),
        );
      });

      // Try to get the token immediately, but ignore errors
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
        print('FCM token error: $e');
        // Optionally show a SnackBar or ignore
      }
    } else {
      print('User declined or has not accepted notification permission');
    }
  }

  // Google Sign-In (commented out)
  // Future<User?> signInWithGoogle() async {
  //   FirebaseAuth auth = FirebaseAuth.instance;
  //   final GoogleSignIn googleSignIn = GoogleSignIn();
  //   try {
  //     final GoogleSignInAccount? googleUser = await googleSignIn.signIn();
  //     if (googleUser != null) {
  //       final GoogleSignInAuthentication googleAuth =
  //           await googleUser.authentication;
  //       final OAuthCredential credential = GoogleAuthProvider.credential(
  //         accessToken: googleAuth.accessToken,
  //         idToken: googleAuth.idToken,
  //       );
  //       final UserCredential userCredential =
  //           await auth.signInWithCredential(credential);
  //       final user = userCredential.user;
  //       if (user != null) {
  //         await saveUserFcmToken(user);
  //         Navigator.of(context).pushReplacementNamed('/profile');
  //       }
  //       return user;
  //     }
  //   } catch (e) {
  //     ScaffoldMessenger.of(context).showSnackBar(
  //       SnackBar(content: Text("Google sign-in error: $e")),
  //     );
  //   }
  //   return null;
  // }

  // Apple Sign-In (commented out)
  // Future<User?> signInWithApple() async {
  //   FirebaseAuth auth = FirebaseAuth.instance;
  //   try {
  //     final AuthorizationCredentialAppleID appleCredential =
  //         await SignInWithApple.getAppleIDCredential(
  //       scopes: [
  //         AppleIDAuthorizationScopes.email,
  //         AppleIDAuthorizationScopes.fullName
  //       ],
  //     );
  //     final OAuthCredential credential = OAuthProvider("apple.com").credential(
  //       idToken: appleCredential.identityToken,
  //       accessToken: appleCredential.authorizationCode,
  //     );
  //     final UserCredential userCredential =
  //         await auth.signInWithCredential(credential);
  //     final user = userCredential.user;
  //     if (user != null) {
  //       await saveUserFcmToken(user);
  //       Navigator.of(context).pushReplacementNamed('/profile');
  //     }
  //     return user;
  //   } catch (e) {
  //     ScaffoldMessenger.of(context).showSnackBar(
  //       SnackBar(content: Text("Apple sign-in error: $e")),
  //     );
  //     return null;
  //   }
  // }

  // Email/Password login
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
        await user.reload(); // Refresh user info
        if (!user.emailVerified) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text("Please verify your email before logging in.")),
          );
          await FirebaseAuth.instance.signOut();
          return null;
        }
        // Check if user is active in Firestore
        final doc = await FirebaseFirestore.instance
            .collection('owners')
            .doc(user.uid)
            .get();
        final data = doc.data() as Map<String, dynamic>? ?? {};
        if (data.containsKey('active') && data['active'] == false) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  "Your account has been deactivated. Please contact support ."),
            ),
          );
          await FirebaseAuth.instance.signOut();
          return null;
        }
        await saveUserFcmToken(user);
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
    print("✅ ModernLoginScreen is building...");
    return Scaffold(
      // resizeToAvoidBottomInset: true, // (default is true)
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
                  cursorColor: Colors.tealAccent, // <-- Add this line
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
                  cursorColor: Colors.tealAccent, // <-- Add this line
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
                //   Text(
                //     "Or sign in with",
                //     style: GoogleFonts.nunito(color: Colors.white54, fontSize: 14),
                //   ),
                const SizedBox(height: 15),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Social login buttons (commented out)
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
