import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../director/order_dispatch_dialog.dart';
import '../director/pack_studio_view.dart';

// ---------------------------------------------------------------------------
// The app tour: a guided walk over the real screens - Director mode, sending
// orders, making them - that highlights one control at a time and explains it.
//
// The tour moves the app itself (switching mode and tab, opening the dispatch
// window and the Pack Studio) so nobody has to find their way while reading,
// and it sits over everything while it runs, so no tap can send an order by
// accident. Each step sets up the whole screen it needs, which is what lets
// Back work without undoing anything.
// ---------------------------------------------------------------------------

/// Named spots the tour can point at. A widget is marked with [wrap]; the
/// tour finds it by name while it is on screen.
class TourTargets {
  TourTargets._();

  static final Map<String, GlobalKey> _keys = {};

  static GlobalKey key(String id) => _keys.putIfAbsent(id, () => GlobalKey(debugLabel: 'tour:$id'));

  static Widget wrap(String id, Widget child) => KeyedSubtree(key: key(id), child: child);

  /// The first of [ids] currently on screen.
  static BuildContext? find(List<String> ids) {
    for (final id in ids) {
      final ctx = _keys[id]?.currentContext;
      if (ctx != null && ctx.mounted && ctx.findRenderObject()?.attached == true) return ctx;
    }
    return null;
  }
}

/// What the tour needs from the home screen.
abstract class TourHost {
  bool get isDirector;
  Future<void> setDirector(bool director);

  /// Shows a Director-mode tab: 0 Control, 1 Quests, 2 Packs, 3 Contacts.
  void showDirectorTab(int index);
}

class TourStep {
  const TourStep({
    required this.title,
    required this.body,
    this.targets = const [],
    this.director,
    this.tab,
    this.open,
  });

  final String title;
  final String body;

  /// Where to point, first one found; none for a card in the middle.
  final List<String> targets;

  /// The mode and Director tab this step is shown in; null leaves it.
  final bool? director;
  final int? tab;

  /// Something to open over the home screen for this step.
  final Future<void> Function(BuildContext context)? open;
}

class AppTour {
  AppTour._();

  static const String seenKey = 'app_tour_seen_v1';

  static OverlayEntry? _entry;
  static bool get isRunning => _entry != null;

  /// Set by the home screen; Settings uses it to start the tour.
  static void Function()? _requestStart;
  static void register(void Function()? start) => _requestStart = start;
  static void requestStart() => _requestStart?.call();

  static Future<bool> hasBeenSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(seenKey) ?? false;
    } catch (_) {
      return true;
    }
  }

  static Future<void> markSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(seenKey, true);
    } catch (_) {}
  }

  static List<TourStep> steps() => [
        const TourStep(
          title: 'Welcome to SubTask Manager',
          body: 'This short tour shows you how to get into Director mode, how to send orders, and how to make '
              'your own. It moves around the app for you - just read and press Next.',
        ),
        const TourStep(
          title: 'Player and Director modes',
          body: 'This badge shows which mode you are in. Players receive and carry out orders; Directors make '
              'and send them. Tap it any time to switch.\n\nNext switches to Director mode for you.',
          targets: ['role-chip'],
        ),
        const TourStep(
          title: 'Your command hub',
          body: 'In Director mode, Control is your dashboard: who you are directing, the orders they are working '
              'on, proof waiting for your review, and their tokens.',
          targets: ['nav-d0-on', 'nav-d0'],
          director: true,
          tab: 0,
        ),
        const TourStep(
          title: 'Who gets your orders',
          body: 'Choose the person you are directing here. Partners appear once you have paired with them in '
              'Contacts; "Myself" sends orders to this device.',
          targets: ['active-partner'],
          director: true,
          tab: 0,
        ),
        const TourStep(
          title: 'Sending an order',
          body: 'Dispatch Order opens the dispatch window. Whatever you send goes straight to the person chosen '
              'above.',
          targets: ['dispatch-order'],
          director: true,
          tab: 0,
        ),
        TourStep(
          title: 'Pick from your library',
          body: 'Browse Library Tasks lists every order in your packs. Search or filter, then press Dispatch Now '
              'to send one as it is, or Customize to change it first.',
          targets: const ['dispatch-tabs'],
          director: true,
          tab: 0,
          open: (context) => OrderDispatchDialog.show(context),
        ),
        TourStep(
          title: 'Or write one on the spot',
          body: 'Custom Directive makes a one-off order: give it a title and details, a time limit, the proof '
              'you want, and the tokens it is worth - then press DISPATCH ORDER at the bottom.',
          targets: const ['dispatch-custom-title', 'dispatch-tabs'],
          director: true,
          tab: 0,
          open: (context) => OrderDispatchDialog.show(context, initialTab: 1),
        ),
        const TourStep(
          title: 'Orders on a schedule',
          body: 'Schedule Order sends orders automatically - at a set time or a random moment in a window, '
              'repeating hourly, daily or weekly. It is unlocked with the community passcode.',
          targets: ['schedule-order'],
          director: true,
          tab: 0,
        ),
        const TourStep(
          title: 'Making your own orders',
          body: 'Packs are where your orders live, ready to send again and again. The library in the dispatch '
              'window is made from them.',
          targets: ['nav-d2-on', 'nav-d2'],
          director: true,
          tab: 2,
        ),
        const TourStep(
          title: 'Create a pack',
          body: 'The + button starts a new pack. Each pack in the list below can be opened to see its orders, '
              'and each order has its own Dispatch button.',
          targets: ['create-pack'],
          director: true,
          tab: 2,
        ),
        TourStep(
          title: 'Add your orders',
          body: 'This is the Pack Studio. Name the pack, then press Add Directive for each order: what to do, how '
              'long it takes, the proof needed and its reward. Save when you are done.',
          targets: const ['add-directive'],
          director: true,
          tab: 2,
          open: (context) =>
              Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PackStudioView())),
        ),
        const TourStep(
          title: 'Pair with your partner',
          body: 'Orders reach a partner once you are paired. Add Partner gives you a code to share, or takes '
              'theirs. Chat with partners here too.',
          targets: ['add-partner', 'nav-d3-on', 'nav-d3'],
          director: true,
          tab: 3,
        ),
        const TourStep(
          title: "That's the tour",
          body: 'You can take it again any time: Settings, then App tour.',
          director: true,
          tab: 0,
        ),
      ];

  /// Starts the tour over [context]'s app.
  static void start(BuildContext context, TourHost host) {
    if (_entry != null) return;
    final overlay = Navigator.of(context, rootNavigator: true).overlay;
    if (overlay == null) return;
    final startedAsDirector = host.isDirector;
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _TourOverlay(
        steps: steps(),
        host: host,
        navigatorContext: context,
        startedAsDirector: startedAsDirector,
        bringToFront: () {
          if (!entry.mounted) return;
          entry.remove();
          overlay.insert(entry);
        },
        onEnd: () {
          if (entry.mounted) entry.remove();
          _entry = null;
          markSeen();
        },
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }
}

