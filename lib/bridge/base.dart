import 'package:atproto_bridge_proxy/server.dart';
import 'package:bluesky/bluesky.dart';

abstract class Bridge {
  final BridgeProxyServer server;
  Bridge({required this.server});

  Future<void> init() async {}
  Future<Feed> getFeed({
    required AtUri generatorUri,
    int? limit,
    String? cursor,
  });

  Future<PostThread> getPostThread({
    required AtUri uri,
    int? depth,
    int? parentHeight,
  });

  Future<Feed> getAuthorFeed({
    required String actor,
    int? limit,
    String? cursor,
  });

  Future<ActorProfile> getProfile({
    required String actor,
  });
}
