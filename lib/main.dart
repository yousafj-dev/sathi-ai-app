import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:webview_flutter/webview_flutter.dart';

/// Rozana tips (Roman Urdu) — roz subah 9 baje notification me ek tip.
const List<String> _dailyTips = [
  'Mushkil sawal ko chhote hisson me todo — Sathi AI se step-by-step samjho.',
  'Roz 25 minute focus parhai, 3 ghante ki rattu se behtar hai.',
  'CV me skills actions me likho — "mehnati" nahi, "project waqt par complete kiya".',
  'Roz 5 naye English lafz seekho aur unhe jumlon me istemal karo.',
  'Jo baat kisi ko samjha sako, wo hamesha yaad rehti hai — parh kar dost ko samjhao.',
  'Interview me jawab short aur confident do — lambi gol baatein bore karti hain.',
  'Subah ka 1 ghanta raat ke 3 ghanton ke barabar hota hai — jaldi utho!',
];

final FlutterLocalNotificationsPlugin _notifications =
    FlutterLocalNotificationsPlugin();

Future<void> _initNotifications() async {
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  await _notifications
      .initialize(const InitializationSettings(android: androidInit));
  tzdata.initializeTimeZones();
  tz.setLocalLocation(tz.getLocation('Asia/Karachi'));
}

/// Roz subah 9 baje ka tip schedule karo (permission mile to).
Future<void> _scheduleDailyTip() async {
  try {
    var status = await Permission.notification.status;
    if (!status.isGranted) {
      status = await Permission.notification.request();
    }
    if (!status.isGranted) return;

    final dayOfYear = DateTime.now()
        .difference(DateTime(DateTime.now().year, 1, 1))
        .inDays;
    final tip = _dailyTips[dayOfYear % _dailyTips.length];

    final now = tz.TZDateTime.now(tz.local);
    final scheduled = tz.TZDateTime(tz.local, now.year, now.month, now.day, 9);

    await _notifications.zonedSchedule(
      1001,
      'Sathi AI ka aaj ka tip 💡',
      tip,
      scheduled,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'sathi_daily_tips',
          'Rozana Tips',
          channelDescription: 'Har subah Sathi AI ka helpful tip',
          importance: Importance.high,
        ),
      ),
      // inexact = no special exact-alarm permission needed
      androidScheduleMode: AndroidScheduleMode.inexact,
      matchDateTimeComponents: DateTimeComponents.time,
    );
  } catch (_) {
    // Notifications optional hain — fail ho to app par asar nahi.
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _initNotifications();
  runApp(const SathiAIApp());
}

class SathiAIApp extends StatelessWidget {
  const SathiAIApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sathi AI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6D28D9)),
        useMaterial3: true,
      ),
      home: const SathiWebView(),
    );
  }
}

class SathiWebView extends StatefulWidget {
  const SathiWebView({super.key});

  @override
  State<SathiWebView> createState() => _SathiWebViewState();
}

class _SathiWebViewState extends State<SathiWebView> {
  late final WebViewController _controller;
  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();
  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _connSub;

  bool _isLoading = true;
  bool _isOffline = false;
  bool _speechReady = false;
  String? _speechLocale;

