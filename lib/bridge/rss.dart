import 'dart:convert';
import 'dart:typed_data';

import 'package:atproto_bridge_proxy/bridge/base.dart';
import 'package:atproto_bridge_proxy/util/make_cid.dart';
import 'package:atproto_bridge_proxy/util/parse_date_time.dart';
import 'package:atproto_bridge_proxy/util/sort_feed.dart';
import 'package:bluesky/bluesky.dart';
import 'package:html_character_entities/html_character_entities.dart';
import 'package:http/http.dart' as http;
import 'package:lib5/src/model/multibase.dart';
import 'package:xml2json/xml2json.dart';

class RSSBridge extends Bridge {
  final List<String> following;

  RSSBridge({
    required super.server,
    required this.following,
  });

  String _feedUrlToDID(String url) {
    return 'did:bridge:rss:${IpfsCid(Uint8List.fromList(utf8.encode(url))).toBase32()}';
  }

  String _didToFeedUrl(String did) {
    return utf8.decode(Multibase.decodeString(did.split(':').last));
  }

  final httpClient = http.Client();
  @override
  Future<Feed> getAuthorFeed({
    required String actor,
    int? limit,
    String? cursor,
  }) async {
    final res = await getRSSFeedPosts(
      _didToFeedUrl(actor),
      actor,
      // convertHtml: true,
    );
    if (res.length > 4) {
      return Feed(feed: res.sublist(0, 4));
    } else {
      return Feed(feed: res);
    }
  }

