import 'dart:convert';
import 'dart:typed_data';

import 'package:atproto_bridge_proxy/util/clean_handle.dart';
import 'package:bluesky/bluesky.dart';
import 'package:http/http.dart' as http;
import 'package:lib5/src/model/multibase.dart';
import 'package:xml2json/xml2json.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'package:atproto_bridge_proxy/bridge/base.dart';
import 'package:atproto_bridge_proxy/util/make_cid.dart';
import 'package:atproto_bridge_proxy/util/sort_feed.dart';

class YouTubeBridge extends Bridge {
  final List<String> following;

  YouTubeBridge({
    required super.server,
    required this.following,
  });
  final httpClient = http.Client();

  final yt = YoutubeExplode();

  String _channelIdToDID(String id) {
    return 'did:bridge:youtube:${IpfsCid(Uint8List.fromList(utf8.encode(id))).toBase32()}';
  }

  String _didToChannelId(String did) {
    return utf8.decode(Multibase.decodeString(did.split(':').last));
  }

  @override
  Future<Feed> getAuthorFeed({
    required String actor,
    int? limit,
    String? cursor,
    DateTime? maxAge,
  }) async {
    if (cursor != null) {
      return Feed(feed: []);
    }
    if (maxAge == null) {
      // TODO Use generic cache provider
      if (authorFeedCache.containsKey(actor)) return authorFeedCache[actor]!;
    }
    final videos = <FeedView>[];
    final channelId = _didToChannelId(actor);

    final profile = await getProfile(actor: actor);
    final res = await httpClient.get(Uri.parse(
      'https://www.youtube.com/feeds/videos.xml?channel_id=$channelId',
    ));

    final transformer = Xml2Json();
    transformer.parse(res.body);
    final data = jsonDecode(transformer.toBadgerfish());
    final actorProfile = Actor.fromJson(
      profile.toJson(),
    );

    for (final e in data['feed']['entry']) {
      videos.add(_convertVideoToPost(
        e,
        actor,
        actorProfile,
      ));
    }
    final feed = Feed(feed: videos);
    authorFeedCache[actor] = feed;
    return feed;
  }

  FeedView _convertVideoToPost(Map v, String did, Actor author) {
    final videoId = v['yt:videoId']?['\$'] ?? v['id']['\$'].split(':').last;

    var uri = AtUri.parse(
      'at://$did/app.bsky.feed.post/$videoId',
    );
    final link = v['link']['@href'];

    // TODO updated
    final ts = DateTime.parse(v['published']['\$']);

    final description = v['media:group']['media:description']['\$'];

    // final thumbnailServerId =
    //     v['media:group']['media:thumbnail']['@url'].substring(8, 11);

    final viewCount = int.tryParse(v['media:group']['media:community']
            ['media:statistics']['@views'] ??
        '');

    final likeCount = int.tryParse(v['media:group']['media:community']
            ['media:starRating']['@count'] ??
        '');

    return FeedView(
      post: Post(
        record: PostRecord(
          text: '',
          createdAt: ts,
        ),
        embed: EmbedView.external(
          data: EmbedViewExternal(
            type: 'app.bsky.embed.external#view',
            external: EmbedViewExternalView(
              uri: link,
              title: v['title']['\$'],
              description: // ${formatDuration(v.duration?.inMilliseconds ?? 0)} •
                  description ?? '',
              thumbnail: 'https://i.ytimg.com/vi_webp/$videoId/mqdefault.webp',
            ),
          ),
        ),
        author: author,
        uri: uri,
        cid: makeCID(uri.toString()),
        replyCount: -1,
        repostCount: viewCount ?? -1,
        likeCount: likeCount ?? -1,
        viewer: PostViewer(),
        indexedAt: ts,
      ),
    );
  }

  int fetchConcurrency = 0;

  final authorFeedCache = <String, Feed>{};

  Future<Feed> getAuthorFeedMulti(String idStr) async {
    fetchConcurrency++;
    await Future.delayed(Duration(milliseconds: fetchConcurrency * 100));
    try {
      final feed = await getAuthorFeed(
        actor: _channelIdToDID(idStr),
        // limit: 10,
      );
      return feed;
    } catch (e, st) {
      print('ERROR FOR $idStr');
      print(e);
      return Feed(feed: []);
    }
  }

  @override
  Future<Feed> getFeed(
      {required AtUri generatorUri, int? limit, String? cursor}) async {
    if (generatorUri.rkey != 'following') {
      throw 'Unknown Feed URI';
    }
    // TODO Pagination
    fetchConcurrency = 0;
    final authorFeeds = await Future.wait([
      for (final id in following)
        getAuthorFeedMulti(
          id,
        )
    ]);
    final posts = authorFeeds.fold(
      <FeedView>[],
      (previousValue, element) => previousValue + element.feed,
    );
    sortFeed(posts);

    return Feed(feed: posts);
  }

  @override
  Future<PostThread> getPostThread(
      {required AtUri uri, int? depth, int? parentHeight}) {
    // TODO: implement getPostThread
    throw UnimplementedError();
  }

  final _profileCache = <String, ActorProfile>{};

  @override
  Future<ActorProfile> getProfile({required String actor}) async {
    if (_profileCache.containsKey(actor)) return _profileCache[actor]!;
    final channelId = _didToChannelId(actor);

    final res = await yt.channels.get(channelId);

    return ActorProfile(
      did: actor,
      handle: '${cleanHandle(res.title)}.youtube.com',
      followsCount: -1,
      followersCount: res.subscribersCount ?? -1,
      displayName: res.title,
      avatar: res.logoUrl.isEmpty ? null : res.logoUrl,
      banner: res.bannerUrl.isEmpty ? null : res.bannerUrl,
      // indexedAt: DateTime.fromMillisecondsSinceEpoch(profile['time'] * 1000),
      description: '',
      postsCount: 0,
      viewer: ActorViewer(isMuted: false, isBlockedBy: false),
    );
  }
}