class _TourOverlay extends StatefulWidget {
  const _TourOverlay({
    required this.steps,
    required this.host,
    required this.navigatorContext,
    required this.startedAsDirector,
    required this.bringToFront,
    required this.onEnd,
  });

  final List<TourStep> steps;
  final TourHost host;
  final BuildContext navigatorContext;
  final bool startedAsDirector;
  final VoidCallback bringToFront;
  final VoidCallback onEnd;

  @override
  State<_TourOverlay> createState() => _TourOverlayState();
}

class _TourOverlayState extends State<_TourOverlay> {
  int _index = 0;
  Rect? _hole;
  bool _busy = false;
  Timer? _follow;
  final GlobalKey _stackKey = GlobalKey();

  TourStep get _step => widget.steps[_index];
  bool get _last => _index == widget.steps.length - 1;

  @override
  void initState() {
    super.initState();
    _go(0);
    // The target can move under the tour - a window resized, a list settling.
    _follow = Timer.periodic(const Duration(milliseconds: 300), (_) => _measure());
  }

  @override
  void dispose() {
    _follow?.cancel();
    super.dispose();
  }

  NavigatorState get _nav => Navigator.of(widget.navigatorContext, rootNavigator: true);

  /// Back to the home screen, with nothing open over it. Waits for what was
  /// open to finish closing: a window still animating away holds the same
  /// marked spots as one about to open, and the two cannot both be on screen.
  Future<void> _closeOpened() async {
    if (!_nav.canPop()) return;
    _nav.popUntil((route) => route.isFirst);
    await Future<void>.delayed(const Duration(milliseconds: 450));
  }

