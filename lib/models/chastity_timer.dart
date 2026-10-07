/// The chastity timer, as the app sees it.
///
/// The timer itself lives on the Worker (worker/src/timer.ts), which works
/// out its end from a log of changes. These are the settings sent to it, the
/// view it sends back, and the record this device keeps of the timers it can
/// reach - which, beyond an id, is only a key.
library;

/// Who a change came from.
enum TimerActor { player, director, random, public }

TimerActor _actor(Object? value) => TimerActor.values.firstWhere(
      (a) => a.name == value,
      orElse: () => TimerActor.random,
    );

enum TimerStatus { running, ended, released }

/// Which side of a timer this device is on.
enum TimerRole { player, director }

class DirectorLimits {
  const DirectorLimits({this.canAdd = true, this.canRemove = true, this.dailyCapSeconds});

  final bool canAdd;
  final bool canRemove;

  /// Seconds of change per rolling 24 hours, added and removed together.
  /// Null: unlimited.
  final int? dailyCapSeconds;

  Map<String, dynamic> toJson() => {
        'canAdd': canAdd,
        'canRemove': canRemove,
        'dailyCapSeconds': dailyCapSeconds,
      };

  factory DirectorLimits.fromJson(Map<String, dynamic>? json) => DirectorLimits(
        canAdd: json?['canAdd'] != false,
        canRemove: json?['canRemove'] != false,
        dailyCapSeconds: (json?['dailyCapSeconds'] as num?)?.toInt(),
      );
}

class RandomChanges {
  const RandomChanges({
    this.enabled = false,
    this.everyMinutes = 240,
    this.minSeconds = -3600,
    this.maxSeconds = 3600,
  });

  final bool enabled;
  final int everyMinutes;

  /// Each change is a whole number of minutes in this range. Negative
  /// removes time.
  final int minSeconds;
  final int maxSeconds;

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'everyMinutes': everyMinutes,
        'minSeconds': minSeconds,
        'maxSeconds': maxSeconds,
      };

  factory RandomChanges.fromJson(Map<String, dynamic>? json) => RandomChanges(
        enabled: json?['enabled'] == true,
        everyMinutes: (json?['everyMinutes'] as num?)?.toInt() ?? 240,
        minSeconds: (json?['minSeconds'] as num?)?.toInt() ?? -3600,
        maxSeconds: (json?['maxSeconds'] as num?)?.toInt() ?? 3600,
      );
}

class PublicLinkSettings {
  const PublicLinkSettings({
    this.enabled = false,
    this.allowRemove = false,
    this.stepSeconds = 600,
    this.perVisitorDailySeconds = 3600,
    this.dailyCapSeconds,
    this.showTimeLeft = true,
    this.shareWithPlayer = false,
  });

  final bool enabled;
  final bool allowRemove;

  /// What one vote adds or removes.
  final int stepSeconds;

  /// Per visitor, per rolling 24 hours.
  final int perVisitorDailySeconds;

  /// Across everyone, per rolling 24 hours. Null: unlimited.
  final int? dailyCapSeconds;
  final bool showTimeLeft;

  /// The player gets the link too, to hand out themselves. Replacing it or
  /// switching it off stays with whoever manages the timer.
  final bool shareWithPlayer;

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'allowRemove': allowRemove,
        'stepSeconds': stepSeconds,
        'perVisitorDailySeconds': perVisitorDailySeconds,
        'dailyCapSeconds': dailyCapSeconds,
        'showTimeLeft': showTimeLeft,
        'shareWithPlayer': shareWithPlayer,
      };

  factory PublicLinkSettings.fromJson(Map<String, dynamic>? json) => PublicLinkSettings(
        enabled: json?['enabled'] == true,
        allowRemove: json?['allowRemove'] == true,
        stepSeconds: (json?['stepSeconds'] as num?)?.toInt() ?? 600,
        perVisitorDailySeconds: (json?['perVisitorDailySeconds'] as num?)?.toInt() ?? 3600,
        dailyCapSeconds: (json?['dailyCapSeconds'] as num?)?.toInt(),
        showTimeLeft: json?['showTimeLeft'] != false,
        shareWithPlayer: json?['shareWithPlayer'] == true,
      );
}

/// What a timer is set up with. Sent when creating one; the Worker checks
/// and bounds every value.
class ChastityTimerConfig {
  const ChastityTimerConfig({
    required this.baseSeconds,
    this.openEnded = false,
    this.notifyOnAdd = true,
    this.notifyMessage,
    this.rewardTokens,
    this.hidden = false,
    this.maxTotalSeconds,
    this.director = const DirectorLimits(),
    this.random = const RandomChanges(),
    this.publicLink = const PublicLinkSettings(),
    this.combinationEnabled = false,
    this.combinationDigits,
    this.combinationLength,
  });

