import 'package:camellia_remote_app/models/group_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('peer pagination advances with a server cursor', () {
    final pagination = PeerPaginationState(pageSize: 100);

    expect(pagination.nextQueryParameters(), {
      'current': '1',
      'pageSize': '100',
    });
    pagination.accept({'total': 250, 'nextCursor': 'cursor-1'});
    expect(pagination.hasMore, isTrue);
    expect(pagination.nextQueryParameters(), {
      'current': '2',
      'pageSize': '100',
      'cursor': 'cursor-1',
    });

    pagination.accept({'total': 249, 'nextCursor': 'cursor-2'});
    expect(pagination.hasMore, isTrue);
    expect(pagination.nextQueryParameters()['cursor'], 'cursor-2');
    pagination.accept({'total': 249, 'nextCursor': ''});
    expect(pagination.hasMore, isFalse);
  });

  test('peer pagination falls back to numbered pages for an older server', () {
    final pagination = PeerPaginationState(pageSize: 100);

    pagination.nextQueryParameters();
    pagination.accept({'total': 250});
    expect(pagination.hasMore, isTrue);
    expect(pagination.nextQueryParameters(), {
      'current': '2',
      'pageSize': '100',
    });
    pagination.accept({'total': 250});
    expect(pagination.hasMore, isTrue);
    pagination.nextQueryParameters();
    pagination.accept({'total': 250});
    expect(pagination.hasMore, isFalse);
  });

  test('peer pagination rejects malformed and repeated cursors', () {
    final invalidTotal = PeerPaginationState(pageSize: 100)
      ..nextQueryParameters();
    expect(
      () => invalidTotal.accept({'total': '250', 'nextCursor': ''}),
      throwsFormatException,
    );

    final invalidCursor = PeerPaginationState(pageSize: 100)
      ..nextQueryParameters();
    expect(
      () => invalidCursor.accept({'total': 1, 'nextCursor': 'bad\ncursor'}),
      throwsFormatException,
    );

    final repeatedCursor = PeerPaginationState(pageSize: 100)
      ..nextQueryParameters();
    repeatedCursor.accept({'total': 300, 'nextCursor': 'cursor-1'});
    repeatedCursor.nextQueryParameters();
    expect(
      () => repeatedCursor.accept({'total': 300, 'nextCursor': 'cursor-1'}),
      throwsFormatException,
    );

    final missingCursor = PeerPaginationState(pageSize: 100)
      ..nextQueryParameters();
    missingCursor.accept({'total': 300, 'nextCursor': 'cursor-1'});
    missingCursor.nextQueryParameters();
    expect(() => missingCursor.accept({'total': 300}), throwsFormatException);
  });
}
