/// The chastity timer, as the app sees it.
///
/// The timer itself lives on the Worker (worker/src/timer.ts), which works
/// out its end from a log of changes. These are the settings sent to it, the
/// view it sends back, and the record this device keeps of the timers it can
/// reach - which, beyond an id, is only a key.
library;

import 'order_item.dart';

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
    this.publicOrders = const PublicOrdersSettings(),
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

  /// Orders the public may send from the timer's page.
  final PublicOrdersSettings publicOrders;
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
        'publicOrders': publicOrders.toJson(),
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
      publicOrders: PublicOrdersSettings.fromJson(sub('publicOrders') ?? const {}),
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
    this.orders,
  });

  /// Public orders as they stand: the one in progress, how many wait, the
  /// feed. Null when the timer takes none.

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
  final PublicOrdersStatus? orders;

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
      orders: json['orders'] is Map && (json['orders'] as Map)['enabled'] == true
          ? PublicOrdersStatus.fromJson(Map<String, dynamic>.from(json['orders'] as Map))
          : null,
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

/// A timer a partner sent while another was already running: held until
/// the player accepts or declines it.
class TimerInvite {
  const TimerInvite({
    required this.id,
    required this.key,
    this.partnerCode,
    this.partnerName,
    required this.receivedAt,
  });

  final String id;

  /// The player's key to it. Never shown, never logged.
  final String key;
  final String? partnerCode;
  final String? partnerName;
  final DateTime receivedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'key': key,
        'partnerCode': partnerCode,
        'partnerName': partnerName,
        'receivedAt': receivedAt.toIso8601String(),
      };

  factory TimerInvite.fromJson(Map<String, dynamic> json) => TimerInvite(
        id: json['id'] as String,
        key: json['key'] as String,
        partnerCode: json['partnerCode'] as String?,
        partnerName: json['partnerName'] as String?,
        receivedAt: DateTime.tryParse(json['receivedAt'] as String? ?? '') ?? DateTime.now(),
      );
}

/// The player's public page: one link for all their timers. The key proves
/// this device may change it - never shown, except to move it to another.
class TimerProfile {
  const TimerProfile({
    required this.profileId,
    required this.key,
    required this.publicId,
    this.name,
    this.showHistory = false,
  });

  final String profileId;
  final String key;
  final String publicId;
  final String? name;
  final bool showHistory;

  TimerProfile copyWith({String? key, String? publicId, String? name, bool clearName = false, bool? showHistory}) =>
      TimerProfile(
        profileId: profileId,
        key: key ?? this.key,
        publicId: publicId ?? this.publicId,
        name: clearName ? null : (name ?? this.name),
        showHistory: showHistory ?? this.showHistory,
      );

  Map<String, dynamic> toJson() => {
        'profileId': profileId,
        'key': key,
        'publicId': publicId,
        'name': name,
        'showHistory': showHistory,
      };

  factory TimerProfile.fromJson(Map<String, dynamic> json) => TimerProfile(
        profileId: json['profileId'] as String,
        key: json['key'] as String,
        publicId: json['publicId'] as String,
        name: json['name'] as String?,
        showHistory: json['showHistory'] == true,
      );
}

/// One order the public may send: the fields of an [OrderItem] the page
/// shows and the player's app needs to rebuild it.
class PublicOrderDef {
  const PublicOrderDef({
    required this.id,
    required this.title,
    this.description = '',
    this.category = 'General',
    this.tier = 1,
    this.durationType = DurationType.instant,
    this.actionSeconds = 0,
    this.deadlineMinutes = 0,
    this.verification = VerificationType.honorCheck,
    this.rewardTokens = 0,
    this.penaltyTokens = 0,
  });

  final String id;
  final String title;
  final String description;
  final String category;
  final int tier;
  final DurationType durationType;
  final int actionSeconds;
  final int deadlineMinutes;
  final VerificationType verification;
  final int rewardTokens;
  final int penaltyTokens;