  final int baseSeconds;

  /// No end time: it runs until someone ends it, or its maximum if it has
  /// one. Nothing adds or removes time - there is no end to move.
  final bool openEnded;

  /// Tell the player each time time is added - by the director or the
  /// public - in [notifyMessage]'s words, or plain ones. Who added it is
  /// always said.
  final bool notifyOnAdd;
  final String? notifyMessage;

  /// Tokens the player earns by completing it - it runs out, or the
  /// director ends it; not by emergency release. A director's timers only.
  final int? rewardTokens;
  final bool hidden;

  /// No change pushes the end past start + this. Null: no ceiling.
  final int? maxTotalSeconds;
  final DirectorLimits director;
  final RandomChanges random;
  final PublicLinkSettings publicLink;

  final bool combinationEnabled;

  /// Only known to whoever may see it: the director throughout, the player
  /// once the timer is over. Null otherwise.
  final String? combinationDigits;
  final int? combinationLength;

  Map<String, dynamic> toJson() => {
        'baseSeconds': baseSeconds,
        'openEnded': openEnded,
        'notify': {'onAdd': notifyOnAdd, 'message': notifyMessage},
        'rewardTokens': rewardTokens,
        'hidden': hidden,
        'maxTotalSeconds': maxTotalSeconds,
        'director': director.toJson(),
        'random': random.toJson(),
        'public': publicLink.toJson(),
        'combination': {'enabled': combinationEnabled, 'digits': combinationDigits},
      };

  factory ChastityTimerConfig.fromJson(Map<String, dynamic> json) {
    final combination = json['combination'] is Map ? Map<String, dynamic>.from(json['combination'] as Map) : null;
    Map<String, dynamic>? sub(String key) =>
        json[key] is Map ? Map<String, dynamic>.from(json[key] as Map) : null;
    return ChastityTimerConfig(
      baseSeconds: (json['baseSeconds'] as num?)?.toInt() ?? 0,
      openEnded: json['openEnded'] == true,
      notifyOnAdd: json['openEnded'] != true && sub('notify')?['onAdd'] != false,
      notifyMessage: sub('notify')?['message'] as String?,
      rewardTokens: (json['rewardTokens'] as num?)?.toInt(),
      hidden: json['hidden'] == true,
      maxTotalSeconds: (json['maxTotalSeconds'] as num?)?.toInt(),
      director: DirectorLimits.fromJson(sub('director')),
      random: RandomChanges.fromJson(sub('random')),
      publicLink: PublicLinkSettings.fromJson(sub('public')),
      combinationEnabled: combination?['enabled'] == true,
      combinationDigits: combination?['digits'] as String?,
      combinationLength: (combination?['length'] as num?)?.toInt(),
    );
  }
}

class TimerHistoryEntry {
  const TimerHistoryEntry({required this.id, required this.at, required this.actor, this.deltaSeconds});

  final String id;
  final DateTime at;
  final TimerActor actor;

  /// Null on a hidden timer, for the player.
  final int? deltaSeconds;

  factory TimerHistoryEntry.fromJson(Map<String, dynamic> json) => TimerHistoryEntry(
        id: json['id'] as String? ?? '',
        at: DateTime.fromMillisecondsSinceEpoch((json['at'] as num?)?.toInt() ?? 0),
        actor: _actor(json['actor']),
        deltaSeconds: (json['delta'] as num?)?.toInt(),
      );
}

/// A timer as the Worker last described it to this device.
class ChastityTimerView {
  ChastityTimerView({
    required this.id,
    required this.role,
    required this.isManager,
    required this.status,
    required this.startAt,
    required this.endAt,
    this.closedAt,
    required this.releasedAt,
    required this.releasedBy,
    required this.config,
    required this.history,
    required this.publicId,
    required this.clockOffset,
    this.atMaximum = false,
    this.partnerConnected,
  });

  final String id;
  final TimerRole role;

  /// Whether this device set the timer up, and so may change its settings.
  final bool isManager;
  final TimerStatus status;
  final DateTime startAt;

  /// Null when this device may not see it: a hidden timer, for the player.
  final DateTime? endAt;

  /// When it stopped - released, or reached its end. Null while running.
  final DateTime? closedAt;
  final DateTime? releasedAt;
  final TimerRole? releasedBy;
  final ChastityTimerConfig config;
  final List<TimerHistoryEntry> history;

  /// The public link's id, for whoever manages the timer - and the player,
  /// when it is shared with them. Null otherwise.
  final String? publicId;

