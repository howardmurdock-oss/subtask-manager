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
  bool _openEnded = false;
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
  bool _publicShareWithPlayer = false;

  bool _comboOn = false;
  int _comboLength = 4;
  bool _comboGenerate = true;
  String _comboDigits = '';
  final _comboController = TextEditingController();

  bool _notifyOn = true;
  final _noticeController = TextEditingController();

  bool _saving = false;

  bool get _isDirector => widget.role == TimerRole.director;

  /// Your own timer with no end time needs no limit: you end it when you
  /// like, and a limit would only make it a timed lock.
  bool get _limitOffered => !_openEnded || _isDirector;

  @override
  void initState() {
    super.initState();
    _regenerate();
  }

  @override
  void dispose() {
    _comboController.dispose();
    _noticeController.dispose();
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
      openEnded: _openEnded,
      notifyOnAdd: !_openEnded && _notifyOn,
      notifyMessage: _noticeController.text.trim().isEmpty ? null : _noticeController.text.trim(),
      hidden: !_openEnded && _hidden,
      maxTotalSeconds: _ceilingOn && _limitOffered ? _ceiling.inSeconds : null,
      director: DirectorLimits(
        canAdd: _directorCanAdd,
        canRemove: _directorCanRemove,
        dailyCapSeconds: _directorUnlimited ? null : _directorCap.inSeconds,
      ),
      random: RandomChanges(
        enabled: !_openEnded && _randomOn,
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
        shareWithPlayer: _isDirector && _publicShareWithPlayer,
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
        // Room for the system navigation bar: Android draws the app behind
        // it, and the last lines of this page sat underneath.
        padding: EdgeInsets.fromLTRB(16, 8, 16, 32 + MediaQuery.paddingOf(context).bottom),
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
                SwitchListTile(
                  value: _openEnded,
                  onChanged: (v) => setState(() => _openEnded = v),
                  title: const Text('No end time'),
                  subtitle: Text(_isDirector
                      ? 'It runs until you end it. They can still use the emergency release.'
                      : 'It runs until you end it, whenever you like.'),
                ),
                if (!_openEnded) ...[
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
                ],
                if (_limitOffered)
                SwitchListTile(
                  value: _ceilingOn,
                  onChanged: (v) => setState(() => _ceilingOn = v),
                  title: Text(_openEnded ? 'End by itself eventually' : 'Maximum length'),
                  subtitle: Text(_openEnded
                      ? 'A safety limit: it ends on its own after this long, counted from the start.'
                      : 'No change can push it past this, counted from the start.'),
                ),
                if (_ceilingOn && _limitOffered)
                  _DurationTile(
                      label: 'At most',
                      value: _ceiling,
                      onChanged: (d) => setState(() => _ceiling = d)),
              ],
            ),
          ),
          // With no end time there is nothing to add, remove or roll.
          if (partnerChosen && !_openEnded) ...[
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
          if (!_openEnded) _section(theme, 'RANDOM CHANGES'),
          if (!_openEnded) Card(
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
          // Nothing is ever added to a timer with no end time.
          if (!_openEnded) ...[
            _section(theme, 'NOTIFICATIONS'),
            Card(
              child: Column(
                children: [
                  SwitchListTile(
                    value: _notifyOn,
                    onChanged: (v) => setState(() => _notifyOn = v),
                    title: Text(_isDirector ? 'Tell them when time is added' : 'Tell me when time is added'),
                    subtitle: Text(_isDirector
                        ? 'Each time you or the public add time.'
                        : 'Each time anyone adds time.'),
                  ),
                  if (_notifyOn)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                      child: NoticeMessageField(
                        controller: _noticeController,
                        by: _isDirector ? TimerActor.director : TimerActor.public,
                        onChanged: () => setState(() {}),
                      ),
                    ),
                ],
              ),
            ),
          ],
          _section(theme, 'PUBLIC LINK'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  value: _publicOn,
                  onChanged: (v) => setState(() => _publicOn = v),
                  title: Text(_openEnded ? 'Share a public link' : 'Let anyone with the link vote'),
                  subtitle: Text(_openEnded
                      ? "A web page showing how long it's been running. It never shows who you are."
                      : 'A web page anyone can open. It never shows who you are.'),
                ),
                if (_publicOn && !_openEnded) ...[
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
                  if (_isDirector && partnerChosen)
                    SwitchListTile(
                      value: _publicShareWithPlayer,
                      onChanged: (v) => setState(() => _publicShareWithPlayer = v),
                      title: const Text('Give them the link too'),
                      subtitle: Text(
                        _hidden && _publicShowTime
                            ? 'So they can hand it out. The page shows the time left, so with the link they could see it.'
                            : 'So they can hand it out. Only you can replace the link or switch it off.',
                      ),
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
                : _openEnded
                    ? 'End it whenever you like, from the timer screen.'
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
        {required String title, Duration initial = Duration.zero}) =>
    showDialog<Duration>(
      context: context,
      builder: (_) => _DurationDialog(title: title, initial: initial),
    );

/// Each box has its unit written underneath, and the total is spelled out
/// below them. The fields' own floating labels were not shown by the app's
/// theme, which left three unlabelled boxes.
///
/// A widget of its own so it owns its controllers: disposing them when the
/// dialog returned broke the fields while its closing animation still drew
/// them.
class _DurationDialog extends StatefulWidget {
  const _DurationDialog({required this.title, required this.initial});

  final String title;
  final Duration initial;

  @override
  State<_DurationDialog> createState() => _DurationDialogState();
}

class _DurationDialogState extends State<_DurationDialog> {
  late final _days = TextEditingController(text: '${widget.initial.inDays}');
  late final _hours = TextEditingController(text: '${widget.initial.inHours % 24}');
  late final _minutes = TextEditingController(text: '${widget.initial.inMinutes % 60}');

  @override
  void dispose() {
    _days.dispose();
    _hours.dispose();
    _minutes.dispose();
    super.dispose();
  }

  int _n(TextEditingController c) => int.tryParse(c.text) ?? 0;
  Duration get _total => Duration(days: _n(_days), hours: _n(_hours), minutes: _n(_minutes));

  Widget _field(TextEditingController c, String unit, ThemeData theme) => Expanded(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: c,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(4)
              ],
              textAlign: TextAlign.center,
              onChanged: (_) => setState(() {}),
              // Typing replaces the 0 rather than landing beside it.
              onTap: () => c.selection = TextSelection(baseOffset: 0, extentOffset: c.text.length),
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
            const SizedBox(height: 6),
            Text(
              unit,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
              ),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final span = _total;
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _field(_days, 'days', theme),
              const SizedBox(width: 8),
              _field(_hours, 'hours', theme),
              const SizedBox(width: 8),
              _field(_minutes, 'minutes', theme),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            span == Duration.zero ? 'None' : '= ${formatSpan(span)}',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _total),
          child: const Text('Set'),
        ),
      ],
    );
  }
}

