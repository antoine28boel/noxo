import 'dart:async';

import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../win/win_desktop.dart';
import 'brain.dart';
import 'owl_painter.dart';

/// Size of Noxo's window and where his feet sit inside it (logical pixels).
const kNoxoWindowSize = NoxoGeometry.windowSize;
const kNoxoFeet = NoxoGeometry.windowFeet;

/// Runs Noxo's brain, moves his window and draws him: every frame while he
/// moves, a few times a second when he is calm ([NoxoBrain.frameRate]).
class NoxoView extends StatefulWidget {
  const NoxoView({
    super.key,
    required this.brain,
    required this.desktop,
    required this.onMouseOver,
    required this.onDoubleClick,
    required this.onCall,
    required this.onToggleNest,
    required this.onNestMoved,
  });

  final NoxoBrain brain;
  final WinDesktop desktop;

  /// Called when the cursor enters (true) or leaves (false) Noxo's body, so
  /// the window only catches clicks on Noxo and lets the rest through.
  final ValueChanged<bool> onMouseOver;

  /// Called when Noxo is double-clicked (opens the "Aujourd'hui" panel).
  final VoidCallback onDoubleClick;

  /// A click on the island: the owl is called, the chat opens.
  final VoidCallback onCall;

  /// Right click on Noxo: sends him to his nest, or brings him out.
  final VoidCallback onToggleNest;

  /// The nest was dragged to a new place.
  final VoidCallback onNestMoved;

  @override
  State<NoxoView> createState() => _NoxoViewState();
}

class _NoxoViewState extends State<NoxoView> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Timer? _timer;
  final _clock = Stopwatch()..start();
  Duration _last = Duration.zero;
  int _lastX = -1 << 30;
  int _lastY = -1 << 30;
  // Start as "over" so the first frame turns click-through on.
  bool _over = true;
  DateTime? _lastDown;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) => _step());
    _schedule();
  }

  /// Ticker (every frame) for a smooth Noxo, timer when he can go slower.
  void _schedule() {
    final fps = widget.brain.frameRate;
    if (fps >= 60) {
      _timer?.cancel();
      _timer = null;
      if (!_ticker.isActive) _ticker.start();
      return;
    }
    if (_ticker.isActive) _ticker.stop();
    _timer?.cancel();
    _timer = Timer(Duration(microseconds: (1e6 / fps).round()), _step);
  }

  void _step() {
    if (!mounted) return;
    final elapsed = _clock.elapsed;
    final dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    final brain = widget.brain;
    final desktop = widget.desktop;

    brain.scale = desktop.scale();
    brain.update(dt, desktop);

    final s = brain.scale;
    final x = (brain.pos.dx - kNoxoFeet.dx * s).round();
    final y = (brain.pos.dy - kNoxoFeet.dy * s).round();
    if (x != _lastX || y != _lastY) {
      _lastX = x;
      _lastY = y;
      desktop.moveWindow(x, y);
    }
    desktop.showFeather(brain.hidden ? null : brain.featherPos, brain.featherOpacity);

    final over = brain.state == NoxoState.dragged || brain.hitTest(desktop.cursor());
    if (over != _over) {
      _over = over;
      widget.onMouseOver(over);
    }

    if (brain.takeCall()) widget.onCall();
    if (brain.takeNestMoved()) widget.onNestMoved();

    brain.pose.changed();
    _schedule();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) {
        final brain = widget.brain;
        // Right click: into the nest (island) or out of it.
        if (event.buttons & kSecondaryMouseButton != 0) {
          widget.onToggleNest();
          return;
        }
        if (brain.state == NoxoState.docked) {
          // In the island a single click calls Noxo: it opens the assistant.
          brain.press(widget.desktop.cursor());
          return;
        }
        final now = DateTime.now();
        final last = _lastDown;
        if (last != null && now.difference(last) < const Duration(milliseconds: 450)) {
          _lastDown = null;
          widget.onDoubleClick();
          return;
        }
        _lastDown = now;
        widget.brain.startDrag(widget.desktop.cursor());
      },
      child: CustomPaint(
        size: kNoxoWindowSize,
        painter: OwlPainter(pose: widget.brain.pose, feet: kNoxoFeet),
      ),
    );
  }
}
