import 'package:flutter/material.dart';

import '../../models/cadence_config.dart';
import '../../models/partner_contact.dart';
import '../../services/sync_service.dart';
import '../../services/toy/toy_patterns.dart';
import '../../services/toy/toy_player.dart';
import '../../services/toy/toy_remote.dart';
import '../../services/toy/toy_service.dart';

/// What the panel steers: your own toy, or a partner's over live control.
abstract class ToyControlTarget extends ChangeNotifier {
  String get title;

  /// Ready to take commands. When false, [blockedReason] says why.
  bool get ready;
  String? get blockedReason;

  String? get toyName;
  int get battery;
  int get speed;
  int get cap;
  ToyActivity get activity;
  int get level;
  ToyPattern? get pattern;
  int? get bpm;

  /// Shown above the controls: who else is involved.
  String? get note;

  /// "Click sound on ..." label for the metronome.
  String get soundLabel;

  void setLevel(int level);
  void playPattern(ToyPattern pattern, int strength);
  void setStrength(int strength);
  void startMetronome(CadenceConfig config, {required int seconds, required int strength});
  void updateMetronome(CadenceConfig config);
  void stop();

  Future<void> open() async {}
  Future<void> close() async {}
}

/// Your own toy, played on this device.
class LocalToyTarget extends ToyControlTarget {
  LocalToyTarget({ToyPlayer? player, ToyService? toy, ToyRemoteHost? host})
      : _player = player ?? ToyPlayer.instance,
        _toy = toy ?? ToyService.instance,
        _host = host ?? ToyRemoteHost.instance {
    _player.addListener(notifyListeners);
    _toy.addListener(notifyListeners);
    _host.addListener(notifyListeners);
  }

  final ToyPlayer _player;
  final ToyService _toy;
  final ToyRemoteHost _host;

  @override
  String get title => 'Your toy';
  @override
  bool get ready => _toy.isConnected;
  @override
  String? get blockedReason => ready ? null : 'Connect your toy first.';
  @override
  String? get toyName => _toy.connectedToy?.name;
  @override
  int get battery => _toy.connectedToy?.batteryLevel ?? -1;
  @override
  int get speed => _toy.currentSpeed;
  @override
  int get cap => 20;
  @override
  ToyActivity get activity => _player.activity;
  @override
  int get level => _player.level;
  @override
  ToyPattern? get pattern => _player.pattern;
  @override
  int? get bpm => _player.currentBpm;
  @override
  String? get note {
    final c = _host.controller;
    return c == null ? null : '${c.displayName} is controlling your toy. Anything you do here takes over.';
  }

  @override
  String get soundLabel => 'Click sound';

  @override
  void setLevel(int level) {
    _host.ownerTookOver();
    _player.setLevel(level);
  }

  @override
  void playPattern(ToyPattern pattern, int strength) {
    _host.ownerTookOver();
    _player.playPattern(pattern, strength);
  }

  @override
  void setStrength(int strength) => _player.setStrength(strength);

  @override
  void startMetronome(CadenceConfig config, {required int seconds, required int strength}) {
    _host.ownerTookOver();
    _player.startMetronome(config, seconds: seconds, strength: strength);
  }

  @override
  void updateMetronome(CadenceConfig config) => _player.updateMetronome(config);

  @override
  void stop() {
    _host.ownerTookOver();
    _player.stop();
  }

  @override
  void dispose() {
    _player.removeListener(notifyListeners);
    _toy.removeListener(notifyListeners);
    _host.removeListener(notifyListeners);
    super.dispose();
  }
}

/// A partner's toy, over live control.
class RemoteToyTarget extends ToyControlTarget {
  RemoteToyTarget(this.partner, {ToyRemoteController? controller})
      : _ctl = controller ??
            ToyRemoteController(
              partner: partner,
              topic: SyncService.getHashedTopic(partner.pairingCode),
            ) {
    _ctl.addListener(notifyListeners);
  }

  final PartnerContact partner;
  final ToyRemoteController _ctl;

  RemoteToyState? get _s => _ctl.state;

  @override
  String get title => "${partner.displayName}'s toy";

  @override
  bool get ready => blockedReason == null;

  @override
  String? get blockedReason {
    final name = partner.displayName;
    if (!_ctl.connected) return 'Connecting…';
    if (_ctl.denied) return "$name hasn't allowed you to control their toy.";
    if (!_ctl.ownerOnline) return "$name's toy isn't available right now. This page connects as soon as it is.";
    final s = _s;
    if (s == null) return 'Waiting for $name…';
    if (!s.toyConnected) return "$name's toy isn't connected.";
    if (s.paused) return '$name has paused partner control.';
    if (_ctl.busy) return '${s.controllerName} is in control right now.';
    return null;
  }