  Future<Feed> getAuthorFeedMulti(String url) async {
    try {
      final feed = await getAuthorFeed(
        actor: _feedUrlToDID(url),
      );
      return feed;
    } catch (e, st) {
      print('ERROR FOR $url');
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
    final authorFeeds = await Future.wait([
      for (final url in following) getAuthorFeedMulti(url),
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

  @override
  Future<ActorProfile> getProfile({required String actor}) async {
    // TODO Caching
    final url = _didToFeedUrl(actor);
    final feedDoc = await fetchFeed(url);
    return getRSSFeedProfile(actor, feedDoc);
  }

  Future<dynamic> fetchFeed(String url) async {
    final res = await http.get(Uri.parse(url), headers: {
      'user-agent': 'skyfeed-bridge-proxy/0.1.0',
    });
    if (res.statusCode == 200) {
      final myTransformer = Xml2Json();
      myTransformer.parse(res.body);
      return json.decode(
        myTransformer
            .toBadgerfish()
            .replaceAll('\\\\', '\\')
            .replaceAll('\\r', '')
            .replaceAll(RegExp(r'\\(?=[^n"\\])'), '\\\\')
            .replaceAll('\\\\\'', '\'')
            .replaceAll('\\"}, "', '"}, "'),
      );
    }
  }

  ActorProfile getRSSFeedProfile(String did, Map data) {
    String? checkCData(dynamic obj) {
      final s = (obj is String)
          ? obj
          : (obj is Map)
              ? (obj['\$'] ?? obj['__cdata'] ?? '')
              : null;

      return s == null ? null : HtmlCharacterEntities.decode(s);
    }

    final url = _didToFeedUrl(did);

    if (data.containsKey('feed')) {
      String? title = checkCData(data['feed']['title']);
      String? description = checkCData(data['feed']['description']) ?? '';
      // String link = checkCData(data['rss']['channel']['link']);

      return ActorProfile(
        did: did,
        displayName: title ?? '',
        description: '$description\n\nURL: $url'.trim(),
        handle: '${Uri.parse(url).host}.rss',
        followsCount: -1,
        followersCount: -1,
        postsCount: 0,
        viewer: ActorViewer(isMuted: false, isBlockedBy: false),
      );
    } else if (data.containsKey('rss')) {
      String? title = checkCData(data['rss']['channel']['title']);
      String? description = checkCData(data['rss']['channel']['description']);
      String? link = checkCData(data['rss']['channel']['link']);

      String? accentColor =
          checkCData(data['rss']['channel']['webfeeds:accentColor']);

      String? image =
          checkCData((data['rss']['channel']['image'] ?? {})['url']);

      String? logo = checkCData(data['rss']['channel']['webfeeds:logo']);

      return ActorProfile(
        did: did,
        displayName: title ?? '',
        description: '$description\n\nURL: $url'.trim(),
        handle: '${Uri.parse(url).host}.rss',
        avatar: image ?? logo,
        followsCount: -1,
        followersCount: -1,
        postsCount: 0,
        viewer: ActorViewer(isMuted: false, isBlockedBy: false),
      );
    } else {
      throw 'Invalid feed $url';
    }
  }

  Future<List<FeedView>> getRSSFeedPosts(
    String feedUrl,
    String did,
  ) async {
    final data = await fetchFeed(feedUrl);

    final actorProfile = Actor.fromJson(
      getRSSFeedProfile(
        did,
        data,
      ).toJson(),
    );

    if (data != null) {
      String? checkCData(dynamic obj) {
        final s = (obj is String)
            ? obj
            : (obj is Map)
                ? (obj['\$'] ?? obj['__cdata'] ?? '')
                : null;

        return s == null ? null : HtmlCharacterEntities.decode(s);
      }

      if (data.containsKey('feed')) {
        final posts = <FeedView>[];

        var list = data['feed']['entry'] ?? [];

        if (list is! List) {
          list = [list];
        }
        /*            video.ratingCount =
                int.parse(mediaCommunity['media:starRating']['@count']);
            video.ratingRatio =
                double.parse(mediaCommunity['media:starRating']['@average']) /
                    5;
            video.views =
                int.parse(mediaCommunity['media:statistics']['@views']); */

        for (final entry in list) {
          String? title =
              checkCData(entry['title'])?.replaceAll('\\n', ' ').trim();
          final link = checkCData((entry['link'] ?? {})['@href']);
          final id = checkCData(entry['id']);
          final published = checkCData(entry['published'] ?? entry['updated']);
          final content = checkCData(entry['content'] ?? entry['description']);
          String? description = content;
          String? image;

          final mediaGroup = entry['media:group'];

          if (mediaGroup != null) {
            final mediaDescription =
                checkCData(mediaGroup['media:description']);
            final mediaThumbnail =
                checkCData((mediaGroup['media:thumbnail'] ?? {})['@url']);

            image = mediaThumbnail;
            description = mediaDescription;
          }
          /* var _cats = entry['category'] ?? [];

          if (_cats is! List) _cats = [_cats];

          final categories = _cats.map(checkCData).toList(); */

          // TODO Convert HTML to facets
          final text = stripHTML(description ?? '').trim();

          /*   EmbedViewImages? images;

          if (image != null) {
            images = EmbedViewImages(images: [
              EmbedViewImagesView(thumbnail: image, fullsize: image, alt: '')
            ]);
          } */

          var uri = AtUri.parse(
            'at://$did/app.bsky.feed.post/${makeRKey(id ?? link ?? entry.toString())}',
          );

          final createdAt = parseDateTime(published) ?? DateTime(2020);

          // _postCache[post.ref!] = post;
          int? likeCount;

          try {
            final int count = int.parse(
                mediaGroup['media:community']['media:starRating']['@count']);
            final double likeRatio = double.parse(mediaGroup['media:community']
                    ['media:starRating']['@average']) /
                5;
            likeCount = (count * (likeRatio)).round();
            /* post.customReactionCounts = {
              '+': (count * (likeRatio)).round(),
              '-': (count * (1 - likeRatio)).round(),
            }; */

            /* post.customReactionCounts!['👁'] = int.parse(
                mediaGroup['media:community']['media:statistics']['@views']); */
          } catch (_) {}

          final ext = EmbedView.external(
            data: EmbedViewExternal(
              type: 'app.bsky.embed.external#view',
              external: EmbedViewExternalView(
                thumbnail: image,
                uri: link!,
                title: title ?? 'title',
                description: text,
              ),
            ),
          );

          final post = Post(
            record: PostRecord(
              // text: '$title\n$text',
              text: '',
              createdAt: createdAt,
            ),
            author: actorProfile,
            uri: uri,
            cid: makeCID(uri.toString()),
            indexedAt: createdAt,
            embed: ext,
            likeCount: likeCount ?? -1,
            replyCount: -1,
            repostCount: -1,
          );

          // postCache[post.fullPostId] = post;

          posts.add(FeedView(post: post));
        }
        return posts;
      } else if (data.containsKey('rss')) {
        final posts = <FeedView>[];

        var list = data['rss']['channel']['item'] ?? [];

        if (list is! List) {
          list = [list];
        }

        for (final entry in list) {
          String? title = checkCData(entry['title']);

          if (title != null) {
            if (title.endsWith('…”')) title = null;
          }
          final link = checkCData(entry['link']);
          final guid = checkCData(entry['guid']) ?? link;
          var _cats = entry['category'] ?? [];

          if (_cats is! List) _cats = [_cats];

          final categories = _cats.map(checkCData).toList();
          final creator = checkCData(entry['dc:creator']);
          final pubDate = checkCData(entry['pubDate']);
          // final contentEncoded = checkCData(entry['content:encoded']);
          final description = checkCData(entry['description']);

          var text = stripHTML(description ?? '').trim();

          // final media = model.Media();

          String? imageUrl;

          if (text.contains('<img src="')) {
            final imageSrc = text.split('<img src="')[1].split('"')[0];
            imageUrl = imageSrc;
          }

          // TODO text = html2md.convert(text);

          String? audioUrl;
          String? videoUrl;

          if (entry.containsKey('enclosure')) {
            var enclosure = entry['enclosure'];

            if (enclosure is! List) {
              enclosure = [enclosure];
            }

            try {
              final e = enclosure.first;
              final url = e['@url'];

              if (url != null) {
                // mySkyProvider.client.addTrustedDomain(url);
                // media.aspectRatio = null;

                final String type = e['@type'] ?? 'image';

                if (type.startsWith('image')) {
                  imageUrl = url;
                } else if (type.startsWith('audio')) {
                  audioUrl = url;
                } else if (type.startsWith('video')) {
                  videoUrl = url;
                }
              }
            } catch (e) {}
          } else if (entry.containsKey('media:content')) {
            var thumbnails = entry['media:content'];

            if (thumbnails is! List) {
              thumbnails = [thumbnails];
            }

            final url = thumbnails.isEmpty ? null : thumbnails.last['@url'];
            if (url != null) {
              final last = thumbnails.last;
              // mySkyProvider.client.addTrustedDomain(url);
              imageUrl = url;

              try {
                // TODO ASPECT RATIO IS HERE!
                // media.aspectRatio =
                //  int.parse(last['@width']) / int.parse(last['@height']);
                //image.w = int.parse(last['@width']);
                // image.h = int.parse(last['@height']);
              } catch (_) {}
            }
          }

          final createdAt = parseDateTime(pubDate) ?? DateTime(2020);

          var uri = AtUri.parse(
            'at://$did/app.bsky.feed.post/${makeRKey(guid ?? link ?? entry.toString())}',
          );

          final ext = EmbedView.external(
            data: EmbedViewExternal(
              type: 'app.bsky.embed.external#view',
              external: EmbedViewExternalView(
                thumbnail: imageUrl,
                uri: link!,
                title: title ?? 'title',
                description: text,
              ),
            ),
          );
          // TODO Duration, video url, creator
          final post = Post(
            record: PostRecord(
              // text: '$title\n$text',
              // text: '# $title\n\n$text',
              text: '',
              createdAt: createdAt,
            ),
            // TODO Show this
            tags: categories.cast<String>(),

            author: actorProfile,
            uri: uri,
            cid: makeCID(uri.toString()),
            indexedAt: createdAt,
            embed: ext,
            likeCount: -1,
            replyCount: -1,
            repostCount: -1,
          );

          // postCache[post.fullPostId] = post;

          posts.add(FeedView(post: post));
        }
        return posts;
      } else {
        throw 'Invalid feed document (x1)';
      }
    } else {
      throw 'Invalid feed document (x2)';
    }
  }

  String stripHTML(String s) => s.replaceAll('<p>', '');
}
