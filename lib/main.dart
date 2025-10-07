// main.dart

import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

// Google Mobile Ads (alias to avoid UMP symbol clashes)
import 'package:google_mobile_ads/google_mobile_ads.dart' as gma
    show MobileAds, RequestConfiguration, MaxAdContentRating;

// UMP (User Messaging Platform) classes (un-aliased)
import 'package:google_mobile_ads/google_mobile_ads.dart'
    show
        ConsentInformation,
        ConsentRequestParameters,
        ConsentForm,
        ConsentDebugSettings,
        DebugGeography;

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

bool _appCheckActivated = false;

/// Configure Mobile Ads (test devices in debug, content rating, etc.)
Future<void> _configureMobileAds() async {
  await gma.MobileAds.instance.updateRequestConfiguration(
    gma.RequestConfiguration(
      testDeviceIds: kReleaseMode ? const <String>[] : const <String>[],
      maxAdContentRating: gma.MaxAdContentRating.pg,
    ),
  );
}

Future<void> _gatherConsentIfNeeded() async {
  final completer = Completer<void>();
  final consentInfo = ConsentInformation.instance;

  consentInfo.requestConsentInfoUpdate(
    ConsentRequestParameters(
        // For testing:
        // consentDebugSettings: ConsentDebugSettings(
        //   debugGeography: DebugGeography.debugGeographyEea,
        //   testIdentifiers: ['YOUR-TEST-DEVICE-HASHED-ID'],
        // ),
        ),
    () async {
      ConsentForm.loadAndShowConsentFormIfRequired((formError) async {
        if (formError != null) {
          print(
              '🟠 UMP form error: ${formError.errorCode}: ${formError.message}');
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
      print('🟠 Consent update error: ${err.errorCode}: ${err.message}');
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

    // ✅ Ads consent
    await _gatherConsentIfNeeded();
  } catch (e, stack) {
    print("🔥 Startup error: $e");
    print("$stack");
  }

  // 🔐 Hard gate BEFORE building your app
  runApp(UpdateGateRoot(
    appBuilder: (context) => const MyApp(),
  ));
}

/// ───────────────────────────────────────────────────────────────────────────
/// Your app
/// ───────────────────────────────────────────────────────────────────────────

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    print("✅ MyApp.build");
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

      // Optional: keep a soft-update banner inside the app as well
      builder: (context, child) => _SoftUpdateBanner(child: child),

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

/// ───────────────────────────────────────────────────────────────────────────
/// HARD gate: blocks the app if build < min_supported_build
/// (Runs BEFORE your app builds; prints diagnostics)
/// ───────────────────────────────────────────────────────────────────────────

class UpdateGateRoot extends StatefulWidget {
  final WidgetBuilder appBuilder;
  const UpdateGateRoot({super.key, required this.appBuilder});

  @override
  State<UpdateGateRoot> createState() => _UpdateGateRootState();
}

class _UpdateGateRootState extends State<UpdateGateRoot> {
  bool _checking = true;
  bool _force = false;
  bool _soft = false;
  String _msg = 'Please update the app';
  String? _url; // iOS App Store URL

  @override
  void initState() {
    super.initState();
    _check();
  }

  int _getInt(FirebaseRemoteConfig rc, String base) {
    final unified = rc.getValue(base);
    if (unified.source != ValueSource.valueDefault) return unified.asInt();
    return rc.getInt('${base}_ios'); // fallback if you created *_ios keys
  }

  String _getStr(FirebaseRemoteConfig rc, String base) {
    final unified = rc.getValue(base);
    if (unified.source != ValueSource.valueDefault) {
      return unified.asString().trim();
    }
    return rc.getString('${base}_ios').trim();
  }

  Future<void> _check() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final currentBuild = int.tryParse(info.buildNumber) ?? 0;

      final rc = FirebaseRemoteConfig.instance;
      await rc.setConfigSettings(RemoteConfigSettings(
        fetchTimeout: const Duration(seconds: 10),
        minimumFetchInterval:
            kReleaseMode ? const Duration(minutes: 30) : Duration.zero,
      ));
      await rc.setDefaults(const {
        'min_supported_build': 0,
        'recommended_build': 0,
        'latest_store_url': '',
        'update_message': 'Please update the app',
        // Optional fallbacks if you kept ios-suffixed params:
        'min_supported_build_ios': 0,
        'recommended_build_ios': 0,
        'latest_store_url_ios': '',
        'update_message_ios': 'Please update the app',
      });

      final fetched = await rc.fetchAndActivate();

      print('🔧 projectId: ${Firebase.app().options.projectId}');
      print('🔧 fetched=$fetched lastFetch=${rc.lastFetchTime}');

      final minBuild = _getInt(rc, 'min_supported_build');
      final recBuild = _getInt(rc, 'recommended_build');
      final url = _getStr(rc, 'latest_store_url');
      final msg = _getStr(rc, 'update_message');

      print('🔧 buildNumber(current)=$currentBuild');
      print('🔧 values -> min=$minBuild rec=$recBuild url="$url" msg="$msg"');

      final force = currentBuild < minBuild;
      final soft = !force && currentBuild < recBuild;

      setState(() {
        _checking = false;
        _force = force;
        _soft = soft;
        _url = url.isEmpty ? null : url;
        _msg = msg.isEmpty ? _msg : msg;
      });

      print('🔧 computed -> force=$_force soft=$_soft url=$_url');
    } catch (e, st) {
      print('⚠️ UpdateGateRoot error: $e\n$st');
      setState(() => _checking = false); // fail-open on RC error
    }
  }

  Future<void> _openStore() async {
    if (Platform.isIOS) {
      if (_url == null) return;
      final itms = Uri.parse(_url!.replaceFirst('https://', 'itms-apps://'));
      final https = Uri.parse(_url!);
      if (await canLaunchUrl(itms)) {
        await launchUrl(itms, mode: LaunchMode.externalApplication);
      } else {
        await launchUrl(https, mode: LaunchMode.externalApplication);
      }
      return;
    }
    final pkg = (await PackageInfo.fromPlatform()).packageName;
    final market = Uri.parse('market://details?id=$pkg');
    final web = Uri.parse('https://play.google.com/store/apps/details?id=$pkg');
    if (await canLaunchUrl(market)) {
      await launchUrl(market, mode: LaunchMode.externalApplication);
    } else {
      await launchUrl(web, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const MaterialApp(
        home: Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }
    if (_force) {
      return MaterialApp(
        home: _ForceUpdateScreen(message: _msg, onUpdate: _openStore),
      );
    }
    // Pass-through to your real app (soft banner handled inside MyApp)
    return widget.appBuilder(context);
  }
}

/// ───────────────────────────────────────────────────────────────────────────
/// SOFT banner inside your app (non-blocking)
/// ───────────────────────────────────────────────────────────────────────────

class _SoftUpdateBanner extends StatefulWidget {
  final Widget? child;
  const _SoftUpdateBanner({this.child});

  @override
  State<_SoftUpdateBanner> createState() => _SoftUpdateBannerState();
}

class _SoftUpdateBannerState extends State<_SoftUpdateBanner> {
  bool _show = false;
  String _message = 'A new version is available.';
  String? _url;

  int _getInt(FirebaseRemoteConfig rc, String base) {
    final unified = rc.getValue(base);
    if (unified.source != ValueSource.valueDefault) return unified.asInt();
    return rc.getInt('${base}_ios');
  }

  String _getStr(FirebaseRemoteConfig rc, String base) {
    final unified = rc.getValue(base);
    if (unified.source != ValueSource.valueDefault) {
      return unified.asString().trim();
    }
    return rc.getString('${base}_ios').trim();
  }

  @override
  void initState() {
    super.initState();
    _checkSoft();
  }

  Future<void> _checkSoft() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final currentBuild = int.tryParse(info.buildNumber) ?? 0;

      final rc = FirebaseRemoteConfig.instance;
      await rc.setConfigSettings(RemoteConfigSettings(
        fetchTimeout: const Duration(seconds: 10),
        minimumFetchInterval:
            kReleaseMode ? const Duration(minutes: 30) : Duration.zero,
      ));

      // Do NOT need to setDefaults again (already set in root), but it's fine if you do:
      // await rc.setDefaults(...);

      await rc.fetchAndActivate();

      final recBuild = _getInt(rc, 'recommended_build');
      final url = _getStr(rc, 'latest_store_url');
      final msg = _getStr(rc, 'update_message');

      final soft = currentBuild < recBuild;

      if (!mounted) return;
      setState(() {
        _show = soft && url.isNotEmpty;
        _url = url.isEmpty ? null : url;
        _message = msg.isEmpty ? _message : msg;
      });

      print('🔔 softBanner -> current=$currentBuild rec=$recBuild show=$_show');
    } catch (e) {
      // ignore banner errors
    }
  }

  Future<void> _openStore() async {
    if (_url == null) return;
    final uri = Uri.parse(_url!);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.child ?? const SizedBox.shrink();
    if (!_show) return child;

    return Stack(
      children: [
        child,
        SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: Material(
              elevation: 6,
              color: Colors.orange.shade700,
              borderRadius:
                  const BorderRadius.vertical(bottom: Radius.circular(12)),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.system_update, color: Colors.white),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        _message,
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 12),
                    TextButton(
                      onPressed: _openStore,
                      child: const Text('Update',
                          style: TextStyle(color: Colors.white)),
                    ),
                    TextButton(
                      onPressed: () => setState(() => _show = false),
                      child: const Text('Later',
                          style: TextStyle(color: Colors.white70)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// ───────────────────────────────────────────────────────────────────────────
/// Shared Force Update screen
/// ───────────────────────────────────────────────────────────────────────────

class _ForceUpdateScreen extends StatelessWidget {
  final String message;
  final VoidCallback onUpdate;
  const _ForceUpdateScreen({required this.message, required this.onUpdate});

  @override
  Widget build(BuildContext context) {
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
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Card(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              margin: const EdgeInsets.all(24),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.system_update, size: 64),
                    const SizedBox(height: 12),
                    Text('Update Required',
                        style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(height: 8),
                    Text(
                      message,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 16),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: onUpdate,
                        child: const Text('Update Now'),
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
}

/// ───────────────────────────────────────────────────────────────────────────
/// Your login screen (unchanged except for context here)
/// ───────────────────────────────────────────────────────────────────────────

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
        print('🔕 Notifications permission not granted');
      }
    } catch (e) {
      print('🟠 FCM token error: $e');
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
        case "wrong-password":
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Incorrect password.")),
          );
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
    print("✅ ModernLoginScreen.build");
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
                      "Connect, Play, Explore",
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
                      onSubmitted: (_) => _attemptLogin(),
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

          if (_isLoading) ...[
            const ModalBarrier(dismissible: false, color: Colors.black38),
            const Center(child: CircularProgressIndicator()),
          ],
        ],
      ),
    );
  }
}
