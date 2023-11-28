import 'package:bluesky/bluesky.dart';

void sortFeed(List<FeedView> feed) {
  feed.sort((a, b) {
    final atime = (a.reason?.mapOrNull(
          repost: (value) => value.data.indexedAt,
        )) ??
        a.post.indexedAt;
    final btime = (b.reason?.mapOrNull(
          repost: (value) => value.data.indexedAt,
        )) ??
        b.post.indexedAt;

    return btime.compareTo(atime);
  });
}
