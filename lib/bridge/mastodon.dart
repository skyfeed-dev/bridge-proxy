import 'package:atproto_bridge_proxy/bridge/base.dart';
import 'package:atproto_bridge_proxy/util/make_cid.dart';
import 'package:atproto_bridge_proxy/util/preprocess_html.dart';
import 'package:bluesky/bluesky.dart';
import 'package:mastodon_api/mastodon_api.dart' as m;

class MastodonBridge extends Bridge {
  late final m.MastodonApi _api;
  final String instance;
  MastodonBridge({
    required super.server,
    required this.instance,
    required String bearerToken,
  }) {
    _api = m.MastodonApi(
      instance: instance,
      bearerToken: bearerToken,
      //! Automatic retry is available when server error or network error occurs
      //! when communicating with the API.
      retryConfig: m.RetryConfig(
        maxAttempts: 5,
        jitter: m.Jitter(
          minInSeconds: 2,
          maxInSeconds: 5,
        ),
        onExecute: (event) => print(
          'Retry after ${event.intervalInSeconds} seconds... '
          '[${event.retryCount} times]',
        ),
      ),

      //! The default timeout is 10 seconds.
      timeout: Duration(seconds: 20),
    );
  }

  String convertHandle(String handle, String did) {
    handle = (handle.contains('@')
            ? handle.replaceFirst('@', '.')
            : '$handle.$instance')
        .replaceAll(
      RegExp(r'[^a-z0-9\-\.]'),
      'x',
    );
    server.handleToDIDMap[handle] = did;

    return handle;
  }

  @override
  Future<Feed> getFeed(
      {required AtUri generatorUri, int? limit, String? cursor}) async {
    final rkey = generatorUri.rkey;
    final future = rkey == 'home'
        ? _api.v1.timelines.lookupHomeTimeline(
            limit: limit,
            maxStatusId: cursor,
          )
        : (rkey == 'public' || rkey == 'local' || rkey == 'remote')
            ? _api.v1.timelines.lookupPublicTimeline(
                limit: limit,
                maxStatusId: cursor,
                onlyLocal: rkey == 'local',
                onlyRemote: rkey == 'remote',
              )
            : rkey.startsWith('tag:')
                ? _api.v1.timelines.lookupTimelineByHashtag(
                    hashtag: rkey.substring(4),
                    limit: limit,
                    maxStatusId: cursor,
                  )
                : _api.v1.timelines.lookupListTimeline(
                    listId: rkey.substring(5),
                    limit: limit,
                    maxStatusId: cursor,
                  );

    final res = await future;
    return Feed(
      feed: [
        for (final status in res.data)
          await convertStatusToFeedViewWithReply(status),
      ],
      cursor: res.data.last.id,
    );
  }

  Future<FeedView> convertStatusToFeedViewWithReply(m.Status status) async {
    final feedView = convertStatusToFeedView(status);
    if (status.reblog != null) {
      status = status.reblog!;
    }
    if (status.inReplyToId != null) {
      try {
        final repliedToStatus =
            await _api.v1.statuses.lookupStatus(statusId: status.inReplyToId!);
        final replyPost = ReplyPost.record(
            data: convertStatusToFeedView(repliedToStatus.data).post);
        return feedView.copyWith(
            reply: Reply(root: replyPost, parent: replyPost));
      } catch (e) {
        print('WARN $e');
        return feedView;
      }
    }
    return feedView;
  }

