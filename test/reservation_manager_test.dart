import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/transfer/reservation_manager.dart';

void main() {
  group('ReservationManager Tests', () {
    late ReservationManager manager;

    setUp(() {
      manager = ReservationManager();
    });

    test('Worker can reserve an available chunk', () {
      final success = manager.tryReserve(0, 'worker_1');
      expect(success, isTrue);
      expect(manager.isReserved(0), isTrue);
    });

    test('Another worker cannot reserve an already reserved chunk', () {
      manager.tryReserve(0, 'worker_1');
      final secondAttempt = manager.tryReserve(0, 'worker_2');
      expect(secondAttempt, isFalse);
    });

    test('Same worker can re-reserve same chunk safely', () {
      manager.tryReserve(0, 'worker_1');
      final sameWorker = manager.tryReserve(0, 'worker_1');
      expect(sameWorker, isTrue);
    });

    test('Release allows another worker to reserve chunk', () {
      manager.tryReserve(0, 'worker_1');
      manager.release(0);
      expect(manager.isReserved(0), isFalse);

      final secondWorker = manager.tryReserve(0, 'worker_2');
      expect(secondWorker, isTrue);
    });

    test('releaseAll frees only chunks held by that specific worker', () {
      manager.tryReserve(0, 'worker_1');
      manager.tryReserve(1, 'worker_1');
      manager.tryReserve(2, 'worker_2');

      manager.releaseAll('worker_1');

      expect(manager.isReserved(0), isFalse);
      expect(manager.isReserved(1), isFalse);
      expect(manager.isReserved(2), isTrue);
    });
  });
}