  /// No more time can be added: it is at its maximum length. Never set for a
  /// hidden timer's player, for whom it would hint at the end.
  final bool atMaximum;

  /// For the manager: whether the partner has ever opened this timer with
  /// their key. False means they may never have received it. Null: not known,
  /// or not this device's to know.
  final bool? partnerConnected;

  /// The Worker's clock minus this device's, so a countdown is right even
  /// when the device's clock is not.
  final Duration clockOffset;

  DateTime get serverNow => DateTime.now().add(clockOffset);

  bool get isOver => status != TimerStatus.running || (endAt != null && !serverNow.isBefore(endAt!));

  /// Who set the timer up, and so manages it.
  TimerRole get managedBy =>
      isManager ? role : (role == TimerRole.player ? TimerRole.director : TimerRole.player);

  /// The player may simply end it: an open-ended timer of their own. Not an
  /// emergency release, and nothing to tell a director about as one.
  bool get playerMayEnd => config.openEnded && managedBy == TimerRole.player;

  /// Ended by the player's own choice, on a timer that was theirs to end.
  bool get endedByPlayerChoice =>
      status == TimerStatus.released && releasedBy == TimerRole.player && playerMayEnd;

  /// Over, with its reward earned: anything but the emergency release.
  bool get earnedReward =>
      (config.rewardTokens ?? 0) > 0 &&
      isOver &&
      !(status == TimerStatus.released && releasedBy == TimerRole.player);

  /// How long it has run: so far, or in all once over.
  Duration get elapsed {
    final until = closedAt ?? (isOver && endAt != null ? endAt! : serverNow);
    final d = until.difference(startAt);
    return d.isNegative ? Duration.zero : d;
  }

  /// Time left, or null when hidden from this device.
  Duration? get remaining {
    if (endAt == null) return null;
    final left = endAt!.difference(serverNow);
    return left.isNegative ? Duration.zero : left;
  }

  factory ChastityTimerView.fromJson(Map<String, dynamic> json, {DateTime? receivedAt}) {
    int? ms(String key) => (json[key] as num?)?.toInt();
    DateTime? time(String key) => ms(key) == null ? null : DateTime.fromMillisecondsSinceEpoch(ms(key)!);
    final serverNow = ms('now');
    final local = receivedAt ?? DateTime.now();
    return ChastityTimerView(
      id: json['id'] as String? ?? '',
      role: json['role'] == 'director' ? TimerRole.director : TimerRole.player,
      isManager: json['manager'] == true,
      status: TimerStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => TimerStatus.running,
      ),
      startAt: time('startAt') ?? local,
      endAt: time('endAt'),
      closedAt: time('closedAt'),
      releasedAt: time('releasedAt'),
      releasedBy: json['releasedBy'] == 'director'
          ? TimerRole.director
          : json['releasedBy'] == 'player'
              ? TimerRole.player
              : null,
      config: ChastityTimerConfig.fromJson(
          json['config'] is Map ? Map<String, dynamic>.from(json['config'] as Map) : const {}),
      history: (json['history'] as List? ?? [])
          .whereType<Map>()
          .map((e) => TimerHistoryEntry.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      publicId: json['publicId'] as String?,
      atMaximum: json['atMaximum'] == true,
      partnerConnected: json['partnerConnected'] as bool?,
      clockOffset: serverNow == null
          ? Duration.zero
          : Duration(milliseconds: serverNow - local.millisecondsSinceEpoch),
    );
  }
}

/// A timer this device can reach: its id and this device's key to it, plus
/// who is on the other side.
class TimerRecord {
  const TimerRecord({
    required this.id,
    required this.role,
    required this.key,
    this.partnerCode,
    this.partnerName,
    required this.addedAt,
  });

  final String id;
  final TimerRole role;

  /// Proves which side this device is on. Never shown, never logged.
  final String key;

  /// The partner on the other side, when there is one.
  final String? partnerCode;
  final String? partnerName;
  final DateTime addedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role.name,
        'key': key,
        'partnerCode': partnerCode,
        'partnerName': partnerName,
        'addedAt': addedAt.toIso8601String(),
      };

  factory TimerRecord.fromJson(Map<String, dynamic> json) => TimerRecord(
        id: json['id'] as String,
        role: json['role'] == 'director' ? TimerRole.director : TimerRole.player,
        key: json['key'] as String,
        partnerCode: json['partnerCode'] as String?,
        partnerName: json['partnerName'] as String?,
        addedAt: DateTime.tryParse(json['addedAt'] as String? ?? '') ?? DateTime.now(),
      );
}
