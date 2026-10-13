import 'dart:convert';
import 'package:e2b/e2b.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('named constructors encode nested models and snapshot collections', () {
    final metadata = <String, String>{'purpose': 'test'};
    final model = ApiSchemaNewSandboxV2(
        templateID: 'base',
        timeout: 0,
        autoPause: false,
        metadata: metadata,
        iam: ApiSchemaSandboxIam(tokens: {
          'service':
              ApiSchemaSandboxIamToken(audience: 'example', tokenType: 'oidc')
        }));
    metadata['purpose'] = 'changed';
    expect(jsonDecode(jsonEncode(model)), {
      'templateID': 'base',
      'timeout': 0,
      'autoPause': false,
      'metadata': {'purpose': 'test'},
      'iam': {
        'tokens': {
          'service': {'audience': 'example', 'tokenType': 'oidc'}
        }
      }
    });
    expect(model.iam!.tokens!['service']!.tokenType, 'oidc');
    expect(model.containsKey('network'), isFalse);
  });

  test('nullable constructor arguments distinguish omission and null', () {
    final omitted = ApiSchemaNewSandboxV2(templateID: 'base');
    final explicit = ApiSchemaNewSandboxV2(
        templateID: 'base', mcp: const ApiSchemaOptional(null));
    expect(omitted.toJson(), {'templateID': 'base'});
    expect(explicit.toJson(), {'templateID': 'base', 'mcp': null});
    final user = ApiSchemaTeamUser(id: 'user', email: null);
    expect(user.toJson(), {'id': 'user', 'email': null});
  });

  test('registry variant constructor accepts typed input', () {
    final model = ApiSchemaFromImageRegistry.gcp(
        ApiSchemaGCPRegistry(type: 'gcp', serviceAccountJson: '{}'));
    expect(model.asGCPRegistry!.serviceAccountJson, '{}');
    expect(jsonDecode(jsonEncode(model)),
        {'type': 'gcp', 'serviceAccountJson': '{}'});
  });

  test('typed request view preserves nested IAM and absent/null JSON', () {
    final raw = <String, Object?>{
      'templateID': 'base',
      'timeout': 1.5,
      'metadata': {'purpose': 'test'},
      'iam': {
        'tokens': {
          'service': {'audience': 'example', 'tokenType': 'oidc'}
        }
      },
      'network': null,
      'futureField': [true, null],
    };
    final model = ApiSchemaNewSandboxV2.fromJson(raw);
    expect(model.templateID, 'base');
    expect(model.timeout, 1.5);
    expect(model.metadata!['purpose'], 'test');
    expect(model.iam!.tokens!['service']!.audience, 'example');
    expect(model.network, isNull);
    expect(model.envVars, isNull);
    expect(model.containsKey('network'), isTrue);
    expect(model.containsKey('envVars'), isFalse);
    expect(jsonDecode(jsonEncode(model)), raw);
    raw['templateID'] = 'changed';
    expect(model.templateID, 'base');
    final copy = model.toJson()..remove('templateID');
    expect(copy.containsKey('templateID'), isFalse);
    expect(model.templateID, 'base');
  });

  test('registry discriminator exposes the matching typed variant', () {
    final registry = ApiSchemaFromImageRegistry.fromJson({
      'type': 'gcp',
      'serviceAccountJson': '{}',
    });
    expect(registry.asGCPRegistry!.serviceAccountJson, '{}');
    expect(registry.asAWSRegistry, isNull);
    expect(registry.asGeneralRegistry, isNull);
    expect(
        ApiSchemaFromImageRegistry.fromJson({'type': 'future'}).asGCPRegistry,
        isNull);
  });

  test('schema views retain wire date strings and nullable referenced fields',
      () {
    final model = ApiSchemaTemplate.fromJson({
      'createdAt': '2026-10-13T00:00:00.123456Z',
      'createdBy': null,
      'lastSpawnedAt': null,
    });
    expect(model.createdAt, '2026-10-13T00:00:00.123456Z');
    expect(model.createdBy, isNull);
    expect(model.lastSpawnedAt, isNull);
    expect(() => model.templateID, throwsA(isA<TypeError>()));
    expect(() => ApiSchemaNewSandboxV2.fromJson({'templateID': 1}).templateID,
        throwsA(isA<TypeError>()));
  });

  test('schema models work as low-level request bodies and response views',
      () async {
    final client = ApiClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          expect(jsonDecode(request.body), {
            'target': 'base:latest',
            'tags': ['stable']
          });
          return http.Response('{"buildID":"build","tags":["stable"]}', 200);
        }));
    try {
      final response = await client.api.POST('/templates/tags',
          body: ApiSchemaAssignTemplateTagsRequest.fromJson({
            'target': 'base:latest',
            'tags': ['stable'],
          }));
      final model = ApiSchemaAssignedTemplateTags.fromJson(
          Map<String, Object?>.from(response.data as Map));
      expect(model.buildID, 'build');
      expect(model.tags, ['stable']);
      expect(() => model.tags.add('extra'), throwsUnsupportedError);
    } finally {
      client.close();
    }
  });
}