/// The player's notification message: their own words, with "{time}" for
/// the amount, and a preview of how it reads with who added it.
class NoticeMessageField extends StatelessWidget {
  const NoticeMessageField({super.key, required this.controller, required this.by, this.onChanged});

  final TextEditingController controller;
  final TimerActor by;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: controller,
          maxLength: noticeMessageMax,
          onChanged: (_) => onChanged?.call(),
          decoration: const InputDecoration(
            labelText: 'Message (optional)',
            hintText: '{time} was added',
            helperText: 'Use {time} for the amount. Who added it is always said.',
            helperMaxLines: 2,
          ),
        ),
        const SizedBox(height: 6),
        Text('Reads as:', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
        Text(
          '"${addedNotice(message: controller.text, amount: const Duration(minutes: 10), by: by)}"',
          style: const TextStyle(fontStyle: FontStyle.italic),
        ),
      ],
    );
  }
}

/// Edits the notification message. Returns it ('' for the plain one), or
/// null when cancelled.
Future<String?> showNoticeMessageDialog(BuildContext context, String? current) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => _NoticeMessageDialog(initial: current ?? ''),
  );
}

class _NoticeMessageDialog extends StatefulWidget {
  const _NoticeMessageDialog({required this.initial});
  final String initial;

  @override
  State<_NoticeMessageDialog> createState() => _NoticeMessageDialogState();
}

class _NoticeMessageDialogState extends State<_NoticeMessageDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Notification message'),
      content: SingleChildScrollView(
        child: NoticeMessageField(controller: _controller, by: TimerActor.director, onChanged: () => setState(() {})),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, _controller.text.trim()), child: const Text('Save')),
      ],
    );
  }
}
