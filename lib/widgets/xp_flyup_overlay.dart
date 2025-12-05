import 'dart:math';
import 'package:flutter/material.dart';

class XpFlyUpOverlay {
  static void show(
    BuildContext context, {
    required GlobalKey xpBarKey,
    int count = 18, // more particles
  }) {
    final overlay = Overlay.of(context);
    if (overlay == null) return;

    final barContext = xpBarKey.currentContext;
    if (barContext == null) return;

    final barRender = barContext.findRenderObject();
    if (barRender is! RenderBox) return;

    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    if (overlayBox == null) return;

    final barTopLeft =
        barRender.localToGlobal(Offset.zero, ancestor: overlayBox);
    final barSize = barRender.size;
    final barCenter =
        barTopLeft + Offset(barSize.width / 2, barSize.height / 2);

    final screenSize = overlayBox.size;
    final bottomY = screenSize.height - 120;
    final bottomCenter = Offset(screenSize.width / 2, bottomY);

    final random = Random();
    final entries = <OverlayEntry>[];

    // --- Flying particles ---
    for (int i = 0; i < count; i++) {
      final start = bottomCenter +
          Offset(
            (random.nextDouble() * 180) - 90, // wider spread
            (random.nextDouble() * 40) - 20,
          );

      final end = barCenter +
          Offset(
            (random.nextDouble() * 60) - 30, // spread around bar
            (random.nextDouble() * 16) - 8,
          );

      final delay =
          Duration(milliseconds: random.nextInt(250)); // slight stagger

      final entry = OverlayEntry(
        builder: (_) => _XpParticle(
          start: start,
          end: end,
          duration: const Duration(milliseconds: 1300),
          delay: delay,
        ),
      );
      entries.add(entry);
      overlay.insert(entry);
    }

    // --- Impact burst at bar center ---
    final burstEntry = OverlayEntry(
      builder: (_) => _XpImpactBurst(
        center: barCenter,
        duration: const Duration(milliseconds: 500),
      ),
    );
    entries.add(burstEntry);
    overlay.insert(burstEntry);

    Future.delayed(const Duration(milliseconds: 1800), () {
      for (final e in entries) {
        e.remove();
      }
    });
  }
}

class _XpParticle extends StatefulWidget {
  final Offset start;
  final Offset end;
  final Duration duration;
  final Duration delay;

  const _XpParticle({
    Key? key,
    required this.start,
    required this.end,
    required this.duration,
    required this.delay,
  }) : super(key: key);

  @override
  State<_XpParticle> createState() => _XpParticleState();
}

class _XpParticleState extends State<_XpParticle>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _curve;
  late final Offset controlPoint;
  final _rand = Random();

  @override
  void initState() {
    super.initState();

    // control point above the straight line for a nice arc
    final midX = (widget.start.dx + widget.end.dx) / 2;
    final midY = (widget.start.dy + widget.end.dy) / 2;
    controlPoint = Offset(
      midX + (_rand.nextDouble() * 60 - 30),
      midY - 80 + (_rand.nextDouble() * 30), // arc upward
    );

    _controller = AnimationController(
      duration: widget.duration,
      vsync: this,
    );

    _curve = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );

    // small stagger so they don't all move in sync
    Future.delayed(widget.delay, () {
      if (mounted) _controller.forward();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _curve,
      builder: (_, __) {
        final t = _curve.value;
        if (t == 0) return const SizedBox.shrink();

        // Quadratic bezier: start -> controlPoint -> end
        final x = _quadraticBezier(
            widget.start.dx, controlPoint.dx, widget.end.dx, t);
        final y = _quadraticBezier(
            widget.start.dy, controlPoint.dy, widget.end.dy, t);

        final opacity = (1.0 - t).clamp(0.0, 1.0);
        final scale = 0.9 + t * 0.6; // bigger & punchier

        return Positioned(
          left: x,
          top: y,
          child: Opacity(
            opacity: opacity,
            child: Transform.scale(
              scale: scale,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.amberAccent.shade200,
                      Colors.orangeAccent.shade200,
                    ],
                  ),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.amber.shade300.withOpacity(0.95),
                      blurRadius: 18,
                      spreadRadius: 4,
                    ),
                  ],
                ),
                child: Center(
                  child: Text(
                    "+XP",
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      color: Colors.brown.shade900,
                      shadows: const [
                        Shadow(
                          color: Colors.black26,
                          offset: Offset(0, 1),
                          blurRadius: 2,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  double _quadraticBezier(double p0, double p1, double p2, double t) {
    final mt = 1 - t;
    return mt * mt * p0 + 2 * mt * t * p1 + t * t * p2;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

class _XpImpactBurst extends StatefulWidget {
  final Offset center;
  final Duration duration;

  const _XpImpactBurst({
    Key? key,
    required this.center,
    required this.duration,
  }) : super(key: key);

  @override
  State<_XpImpactBurst> createState() => _XpImpactBurstState();
}

class _XpImpactBurstState extends State<_XpImpactBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _curve;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: widget.duration,
      vsync: this,
    )..forward();

    _curve = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutQuad,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _curve,
      builder: (_, __) {
        final t = _curve.value;
        final size = 26 + t * 32;
        final opacity = (1.0 - t).clamp(0.0, 1.0);

        return Positioned(
          left: widget.center.dx - size / 2,
          top: widget.center.dy - size / 2,
          child: Opacity(
            opacity: opacity,
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.amberAccent.withOpacity(0.9),
                  width: 2 + t * 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.amber.withOpacity(0.8),
                    blurRadius: 18,
                    spreadRadius: 4,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
