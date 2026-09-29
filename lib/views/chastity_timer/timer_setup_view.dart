import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/chastity_timer.dart';
import '../../models/partner_contact.dart';
import '../../services/chastity_timer_service.dart';
import '../../services/partner_service.dart';
import '../../services/sync_service.dart';
import 'timer_detail_view.dart';
import 'timer_format.dart';

/// Setting up a timer. A director sets one up for a player, and manages it;
/// a player can set up their own, optionally with a director who may change
/// it. Everything chosen here is checked again by the Worker.
class TimerSetupView extends StatefulWidget {
  const TimerSetupView({super.key, required this.role});

  /// The side this device is on: director (for a partner) or player (own).
  final TimerRole role;

  @override
  State<TimerSetupView> createState() => _TimerSetupViewState();
}

class _TimerSetupViewState extends State<TimerSetupView> {
  PartnerContact? _partner;

  Duration _base = const Duration(days: 1);
  bool _hidden = false;
  bool _ceilingOn = false;
  Duration _ceiling = const Duration(days: 7);

  bool _directorCanAdd = true;
  bool _directorCanRemove = true;
  bool _directorUnlimited = true;
  Duration _directorCap = const Duration(hours: 4);

  bool _randomOn = false;
  Duration _randomEvery = const Duration(hours: 4);
  Duration _randomRemoveUpTo = const Duration(minutes: 30);
  Duration _randomAddUpTo = const Duration(hours: 1);

  bool _publicOn = false;
  Duration _publicStep = const Duration(minutes: 10);
  bool _publicRemove = false;
  Duration _publicPerVisitor = const Duration(hours: 1);
  bool _publicUnlimited = false;
  Duration _publicCap = const Duration(hours: 12);
  bool _publicShowTime = true;

  bool _comboOn = false;
  int _comboLength = 4;
  bool _comboGenerate = true;
  String _comboDigits = '';
  final _comboController = TextEditingController();

  bool _saving = false;

  bool get _isDirector => widget.role == TimerRole.director;

  @override
  void initState() {
    super.initState();
    _regenerate();
  }

  @override
  void dispose() {
    _comboController.dispose();
    super.dispose();
  }

  void _regenerate() {
    final rng = Random.secure();
    _comboDigits = List.generate(_comboLength, (_) => rng.nextInt(10)).join();
  }

  String get _combination => _comboGenerate
      ? _comboDigits
      : _comboController.text.replaceAll(RegExp(r'\D'), '');

  /// Every paired contact, as the dashboards list them. Not filtered by the
  /// role saved with the contact: that is often "peer", and devices switch
  /// sides, so filtering on it hid real partners and said nobody was paired.
  /// Contacts whose copy lacks the timer are listed too, disabled, with why.
  List<PartnerContact> _candidates(PartnerService partners, SyncService sync) {
    int rank(PartnerContact c) {
      if (!sync.partnerHas(c, chastityTimerFeature)) return 2;
      final fits = _isDirector ? c.role == PartnerRole.submissive : c.role == PartnerRole.dominant;
      return fits ? 0 : 1;
    }

    return partners.unblockedContacts
        .where((c) => !c.isSelf && c.pairingCode.isNotEmpty)
        .toList()
      ..sort((a, b) {
        final byRank = rank(a).compareTo(rank(b));
        return byRank != 0 ? byRank : a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
      });
  }