  @override
  String? get toyName => _s?.toyName;
  @override
  int get battery => _s?.battery ?? -1;
  @override
  int get speed => _s?.speed ?? 0;
  @override
  int get cap => _s?.cap ?? 20;
  @override
  ToyActivity get activity => _s?.activity ?? ToyActivity.idle;
  @override
  int get level => _s?.level ?? 0;
  @override
  ToyPattern? get pattern => _s?.pattern;
  @override
  int? get bpm => _s?.bpm;
  @override
  String? get note {
    final c = cap;
    final parts = <String>[
      if (_s?.youControl ?? false) 'You are in control.',
      if (c < 20) '${partner.displayName} has set a limit of $c/20.',
      'If you leave this page, the toy stops.',
      if (ready) _ctl.direct ? 'Direct connection.' : 'Connected through the server.',
    ];
    return parts.join(' ');
  }

  @override
  String get soundLabel => "Click sound on ${partner.displayName}'s device";

  @override
  void setLevel(int level) => _ctl.setLevel(level);
  @override
  void playPattern(ToyPattern pattern, int strength) => _ctl.playPattern(pattern, strength);
  @override
  void setStrength(int strength) => _ctl.setStrength(strength);
  @override
  void startMetronome(CadenceConfig config, {required int seconds, required int strength}) =>
      _ctl.startMetronome(config, seconds: seconds, strength: strength);
  @override
  void updateMetronome(CadenceConfig config) => _ctl.updateMetronome(config);
  @override
  void stop() => _ctl.stop();

  @override
  Future<void> open() => _ctl.open();

  @override
  Future<void> close() => _ctl.close();

  @override
  void dispose() {
    _ctl.removeListener(notifyListeners);
    _ctl.dispose();
    super.dispose();
  }
}

/// Direct control of a toy: a level slider, hold-to-buzz, patterns and a
/// live metronome, with Stop always in reach.
class ToyControlView extends StatefulWidget {
  const ToyControlView({super.key, required this.target});

  final ToyControlTarget target;

  static Future<void> openLocal(BuildContext context) => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ToyControlView(target: LocalToyTarget())),
      );

  static Future<void> openPartner(BuildContext context, PartnerContact partner) => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ToyControlView(target: RemoteToyTarget(partner))),
      );

  @override
  State<ToyControlView> createState() => _ToyControlViewState();
}

class _ToyControlViewState extends State<ToyControlView> {
  ToyControlTarget get t => widget.target;

  double _level = 0;
  bool _dragging = false;
  bool _holding = false;
  int _strength = 12;

  CadenceMode _mode = CadenceMode.fixed;
  int _bpm = 60;
  RangeValues _range = const RangeValues(40, 120);
  CadenceToyMode _toyMode = CadenceToyMode.pulse;
  bool _sound = false;
  int _minutes = 0;

  /// Metronome chosen among the patterns: its settings show, ready to start.
  bool _metronomeOpen = false;

  static const _durations = [0, 1, 2, 5, 10, 15, 30, 60];

  bool get _needsDuration => _mode == CadenceMode.wave || _mode == CadenceMode.peak || _mode == CadenceMode.ramp;

  @override
  void initState() {
    super.initState();
    t.addListener(_changed);
    t.open();
  }

