import 'dart:io';
import 'dart:convert';

import 'package:alfred/alfred.dart';
import 'package:atproto/atproto.dart';
import 'package:atproto_bridge_proxy/util/make_cid.dart';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';
import 'package:path/path.dart';

import 'package:atproto_bridge_proxy/bridge/base.dart';
import 'package:atproto_bridge_proxy/bridge/hacker_news.dart';
import 'package:atproto_bridge_proxy/bridge/mastodon.dart';
import 'package:atproto_bridge_proxy/bridge/rss.dart';
import 'package:atproto_bridge_proxy/bridge/youtube.dart';

class BridgeProxyServer {
  final String service;
  final String serviceProtocol;
  final String serviceEndpoint;
  final Logger logger;

  final handleToDIDMap = <String, String>{};

  BridgeProxyServer({
    this.service = 'bsky.social',
    this.serviceProtocol = 'https',
    required this.serviceEndpoint,
    required this.logger,
  });

  Future<void> start() async {
    final server = await HttpServer.bind(
      '0.0.0.0',
      7070,
      // backlog: backlog,
      // shared: shared,
    );

    logger.i('Listening on ${server.address} port ${server.port}');

    // server.idleTimeout = Duration(seconds: 1);

    server.listen(
      handleRequest,
    );
  }

  final httpClient = HttpClient();
  final simpleHttpClient = http.Client();

  final bridges = <String, Map<String, Bridge>>{};

  void handleRequest(HttpRequest req) async {
    try {
      await handleRequestInternal(req);
    } catch (e, st) {
      logger.w(e);
      logger.t(st);
    }
  }

  // header value -> DID
  final validAuthHeaders = <String, String>{};

  Future<bool> validateAuthHeader(HttpRequest req, String header) async {
    final res = await simpleHttpClient.get(
      Uri.parse(
        '$serviceProtocol://$service/xrpc/com.atproto.server.getSession',
      ),
      headers: {'authorization': header},
    );
    if (res.statusCode != 200) {
      req.response.statusCode = res.statusCode;
      req.response.add(res.bodyBytes);
      req.response.close();
      return false;
    }

    final String did = jsonDecode(res.body)['did'];
    if (!bridges.containsKey(did)) {
      logger.i('[server] Setting up bridges for $did');
      final state = readUserState(did);
      final bridgeMap = <String, Bridge>{
        'hn': HackerNewsBridge(server: this),
      };

      if (state['bridge']?['mastodon'] != null) {
        logger.i('[mastodon] init $did');
        bridgeMap['mastodon'] = MastodonBridge(
          server: this,
          instance: state['bridge']?['mastodon']['instance'],
          bearerToken: state['bridge']?['mastodon']['bearerToken'],
        );
      }

      if (state['bridge']?['youtube'] != null) {
        logger.i('[youtube] init $did');
        bridgeMap['youtube'] = YouTubeBridge(
          server: this,
          following:
              state['bridge']?['youtube']?['following']?.cast<String>() ?? [],
        );
      }

      if (state['bridge']?['rss'] != null) {
        logger.i('[rss] init $did');
        bridgeMap['rss'] = RSSBridge(
          server: this,
          following:
              state['bridge']?['rss']?['following']?.cast<String>() ?? [],
        );
      }

      await Future.wait([
        for (final bridge in bridgeMap.values) bridge.init(),
      ]);

      bridges[did] = bridgeMap;
    }

    validAuthHeaders[header] = did;
    return true;
  }

  Map readUserState(String did) {
    final file = File(join('config', '$did.json'));

    if (!file.existsSync()) return {};

    return jsonDecode(file.readAsStringSync());
  }