  Future<void> _go(int index) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _index = index;
      _hole = null;
    });
    final step = widget.steps[index];
    try {
      await _closeOpened();
      if (step.director != null && widget.host.isDirector != step.director) {
        await widget.host.setDirector(step.director!);
      }
      if (step.tab != null && (step.director ?? widget.host.isDirector)) widget.host.showDirectorTab(step.tab!);
      await _frame();
      if (step.open != null && widget.navigatorContext.mounted) {
        unawaited(step.open!(widget.navigatorContext));
        await _frame();
        // Whatever was opened went on top of the tour; put the tour back above it.
        widget.bringToFront();
      }
      await _waitFor(step.targets);
    } finally {
      if (mounted) setState(() => _busy = false);
      _measure();
    }
  }

  Future<void> _frame() {
    final done = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) => done.complete());
    WidgetsBinding.instance.scheduleFrame();
    return done.future.then((_) => Future<void>.delayed(const Duration(milliseconds: 60)));
  }

  /// Waits for the step's target to appear (a route animating in), then
  /// scrolls it into view.
  Future<void> _waitFor(List<String> ids) async {
    if (ids.isEmpty) return;
    final until = DateTime.now().add(const Duration(seconds: 2));
    BuildContext? ctx;
    while ((ctx = TourTargets.find(ids)) == null && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (ctx != null && ctx.mounted) {
      try {
        await Scrollable.ensureVisible(ctx, alignment: 0.3, duration: const Duration(milliseconds: 250));
      } catch (_) {}
      // A route still sliding in: let it land before measuring.
      await Future<void>.delayed(const Duration(milliseconds: 320));
    }
  }

  void _measure() {
    if (!mounted) return;
    Rect? rect;
    final ctx = TourTargets.find(_step.targets);
    final stack = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    final box = ctx?.findRenderObject();
    if (box is RenderBox && box.hasSize && stack != null && stack.hasSize) {
      final topLeft = box.localToGlobal(Offset.zero, ancestor: stack);
      rect = (topLeft & box.size).inflate(6);
    }
    if (rect != _hole) setState(() => _hole = rect);
  }

  Future<void> _end({required bool backToStartingMode}) async {
    _follow?.cancel();
    await _closeOpened();
    if (backToStartingMode && widget.host.isDirector != widget.startedAsDirector) {
      await widget.host.setDirector(widget.startedAsDirector);
    }
    widget.onEnd();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hole = _busy ? null : _hole;
    return Material(
      type: MaterialType.transparency,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          return Stack(
            key: _stackKey,
            children: [
              // Takes every tap: nothing underneath can be pressed mid-tour.
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {},
                  child: CustomPaint(painter: _ScrimPainter(hole, theme.colorScheme.primary)),
                ),
              ),
              _card(theme, size, hole),
            ],
          );
        },
      ),
    );
  }

  Widget _card(ThemeData theme, Size size, Rect? hole) {
    final width = (size.width - 32).clamp(200.0, 380.0);
    double left = (size.width - width) / 2;
    double? top;
    double? bottom;
    if (hole == null) {
      top = null;
    } else {
      left = (hole.center.dx - width / 2).clamp(16.0, size.width - width - 16);
      if (hole.center.dy < size.height / 2) {
        top = (hole.bottom + 14).clamp(16.0, size.height - 120);
      } else {
        bottom = (size.height - hole.top + 14).clamp(16.0, size.height - 120);
      }
    }

    final card = Card(
      key: const Key('tour-card'),
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text(
                  _step.title,
                  key: const Key('tour-title'),
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              Text(
                '${_index + 1}/${widget.steps.length}',
                style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
              ),
            ]),
            const SizedBox(height: 8),
            Flexible(
              child: SingleChildScrollView(
                child: Text(_step.body, style: const TextStyle(height: 1.35)),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 4,
                children: _buttons(),
              ),
            ),
          ],
        ),
      ),
    );

    return AnimatedPositioned(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      left: left,
      width: width,
      top: hole == null ? null : top,
      bottom: hole == null ? null : bottom,
      child: hole == null
          ? SizedBox(
              height: size.height,
              child: Center(
                child: ConstrainedBox(constraints: BoxConstraints(maxHeight: size.height * 0.8), child: card),
              ),
            )
          : ConstrainedBox(constraints: BoxConstraints(maxHeight: size.height * 0.45), child: card),
    );
  }

  List<Widget> _buttons() {
    if (_last) {
      return [
        TextButton(
          key: const Key('tour-prev'),
          onPressed: _busy ? null : () => _go(_index - 1),
          child: const Text('Back'),
        ),
        if (!widget.startedAsDirector)
          TextButton(
            key: const Key('tour-back-to-player'),
            onPressed: () => _end(backToStartingMode: true),
            child: const Text('Back to Player mode'),
          ),
        FilledButton(
          key: const Key('tour-done'),
          onPressed: () => _end(backToStartingMode: false),
          child: Text(widget.startedAsDirector ? 'Done' : 'Stay in Director mode'),
        ),
      ];
    }
    return [
      TextButton(
        key: const Key('tour-skip'),
        onPressed: _busy ? null : () => _end(backToStartingMode: true),
        child: const Text('Skip tour'),
      ),
      if (_index > 0)
        TextButton(
          key: const Key('tour-prev'),
          onPressed: _busy ? null : () => _go(_index - 1),
          child: const Text('Back'),
        ),
      FilledButton(
        key: const Key('tour-next'),
        onPressed: _busy ? null : () => _go(_index + 1),
        child: Text(_index == 0 ? 'Start' : 'Next'),
      ),
    ];
  }
}

/// Dims everything but the highlighted spot, which gets an outline.
class _ScrimPainter extends CustomPainter {
  _ScrimPainter(this.hole, this.accent);
  final Rect? hole;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final screen = Path()..addRect(Offset.zero & size);
    final h = hole;
    if (h == null) {
      canvas.drawPath(screen, Paint()..color = Colors.black.withValues(alpha: 0.6));
      return;
    }
    final spot = RRect.fromRectAndRadius(h, const Radius.circular(12));
    canvas.drawPath(
      Path.combine(PathOperation.difference, screen, Path()..addRRect(spot)),
      Paint()..color = Colors.black.withValues(alpha: 0.6),
    );
    canvas.drawRRect(
      spot,
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(_ScrimPainter old) => old.hole != hole || old.accent != accent;
}