  @override
  void dispose() {
    t.removeListener(_changed);
    // A partner's toy stops when you leave; your own keeps going until you
    // stop it, as a running metronome on the cadence screen does.
    t.close().whenComplete(t.dispose);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {
      // Follow the toy unless the slider is in the user's hand.
      if (!_dragging && !_holding) {
        _level = t.activity == ToyActivity.level ? t.level.toDouble() : 0;
      }
    });
  }

  CadenceConfig _config() => CadenceConfig(
        mode: _mode,
        bpm: _bpm,
        minBpm: _range.start.round(),
        maxBpm: _range.end.round(),
        toyMode: _toyMode,
        enableAudio: _sound,
        enableHaptics: false,
        enableToy: true,
      );

  int get _seconds {
    final m = _needsDuration && _minutes == 0 ? 5 : _minutes;
    return m * 60;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ready = t.ready;

    return Scaffold(
      appBar: AppBar(title: Text(t.title)),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                _statusCard(theme),
                const SizedBox(height: 12),
                SizedBox(
                  height: 56,
                  child: FilledButton.icon(
                    key: const Key('toy-stop'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    icon: const Icon(Icons.stop_circle_rounded),
                    label: const Text('STOP', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                    onPressed: () {
                      setState(() {
                        _level = 0;
                        _holding = false;
                      });
                      t.stop();
                    },
                  ),
                ),
                const SizedBox(height: 16),
                AbsorbPointer(
                  absorbing: !ready,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 200),
                    opacity: ready ? 1 : 0.45,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _directCard(theme),
                        const SizedBox(height: 12),
                        _patternsCard(theme),
                      ],
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

  Widget _section(ThemeData theme, String title, IconData icon, List<Widget> children) => Card(
        elevation: 0,
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Icon(icon, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              ]),
              const SizedBox(height: 8),
              ...children,
            ],
          ),
        ),
      );

  Widget _statusCard(ThemeData theme) {
    final blocked = t.blockedReason;
    final activity = switch (t.activity) {
      ToyActivity.idle => 'Still',
      ToyActivity.level => 'Holding at ${t.level}/20',
      ToyActivity.pattern => 'Playing ${t.pattern?.displayName ?? 'a pattern'}',
      ToyActivity.metronome => t.bpm == null ? 'Metronome' : 'Metronome · ${t.bpm} BPM',
    };
    return Card(
      elevation: 0,
      color: theme.colorScheme.primary.withValues(alpha: 0.08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.primary.withValues(alpha: 0.3)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(
                t.ready ? Icons.bluetooth_connected_rounded : Icons.bluetooth_disabled_rounded,
                color: t.ready ? theme.colorScheme.primary : theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  t.toyName ?? 'No toy',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ),
              if (t.battery >= 0) Text('${t.battery}%', style: const TextStyle(fontWeight: FontWeight.bold)),
            ]),
            const SizedBox(height: 10),
            Text(blocked ?? activity, key: const Key('toy-status')),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(minHeight: 8, value: (t.speed / 20).clamp(0.0, 1.0)),
            ),
            if (t.note != null) ...[
              const SizedBox(height: 8),
              Text(
                t.note!,
                style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _directCard(ThemeData theme) {
    final max = t.cap.toDouble();
    return _section(theme, 'Direct', Icons.tune_rounded, [
      Row(children: [
        const Text('Intensity'),
        const Spacer(),
        Text('${_level.round()}/20', style: const TextStyle(fontWeight: FontWeight.bold)),
      ]),
      Slider(
        key: const Key('toy-level'),
        value: _level.clamp(0, max),
        max: max,
        divisions: t.cap,
        onChangeStart: (_) => _dragging = true,
        onChanged: (v) {
          setState(() => _level = v);
          t.setLevel(v.round());
        },
        onChangeEnd: (v) {
          _dragging = false;
          t.setLevel(v.round());
        },
      ),
      const SizedBox(height: 4),
      GestureDetector(
        onTapDown: (_) {
          setState(() => _holding = true);
          final v = _level.round() > 0 ? _level.round() : (_strength.clamp(1, t.cap));
          t.setLevel(v);
        },
        onTapUp: (_) => _release(),
        onTapCancel: _release,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 64,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _holding ? theme.colorScheme.primary : theme.colorScheme.primary.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            _holding ? 'Buzzing…' : 'Hold to buzz',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: _holding ? theme.colorScheme.onPrimary : theme.colorScheme.primary,
            ),
          ),
        ),
      ),
    ]);
  }

  void _release() {
    if (!_holding) return;
    setState(() {
      _holding = false;
      _level = 0;
    });
    t.stop();
  }

  Widget _strengthSlider() => Row(children: [
        const Text('Strength'),
        Expanded(
          child: Slider(
            value: _strength.clamp(1, t.cap).toDouble(),
            min: 1,
            max: t.cap.toDouble().clamp(1, 20),
            divisions: (t.cap - 1).clamp(1, 19),
            label: '$_strength',
            onChanged: (v) => setState(() => _strength = v.round()),
            onChangeEnd: (v) {
              if (t.activity == ToyActivity.pattern || t.activity == ToyActivity.metronome) {
                t.setStrength(v.round());
              }
            },
          ),
        ),
        SizedBox(width: 28, child: Text('$_strength', textAlign: TextAlign.end)),
      ]);

  /// Patterns, with the metronome as one of them: a beat whose tempo you
  /// set, where the others are fixed shapes that just play.
  Widget _patternsCard(ThemeData theme) {
    final running = t.activity == ToyActivity.metronome;
    final showMetronome = running || _metronomeOpen;
    return _section(theme, 'Patterns', Icons.graphic_eq_rounded, [
      _strengthSlider(),
      const SizedBox(height: 4),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          Tooltip(
            message: 'A beat at a tempo you set, with an optional click',
            child: ChoiceChip(
              key: const Key('toy-pattern-metronome'),
              avatar: const Icon(Icons.av_timer_rounded, size: 18),
              label: const Text('Metronome'),
              selected: showMetronome,
              onSelected: (_) {
                if (running) {
                  t.stop();
                  setState(() => _metronomeOpen = false);
                } else {
                  setState(() => _metronomeOpen = !_metronomeOpen);
                }
              },
            ),
          ),
          for (final p in ToyPattern.values)
            Tooltip(
              message: p.description,
              child: ChoiceChip(
                key: Key('toy-pattern-${p.name}'),
                label: Text(p.displayName),
                selected: t.activity == ToyActivity.pattern && t.pattern == p,
                onSelected: (_) {
                  setState(() => _metronomeOpen = false);
                  if (t.activity == ToyActivity.pattern && t.pattern == p) {
                    t.stop();
                  } else {
                    t.playPattern(p, _strength.clamp(1, t.cap));
                  }
                },
              ),
            ),
        ],
      ),
      if (showMetronome) ...[
        const SizedBox(height: 12),
        const Divider(height: 1),
        const SizedBox(height: 12),
        ..._metronomeSettings(running),
      ],
    ]);
  }

  List<Widget> _metronomeSettings(bool running) {
    const modes = {
      CadenceMode.fixed: 'Steady',
      CadenceMode.wave: 'Wave',
      CadenceMode.peak: 'Peak',
      CadenceMode.ramp: 'Ramp',
      CadenceMode.random: 'Random',
    };
    final durations = _needsDuration ? _durations.where((d) => d > 0).toList() : _durations;
    final minutes = durations.contains(_minutes) ? _minutes : durations.first;

    return [
      const Text('Tempo', style: TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final e in modes.entries)
          ChoiceChip(
            key: Key('toy-tempo-${e.key.name}'),
            label: Text(e.value),
            selected: _mode == e.key,
            onSelected: (_) => setState(() => _mode = e.key),
          ),
      ]),
      const SizedBox(height: 8),
      if (_mode == CadenceMode.fixed) ...[
        Text('Tempo: $_bpm BPM'),
        Slider(
          value: _bpm.toDouble(),
          min: 20,
          max: 200,
          divisions: 180,
          onChanged: (v) => setState(() => _bpm = v.round()),
          onChangeEnd: (_) {
            if (running) t.updateMetronome(_config());
          },
        ),
      ] else ...[
        Text('Tempo: ${_range.start.round()}–${_range.end.round()} BPM'),
        RangeSlider(
          values: _range,
          min: 20,
          max: 200,
          divisions: 180,
          onChanged: (v) => setState(() => _range = v),
          onChangeEnd: (_) {
            if (running) t.updateMetronome(_config());
          },
        ),
      ],
      SegmentedButton<CadenceToyMode>(
        segments: const [
          ButtonSegment(value: CadenceToyMode.pulse, label: Text('Beat pulses')),
          ButtonSegment(value: CadenceToyMode.continuous, label: Text('Steady buzz')),
        ],
        selected: {_toyMode},
        onSelectionChanged: (s) {
          setState(() => _toyMode = s.first);
          if (running) t.updateMetronome(_config());
        },
      ),
      const SizedBox(height: 8),
      Row(children: [
        const Text('Length'),
        const SizedBox(width: 12),
        Expanded(
          child: DropdownButton<int>(
            isExpanded: true,
            value: minutes,
            items: [
              for (final d in durations)
                DropdownMenuItem(
                  value: d,
                  child: Text(d == 0 ? 'Until stopped' : '$d min', overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) => setState(() => _minutes = v ?? 0),
          ),
        ),
      ]),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(t.soundLabel),
        value: _sound,
        onChanged: (v) {
          setState(() => _sound = v);
          if (running) t.updateMetronome(_config());
        },
      ),
      const SizedBox(height: 4),
      Row(children: [
        Expanded(
          child: FilledButton.icon(
            key: const Key('toy-metronome-start'),
            icon: Icon(running ? Icons.restart_alt_rounded : Icons.play_arrow_rounded),
            label: Text(running ? 'Restart' : 'Start'),
            onPressed: () {
              _minutes = minutes;
              t.startMetronome(_config(), seconds: _seconds, strength: _strength.clamp(1, t.cap));
            },
          ),
        ),
        if (running) ...[
          const SizedBox(width: 8),
          OutlinedButton(onPressed: t.stop, child: const Text('Stop')),
        ],
      ]),
    ];
  }
}