  factory PublicOrderDef.fromOrder(OrderItem o) => PublicOrderDef(
        id: _safeId(o.id),
        title: o.title,
        description: o.description,
        category: o.category,
        tier: o.tier,
        durationType: o.durationType,
        actionSeconds: o.actionDurationSeconds,
        deadlineMinutes: o.durationMinutes,
        verification: o.verificationType,
        rewardTokens: o.rewardTokens,
        penaltyTokens: o.penaltyTokens,
      );

  /// Order ids as the Worker accepts them: letters, digits, - and _.
  static String _safeId(String raw) {
    final clean = raw.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
    if (clean.isEmpty) return 'order';
    return clean.length > 64 ? clean.substring(0, 64) : clean;
  }

  /// As an order for the player's list. [id] keeps each delivery its own.
  OrderItem toOrder({required String id}) => OrderItem(
        id: id,
        title: title,
        description: description,
        category: category,
        tier: tier,
        durationType: durationType,
        actionDurationSeconds: actionSeconds,
        durationMinutes: deadlineMinutes,
        verificationType: verification,
        rewardTokens: rewardTokens,
        penaltyTokens: penaltyTokens,
        allowRandomDraw: false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'description': description,
        'category': category,
        'tier': tier,
        'durationType': durationType.name,
        'actionSeconds': actionSeconds,
        'deadlineMinutes': deadlineMinutes,
        'verification': verification.name,
        'rewardTokens': rewardTokens,
        'penaltyTokens': penaltyTokens,
      };

  factory PublicOrderDef.fromJson(Map<String, dynamic> json) => PublicOrderDef(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        description: json['description'] as String? ?? '',
        category: json['category'] as String? ?? 'General',
        tier: (json['tier'] as num?)?.toInt() ?? 1,
        durationType: DurationType.values.firstWhere((d) => d.name == json['durationType'],
            orElse: () => DurationType.instant),
        actionSeconds: (json['actionSeconds'] as num?)?.toInt() ?? 0,
        deadlineMinutes: (json['deadlineMinutes'] as num?)?.toInt() ?? 0,
        verification: VerificationType.values.firstWhere((v) => v.name == json['verification'],
            orElse: () => VerificationType.honorCheck),
        rewardTokens: (json['rewardTokens'] as num?)?.toInt() ?? 0,
        penaltyTokens: (json['penaltyTokens'] as num?)?.toInt() ?? 0,
      );
}

/// Where proof for a public order goes.
enum PublicProofTo { director, issuer }

/// What the timer's manager allows the public to order, and how.
class PublicOrdersSettings {
  const PublicOrdersSettings({
    this.enabled = false,
    this.orders = const [],
    this.maxQueued,
    this.perVisitorDaily = 1,
    this.proofTo = PublicProofTo.director,
    this.skipsPerDay = 2,
    this.skipPauseMinutes = 30,
  });

  final bool enabled;
  final List<PublicOrderDef> orders;

  /// Waiting or in progress at once; null for no limit.
  final int? maxQueued;
  final int perVisitorDaily;
  final PublicProofTo proofTo;
  final int skipsPerDay;
  final int skipPauseMinutes;

  PublicOrdersSettings copyWith({
    bool? enabled,
    List<PublicOrderDef>? orders,
    int? maxQueued,
    bool noLimit = false,
    int? perVisitorDaily,
    PublicProofTo? proofTo,
    int? skipsPerDay,
    int? skipPauseMinutes,
  }) =>
      PublicOrdersSettings(
        enabled: enabled ?? this.enabled,
        orders: orders ?? this.orders,
        maxQueued: noLimit ? null : (maxQueued ?? this.maxQueued),
        perVisitorDaily: perVisitorDaily ?? this.perVisitorDaily,
        proofTo: proofTo ?? this.proofTo,
        skipsPerDay: skipsPerDay ?? this.skipsPerDay,
        skipPauseMinutes: skipPauseMinutes ?? this.skipPauseMinutes,
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'orders': orders.map((o) => o.toJson()).toList(),
        'maxQueued': maxQueued,
        'perVisitorDaily': perVisitorDaily,
        'proofTo': proofTo.name,
        'skipsPerDay': skipsPerDay,
        'skipPauseMinutes': skipPauseMinutes,
      };

