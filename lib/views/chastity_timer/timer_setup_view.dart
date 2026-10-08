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
import 'public_orders_editor.dart';
import '../../services/timer_presets.dart';

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
  PublicOrdersSettings _publicOrders = const PublicOrdersSettings();
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
  bool _rewardOn = false;
  final _rewardController = TextEditingController(text: '50');
  int? get _reward {
    final n = int.tryParse(_rewardController.text.trim());
    return _isDirector && _rewardOn && n != null && n > 0 ? n : null;
  }
  final _noticeController = TextEditingController();

  bool _saving = false;

  bool get _isDirector => widget.role == TimerRole.director;

  bool _otherComboRunning(BuildContext context) {
    final timers = Provider.of<ChastityTimerService>(context, listen: false);
    return timers.runningAsPlayer().any((r) => timers.viewOf(r.id)?.config.combinationEnabled ?? false);
  }

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
    _rewardController.dispose();
    super.dispose();
  }

  // ---- Saved settings -------------------------------------------------------

  /// The screen's settings, to save. Not the combination's digits, nor who
  /// the timer is for.
  Map<String, dynamic> _settings() => {
        'base': _base.inSeconds,
        'hidden': _hidden,
        'openEnded': _openEnded,
        'ceilingOn': _ceilingOn,
        'ceiling': _ceiling.inSeconds,
        'directorCanAdd': _directorCanAdd,
        'directorCanRemove': _directorCanRemove,
        'directorUnlimited': _directorUnlimited,
        'directorCap': _directorCap.inSeconds,
        'randomOn': _randomOn,
        'randomEvery': _randomEvery.inSeconds,
        'randomRemoveUpTo': _randomRemoveUpTo.inSeconds,
        'randomAddUpTo': _randomAddUpTo.inSeconds,
        'publicOn': _publicOn,
        'publicOrders': _publicOrders.toJson(),
        'publicStep': _publicStep.inSeconds,
        'publicRemove': _publicRemove,
        'publicPerVisitor': _publicPerVisitor.inSeconds,
        'publicUnlimited': _publicUnlimited,
        'publicCap': _publicCap.inSeconds,
        'publicShowTime': _publicShowTime,
        'publicShareWithPlayer': _publicShareWithPlayer,
        'comboOn': _comboOn,
        'comboLength': _comboLength,
        'comboGenerate': _comboGenerate,
        'notifyOn': _notifyOn,
        'notice': _noticeController.text,
        'rewardOn': _rewardOn,
        'reward': _rewardController.text,
      };

  /// Puts saved settings back on the screen. Anything missing - saved by an
  /// older copy - keeps what the screen has.
  void _apply(Map<String, dynamic> s) {
    Duration d(String k, Duration now) => s[k] is num ? Duration(seconds: (s[k] as num).toInt()) : now;
    bool b(String k, bool now) => s[k] is bool ? s[k] as bool : now;
    setState(() {
      _base = d('base', _base);
      _hidden = b('hidden', _hidden);
      _openEnded = b('openEnded', _openEnded);
      _ceilingOn = b('ceilingOn', _ceilingOn);
      _ceiling = d('ceiling', _ceiling);
      _directorCanAdd = b('directorCanAdd', _directorCanAdd);
      _directorCanRemove = b('directorCanRemove', _directorCanRemove);
      _directorUnlimited = b('directorUnlimited', _directorUnlimited);
      _directorCap = d('directorCap', _directorCap);
      _randomOn = b('randomOn', _randomOn);
      _randomEvery = d('randomEvery', _randomEvery);
      _randomRemoveUpTo = d('randomRemoveUpTo', _randomRemoveUpTo);
      _randomAddUpTo = d('randomAddUpTo', _randomAddUpTo);
      _publicOn = b('publicOn', _publicOn);
      if (s['publicOrders'] is Map) {
        _publicOrders = PublicOrdersSettings.fromJson(Map<String, dynamic>.from(s['publicOrders'] as Map));
      }
      _publicStep = d('publicStep', _publicStep);
      _publicRemove = b('publicRemove', _publicRemove);
      _publicPerVisitor = d('publicPerVisitor', _publicPerVisitor);
      _publicUnlimited = b('publicUnlimited', _publicUnlimited);
      _publicCap = d('publicCap', _publicCap);
      _publicShowTime = b('publicShowTime', _publicShowTime);
      _publicShareWithPlayer = b('publicShareWithPlayer', _publicShareWithPlayer);
      _comboOn = b('comboOn', _comboOn);
      if (s['comboLength'] is num) _comboLength = (s['comboLength'] as num).toInt().clamp(3, 8);
      _comboGenerate = b('comboGenerate', _comboGenerate);
      // A fresh combination each time: the digits are never saved.
      _regenerate();
      _comboController.clear();
      _notifyOn = b('notifyOn', _notifyOn);
      if (s['notice'] is String) _noticeController.text = s['notice'] as String;
      _rewardOn = b('rewardOn', _rewardOn);
      if (s['reward'] is String) _rewardController.text = s['reward'] as String;
    });
  }

  Future<void> _showPresets() async {
    final presets = await TimerPresets.all(role: widget.role);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              const Text('Saved settings', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              const Text(
                "Everything on this page except who it's for and the combination's digits - "
                'a fresh combination is made, or entered, each time.',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 8),
              if (presets.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('Nothing saved yet.'),
                ),
              for (final p in presets)
                Card(
                  child: ListTile(
                    title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(_describe(p.settings)),
                    onTap: () {
                      Navigator.pop(ctx);
                      _apply(p.settings);
                      _snack('Loaded "${p.name}". Check who it\'s for, then start it.');
                    },
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline_rounded),
                      tooltip: 'Delete',
                      onPressed: () async {
                        await TimerPresets.delete(p.id);
                        setSheet(() => presets.remove(p));
                      },
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              FilledButton.icon(
                icon: const Icon(Icons.bookmark_add_rounded),
                label: const Text('Save these settings'),
                onPressed: () async {
                  final name = await _askName();
                  if (name == null) return;
                  await TimerPresets.save(name, widget.role, _settings());
                  if (ctx.mounted) Navigator.pop(ctx);
                  _snack('Saved as "$name".');
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<String?> _askName() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save these settings'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(labelText: 'Name', hintText: 'e.g. Weekend lock'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) Navigator.pop(ctx, name);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  /// "1 day · hidden · public link · 3 orders" - enough to tell them apart.
  static String _describe(Map<String, dynamic> s) {
    final base = Duration(seconds: (s['base'] as num?)?.toInt() ?? 0);
    final orders = s['publicOrders'] is Map ? (s['publicOrders']['orders'] as List?)?.length ?? 0 : 0;
    return [
      s['openEnded'] == true ? 'no end time' : formatSpan(base),
      if (s['hidden'] == true && s['openEnded'] != true) 'hidden',
      if (s['randomOn'] == true && s['openEnded'] != true) 'random changes',
      if (s['publicOn'] == true) 'public link',
      if (s['publicOn'] == true && s['publicOrders'] is Map && s['publicOrders']['enabled'] == true) '$orders orders',
      if (s['comboOn'] == true) 'combination',
      if (s['rewardOn'] == true) 'reward',
    ].join(' · ');
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
    if (_publicOn && _publicOrders.enabled && _publicOrders.orders.isEmpty) {
      _snack('Add at least one order the public may send, or switch public orders off.');
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
      rewardTokens: _reward,
      publicOrders: _publicOn ? _publicOrders : const PublicOrdersSettings(),
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
      appBar: AppBar(
        title: Text(_isDirector ? 'New timer' : 'My timer'),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.bookmarks_rounded, size: 18),
            label: const Text('Saved settings'),
            onPressed: _saving ? null : _showPresets,
          ),
        ],
      ),
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
          // Orders from the page: only with a page to send them from.
          if (_publicOn) ...[
            _section(theme, 'PUBLIC ORDERS'),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: PublicOrdersEditor(
                  value: _publicOrders,
                  onChanged: (v) => setState(() => _publicOrders = v),
                  isDirector: _isDirector,
                  hasDirector: _isDirector || _partner != null,
                ),
              ),
            ),
          ],
          // Tokens are the director's to give.
          if (_isDirector) ...[
            _section(theme, 'REWARD'),
            Card(
              child: Column(
                children: [
                  SwitchListTile(
                    value: _rewardOn,
                    onChanged: (v) => setState(() => _rewardOn = v),
                    title: const Text('Reward tokens for completing it'),
                    subtitle: const Text(
                        'Earned when it runs out, or when you end it. Not if they use the emergency release.'),
                  ),
                  if (_rewardOn)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                      child: TextField(
                        controller: _rewardController,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                        decoration: const InputDecoration(labelText: 'Tokens', suffixText: 'tokens'),
                      ),
                    ),
                ],
              ),
            ),
          ],
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
                // One lock, two codes: only with a separate lock for each.
                if (_comboOn && !_isDirector && _otherComboRunning(context))
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 20),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                              'Another running timer already uses a combination. Use a separate lock for this one.'),
                        ),
                      ],
                    ),
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
