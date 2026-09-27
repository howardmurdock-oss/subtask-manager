import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:pointycastle/ecc/curves/secp256r1.dart';
import 'package:pointycastle/ecc/ecc_fp.dart' as fp;

/// Key agreement for pairing two devices, so the secret they share is worked
/// out on each device and never crosses the relay, the Worker or FCM.
///
/// Three messages, all readable by the relays and none of them secret:
///
/// 1. pairingRequest (requester to accepter): a commitment, the SHA-256 of the
///    requester's public key. The key itself is held back.
/// 2. pairingAccept (accepter to requester): the accepter's public key.
/// 3. pairingConfirm (requester to accepter): the requester's public key, which
///    must match the commitment, and a proof that it derived the same secret.
///
/// Both sides then hold the same secret and the same six-digit verification
/// code. A relay that swaps in its own keys ends up sharing one secret with
/// each side, and the two devices show different codes. The commitment is what
/// makes that comparison worth anything: without it, whoever sends the second
/// message has seen both keys and can try a million of its own until the codes
/// happen to match. With it, the requester's key is fixed before the accepter's
/// is seen, and the accepter's before the requester's is revealed, so there is
/// nothing left to search.
///
/// P-256, because pointycastle has no X25519.
class PairingCrypto {
  /// The `pairing` field in a request, accept or confirm payload. A request
  /// without it comes from a build that sent the secret in the clear.
  static const int version = 2;

  static final _params = ECCurve_secp256r1();
  static final _curve = _params.curve as fp.ECCurve;
  static final Random _random = Random.secure();

  static final Uint8List _salt = _utf8('orders-app/pairing/v2');

  /// A one-off key pair for a single exchange.
  static PairingKeyPair generateKeyPair() {
    final n = _params.n;
    // 16 bytes wider than the order, so reducing it leaves no usable bias.
    final bytes = List<int>.generate(48, (_) => _random.nextInt(256));
    return keyPairFor(_toBigInt(bytes) % (n - BigInt.one) + BigInt.one);
  }

  /// The key pair for a chosen private key. Real exchanges use
  /// [generateKeyPair]; this is for tests that need fixed keys.
  @visibleForTesting
  static PairingKeyPair keyPairFor(BigInt privateKey) {
    final q = (_params.G * privateKey)!;
    return PairingKeyPair._(privateKey, base64Encode(q.getEncoded(false)));
  }

  /// What the request carries in place of the requester's public key.
  static String commitmentFor(String publicKey) =>
      base64Encode(sha256.convert(base64Decode(publicKey)).bytes);

  /// Works out the shared secret from this side's private key and the other
  /// side's public key.
  ///
  /// [requesterKey] and [accepterKey] are the two public keys in protocol
  /// order, so both sides feed the same transcript into the derivation. One
  /// of them is this side's own key. Throws [FormatException] if the peer's
  /// key is not a valid P-256 point.
  static PairingResult derive({
    required BigInt privateKey,
    required String requesterKey,
    required String accepterKey,
    required bool isRequester,
  }) {
    final peer = _decodePoint(isRequester ? accepterKey : requesterKey);
    final shared = (peer * privateKey)!;
    if (shared.isInfinity) throw const FormatException('Degenerate agreement');
    final ikm = _fixedWidth(shared.x!.toBigInteger()!, 32);

    final transcript = [
      ...base64Decode(requesterKey),
      ...base64Decode(accepterKey),
    ];
    final prk = Hmac(sha256, _salt).convert(ikm).bytes;
    List<int> expand(String label) => Hmac(sha256, prk)
        .convert([..._utf8(label), ...transcript, 1]).bytes;

    final codeBytes = expand('verification-code');
    final codeValue = ((codeBytes[0] << 24) |
            (codeBytes[1] << 16) |
            (codeBytes[2] << 8) |
            codeBytes[3]) %
        1000000;
    final digits = codeValue.toString().padLeft(6, '0');

    return PairingResult._(
      secret: base64Url.encode(expand('shared-secret')).replaceAll('=', ''),
      verificationCode: '${digits.substring(0, 3)} ${digits.substring(3)}',
      proof: base64Encode(expand('confirm').sublist(0, 16)),
    );
  }

  /// Whether [a] and [b] are the same proof, without leaking where they
  /// first differ.
  static bool proofsMatch(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// Decodes an uncompressed P-256 point and checks it is actually on the
  /// curve. pointycastle's decoder does not, and multiplying by a point off
  /// the curve can give away bits of the private key.
  static fp.ECPoint _decodePoint(String publicKey) {
    final bytes = base64Decode(publicKey);
    if (bytes.length != 65 || bytes[0] != 0x04) {
      throw const FormatException('Not an uncompressed P-256 public key');
    }
    final p = _curve.q!;
    final x = _toBigInt(bytes.sublist(1, 33));
    final y = _toBigInt(bytes.sublist(33, 65));
    if (x >= p || y >= p) throw const FormatException('Coordinate out of range');
    final a = _curve.a!.toBigInteger()!;
    final b = _curve.b!.toBigInteger()!;
    if ((y * y - (x * x * x + a * x + b)) % p != BigInt.zero) {
      throw const FormatException('Public key is not on the curve');
    }
    return _curve.createPoint(x, y);
  }

  static BigInt _toBigInt(List<int> bytes) =>
      bytes.fold(BigInt.zero, (acc, b) => (acc << 8) | BigInt.from(b));

  static Uint8List _fixedWidth(BigInt value, int length) {
    final out = Uint8List(length);
    var v = value;
    for (var i = length - 1; i >= 0; i--) {
      out[i] = (v & BigInt.from(0xff)).toInt();
      v = v >> 8;
    }
    return out;
  }

  static Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));
}

class PairingKeyPair {
  final BigInt privateKey;

  /// Base64 of the uncompressed point.
  final String publicKey;

  PairingKeyPair._(this.privateKey, this.publicKey);
}

class PairingResult {
  /// The shared secret, in the string form every other secret in the app
  /// takes.
  final String secret;

  /// Six digits, grouped "123 456", for the two people to compare.
  final String verificationCode;

  /// Sent in pairingConfirm so the accepter can tell it derived the same
  /// secret, rather than finding out when messages stop decrypting.
  final String proof;

  PairingResult._({
    required this.secret,
    required this.verificationCode,
    required this.proof,
  });
}