  @override
  void initState() {
    super.initState();
    _initTts();
    _initWebView();
    _initConnectivity();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleDailyTip());
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _tts.stop();
    super.dispose();
  }

  // ---------------- WebView + JS channels ----------------

  void _initWebView() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF0A0A28))
      ..addJavaScriptChannel('SathiVoice',
          onMessageReceived: _onVoiceMessage)
      ..addJavaScriptChannel('SathiTts', onMessageReceived: _onTtsMessage)
      ..addJavaScriptChannel('SathiShare',
          onMessageReceived: _onShareMessage)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (mounted) setState(() => _isLoading = false);
          },
        ),
      )
      ..loadFlutterAsset('assets/www/index.html');
  }

  // ---------------- Voice input (native speech-to-text) ----------------

  Future<void> _onVoiceMessage(JavaScriptMessage message) async {
    if (message.message != 'start') return;

    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Mic ki ijazat nahi mili — Settings me ja kar Microphone allow karein.'),
        ),
      );
      return;
    }

    if (!_speechReady) {
      _speechReady = await _speech.initialize(
        onStatus: _onSpeechStatus,
        onError: (_) => _setMicUi(false),
      );
      if (_speechReady && _speechLocale == null) {
        try {
          final locales = await _speech.locales();
          final urdu = locales
              .where(
                  (l) => l.localeId.toLowerCase().startsWith('ur'))
              .toList();
          if (urdu.isNotEmpty) _speechLocale = urdu.first.localeId;
        } catch (_) {}
      }
    }

    if (!_speechReady) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Voice input is waqt kaam nahi kar raha.')),
      );
      return;
    }

    _setMicUi(true);
    await _speech.listen(
      onResult: (result) {
        if (result.finalResult && result.recognizedWords.isNotEmpty) {
          _setInputText(result.recognizedWords);
        }
      },
      localeId: _speechLocale,
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 4),
    );
  }

  void _onSpeechStatus(String status) {
    if (status == 'done' || status == 'notListening') {
      _setMicUi(false);
    }
  }

  void _setMicUi(bool listening) {
    _controller.runJavaScript(listening
        ? "window.__sathiMicState && window.__sathiMicState('listening')"
        : "window.__sathiMicState && window.__sathiMicState('idle')");
  }

  void _setInputText(String text) {
    final jsText = jsonEncode(text); // safe JS string literal
    _controller.runJavaScript(
        "window.__sathiSetInput && window.__sathiSetInput($jsText)");
  }

  // ---------------- Listen to replies (native TTS) ----------------

  Future<void> _initTts() async {
    await _tts.setSpeechRate(0.95);
    try {
      await _tts.setLanguage('ur-PK');
    } catch (_) {
      // Device par Urdu voice na ho to default voice use hogi.
    }
    _tts.setCompletionHandler(() {
      _controller.runJavaScript(
        "document.querySelectorAll('[data-listen].playing').forEach("
        "function(b){b.classList.remove('playing');b.textContent='▷ Sunno';});",
      );
    });
  }

  Future<void> _onTtsMessage(JavaScriptMessage message) async {
    final text = message.message;
    if (text == '__STOP__') {
      await _tts.stop();
      return;
    }
    if (text.trim().isEmpty) return;
    await _tts.stop();
    await _tts.speak(text);
  }

  // ---------------- Native share ----------------

  void _onShareMessage(JavaScriptMessage message) {
    final text = message.message.trim();
    if (text.isEmpty) return;
    Share.share(text, subject: 'Sathi AI');
  }

  // ---------------- Offline handling ----------------

  Future<void> _initConnectivity() async {
    final results = await _connectivity.checkConnectivity();
    _updateOffline(results);
    _connSub = _connectivity.onConnectivityChanged.listen(_updateOffline);
  }

  void _updateOffline(List<ConnectivityResult> results) {
    final offline =
        results.isEmpty || results.every((r) => r == ConnectivityResult.none);
    if (mounted && offline != _isOffline) {
      setState(() => _isOffline = offline);
    }
  }

  Future<void> _retryConnection() async {
    final results = await _connectivity.checkConnectivity();
    final offline =
        results.isEmpty || results.every((r) => r == ConnectivityResult.none);
    if (!mounted) return;
    if (offline) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Abhi bhi internet nahi hai.')),
      );
      return;
    }
    setState(() => _isOffline = false);
    _controller.reload();
  }

  // ---------------- Back button ----------------

  Future<bool> _onBackPressed() async {
    if (await _controller.canGoBack()) {
      _controller.goBack();
      return false;
    }
    SystemNavigator.pop();
    return false;
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _onBackPressed();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0A0A28),
        body: SafeArea(
          child: Stack(
            children: [
              WebViewWidget(controller: _controller),
              if (_isLoading && !_isOffline) _buildSplash(),
              if (_isOffline) _buildOfflineScreen(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSplash() {
    return Container(
      color: const Color(0xFF0A0A28),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: Image.asset(
                'assets/logo.webp',
                width: 110,
                height: 110,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Sathi AI',
              style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Your Personal AI',
              style: TextStyle(
                color: Color(0xFFB39DDB),
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 32),
            const CircularProgressIndicator(
              color: Color(0xFF9D4EDD),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOfflineScreen() {
    return Container(
      color: const Color(0xFF0A0A28),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wifi_off,
                  size: 72, color: Color(0xFF9D4EDD)),
              const SizedBox(height: 20),
              const Text(
                'Internet nahi hai',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'AI chat ke liye internet zaroori hai.',
                textAlign: TextAlign.center,
                style:
                    TextStyle(color: Color(0xFFB39DDB), fontSize: 15),
              ),
              const SizedBox(height: 28),
              ElevatedButton.icon(
                onPressed: _retryConnection,
                icon: const Icon(Icons.refresh),
                label: const Text('Dobara koshish karo'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF7C3AED),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 28, vertical: 14),
                ),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => setState(() => _isOffline = false),
                child: const Text(
                  'Offline kholo (limited)',
                  style: TextStyle(color: Color(0xFFB39DDB)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
