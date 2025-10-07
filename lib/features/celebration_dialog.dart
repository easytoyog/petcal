import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:confetti/confetti.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

class CelebrationDialog extends StatefulWidget {
  final int steps;
  final String kmText;

  /// Keep passing this in; if it's empty we'll use a built-in fallback.
  final List<String> encouragements;

  /// Optional: a public URL that represents the completed walk (landing page / dynamic link).
  final String? shareUrl;

  /// NEW: streak details to show inside the dialog
  final int? streakCurrent;
  final int? streakLongest;
  final bool streakIsNewRecord;

  const CelebrationDialog({
    Key? key,
    required this.steps,
    required this.kmText,
    required this.encouragements,
    this.shareUrl,
    this.streakCurrent,
    this.streakLongest,
    this.streakIsNewRecord = false,
  }) : super(key: key);

  @override
  State<CelebrationDialog> createState() => _CelebrationDialogState();
}

class _CelebrationDialogState extends State<CelebrationDialog> {
  late final ConfettiController _controller;
  final Random _rand = Random();

  // Headlines + fallback encouragements
  static const List<String> _headlines = [
    "Paws up! You and your pup crushed it! 🐾",
    "Walkies complete — tails are wagging! 🎯",
    "Another lap, another clap! 👏",
    "That was pawsitively awesome! ✨",
    "Steps smashed. Treats deserved. 🍪",
    "Leashes up, victory achieved! 🏅",
    "Stride pride activated! 💪",
    "Fetch the bragging rights — you earned them! 🥳",
    "You two just owned that route! 🗺️",
    "More sniffing, less sitting — nailed it! 🐶",
    "Miles + smiles: mission accomplished. 😄",
    "You walked the walk. Literally. 🚶‍♂️🐕",
    "That was a barkworthy performance! 🗣️",
    "High fives and floppy ears! ✋🐶",
    "Zoomies unlocked! ⚡"
  ];

  static const List<String> _fallbackEncouragements = [
    "Way to go!",
    "Good job!",
    "Pawsome!",
    "Nice work!",
    "You crushed it!",
    "Amazing stride!",
    "Keep wagging!",
    "Walkstar!",
    "Top dog effort!",
    "Heel yeah!",
    "On a roll!",
    "Trailblazer!",
    "Strong finish!",
    "Gold leash material!",
    "Champion steps!"
  ];

  late final String _headlinePick;
  late final String _encouragementPick;

  @override
  void initState() {
    super.initState();
    _controller = ConfettiController(duration: const Duration(seconds: 2));
    _headlinePick = _headlines[_rand.nextInt(_headlines.length)];
    final pool = (widget.encouragements.isNotEmpty)
        ? widget.encouragements
        : _fallbackEncouragements;
    _encouragementPick = pool[_rand.nextInt(pool.length)];
    WidgetsBinding.instance.addPostFrameCallback((_) => _controller.play());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // ---- Sharing helpers ----
  String get _defaultShareUrl => 'https://inthepark.app';
  String get _walkUrl => (widget.shareUrl?.trim().isNotEmpty == true)
      ? widget.shareUrl!.trim()
      : _defaultShareUrl;

  String get _shareLine =>
      "We just finished a walk: ${widget.steps} steps • ${widget.kmText} km with InThePark 🐾";

  Future<void> _shareToTwitter() async {
    final text = Uri.encodeComponent("$_shareLine\n$_walkUrl");
    final uri = Uri.parse("https://twitter.com/intent/tweet?text=$text");
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      await Share.share("$_shareLine\n$_walkUrl");
    }
  }

  Future<void> _shareToFacebook() async {
    final urlParam = Uri.encodeComponent(_walkUrl);
    final sharer =
        Uri.parse("https://www.facebook.com/sharer/sharer.php?u=$urlParam");
    if (!await launchUrl(sharer, mode: LaunchMode.externalApplication)) {
      await Share.share(_walkUrl);
    }
  }

  Future<void> _shareSystem() async {
    try {
      final file = await _generateStatCardPng(
        headline: "Walk Complete!",
        steps: widget.steps,
        kmText: widget.kmText,
      );

      final xfile = XFile(
        file.path,
        mimeType: 'image/png',
        name: 'inthepark_walk.png',
      );

      await Share.shareXFiles(
        [xfile],
        text: "$_shareLine\n$_walkUrl",
        subject: "InThePark Walk",
      );
    } catch (_) {
      await Share.share(
        "$_shareLine\n$_walkUrl",
        subject: "InThePark Walk",
      );
    }
  }

