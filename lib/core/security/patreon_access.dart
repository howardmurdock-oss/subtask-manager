import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// Checks the Patreon access code that unlocks Quests and Scheduled Orders.
///
/// The repository is public, so the code itself is never written here - only
/// its salted SHA-256. This keeps it from being read off GitHub or guessed
/// from a list of obvious words; it is not proof against someone determined
/// to brute-force a short code or patch the app, which a client-side check
/// cannot be.
///
/// To change the code, replace the digest with
/// `sha256('patreon_quest_salt_v1_' + CODE)`, CODE trimmed and upper-cased,
/// and keep the new code out of source, tests and commit messages.
class PatreonAccess {
  static const Set<String> _validDigests = {
    '41b8e53589df24f399069c68e060d25c9eac2c20eca096f8d6fc6a20ba99895e',
  };

  /// Lets tests exercise the check with a code of their own, so the real one
  /// never has to appear in the test suite either.
  @visibleForTesting
  static Set<String>? debugDigests;

  @visibleForTesting
  static int get validCodeCount => _validDigests.length;

  /// Whether [code] unlocks the Patreon features. Case and surrounding
  /// whitespace do not matter.
  static bool isValid(String code) =>
      (debugDigests ?? _validDigests).contains(digestOf(code));

  static String digestOf(String code) {
    final clean = code.trim().toUpperCase();
    return sha256.convert(utf8.encode('patreon_quest_salt_v1_$clean')).toString();
  }
}
