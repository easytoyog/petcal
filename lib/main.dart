// main.dart

import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

// Badge
import 'package:app_badge_plus/app_badge_plus.dart';

// ATT
import 'package:app_tracking_transparency/app_tracking_transparency.dart';

// Google Mobile Ads (alias to avoid UMP symbol clashes)
import 'package:google_mobile_ads/google_mobile_ads.dart' as gma
    show MobileAds, RequestConfiguration, MaxAdContentRating;

// UMP (User Messaging Platform) classes
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

// ✅ DM screen route (adjust import path if yours differs)
import 'package:inthepark/screens/dm_chat_screen.dart';

// Saves tz + dailyStepsOptIn + updatedAt
import 'package:inthepark/services/notification_prefs.dart';

// ✅ NEW: push/local notifications helper you created
import 'package:inthepark/services/push_notifications.dart';

bool _appCheckActivated = false;
final RouteObserver<PageRoute> routeObserver = RouteObserver<PageRoute>();

final ValueNotifier<String?> currentRouteName = ValueNotifier<String?>('/');

class RouteNameObserver extends RouteObserver<PageRoute<dynamic>> {
  void _set(Route<dynamic>? route) {
    if (route is PageRoute) {
      currentRouteName.value = route.settings.name;
    }
  }

  @override
  void didPush(Route route, Route? previousRoute) {
    _set(route);
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    _set(previousRoute);
    super.didPop(route, previousRoute);
  }

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) {
    _set(newRoute);
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }
}

final routeNameObserver = RouteNameObserver();

/// ✅ Global navigator key (needed for notification tap -> open DM)
final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

/// Configure Mobile Ads (test devices in debug, content rating, etc.)
Future<void> _configureMobileAds() async {
  await gma.MobileAds.instance.updateRequestConfiguration(
    gma.RequestConfiguration(
      testDeviceIds: kReleaseMode ? const <String>[] : const <String>[],
      maxAdContentRating: gma.MaxAdContentRating.pg,
    ),
  );
}

Future<void> _requestATTIfNeeded() async {
  if (!Platform.isIOS) return;
  try {
    final status = await AppTrackingTransparency.trackingAuthorizationStatus;
    if (status == TrackingStatus.notDetermined) {
      await AppTrackingTransparency.requestTrackingAuthorization();
    }
  } catch (_) {}
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
          // ignore; canRequestAds might still be true
          // print('🟠 UMP form error: ${formError.errorCode}: ${formError.message}');
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
      // print('🟠 Consent update error: ${err.errorCode}: ${err.message}');
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

Future<void> _ensureFcmTokenPersistenceForSignedInUser() async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return;

  final messaging = FirebaseMessaging.instance;

  // Save current token
  final token = await messaging.getToken();
  if (token != null) {
    await FirebaseFirestore.instance
        .collection('owners')
        .doc(user.uid)
        .set({'fcmToken': token}, SetOptions(merge: true));
  }

  // Keep it updated
  messaging.onTokenRefresh.listen((t) async {
    await FirebaseFirestore.instance
        .collection('owners')
        .doc(user.uid)
        .set({'fcmToken': t}, SetOptions(merge: true));
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await dotenv.load(fileName: '.env').catchError((_) {});
    await Firebase.initializeApp();

    await _requestATTIfNeeded();

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

    // ✅ Notifications permission
    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission();
    await messaging.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    // Persist FCM token if signed in
    await _ensureFcmTokenPersistenceForSignedInUser();

    // ✅ NEW: init push + local notifications (foreground + tap-to-open)
    await initPushNotifications(navigatorKey: navKey);

    // ✅ Ads consent
    await _gatherConsentIfNeeded();

    // If already signed-in at launch, save tz + opt-in
    final existing = FirebaseAuth.instance.currentUser;
    if (existing != null) {
      await upsertNotificationPrefs();
    }
  } catch (e, stack) {
    // fail-open; don't block app boot
    // print("🔥 Startup error: $e");
    // print("$stack");
  }

  runApp(UpdateGateRoot(
    appBuilder: (context) => const MyApp(),
  ));
}

/// ───────────────────────────────────────────────────────────────────────────
/// Your app
/// ───────────────────────────────────────────────────────────────────────────

class MyApp extends StatefulWidget {
  const MyApp({Key? key}) : super(key: key);
  @override
  State<MyApp> createState() => _MyAppState();
}

// Badge clearer: clear on launch and whenever the app resumes
class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppBadgePlus.updateBadge(0);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      AppBadgePlus.updateBadge(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navKey, // ✅ REQUIRED for notification tap navigation
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primaryColor: const Color(0xFF567D46),
        colorScheme: ColorScheme.fromSwatch().copyWith(
          primary: const Color(0xFF567D46),
          secondary: const Color(0xFF365A38),
        ),
        textTheme: GoogleFonts.nunitoTextTheme(),
      ),
      navigatorObservers: [routeNameObserver],
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

        // ✅ NEW: DM route used by push_notifications.dart
        '/dm': (context) {
          final args = ModalRoute.of(context)?.settings.arguments
              as Map<String, dynamic>?;
          final otherUserId = (args?['otherUserId'] ?? '').toString();
          final otherDisplayName =
              (args?['otherDisplayName'] ?? 'Message').toString();
          return DmChatScreen(
            otherUserId: otherUserId,
            otherDisplayName: otherDisplayName,
          );
        },
      },
    );
  }
}

