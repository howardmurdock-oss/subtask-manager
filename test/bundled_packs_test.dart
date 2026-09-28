import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/models/order_pack.dart';
import 'package:orders_app/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a fresh install gets the bundled order packs, switched on', () async {
    SharedPreferences.setMockInitialValues({});
    final packs = await StorageService().loadPacks();

    final byTitle = {for (final p in packs) p.title: p};
    expect(byTitle['Chastity Cage']?.orders, hasLength(9));
    expect(byTitle['Tease and Edge']?.orders, hasLength(12));
    expect(byTitle['Chastity Cage']!.isEnabled, isTrue);
    expect(byTitle['Tease and Edge']!.isEnabled, isTrue);

    // order_engine takes the first default order as a placeholder.
    expect(packs.first.id, 'starter-discipline');
  });

  test('a fresh install gets the bundled reward packs, switched on', () async {
    SharedPreferences.setMockInitialValues({});
    final packs = await StorageService().loadRewardPacks();

    final byTitle = {for (final p in packs) p.title: p};
    expect(byTitle['Orgasm (Vaginal)']?.rewards, hasLength(5));
    expect(byTitle['Orgasms (Penis)']?.rewards, hasLength(4));
    expect(byTitle['Orgasm (Vaginal)']!.isEnabled, isTrue);
    expect(byTitle['Orgasms (Penis)']!.isEnabled, isTrue);
  });

  test('a device that already has packs saved does not gain them', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.savePacks([
      OrderPack(id: 'mine', title: 'My Pack', description: '', author: 'Me', orders: []),
    ]);

    final packs = await storage.loadPacks();
    expect(packs.map((p) => p.title), ['My Pack']);
  });
}