  factory PublicOrdersSettings.fromJson(Map<String, dynamic> json) => PublicOrdersSettings(
        enabled: json['enabled'] == true,
        orders: ((json['orders'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) => PublicOrderDef.fromJson(Map<String, dynamic>.from(m)))
            .toList(),
        maxQueued: (json['maxQueued'] as num?)?.toInt(),
        perVisitorDaily: (json['perVisitorDaily'] as num?)?.toInt() ?? 1,
        proofTo: json['proofTo'] == 'issuer' ? PublicProofTo.issuer : PublicProofTo.director,
        skipsPerDay: (json['skipsPerDay'] as num?)?.toInt() ?? 2,
        skipPauseMinutes: (json['skipPauseMinutes'] as num?)?.toInt() ?? 30,
      );
}

/// The public order in progress, as delivered to the player.
class PublicOrderActive {
  const PublicOrderActive({required this.no, required this.def, this.deliveredAt, this.dueAt, this.issuerKey});

  final int no;
  final PublicOrderDef def;
  final DateTime? deliveredAt;
  final DateTime? dueAt;

  /// The sender's key, to encrypt proof to. Null if proof goes to the director.
  final String? issuerKey;

  factory PublicOrderActive.fromJson(Map<String, dynamic> json) {
    DateTime? t(String k) =>
        json[k] == null ? null : DateTime.fromMillisecondsSinceEpoch((json[k] as num).toInt());
    return PublicOrderActive(
      no: (json['no'] as num).toInt(),
      def: PublicOrderDef.fromJson(Map<String, dynamic>.from(json['def'] as Map)),
      deliveredAt: t('deliveredAt'),
      dueAt: t('dueAt'),
      issuerKey: json['issuerKey'] as String?,
    );
  }
}

/// One line of the feed: what was ordered, and how it went.
class PublicOrderFeedEntry {
  const PublicOrderFeedEntry({required this.no, required this.title, required this.status, required this.at});

  final int no;
  final String title;

  /// queued, active, completed, failed, expired, skipped or cancelled.
  final String status;
  final DateTime at;

  factory PublicOrderFeedEntry.fromJson(Map<String, dynamic> json) => PublicOrderFeedEntry(
        no: (json['no'] as num).toInt(),
        title: json['title'] as String? ?? '',
        status: json['status'] as String? ?? '',
        at: DateTime.fromMillisecondsSinceEpoch((json['at'] as num?)?.toInt() ?? 0),
      );
}

/// Public orders on a timer, as either side's app sees them.
class PublicOrdersStatus {
  const PublicOrdersStatus({
    required this.proofTo,
    this.active,
    this.waiting = 0,
    this.skipsLeft = 0,
    this.pausedUntil,
    this.feed = const [],
  });

  final PublicProofTo proofTo;
  final PublicOrderActive? active;
  final int waiting;
  final int skipsLeft;
  final DateTime? pausedUntil;
  final List<PublicOrderFeedEntry> feed;

  factory PublicOrdersStatus.fromJson(Map<String, dynamic> json) => PublicOrdersStatus(
        proofTo: json['proofTo'] == 'issuer' ? PublicProofTo.issuer : PublicProofTo.director,
        active: json['active'] is Map
            ? PublicOrderActive.fromJson(Map<String, dynamic>.from(json['active'] as Map))
            : null,
        waiting: (json['waiting'] as num?)?.toInt() ?? 0,
        skipsLeft: (json['skipsLeft'] as num?)?.toInt() ?? 0,
        pausedUntil: json['pausedUntil'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch((json['pausedUntil'] as num).toInt()),
        feed: ((json['feed'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) => PublicOrderFeedEntry.fromJson(Map<String, dynamic>.from(m)))
            .toList(),
      );
}