  Future<void> _create() async {
    if (_isDirector && _partner == null) {
      _snack('Choose who the timer is for.');
      return;
    }
    if (_comboOn && _combination.length < 3) {
      _snack('Enter a combination of at least 3 digits.');
      return;
    }
    setState(() => _saving = true);
    final timers = Provider.of<ChastityTimerService>(context, listen: false);
    final sync = Provider.of<SyncService>(context, listen: false);

    final config = ChastityTimerConfig(
      baseSeconds: _base.inSeconds,
      hidden: _hidden,
      maxTotalSeconds: _ceilingOn ? _ceiling.inSeconds : null,
      director: DirectorLimits(
        canAdd: _directorCanAdd,
        canRemove: _directorCanRemove,
        dailyCapSeconds: _directorUnlimited ? null : _directorCap.inSeconds,
      ),
      random: RandomChanges(
        enabled: _randomOn,
        everyMinutes: _randomEvery.inMinutes,
        minSeconds: -_randomRemoveUpTo.inSeconds,
        maxSeconds: _randomAddUpTo.inSeconds,
      ),
      publicLink: PublicLinkSettings(
        enabled: _publicOn,
        allowRemove: _publicRemove,
        stepSeconds: _publicStep.inSeconds,
        perVisitorDailySeconds: _publicPerVisitor.inSeconds,
        dailyCapSeconds: _publicUnlimited ? null : _publicCap.inSeconds,
        showTimeLeft: _publicShowTime,
      ),
      combinationEnabled: _comboOn,
      combinationDigits: _comboOn ? _combination : null,
    );

    final result = await timers.create(
      config: config,
      role: widget.role,
      partnerCode: _partner?.pairingCode,
      partnerName: _partner?.displayName,
    );
    if (!mounted) return;
    setState(() => _saving = false);

    if (result.view == null) {
      _snack(describeTimerError(result.error));
      return;
    }
    final partner = _partner;
    if (partner != null && result.partnerKey != null) {
      await sync.shareTimer(
        partner,
        timerId: result.view!.id,
        key: result.partnerKey!,
        theirRole: _isDirector ? TimerRole.player : TimerRole.director,
      );
    }
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
          builder: (_) => TimerDetailView(timerId: result.view!.id)),
    );
  }

  void _snack(String text) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final partners = Provider.of<PartnerService>(context);
    final sync = Provider.of<SyncService>(context);
    final candidates = _candidates(partners, sync);
    final partnerChosen = _partner != null;

    return Scaffold(
      appBar: AppBar(title: Text(_isDirector ? 'New timer' : 'My timer')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _section(theme, _isDirector ? 'WHO IT\'S FOR' : 'DIRECTOR'),
          Card(
            child: RadioGroup<String?>(
              groupValue: _partner?.id,
              onChanged: (id) => setState(() {
                _partner = id == null
                    ? null
                    : candidates.firstWhere((c) => c.id == id);
              }),
              child: Column(
                children: [
                  if (!_isDirector)
                    const RadioListTile<String?>(
                      value: null,
                      title: Text('Just me'),
                      subtitle: Text('Nobody else can change it.'),
                    ),
                  if (candidates.isEmpty && _isDirector)
                    const ListTile(
                        title: Text(
                            'Nobody is paired yet. Pair with someone in Contacts first.')),
                  ...candidates.map((c) {
                    final has = sync.partnerHas(c, chastityTimerFeature);
                    return RadioListTile<String?>(
                      value: c.id,
                      enabled: has,
                      title: Text(c.displayName),
                      subtitle: has
                          ? Text(_isDirector
                              ? 'Will get their key to this timer.'
                              : 'Can add or remove time, as allowed below.')
                          : Text(
                              _isDirector
                                  ? partnerCannotReceiveTimer(c)
                                  : partnerCannotManageTimer(c),
                              style: TextStyle(
                                  fontSize: 12,
                                  color: theme.colorScheme.error)),
                      isThreeLine: !has,
                    );
                  }),
                ],
              ),
            ),
          ),
          _section(theme, 'LENGTH'),
          Card(
            child: Column(
              children: [
                _DurationTile(
                  label: 'Starts at',
                  value: _base,
                  onChanged: (d) => setState(() => _base = d),
                ),
                SwitchListTile(
                  value: _hidden,
                  onChanged: (v) => setState(() => _hidden = v),
                  title: Text(_isDirector
                      ? 'Hide the time from them'
                      : 'Hide the time from me'),
                  subtitle: const Text(
                      'The player sees that it is running, and who changed it, but not how long is left or by how much.'),
                ),
                SwitchListTile(
                  value: _ceilingOn,
                  onChanged: (v) => setState(() => _ceilingOn = v),
                  title: const Text('Maximum length'),
                  subtitle: const Text(
                      'No change can push it past this, counted from the start.'),
                ),
                if (_ceilingOn)
                  _DurationTile(
                      label: 'At most',
                      value: _ceiling,
                      onChanged: (d) => setState(() => _ceiling = d)),
              ],
            ),
          ),
          if (partnerChosen) ...[
            _section(theme, _isDirector ? 'YOUR CHANGES' : 'THEIR CHANGES'),
            Card(
              child: Column(
                children: [
                  SwitchListTile(
                    value: _directorCanAdd,
                    onChanged: (v) => setState(() => _directorCanAdd = v),
                    title: Text(
                        _isDirector ? 'I can add time' : 'They can add time'),
                  ),
                  SwitchListTile(
                    value: _directorCanRemove,
                    onChanged: (v) => setState(() => _directorCanRemove = v),
                    title: Text(_isDirector
                        ? 'I can remove time'
                        : 'They can remove time'),
                  ),
                  SwitchListTile(
                    value: _directorUnlimited,
                    onChanged: (v) => setState(() => _directorUnlimited = v),
                    title: const Text('Unlimited changes'),
                    subtitle: const Text(
                        'Off: a daily limit on how much can be changed, added and removed together.'),
                  ),
                  if (!_directorUnlimited)
                    _DurationTile(
                      label: 'Per 24 hours',
                      value: _directorCap,
                      onChanged: (d) => setState(() => _directorCap = d),
                    ),
                ],
              ),
            ),
          ],
          _section(theme, 'RANDOM CHANGES'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  value: _randomOn,
                  onChanged: (v) => setState(() => _randomOn = v),
                  title: const Text('Let the app change it at random'),
                  subtitle: const Text(
                      'Rolled on a fixed schedule. Nobody can re-roll it.'),
                ),
                if (_randomOn) ...[
                  _DurationTile(
                    label: 'Every',
                    value: _randomEvery,
                    minimum: const Duration(minutes: 15),
                    onChanged: (d) => setState(() => _randomEvery = d),
                  ),
                  _DurationTile(
                    label: 'Remove up to',
                    value: _randomRemoveUpTo,
                    allowZero: true,
                    onChanged: (d) => setState(() => _randomRemoveUpTo = d),
                  ),
                  _DurationTile(
                    label: 'Add up to',
                    value: _randomAddUpTo,
                    allowZero: true,
                    onChanged: (d) => setState(() => _randomAddUpTo = d),
                  ),
                ],
              ],
            ),
          ),
          _section(theme, 'PUBLIC LINK'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  value: _publicOn,
                  onChanged: (v) => setState(() => _publicOn = v),
                  title: const Text('Let anyone with the link vote'),
                  subtitle: const Text(
                      'A web page anyone can open. It never shows who you are.'),
                ),
                if (_publicOn) ...[
                  _DurationTile(
                      label: 'Each vote',
                      value: _publicStep,
                      onChanged: (d) => setState(() => _publicStep = d)),
                  SwitchListTile(
                    value: _publicRemove,
                    onChanged: (v) => setState(() => _publicRemove = v),
                    title: const Text('Votes can remove time too'),
                  ),
                  _DurationTile(
                    label: 'Per visitor, per day',
                    value: _publicPerVisitor,
                    onChanged: (d) => setState(() => _publicPerVisitor = d),
                  ),
                  SwitchListTile(
                    value: _publicUnlimited,
                    onChanged: (v) => setState(() => _publicUnlimited = v),
                    title: const Text('No daily limit across everyone'),
                  ),
                  if (!_publicUnlimited)
                    _DurationTile(
                      label: 'Everyone, per day',
                      value: _publicCap,
                      onChanged: (d) => setState(() => _publicCap = d),
                    ),
                  SwitchListTile(
                    value: _publicShowTime,
                    onChanged: (v) => setState(() => _publicShowTime = v),
                    title: const Text('Show visitors the time left'),
                  ),
                ],
              ],
            ),
          ),
          _section(theme, 'COMBINATION'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  value: _comboOn,
                  onChanged: (v) => setState(() => _comboOn = v),
                  title: const Text('Reveal a combination at the end'),
                  subtitle: Text(_isDirector
                      ? "For a combination lock, or a lockbox holding the key. The player only sees it when the timer ends."
                      : 'Set your lock to it, then scramble the dials. The app shows it again when the timer ends.'),
                ),
                if (_comboOn) ...[
                  SwitchListTile(
                    value: _comboGenerate,
                    onChanged: (v) => setState(() => _comboGenerate = v),
                    title: const Text('Generate one for me'),
                  ),
                  if (_comboGenerate) ...[
                    ListTile(
                      title: const Text('Digits'),
                      trailing: DropdownButton<int>(
                        value: _comboLength,
                        items: [
                          for (var n = 3; n <= 8; n++)
                            DropdownMenuItem(value: n, child: Text('$n'))
                        ],
                        onChanged: (n) => setState(() {
                          _comboLength = n!;
                          _regenerate();
                        }),
                      ),
                    ),
                    ListTile(
                      title: Text(
                        _comboDigits.split('').join(' '),
                        style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 4,
                            fontFeatures: [FontFeature.tabularFigures()]),
                      ),
                      subtitle:
                          const Text('Set your lock to this before starting.'),
                      trailing: IconButton(
                        tooltip: 'Generate another',
                        icon: const Icon(Icons.refresh_rounded),
                        onPressed: () => setState(_regenerate),
                      ),
                    ),
                  ] else
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: TextField(
                        controller: _comboController,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(12)
                        ],
                        decoration: const InputDecoration(
                          labelText: "The lock's combination",
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _saving ? null : _create,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.lock_clock_rounded),
            label: Text(_saving ? 'Starting…' : 'Start the timer'),
            style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14)),
          ),
          const SizedBox(height: 8),
          Text(
            _isDirector
                ? 'The player can always end it with an emergency release. You will be told if they do.'
                : 'You can always end it with an emergency release. Your director is told if you do.',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
          ),
        ],
      ),
    );
  }

  Widget _section(ThemeData theme, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
        child: Text(
          text,
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
              color: theme.colorScheme.primary),
        ),
      );
}