  Future<void> handleRequestInternal(HttpRequest req) async {
    final res = req.response;
    res.headers.set('Access-Control-Allow-Origin', '*');
    res.headers.set('Access-Control-Allow-Methods',
        'POST, GET, OPTIONS, PUT, PATCH, DELETE');
    res.headers.set('Access-Control-Allow-Headers', '*');
    res.headers.set('Access-Control-Expose-Headers', '*');
    res.headers.set('Access-Control-Max-Age', '86400');
    if (req.method == 'OPTIONS') {
      res.close();
      return;
    }
    final authHeader = req.headers.value('authorization');

    final path = req.uri.path;

    logger.t('${req.method} $path');

    if (![
      '/xrpc/com.atproto.server.refreshSession',
      '/xrpc/com.atproto.server.createSession',
      '/xrpc/com.atproto.server.describeServer'
    ].contains(path)) {
      if (authHeader == null) throw 'Auth required';

      if (!validAuthHeaders.containsKey(authHeader)) {
        final valid = await validateAuthHeader(req, authHeader);
        if (!valid) return;
      }
    }
    final String did = validAuthHeaders[authHeader] ?? '';

    Map<String, dynamic>? body;

    if (path == '/xrpc/app.bsky.feed.getFeed') {
      if (await handleFeedRequest(req, did)) {
        return;
      }
    } else if (path == '/xrpc/app.bsky.feed.getFeedGenerator') {
      if (await handleFeedGeneratorRequest(req, did)) {
        return;
      }
    } else if (path == '/xrpc/app.bsky.feed.getTimeline') {
      // TODO Override timeline with feed in config
      /* if (await handleFeedRequest(req, did)) {
        return;
      } */
    } else if (path == '/xrpc/app.bsky.feed.getPostThread') {
      if (await handlePostThreadRequest(req, did)) {
        return;
      }
    } else if (path == '/xrpc/app.bsky.actor.getProfile') {
      if (await handleProfileRequest(req, did)) {
        return;
      }
    } else if (path == '/xrpc/app.bsky.feed.getAuthorFeed') {
      if (await handleAuthorFeedRequest(req, did)) {
        return;
      }
    } else if (path == '/xrpc/com.atproto.repo.createRecord') {
      body = await req.bodyAsJsonMap;
      final collection = body['collection'];

      logger.i('[createRecord] $collection $body');
      if (collection == 'app.bsky.feed.like') {
        final String subject = body['record']['subject']['uri'];
        if (!subject.startsWith('at://did:plc:')) {
          throw UnimplementedError();
        }
      } else if (collection == 'app.bsky.feed.repost') {
        final String subject = body['record']['subject']['uri'];
        if (!subject.startsWith('at://did:plc:')) {
          throw UnimplementedError();
        }
      } else if (collection == 'app.bsky.feed.post') {
        final String subject =
            body['record']['reply']?['parent']?['uri'] ?? 'at://did:plc:';
        if (!subject.startsWith('at://did:plc:')) {
          throw UnimplementedError();
        }
      } else if (collection == 'app.bsky.graph.follow') {
        final String subject = body['record']['subject'];
        if (!subject.startsWith('did:plc:')) {
          throw UnimplementedError();
        }
      } else {
        throw UnimplementedError();
      }
    }

    final proxyUri = req.uri.replace(
      host: service,
      scheme: serviceProtocol,
    );

    final proxyReq = await httpClient.openUrl(
      req.method,
      proxyUri,
    )
      ..followRedirects = true;

    // proxyReq.headers.removeAll(HttpHeaders.acceptEncodingHeader);

    req.headers.forEach((name, values) {
      // print('> $name $values');
      if (['host'].contains(name)) return;
      proxyReq.headers.add(name, values.join('; '));
    });
    if (body != null) {
      proxyReq.add(utf8.encode(jsonEncode(body)));
    } else {
      await proxyReq.addStream(req);
    }

    final proxyRes = await proxyReq.close();

    res.statusCode = proxyRes.statusCode;

    proxyRes.headers.forEach((name, values) {
      // print('< $name $values');
      if ([
        'transfer-encoding',
        'content-encoding',
        'content-length',
      ].contains(name)) return;
      // print('header $name ${values.join(',')}');
      res.headers.set(name, values.join('; '));
    });
    if (path == '/xrpc/com.atproto.server.createSession' ||
        path == '/xrpc/com.atproto.server.getSession') {
      final body = await utf8.decodeStream(proxyRes);

      final modifiedBody = body.replaceFirst(
        RegExp(r'"serviceEndpoint":\s*"[^"]+"'),
        '"serviceEndpoint": "$serviceEndpoint"',
      );

      res.add(utf8.encode(modifiedBody));
    } else {
      /* if (req.method == 'OPTIONS') {
        res.headers.set('Cache-Control', 'public, max-age=86400');
        res.headers.set('Vary', 'origin');
      } */
      await res.addStream(proxyRes);
    }
    await res.close();
  }

