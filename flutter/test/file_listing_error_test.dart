import 'package:camellia_remote_app/models/file_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

void main() {
  FileFetcher newFetcher() =>
      FileFetcher(() => const UuidValue.fromNamespace(Namespace.nil));

  test(
    'directory listing error completes only the matching path task',
    () async {
      final fetcher = newFetcher();
      final failed = fetcher.registerReadTask(false, '/requested');
      final untouched = fetcher.registerReadTask(false, '/other');
      final expectation = expectLater(failed, throwsA('permission denied'));

      fetcher.tryCompleteListingTaskWithError(
        '/requested',
        'permission denied',
        false,
      );

      await expectation;
      expect(fetcher.remoteTasks.containsKey('/requested'), isFalse);
      expect(fetcher.remoteTasks.containsKey('/other'), isTrue);
      final untouchedExpectation = expectLater(untouched, throwsA('cleanup'));
      fetcher.tryCompleteListingTaskWithError('/other', 'cleanup', false);
      await untouchedExpectation;
    },
  );

  test('empty-directory error is isolated from normal listing tasks', () async {
    final fetcher = newFetcher();
    final normal = fetcher.registerReadTask(false, '/same');
    final emptyDirs = fetcher.registerReadEmptyDirsTask(false, '/same');
    final expectation = expectLater(emptyDirs, throwsA('scan failed'));

    fetcher.tryCompleteListingTaskWithError('/same', 'scan failed', true);

    await expectation;
    expect(fetcher.remoteEmptyDirsTasks.containsKey('/same'), isFalse);
    expect(fetcher.remoteTasks.containsKey('/same'), isTrue);
    final normalExpectation = expectLater(normal, throwsA('cleanup'));
    fetcher.tryCompleteListingTaskWithError('/same', 'cleanup', false);
    await normalExpectation;
  });
}