/// A duration shown as text, set with a days / hours / minutes dialog.
class _DurationTile extends StatelessWidget {
  const _DurationTile({
    required this.label,
    required this.value,
    required this.onChanged,
    this.minimum = const Duration(minutes: 1),
    this.allowZero = false,
  });

  final String label;
  final Duration value;
  final ValueChanged<Duration> onChanged;
  final Duration minimum;
  final bool allowZero;

  @override
  Widget build(BuildContext context) => ListTile(
        title: Text(label),
        trailing: Text(
          value == Duration.zero ? 'None' : formatSpan(value),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        onTap: () async {
          final picked =
              await showDurationDialog(context, title: label, initial: value);
          if (picked == null) return;
          if (picked == Duration.zero && allowZero) {
            onChanged(Duration.zero);
          } else {
            onChanged(picked < minimum ? minimum : picked);
          }
        },
      );
}

/// Asks for a length in days, hours and minutes.
Future<Duration?> showDurationDialog(BuildContext context,
    {required String title, Duration initial = Duration.zero}) {
  final days = TextEditingController(text: '${initial.inDays}');
  final hours = TextEditingController(text: '${initial.inHours % 24}');
  final minutes = TextEditingController(text: '${initial.inMinutes % 60}');
  Widget field(TextEditingController c, String label) => Expanded(
        child: TextField(
          controller: c,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(4)
          ],
          textAlign: TextAlign.center,
          decoration: InputDecoration(
              labelText: label, border: const OutlineInputBorder()),
        ),
      );
  return showDialog<Duration>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Row(
        children: [
          field(days, 'Days'),
          const SizedBox(width: 8),
          field(hours, 'Hours'),
          const SizedBox(width: 8),
          field(minutes, 'Min'),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            int n(TextEditingController c) => int.tryParse(c.text) ?? 0;
            Navigator.pop(ctx,
                Duration(days: n(days), hours: n(hours), minutes: n(minutes)));
          },
          child: const Text('Set'),
        ),
      ],
    ),
  ).whenComplete(() {
    days.dispose();
    hours.dispose();
    minutes.dispose();
  });
}