/// ───────────────────────────────────────────────────────────────────────────
/// HARD gate: blocks the app if build < min_supported_build
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
  String _msg = 'Please update the app';
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
    _check();
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
        'min_supported_build_ios': 0,
        'recommended_build_ios': 0,
        'latest_store_url_ios': '',
        'update_message_ios': 'Please update the app',
      });

      await rc.fetchAndActivate();

      final minBuild = _getInt(rc, 'min_supported_build');
      final url = _getStr(rc, 'latest_store_url');
      final msg = _getStr(rc, 'update_message');

      final force = currentBuild < minBuild;

      setState(() {
        _checking = false;
        _force = force;
        _url = url.isEmpty ? null : url;
        _msg = msg.isEmpty ? _msg : msg;
      });
    } catch (_) {
      setState(() => _checking = false); // fail-open
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
    return widget.appBuilder(context);
  }
}

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
/// Login (unchanged from your version; kept intact)
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

  InputDecoration _decoration({
    required String hint,
    required IconData icon,
    double fillOpacity = 0.15,
  }) {
    return InputDecoration(
      filled: true,
      fillColor: Colors.white.withOpacity(fillOpacity),
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.white70),
      prefixIcon: Icon(icon, color: Colors.white),
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

  Future<void> _attemptLogin() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);

    try {
      await _loginUsingEmailPassword(
        email: emailController.text.trim(),
        password: passwordController.text,
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _saveUserFcmToken(User user) async {
    final messaging = FirebaseMessaging.instance;
    try {
      final settings = await messaging.getNotificationSettings();
      if (settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional) {
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
      }
    } catch (_) {}
  }

  Future<User?> _loginUsingEmailPassword({
    required String email,
    required String password,
  }) async {
    final auth = FirebaseAuth.instance;
    try {
      final cred = await auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      final user = cred.user;
      if (user == null) return null;

      await user.reload();
      if (!user.emailVerified) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text("Please verify your email before logging in.")),
          );
        }
        await auth.signOut();
        return null;
      }

      final doc = await FirebaseFirestore.instance
          .collection('owners')
          .doc(user.uid)
          .get();
      final data = doc.data() ?? {};
      if (data['active'] == false) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  "Your account has been deactivated. Please contact support."),
            ),
          );
        }
        await auth.signOut();
        return null;
      }

      await _saveUserFcmToken(user);
      await upsertNotificationPrefs();

      if (mounted) {
        Navigator.of(context).pushReplacementNamed('/profile');
      }
      return user;
    } on FirebaseAuthException catch (e) {
      if (!mounted) rethrow;
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
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;

    return Scaffold(
      body: Stack(
        children: [
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
                  children: [
                    Image.asset("assets/images/home_icon.png",
                        width: screenWidth / 3),
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
                      decoration: _decoration(hint: "Email", icon: Icons.mail),
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: passwordController,
                      enabled: !_isLoading,
                      obscureText: true,
                      enableSuggestions: false,
                      cursorColor: Colors.tealAccent,
                      style: const TextStyle(color: Colors.white),
                      decoration:
                          _decoration(hint: "Password", icon: Icons.lock),
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _attemptLogin(),
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
                                  setState(() => emailController.text = result);
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
                              borderRadius: BorderRadius.circular(12)),
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
                          : () =>
                              Navigator.pushNamed(context, '/accountCreation'),
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
