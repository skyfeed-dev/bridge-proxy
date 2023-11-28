import 'dart:convert';

import 'package:atproto_bridge_proxy/bridge/base.dart';
import 'package:atproto_bridge_proxy/util/clean_handle.dart';
import 'package:atproto_bridge_proxy/util/make_cid.dart';
import 'package:atproto_bridge_proxy/util/preprocess_html.dart';
import 'package:atproto_bridge_proxy/util/string.dart';
import 'package:bluesky/bluesky.dart';
import 'package:html_unescape/html_unescape.dart';
import 'package:http/http.dart' as http;

class HackerNewsBridge extends Bridge {
  final httpClient = http.Client();
  final htmlUnescape = HtmlUnescape();

  HackerNewsBridge({
    required super.server,
  });

  Future<dynamic> fetchAPI(String path) async {
    final res = await httpClient.get(
      Uri.parse(
        'https://hacker-news.firebaseio.com$path',
      ),
      headers: {
        'accept': 'application/json',
      },
    );
    if (res.statusCode != 200) throw 'HTTP ${res.statusCode}: ${res.body}';
    return jsonDecode(res.body);
  }

  final itemCache = <int, Post>{};

  final kidsMap = <int, List<int>>{};
  final parentMap = <int, int>{};

  Future<Post> loadItem(int id, {required bool useCache}) async {
    if (useCache) {
      if (itemCache.containsKey(id)) return itemCache[id]!;
    }
    final res = await fetchAPI('/v0/item/$id.json');

    final dt = DateTime.fromMillisecondsSinceEpoch((res['time'] ?? 0) * 1000);
    final String by = res['by'] ?? '';
    final did = 'did:bridge:hn:${encodeString(by)}';

    if (res['kids'] != null) {
      kidsMap[id] = res['kids'].cast<int>();
    }
    if (res['parent'] != null) {
      parentMap[id] = res['parent'];
    }

    final uri = Uri.tryParse(res['url'] ?? '');

    final thumbnail = uri?.host;

    final postUri = AtUri.parse(
      'at://$did/app.bsky.feed.post/$id',
    );

    final post = Post(
      record: PostRecord(
        // TODO Remove
        // text: 'text',
        text: res['text'] == null
            ? ''
            // TODO Replace HTML links with facets :)
            : res['title'] == null
                ? preprocessHtml(res['text'])
                : '# ${res['title']}\n\n${preprocessHtml(res['text'])}',
        createdAt: dt,
      ),
      embed: res['url'] == null
          ? null
          : EmbedView.external(
              data: EmbedViewExternal(
                type: 'app.bsky.embed.external#view',
                external: EmbedViewExternalView(
                  uri: res['url'],
                  title: res['title'],
                  description: '',
                  thumbnail:
                      // TODO Maybe use different favicon preview API
                      'https://anxious-amber-tarsier.faviconkit.com/$thumbnail/256',
                ),
              ),
            ),
      author: Actor(
        displayName: by,
        did: did,
        handle: '${cleanHandle(by)}.news.ycombinator.com',
        viewer: ActorViewer(
          isMuted: false,
          isBlockedBy: false,
        ),
      ),
      uri: postUri,
      cid: makeCID(postUri.toString()),
      replyCount: res['descendants'] ?? res['kids']?.length ?? 0,
      // repostCount: 100,
      // likeCount: 100,
      repostCount: -1,
      likeCount: res['score'] ?? -1,
      viewer: PostViewer(),
      indexedAt: dt,
    );
    itemCache[id] = post;
    return post;
  }

  @override
  Future<Feed> getFeed(
      {required AtUri generatorUri, int? limit, String? cursor}) async {
    int offset = int.tryParse(cursor ?? '') ?? 0;
    limit ??= 8;
    if (limit > 16) {
      limit = 16;
    }

    final res = await fetchAPI('/v0/${generatorUri.rkey}.json');

    final posts = await Future.wait([
      for (final id in res.sublist(offset, offset + limit))
        loadItem(id, useCache: true),
    ]);
    return Feed(
      feed: [
        for (final post in posts)
          FeedView(
            post: post,
          ),
      ],
      cursor: (offset + limit).toString(),
    );
  }

  Future<PostThreadView?> loadParent(int id) async {
    final parentId = parentMap[id];
    if (parentId == null) return null;
    final post = await loadItem(parentId, useCache: true);
    return PostThreadView.record(
      data: PostThreadViewRecord(
        type: 'app.bsky.feed.defs#threadViewPost',
        post: post,
        parent: await loadParent(
          parentId,
        ),
        replies: [],
      ),
    );
  }

  @override
  Future<PostThread> getPostThread(
      {required AtUri uri, int? depth, int? parentHeight}) async {
    final id = int.parse(uri.rkey);

    final post = await loadItem(id, useCache: false);
    final replies = await Future.wait([
      for (final child in kidsMap[id] ?? []) loadReply(child, 1),
    ]);

    return PostThread(
        thread: PostThreadView.record(
      data: PostThreadViewRecord(
        type: 'app.bsky.feed.defs#threadViewPost',
        post: post,
        parent: await loadParent(id),
        replies: replies,
      ),
    ));
  }

  Future<PostThreadView> loadReply(int id, int level) async {
    final post = await loadItem(id, useCache: true);

    final replies = level > 3
        ? <PostThreadView>[]
        : await Future.wait([
            for (final child in kidsMap[id] ?? []) loadReply(child, level + 1),
          ]);
    return PostThreadView.record(
        data: PostThreadViewRecord(
      type: 'app.bsky.feed.defs#threadViewPost',
      post: post,
      parent: null,
      replies: replies,
    ));
  }

  @override
  Future<Feed> getAuthorFeed(
      {required String actor, int? limit, String? cursor}) async {
    final res = await fetchProfile(actor);
    int offset = int.tryParse(cursor ?? '') ?? 0;

    limit ??= 16;
    if (limit > 16) {
      limit = 16;
    }

    final posts = await Future.wait([
      for (final id in res.$2.sublist(offset, offset + limit))
        loadItem(id, useCache: true),
    ]);

    return Feed(
      feed: [
        for (final post in posts)
          FeedView(
            post: post,
          ),
      ],
      cursor: (offset + limit).toString(),
    );
  }

  @override
  Future<ActorProfile> getProfile({required String actor}) async {
    return (await fetchProfile(actor)).$1;
  }

  Future<(ActorProfile, List<int>)> fetchProfile(String actor) async {
    final username = decodeString(actor.split(':')[2]);
    final profile = await fetchAPI(
      '/v0/user/$username.json',
    );
    final List<int> submitted = (profile['submitted'] ?? []).cast<int>();
    return (
      ActorProfile(
        did: actor,
        handle: '${cleanHandle(actor)}.news.ycombinator.com',
        followsCount: -1,
        followersCount: -1,
        displayName: profile['id'],
        // indexedAt: DateTime.fromMillisecondsSinceEpoch(profile['time'] * 1000),
        description:
            '${preprocessHtml(profile['about'] ?? '')}\n\nKarma: ${profile['karma']}',
        postsCount: submitted.length,
        viewer: ActorViewer(isMuted: false, isBlockedBy: false),
      ),
      submitted
    );
  }
}