  Future<bool> handleFeedRequest(HttpRequest req, String did) async {
    final AtUri feed;
    final isTimeline = req.uri.path == '/xrpc/app.bsky.feed.getTimeline';

    if (isTimeline) {
      // TODO feed = AtUri.parse('at://did:bridge:mastodon/app.bsky.feed.generator/home',);
      throw UnimplementedError();
    } else {
      feed = AtUri.parse(req.uri.queryParameters['feed']!);
    }

    if (!feed.hostname.startsWith('did:bridge:')) {
      return false;
    }
    final bridgeId = feed.hostname.split(':')[2];

    final res = await bridges[did]![bridgeId]!.getFeed(
      generatorUri: feed,
      limit: int.tryParse(req.uri.queryParameters['limit'] ?? ''),
      cursor: req.uri.queryParameters['cursor'],
    );
    /* if (isTimeline) {
      final timeline = jsonDecode(jsonEncode(res));
      for (final post in timeline['feed']) {
        (post['post'] as Map).remove('\$type');
      }
      req.response.add(utf8.encode(jsonEncode(timeline)));
    } else { */
    req.response.headers.set('content-type', 'application/json; charset=utf-8');
    req.response.add(utf8.encode(jsonEncode(res)));
    // }
    await req.response.close();
    return true;
  }

  Future<bool> handleFeedGeneratorRequest(HttpRequest req, String did) async {
    final feed = AtUri.parse(req.uri.queryParameters['feed']!);

    if (!feed.hostname.startsWith('did:bridge:')) {
      return false;
    }

    req.response.headers.set('content-type', 'application/json; charset=utf-8');
    req.response.add(utf8.encode(jsonEncode({
      "view": {
        "uri": feed.toString(),
        "cid": makeCID(feed.toString()),
        "did": "did:web:bridge.proxy",
        "creator": {
          "did": "did:bridge:proxy",
          "handle": "bridge.proxy",
          "displayName": 'Bridge Proxy',
          "viewer": {"muted": false, "blockedBy": false},
          "labels": []
        },
        "displayName": '${feed.hostname.substring(11)} • ${feed.rkey}',
        "description": "",
        "likeCount": 0,
        "viewer": {},
        'indexedAt': '0000-01-01T00:00:00Z',
      },
      "isOnline": true,
      "isValid": true
    })));

    await req.response.close();
    return true;
  }

  Future<bool> handlePostThreadRequest(HttpRequest req, String did) async {
    var uri = AtUri.parse(req.uri.queryParameters['uri']!);
    if (!uri.hostname.startsWith('did:bridge:')) {
      if (handleToDIDMap.containsKey(uri.hostname)) {
        uri = AtUri.make(
          handleToDIDMap[uri.hostname]!,
          uri.collection,
          uri.rkey,
        );
      } else {
        return false;
      }
    }
    final bridgeId = uri.hostname.split(':')[2];

    final res = await bridges[did]![bridgeId]!.getPostThread(
      uri: uri,
      depth: int.tryParse(req.uri.queryParameters['depth'] ?? ''),
      parentHeight: int.tryParse(req.uri.queryParameters['parentHeight'] ?? ''),
    );

    final data = jsonEncode(res)
        .replaceAll('"parent":null,', '')
        .replaceAll(',"parent":null', '');
    req.response.headers.set('content-type', 'application/json; charset=utf-8');
    req.response.add(utf8.encode(data));
    await req.response.close();
    return true;
  }

  Future<bool> handleProfileRequest(HttpRequest req, String did) async {
    final actor = resolveActor(req.uri.queryParameters['actor']!);
    if (!actor.startsWith('did:bridge:')) {
      return false;
    }
    final bridgeId = actor.split(':')[2];
    final res = await bridges[did]![bridgeId]!.getProfile(
      actor: actor,
    );
    req.response.headers.set('content-type', 'application/json; charset=utf-8');
    req.response.add(utf8.encode(jsonEncode(res)));
    await req.response.close();
    return true;
  }

  Future<bool> handleAuthorFeedRequest(HttpRequest req, String did) async {
    final actor = resolveActor(req.uri.queryParameters['actor']!);
    if (!actor.startsWith('did:bridge:')) {
      return false;
    }
    final bridgeId = actor.split(':')[2];
    final res = await bridges[did]![bridgeId]!.getAuthorFeed(
      actor: actor,
      limit: int.tryParse(req.uri.queryParameters['limit'] ?? ''),
      cursor: req.uri.queryParameters['cursor'],
    );
    req.response.headers.set('content-type', 'application/json; charset=utf-8');
    req.response.add(utf8.encode(jsonEncode(res)));
    await req.response.close();
    return true;
  }

  String resolveActor(String actor) {
    if (actor.startsWith('did:bridge:')) return actor;
    return handleToDIDMap[actor] ?? 'did:plc:???';
  }
}