  FeedView convertStatusToFeedView(m.Status status) {
    String did = 'did:bridge:mastodon:${status.account.id}';
    var uri = AtUri.parse(
      'at://$did/app.bsky.feed.post/${status.id}',
    );
    Reason? reason;

    if (status.reblog != null) {
      reason = Reason.repost(
        data: ReasonRepost(
          by: Actor(
            displayName: status.account.displayName.isEmpty
                ? status.account.username
                : status.account.displayName,
            did: did,
            handle: convertHandle(status.account.acct, did),
            avatar: status.account.avatar,
            viewer: ActorViewer(
              isMuted: false,
              isBlockedBy: false,
            ),
          ),
          indexedAt: status.createdAt,
        ),
      );
      status = status.reblog!;
      did = 'did:bridge:mastodon:${status.account.id}';
      uri = AtUri.parse(
        'at://$did/app.bsky.feed.post/${status.id}',
      );
    }
    var text = preprocessHtml(status.content);

    if (status.tags.isNotEmpty) {
      for (final tag in status.tags) {
        text += ' #${tag.name}';
      }
    }

    EmbedView? embed;

    if (status.mediaAttachments.isNotEmpty) {
      final images = <EmbedViewImagesView>[];
      for (final m in status.mediaAttachments) {
        // TODO m.meta.original.height
        images.add(
          EmbedViewImagesView(
            alt: '',
            fullsize: m.url ?? m.previewUrl,
            thumbnail: m.previewUrl,
          ),
        );
      }
      embed = EmbedView.images(
        data: EmbedViewImages(
          type: 'app.bsky.embed.images#view',
          images: images,
        ),
      );
    }

    // TODO languages

    return FeedView(
        reason: reason,
        post: Post(
          record: PostRecord(
            text: text,
            createdAt: status.createdAt,
          ),
          embed: embed,
          author: Actor(
            displayName: status.account.displayName.isEmpty
                ? status.account.username
                : status.account.displayName,
            did: did,
            handle: convertHandle(status.account.acct, did),
            avatar: status.account.avatar,
            viewer: ActorViewer(
              isMuted: false,
              isBlockedBy: false,
            ),
          ),
          //TODO labels
          /*  labels: (status.isSensitive ?? false)
              ? [
                  Label(
                    src: 'src',
                    uri: 'sensitive',
                    value: 'sensitive',
                    isNegate: false,
                    createdAt: DateTime(2020),
                  ),
                ]
              : null, */
          uri: uri,
          cid: makeCID(uri.toString()),
          replyCount: status.repliesCount,
          repostCount: status.reblogsCount,
          likeCount: status.favouritesCount,
          viewer: PostViewer(),
          indexedAt: status.createdAt,
        ));
  }

  @override
  Future<ActorProfile> getProfile({required String actor}) async {
    final id = actor.split(':').last;
    final res = await _api.v1.accounts.lookupAccount(
      accountId: id,
    );
    final p = res.data;

    var desc = preprocessHtml(p.note);
    for (final f in p.fields) {
      desc += '\n${f.name}: ${preprocessHtml(f.value)}';
      if (f.verifiedAt != null) desc += ' ✅';
    }

    if (p.isBot == true) {
      desc += '\n🤖 Bot';
    }

    return ActorProfile(
      did: actor,
      handle: convertHandle(p.acct, actor),
      avatar: p.avatar,
      banner: p.header,
      description: desc,
      indexedAt: p.createdAt,
      displayName: p.displayName.isEmpty ? p.username : p.displayName,
      followsCount: p.followingCount,
      followersCount: p.followersCount,
      postsCount: p.statusesCount,
      viewer: ActorViewer(isMuted: false, isBlockedBy: false),
    );
  }

  @override
  Future<PostThread> getPostThread(
      {required AtUri uri, int? depth, int? parentHeight}) async {
    final contextRes =
        await _api.v1.statuses.lookupStatusContext(statusId: uri.rkey);

    final statusRes = await _api.v1.statuses.lookupStatus(statusId: uri.rkey);

    final replies = <PostThreadView>[];
    for (final reply in contextRes.data.descendants) {
      replies.add(PostThreadView.record(
        data: PostThreadViewRecord(
          type: 'app.bsky.feed.defs#threadViewPost',
          post: convertStatusToFeedView(reply).post,
          replies: [],
        ),
      ));
    }
    return PostThread(
        thread: PostThreadView.record(
      data: PostThreadViewRecord(
        type: 'app.bsky.feed.defs#threadViewPost',
        post: convertStatusToFeedView(statusRes.data).post,
        parent: buildParent(contextRes.data.ancestors),
        replies: replies,
      ),
    ));
  }

  PostThreadView? buildParent(List<m.Status> ancestors) {
    if (ancestors.isEmpty) return null;
    return PostThreadView.record(
      data: PostThreadViewRecord(
        type: 'app.bsky.feed.defs#threadViewPost',
        post: convertStatusToFeedView(ancestors.last).post,
        parent: buildParent(ancestors.sublist(0, ancestors.length - 1)),
        replies: [],
      ),
    );
  }

  @override
  Future<Feed> getAuthorFeed(
      {required String actor, int? limit, String? cursor}) async {
    final id = actor.split(':').last;
    final res = await _api.v1.accounts.lookupStatuses(
      accountId: id,
      limit: limit,
      maxStatusId: cursor,
    );
    return Feed(
      feed: [
        for (final status in res.data)
          await convertStatusToFeedViewWithReply(status),
      ],
      cursor: res.data.last.id,
    );
  }
}
