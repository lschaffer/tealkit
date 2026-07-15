import 'dart:math';
import 'package:flutter/material.dart';
import '../config/app_theme.dart';

/// Animated neural network / constellation particle background.
/// Draws floating dots with connecting lines on a deep blue gradient.
class ParticleBackground extends StatefulWidget {
  final Widget child;
  final bool animate;

  const ParticleBackground({super.key, required this.child, this.animate = false});

  @override
  State<ParticleBackground> createState() => _ParticleBackgroundState();
}

class _ParticleBackgroundState extends State<ParticleBackground> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late List<_Particle> _particles;
  final Random _random = Random();

  static const int _particleCount = 50;
  static const double _connectionDistance = 120.0;

  @override
  void initState() {
    super.initState();
    _particles = List.generate(_particleCount, (_) => _generateParticle());
    _controller = AnimationController(vsync: this, duration: const Duration(seconds: 60))..addListener(_updateParticles);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateAnimationState();
  }

  @override
  void didUpdateWidget(covariant ParticleBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate != oldWidget.animate) {
      _updateAnimationState();
    }
  }

  void _updateAnimationState() {
    final width = MediaQuery.sizeOf(context).width;
    final shouldAnimate = widget.animate || width > 1200;
    if (shouldAnimate) {
      if (!_controller.isAnimating) {
        _controller.repeat();
      }
    } else {
      if (_controller.isAnimating) {
        _controller.stop();
      }
    }
  }

  _Particle _generateParticle() {
    return _Particle(
      x: _random.nextDouble(),
      y: _random.nextDouble(),
      vx: (_random.nextDouble() - 0.5) * 0.3,
      vy: (_random.nextDouble() - 0.5) * 0.3,
      radius: _random.nextDouble() * 2.0 + 1.0,
      opacity: _random.nextDouble() * 0.5 + 0.2,
    );
  }

  void _updateParticles() {
    for (final p in _particles) {
      p.x += p.vx * 0.002;
      p.y += p.vy * 0.002;

      // Wrap around edges
      if (p.x < -0.05) p.x = 1.05;
      if (p.x > 1.05) p.x = -0.05;
      if (p.y < -0.05) p.y = 1.05;
      if (p.y > 1.05) p.y = -0.05;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Stack(
      children: [
        // Gradient background
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isDark
                  ? [const Color(0xFF060F1F), AppTheme.backgroundDark, const Color(0xFF0D1F3C), const Color(0xFF081428)]
                  : [const Color(0xFFE3F2FD), const Color(0xFFF0F4FA), const Color(0xFFE8EFF9), const Color(0xFFDBE9F9)],
              stops: const [0.0, 0.3, 0.7, 1.0],
            ),
          ),
        ),
        // Particles
        CustomPaint(
          painter: _ParticlePainter(particles: _particles, connectionDistance: _connectionDistance, isDark: isDark),
          size: Size.infinite,
        ),
        // Child content
        widget.child,
      ],
    );
  }
}

class _Particle {
  double x; // 0.0 to 1.0 (normalized)
  double y;
  double vx;
  double vy;
  double radius;
  double opacity;

  _Particle({required this.x, required this.y, required this.vx, required this.vy, required this.radius, required this.opacity});
}

class _ParticlePainter extends CustomPainter {
  final List<_Particle> particles;
  final double connectionDistance;
  final bool isDark;

  _ParticlePainter({required this.particles, required this.connectionDistance, required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    final dotPaint = Paint()..style = PaintingStyle.fill;
    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5;

    final dotColor = isDark ? AppTheme.primaryLight : AppTheme.primaryBlue;

    final lineColor = isDark ? AppTheme.primaryBlue : AppTheme.primaryLight;

    // Draw connection lines
    for (int i = 0; i < particles.length; i++) {
      final a = particles[i];
      final ax = a.x * size.width;
      final ay = a.y * size.height;

      for (int j = i + 1; j < particles.length; j++) {
        final b = particles[j];
        final bx = b.x * size.width;
        final by = b.y * size.height;

        final dist = sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by));
        if (dist < connectionDistance) {
          final alpha = (1.0 - dist / connectionDistance) * 0.25;
          linePaint.color = lineColor.withValues(alpha: alpha);
          canvas.drawLine(Offset(ax, ay), Offset(bx, by), linePaint);
        }
      }
    }

    // Draw dots
    for (final p in particles) {
      final px = p.x * size.width;
      final py = p.y * size.height;

      // Glow
      dotPaint.color = dotColor.withValues(alpha: p.opacity * 0.3);
      canvas.drawCircle(Offset(px, py), p.radius * 3, dotPaint);

      // Core dot
      dotPaint.color = dotColor.withValues(alpha: p.opacity);
      canvas.drawCircle(Offset(px, py), p.radius, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _ParticlePainter oldDelegate) => true;
}