  Future<void> _shareToInstagram() async {
    try {
      final file = await _generateStatCardPng(
        headline: "Walk Complete!",
        steps: widget.steps,
        kmText: widget.kmText,
      );
      final xfile =
          XFile(file.path, mimeType: 'image/png', name: 'inthepark_walk.png');
      await Share.shareXFiles(
        [xfile],
        text: _shareLine,
        subject: "InThePark Walk",
      );
    } catch (_) {
      await Share.share("$_shareLine\n$_walkUrl");
    }
  }

  /// Draw a simple 1080x1080 PNG with brand colors and stats.
  Future<File> _generateStatCardPng({
    required String headline,
    required int steps,
    required String kmText,
  }) async {
    const int size = 1080; // square
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final rect = Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble());

    // Background gradient (green tones)
    final paint = Paint()
      ..shader = ui.Gradient.linear(
        const Offset(0, 0),
        Offset(size.toDouble(), size.toDouble()),
        const [Color(0xFF567D46), Color(0xFF365A38)],
      );
    canvas.drawRect(rect, paint);

    // Helper for text
    TextPainter tp(String text, double fontSize, FontWeight weight, Color color,
        {TextAlign align = TextAlign.center}) {
      final t = TextPainter(
        textDirection: TextDirection.ltr,
        textAlign: align,
        maxLines: 2,
        ellipsis: '…',
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: weight,
            color: color,
            height: 1.2,
          ),
        ),
      );
      t.layout(maxWidth: size * 0.86);
      return t;
    }

    // Headline
    final h1 = tp("🎉 $headline", 72, FontWeight.w900, Colors.white);
    h1.paint(canvas, Offset((size - h1.width) / 2, size * 0.20));

    // Big numbers
    final stats =
        tp("$steps steps · $kmText km", 72, FontWeight.w900, Colors.white);
    stats.paint(canvas, Offset((size - stats.width) / 2, size * 0.40));

    // Encouragement
    final enc = tp(_encouragementPick, 48, FontWeight.w800, Colors.white70);
    enc.paint(canvas, Offset((size - enc.width) / 2, size * 0.54));

    // Footer / brand
    final brand =
        tp("InThePark", 42, FontWeight.w800, Colors.white.withOpacity(0.95));
    brand.paint(canvas, Offset((size - brand.width) / 2, size * 0.80));

    final picture = recorder.endRecording();
    final image = await picture.toImage(size, size);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    final bytes = byteData!.buffer.asUint8List();

    final dir = await getTemporaryDirectory();
    final file = File(
        '${dir.path}/inthepark_walk_${DateTime.now().millisecondsSinceEpoch}.png');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  // ---- UI helpers ----
  Widget _socialButton({
    required Color background,
    required String tooltip,
    required VoidCallback onTap,
    required Widget icon,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 28,
        child: CircleAvatar(
          radius: 20,
          backgroundColor: background,
          child: icon,
        ),
      ),
    );
  }

  String _days(int n) => '$n day${n == 1 ? '' : 's'}';

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text(
            "🎉 Walk Complete!",
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _headlinePick,
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              Text(
                "${widget.steps} steps · ${widget.kmText} km",
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 8),
              Text(
                _encouragementPick,
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),

              // NEW — streak pill inside the dialog
              if (widget.streakCurrent != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: widget.streakIsNewRecord
                        ? const Color(0xFFFFF7E6) // soft gold
                        : const Color(0xFFE7F6EA), // soft green
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: widget.streakIsNewRecord
                          ? const Color(0xFFFFC107)
                          : const Color(0xFF66BB6A),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        widget.streakIsNewRecord
                            ? Icons.emoji_events
                            : Icons.local_fire_department,
                        size: 20,
                        color: widget.streakIsNewRecord
                            ? const Color(0xFFFFC107)
                            : const Color(0xFF2E7D32),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        widget.streakIsNewRecord
                            ? "New streak record: ${_days(widget.streakCurrent!)}!"
                            : "Streak: ${_days(widget.streakCurrent!)}"
                                "${widget.streakLongest != null ? " • Best: ${_days(widget.streakLongest!)}" : ""}",
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w800,
                          color: widget.streakIsNewRecord
                              ? const Color(0xFF7A5A00)
                              : const Color(0xFF1B5E20),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.ios_share),
                  label: const Text("Share your walk!"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF567D46),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                    textStyle: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                  onPressed: _shareSystem,
                ),
              ),
            ],
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF567D46),
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                textStyle:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text("Nice!"),
            ),
          ],
        ),
        Align(
          alignment: Alignment.topCenter,
          child: ConfettiWidget(
            confettiController: _controller,
            blastDirectionality: BlastDirectionality.explosive,
            numberOfParticles: 40,
            gravity: 0.25,
            shouldLoop: false,
          ),
        ),
      ],
    );
  }
}
