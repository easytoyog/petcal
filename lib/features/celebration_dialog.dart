import 'dart:io';
import 'dart:ui' as ui;

import 'package:confetti/confetti.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:math';

class CelebrationDialog extends StatefulWidget {
  final int steps;
  final String kmText;

  /// You can still pass encouragements if you want to use them elsewhere,
  /// but the share card itself stays neutral.
  final List<String> encouragements;

  /// Optional: public URL for the walk (dynamic link / landing page).
  final String? shareUrl;

  /// Optional streak details
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

  // 10 quick options to rotate through
  static const List<String> _ctaOptions = [
    "Nice!",
    "Sweet!",
    "Love it!",
    "Heck yeah!",
    "All done!",
    "Paws up!",
    "High five!",
    "Crushed it!",
    "Let’s go!",
    "Woohoo!",
  ];

  // chosen once per dialog instance
  late final String _ctaLabel;

  @override
  void initState() {
    super.initState();
    _controller = ConfettiController(duration: const Duration(seconds: 2));
    _ctaLabel = _ctaOptions[Random().nextInt(_ctaOptions.length)];
    WidgetsBinding.instance.addPostFrameCallback((_) => _controller.play());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _walkUrl {
    final u = widget.shareUrl?.trim() ?? '';
    return u.isEmpty ? '' : u;
  }

  /// Draw a square PNG with the neutral caption *inside* the card.
  Future<File> _generateStatCardPng({
    required int steps,
    required String kmText,
  }) async {
    const int size = 1080; // 1080x1080
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final rect = Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble());

    // Background gradient
    final bg = Paint()
      ..shader = ui.Gradient.linear(
        const Offset(0, 0),
        Offset(size.toDouble(), size.toDouble()),
        const [Color(0xFF567D46), Color(0xFF365A38)],
      );
    canvas.drawRect(rect, bg);

    TextPainter tp(
      String text, {
      double fontSize = 60,
      FontWeight weight = FontWeight.w800,
      Color color = Colors.white,
      int maxLines = 2,
      TextAlign align = TextAlign.center,
    }) {
      final t = TextPainter(
        textDirection: TextDirection.ltr,
        textAlign: align,
        maxLines: maxLines,
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

    // Title
    final title =
        tp("🎉 Walk completed!", fontSize: 84, weight: FontWeight.w900);
    title.paint(canvas, Offset((size - title.width) / 2, size * 0.22));

    // Neutral connection line (inside the card)
    final line = tp(
      "You and your pup walked $kmText km ($steps steps).",
      fontSize: 48,
      weight: FontWeight.w800,
      color: Colors.white.withOpacity(0.95),
    );
    line.paint(canvas, Offset((size - line.width) / 2, size * 0.38));

    // Brand footer
    final brand = tp("InThePark",
        fontSize: 46, weight: FontWeight.w800, color: Colors.white70);
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

  Future<void> _shareSystem() async {
    try {
      final file = await _generateStatCardPng(
        steps: widget.steps,
        kmText: widget.kmText,
      );

      final xfile = XFile(
        file.path,
        mimeType: 'image/png',
        name: 'inthepark_walk.png',
      );

      // No separate message; the caption is in the image.
      // Optionally include a link if provided.
      if (_walkUrl.isNotEmpty) {
        await Share.shareXFiles(
          [xfile],
          text: _walkUrl,
          subject: "InThePark Walk",
        );
      } else {
        await Share.shareXFiles(
          [xfile],
          subject: "InThePark Walk",
        );
      }
    } catch (_) {
      // Fallback share without text message.
      await Share.shareXFiles(const [], subject: "InThePark Walk");
    }
  }

  String _days(int n) => '$n day${n == 1 ? '' : 's'}';

  @override
  Widget build(BuildContext context) {
    final neutralLine =
        "You and your pup walked ${widget.kmText} km (${widget.steps} steps).";

    return Stack(
      children: [
        AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text(
            "🎉 Walk completed!",
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Neutral caption under the title, not cheesy
              Text(
                neutralLine,
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),

              // Optional streak pill
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
                  label: const Text("Share your walk"),
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
              child: Text(_ctaLabel), // ← was "Nice!"
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
