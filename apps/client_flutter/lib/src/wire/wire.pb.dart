// This is a generated file - do not edit.
//
// Generated from wire.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:fixnum/fixnum.dart' as $fixnum;
import 'package:protobuf/protobuf.dart' as $pb;

import 'wire.pbenum.dart';

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

export 'wire.pbenum.dart';

enum Frame_Payload {
  hello,
  auth,
  encrypted,
  durableAck,
  syncRequest,
  syncResponse,
  processedAck,
  serverError,
  callSignal,
  notSet
}

class Frame extends $pb.GeneratedMessage {
  factory Frame({
    $core.int? protocolVersion,
    $core.List<$core.int>? requestId,
    FrameKind? kind,
    Hello? hello,
    Auth? auth,
    EncryptedEnvelope? encrypted,
    DurableAck? durableAck,
    SyncRequest? syncRequest,
    SyncResponse? syncResponse,
    ProcessedAck? processedAck,
    Error? serverError,
    CallSignal? callSignal,
  }) {
    final result = Frame._();
    if (protocolVersion != null) result.protocolVersion = protocolVersion;
    if (requestId != null) result.requestId = requestId;
    if (kind != null) result.kind = kind;
    if (hello != null) result.hello = hello;
    if (auth != null) result.auth = auth;
    if (encrypted != null) result.encrypted = encrypted;
    if (durableAck != null) result.durableAck = durableAck;
    if (syncRequest != null) result.syncRequest = syncRequest;
    if (syncResponse != null) result.syncResponse = syncResponse;
    if (processedAck != null) result.processedAck = processedAck;
    if (serverError != null) result.serverError = serverError;
    if (callSignal != null) result.callSignal = callSignal;
    return result;
  }

  Frame._();

  factory Frame.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Frame()..mergeFromBuffer(data, registry);
  factory Frame.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Frame()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, Frame_Payload> _Frame_PayloadByTag = {
    4: Frame_Payload.hello,
    5: Frame_Payload.auth,
    6: Frame_Payload.encrypted,
    7: Frame_Payload.durableAck,
    8: Frame_Payload.syncRequest,
    9: Frame_Payload.syncResponse,
    10: Frame_Payload.processedAck,
    11: Frame_Payload.serverError,
    12: Frame_Payload.callSignal,
    0: Frame_Payload.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Frame',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'securemesh.transport.v1'),
      createEmptyInstance: Frame.$_createMessage)
    ..oo(0, [4, 5, 6, 7, 8, 9, 10, 11, 12])
    ..aI(1, _omitFieldNames ? '' : 'protocolVersion',
        fieldType: $pb.PbFieldType.OU3)
    ..a<$core.List<$core.int>>(
        2, _omitFieldNames ? '' : 'requestId', $pb.PbFieldType.OY)
    ..aE<FrameKind>(3, _omitFieldNames ? '' : 'kind',
        enumValues: FrameKind.values)
    ..aOM<Hello>(4, _omitFieldNames ? '' : 'hello',
        subBuilder: Hello.$_createMessage)
    ..aOM<Auth>(5, _omitFieldNames ? '' : 'auth',
        subBuilder: Auth.$_createMessage)
    ..aOM<EncryptedEnvelope>(6, _omitFieldNames ? '' : 'encrypted',
        subBuilder: EncryptedEnvelope.$_createMessage)
    ..aOM<DurableAck>(7, _omitFieldNames ? '' : 'durableAck',
        subBuilder: DurableAck.$_createMessage)
    ..aOM<SyncRequest>(8, _omitFieldNames ? '' : 'syncRequest',
        subBuilder: SyncRequest.$_createMessage)
    ..aOM<SyncResponse>(9, _omitFieldNames ? '' : 'syncResponse',
        subBuilder: SyncResponse.$_createMessage)
    ..aOM<ProcessedAck>(10, _omitFieldNames ? '' : 'processedAck',
        subBuilder: ProcessedAck.$_createMessage)
    ..aOM<Error>(11, _omitFieldNames ? '' : 'serverError',
        subBuilder: Error.$_createMessage)
    ..aOM<CallSignal>(12, _omitFieldNames ? '' : 'callSignal',
        subBuilder: CallSignal.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Frame clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Frame copyWith(void Function(Frame) updates) =>
      super.copyWith((message) => updates(message as Frame)) as Frame;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Frame() / Frame.new instead')
  static Frame create() => Frame._();
  static $pb.GeneratedMessage $_createMessage() => Frame._();
  @$core.override
  Frame createEmptyInstance() => Frame._();
  @$core.pragma('dart2js:noInline')
  static Frame getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Frame>(Frame.$_createMessage);
  static Frame? _defaultInstance;

  @$pb.TagNumber(4)
  @$pb.TagNumber(5)
  @$pb.TagNumber(6)
  @$pb.TagNumber(7)
  @$pb.TagNumber(8)
  @$pb.TagNumber(9)
  @$pb.TagNumber(10)
  @$pb.TagNumber(11)
  @$pb.TagNumber(12)
  Frame_Payload whichPayload() => _Frame_PayloadByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(4)
  @$pb.TagNumber(5)
  @$pb.TagNumber(6)
  @$pb.TagNumber(7)
  @$pb.TagNumber(8)
  @$pb.TagNumber(9)
  @$pb.TagNumber(10)
  @$pb.TagNumber(11)
  @$pb.TagNumber(12)
  void clearPayload() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  $core.int get protocolVersion => $_getIZ(0);
  @$pb.TagNumber(1)
  set protocolVersion($core.int value) => $_setUnsignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasProtocolVersion() => $_has(0);
  @$pb.TagNumber(1)
  void clearProtocolVersion() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.List<$core.int> get requestId => $_getN(1);
  @$pb.TagNumber(2)
  set requestId($core.List<$core.int> value) => $_setBytes(1, value);
  @$pb.TagNumber(2)
  $core.bool hasRequestId() => $_has(1);
  @$pb.TagNumber(2)
  void clearRequestId() => $_clearField(2);

  @$pb.TagNumber(3)
  FrameKind get kind => $_getN(2);
  @$pb.TagNumber(3)
  set kind(FrameKind value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasKind() => $_has(2);
  @$pb.TagNumber(3)
  void clearKind() => $_clearField(3);

  @$pb.TagNumber(4)
  Hello get hello => $_getN(3);
  @$pb.TagNumber(4)
  set hello(Hello value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasHello() => $_has(3);
  @$pb.TagNumber(4)
  void clearHello() => $_clearField(4);
  @$pb.TagNumber(4)
  Hello ensureHello() => $_ensure(3);

  @$pb.TagNumber(5)
  Auth get auth => $_getN(4);
  @$pb.TagNumber(5)
  set auth(Auth value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasAuth() => $_has(4);
  @$pb.TagNumber(5)
  void clearAuth() => $_clearField(5);
  @$pb.TagNumber(5)
  Auth ensureAuth() => $_ensure(4);

  @$pb.TagNumber(6)
  EncryptedEnvelope get encrypted => $_getN(5);
  @$pb.TagNumber(6)
  set encrypted(EncryptedEnvelope value) => $_setField(6, value);
  @$pb.TagNumber(6)
  $core.bool hasEncrypted() => $_has(5);
  @$pb.TagNumber(6)
  void clearEncrypted() => $_clearField(6);
  @$pb.TagNumber(6)
  EncryptedEnvelope ensureEncrypted() => $_ensure(5);

  @$pb.TagNumber(7)
  DurableAck get durableAck => $_getN(6);
  @$pb.TagNumber(7)
  set durableAck(DurableAck value) => $_setField(7, value);
  @$pb.TagNumber(7)
  $core.bool hasDurableAck() => $_has(6);
  @$pb.TagNumber(7)
  void clearDurableAck() => $_clearField(7);
  @$pb.TagNumber(7)
  DurableAck ensureDurableAck() => $_ensure(6);

  @$pb.TagNumber(8)
  SyncRequest get syncRequest => $_getN(7);
  @$pb.TagNumber(8)
  set syncRequest(SyncRequest value) => $_setField(8, value);
  @$pb.TagNumber(8)
  $core.bool hasSyncRequest() => $_has(7);
  @$pb.TagNumber(8)
  void clearSyncRequest() => $_clearField(8);
  @$pb.TagNumber(8)
  SyncRequest ensureSyncRequest() => $_ensure(7);

  @$pb.TagNumber(9)
  SyncResponse get syncResponse => $_getN(8);
  @$pb.TagNumber(9)
  set syncResponse(SyncResponse value) => $_setField(9, value);
  @$pb.TagNumber(9)
  $core.bool hasSyncResponse() => $_has(8);
  @$pb.TagNumber(9)
  void clearSyncResponse() => $_clearField(9);
  @$pb.TagNumber(9)
  SyncResponse ensureSyncResponse() => $_ensure(8);

  @$pb.TagNumber(10)
  ProcessedAck get processedAck => $_getN(9);
  @$pb.TagNumber(10)
  set processedAck(ProcessedAck value) => $_setField(10, value);
  @$pb.TagNumber(10)
  $core.bool hasProcessedAck() => $_has(9);
  @$pb.TagNumber(10)
  void clearProcessedAck() => $_clearField(10);
  @$pb.TagNumber(10)
  ProcessedAck ensureProcessedAck() => $_ensure(9);

  @$pb.TagNumber(11)
  Error get serverError => $_getN(10);
  @$pb.TagNumber(11)
  set serverError(Error value) => $_setField(11, value);
  @$pb.TagNumber(11)
  $core.bool hasServerError() => $_has(10);
  @$pb.TagNumber(11)
  void clearServerError() => $_clearField(11);
  @$pb.TagNumber(11)
  Error ensureServerError() => $_ensure(10);

  @$pb.TagNumber(12)
  CallSignal get callSignal => $_getN(11);
  @$pb.TagNumber(12)
  set callSignal(CallSignal value) => $_setField(12, value);
  @$pb.TagNumber(12)
  $core.bool hasCallSignal() => $_has(11);
  @$pb.TagNumber(12)
  void clearCallSignal() => $_clearField(12);
  @$pb.TagNumber(12)
  CallSignal ensureCallSignal() => $_ensure(11);
}

class Hello extends $pb.GeneratedMessage {
  factory Hello({
    $core.Iterable<$core.int>? supportedVersions,
    $core.List<$core.int>? clientDeviceId,
    $core.List<$core.int>? opaqueResumeToken,
    $core.int? maxFrameBytesSupported,
  }) {
    final result = Hello._();
    if (supportedVersions != null)
      result.supportedVersions.addAll(supportedVersions);
    if (clientDeviceId != null) result.clientDeviceId = clientDeviceId;
    if (opaqueResumeToken != null) result.opaqueResumeToken = opaqueResumeToken;
    if (maxFrameBytesSupported != null)
      result.maxFrameBytesSupported = maxFrameBytesSupported;
    return result;
  }

  Hello._();

  factory Hello.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Hello()..mergeFromBuffer(data, registry);
  factory Hello.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Hello()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Hello',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'securemesh.transport.v1'),
      createEmptyInstance: Hello.$_createMessage)
    ..p<$core.int>(
        1, _omitFieldNames ? '' : 'supportedVersions', $pb.PbFieldType.KU3)
    ..a<$core.List<$core.int>>(
        2, _omitFieldNames ? '' : 'clientDeviceId', $pb.PbFieldType.OY)
    ..a<$core.List<$core.int>>(
        3, _omitFieldNames ? '' : 'opaqueResumeToken', $pb.PbFieldType.OY)
    ..aI(4, _omitFieldNames ? '' : 'maxFrameBytesSupported',
        fieldType: $pb.PbFieldType.OU3)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Hello clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Hello copyWith(void Function(Hello) updates) =>
      super.copyWith((message) => updates(message as Hello)) as Hello;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Hello() / Hello.new instead')
  static Hello create() => Hello._();
  static $pb.GeneratedMessage $_createMessage() => Hello._();
  @$core.override
  Hello createEmptyInstance() => Hello._();
  @$core.pragma('dart2js:noInline')
  static Hello getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Hello>(Hello.$_createMessage);
  static Hello? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<$core.int> get supportedVersions => $_getList(0);

  @$pb.TagNumber(2)
  $core.List<$core.int> get clientDeviceId => $_getN(1);
  @$pb.TagNumber(2)
  set clientDeviceId($core.List<$core.int> value) => $_setBytes(1, value);
  @$pb.TagNumber(2)
  $core.bool hasClientDeviceId() => $_has(1);
  @$pb.TagNumber(2)
  void clearClientDeviceId() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.List<$core.int> get opaqueResumeToken => $_getN(2);
  @$pb.TagNumber(3)
  set opaqueResumeToken($core.List<$core.int> value) => $_setBytes(2, value);
  @$pb.TagNumber(3)
  $core.bool hasOpaqueResumeToken() => $_has(2);
  @$pb.TagNumber(3)
  void clearOpaqueResumeToken() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.int get maxFrameBytesSupported => $_getIZ(3);
  @$pb.TagNumber(4)
  set maxFrameBytesSupported($core.int value) => $_setUnsignedInt32(3, value);
  @$pb.TagNumber(4)
  $core.bool hasMaxFrameBytesSupported() => $_has(3);
  @$pb.TagNumber(4)
  void clearMaxFrameBytesSupported() => $_clearField(4);
}

class Auth extends $pb.GeneratedMessage {
  factory Auth({
    $core.List<$core.int>? accessToken,
  }) {
    final result = Auth._();
    if (accessToken != null) result.accessToken = accessToken;
    return result;
  }

  Auth._();

  factory Auth.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Auth()..mergeFromBuffer(data, registry);
  factory Auth.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Auth()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Auth',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'securemesh.transport.v1'),
      createEmptyInstance: Auth.$_createMessage)
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'accessToken', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Auth clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Auth copyWith(void Function(Auth) updates) =>
      super.copyWith((message) => updates(message as Auth)) as Auth;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Auth() / Auth.new instead')
  static Auth create() => Auth._();
  static $pb.GeneratedMessage $_createMessage() => Auth._();
  @$core.override
  Auth createEmptyInstance() => Auth._();
  @$core.pragma('dart2js:noInline')
  static Auth getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Auth>(Auth.$_createMessage);
  static Auth? _defaultInstance;

  /// Authentication header or secure token inside authenticated TLS connection.
  /// Never use query-string token. Redact from logs.
  @$pb.TagNumber(1)
  $core.List<$core.int> get accessToken => $_getN(0);
  @$pb.TagNumber(1)
  set accessToken($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasAccessToken() => $_has(0);
  @$pb.TagNumber(1)
  void clearAccessToken() => $_clearField(1);
}

class EncryptedEnvelope extends $pb.GeneratedMessage {
  factory EncryptedEnvelope({
    $core.List<$core.int>? conversationId,
    $core.List<$core.int>? clientMessageId,
    $core.List<$core.int>? senderDeviceId,
    $fixnum.Int64? mlsEpoch,
    EnvelopeKind? envelopeKind,
    $core.List<$core.int>? opaqueCiphertext,
    $core.List<$core.int>? ciphertextSha256,
    $fixnum.Int64? serverSequence,
    $core.List<$core.int>? serverMessageId,
  }) {
    final result = EncryptedEnvelope._();
    if (conversationId != null) result.conversationId = conversationId;
    if (clientMessageId != null) result.clientMessageId = clientMessageId;
    if (senderDeviceId != null) result.senderDeviceId = senderDeviceId;
    if (mlsEpoch != null) result.mlsEpoch = mlsEpoch;
    if (envelopeKind != null) result.envelopeKind = envelopeKind;
    if (opaqueCiphertext != null) result.opaqueCiphertext = opaqueCiphertext;
    if (ciphertextSha256 != null) result.ciphertextSha256 = ciphertextSha256;
    if (serverSequence != null) result.serverSequence = serverSequence;
    if (serverMessageId != null) result.serverMessageId = serverMessageId;
    return result;
  }

  EncryptedEnvelope._();

  factory EncryptedEnvelope.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      EncryptedEnvelope()..mergeFromBuffer(data, registry);
  factory EncryptedEnvelope.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      EncryptedEnvelope()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'EncryptedEnvelope',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'securemesh.transport.v1'),
      createEmptyInstance: EncryptedEnvelope.$_createMessage)
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'conversationId', $pb.PbFieldType.OY)
    ..a<$core.List<$core.int>>(
        2, _omitFieldNames ? '' : 'clientMessageId', $pb.PbFieldType.OY)
    ..a<$core.List<$core.int>>(
        3, _omitFieldNames ? '' : 'senderDeviceId', $pb.PbFieldType.OY)
    ..a<$fixnum.Int64>(
        4, _omitFieldNames ? '' : 'mlsEpoch', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..aE<EnvelopeKind>(5, _omitFieldNames ? '' : 'envelopeKind',
        enumValues: EnvelopeKind.values)
    ..a<$core.List<$core.int>>(
        6, _omitFieldNames ? '' : 'opaqueCiphertext', $pb.PbFieldType.OY)
    ..a<$core.List<$core.int>>(
        7, _omitFieldNames ? '' : 'ciphertextSha256', $pb.PbFieldType.OY)
    ..a<$fixnum.Int64>(
        8, _omitFieldNames ? '' : 'serverSequence', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$core.List<$core.int>>(
        9, _omitFieldNames ? '' : 'serverMessageId', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  EncryptedEnvelope clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  EncryptedEnvelope copyWith(void Function(EncryptedEnvelope) updates) =>
      super.copyWith((message) => updates(message as EncryptedEnvelope))
          as EncryptedEnvelope;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use EncryptedEnvelope() / EncryptedEnvelope.new instead')
  static EncryptedEnvelope create() => EncryptedEnvelope._();
  static $pb.GeneratedMessage $_createMessage() => EncryptedEnvelope._();
  @$core.override
  EncryptedEnvelope createEmptyInstance() => EncryptedEnvelope._();
  @$core.pragma('dart2js:noInline')
  static EncryptedEnvelope getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<EncryptedEnvelope>(
          EncryptedEnvelope.$_createMessage);
  static EncryptedEnvelope? _defaultInstance;

  @$pb.TagNumber(1)
  $core.List<$core.int> get conversationId => $_getN(0);
  @$pb.TagNumber(1)
  set conversationId($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasConversationId() => $_has(0);
  @$pb.TagNumber(1)
  void clearConversationId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.List<$core.int> get clientMessageId => $_getN(1);
  @$pb.TagNumber(2)
  set clientMessageId($core.List<$core.int> value) => $_setBytes(1, value);
  @$pb.TagNumber(2)
  $core.bool hasClientMessageId() => $_has(1);
  @$pb.TagNumber(2)
  void clearClientMessageId() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.List<$core.int> get senderDeviceId => $_getN(2);
  @$pb.TagNumber(3)
  set senderDeviceId($core.List<$core.int> value) => $_setBytes(2, value);
  @$pb.TagNumber(3)
  $core.bool hasSenderDeviceId() => $_has(2);
  @$pb.TagNumber(3)
  void clearSenderDeviceId() => $_clearField(3);

  @$pb.TagNumber(4)
  $fixnum.Int64 get mlsEpoch => $_getI64(3);
  @$pb.TagNumber(4)
  set mlsEpoch($fixnum.Int64 value) => $_setInt64(3, value);
  @$pb.TagNumber(4)
  $core.bool hasMlsEpoch() => $_has(3);
  @$pb.TagNumber(4)
  void clearMlsEpoch() => $_clearField(4);

  @$pb.TagNumber(5)
  EnvelopeKind get envelopeKind => $_getN(4);
  @$pb.TagNumber(5)
  set envelopeKind(EnvelopeKind value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasEnvelopeKind() => $_has(4);
  @$pb.TagNumber(5)
  void clearEnvelopeKind() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.List<$core.int> get opaqueCiphertext => $_getN(5);
  @$pb.TagNumber(6)
  set opaqueCiphertext($core.List<$core.int> value) => $_setBytes(5, value);
  @$pb.TagNumber(6)
  $core.bool hasOpaqueCiphertext() => $_has(5);
  @$pb.TagNumber(6)
  void clearOpaqueCiphertext() => $_clearField(6);

  @$pb.TagNumber(7)
  $core.List<$core.int> get ciphertextSha256 => $_getN(6);
  @$pb.TagNumber(7)
  set ciphertextSha256($core.List<$core.int> value) => $_setBytes(6, value);
  @$pb.TagNumber(7)
  $core.bool hasCiphertextSha256() => $_has(6);
  @$pb.TagNumber(7)
  void clearCiphertextSha256() => $_clearField(7);

  @$pb.TagNumber(8)
  $fixnum.Int64 get serverSequence => $_getI64(7);
  @$pb.TagNumber(8)
  set serverSequence($fixnum.Int64 value) => $_setInt64(7, value);
  @$pb.TagNumber(8)
  $core.bool hasServerSequence() => $_has(7);
  @$pb.TagNumber(8)
  void clearServerSequence() => $_clearField(8);

  @$pb.TagNumber(9)
  $core.List<$core.int> get serverMessageId => $_getN(8);
  @$pb.TagNumber(9)
  set serverMessageId($core.List<$core.int> value) => $_setBytes(8, value);
  @$pb.TagNumber(9)
  $core.bool hasServerMessageId() => $_has(8);
  @$pb.TagNumber(9)
  void clearServerMessageId() => $_clearField(9);
}

class DurableAck extends $pb.GeneratedMessage {
  factory DurableAck({
    $core.List<$core.int>? conversationId,
    $core.List<$core.int>? clientMessageId,
    $core.List<$core.int>? serverMessageId,
    $fixnum.Int64? serverSequence,
    $core.bool? alreadyCommitted,
  }) {
    final result = DurableAck._();
    if (conversationId != null) result.conversationId = conversationId;
    if (clientMessageId != null) result.clientMessageId = clientMessageId;
    if (serverMessageId != null) result.serverMessageId = serverMessageId;
    if (serverSequence != null) result.serverSequence = serverSequence;
    if (alreadyCommitted != null) result.alreadyCommitted = alreadyCommitted;
    return result;
  }

  DurableAck._();

  factory DurableAck.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      DurableAck()..mergeFromBuffer(data, registry);
  factory DurableAck.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      DurableAck()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DurableAck',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'securemesh.transport.v1'),
      createEmptyInstance: DurableAck.$_createMessage)
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'conversationId', $pb.PbFieldType.OY)
    ..a<$core.List<$core.int>>(
        2, _omitFieldNames ? '' : 'clientMessageId', $pb.PbFieldType.OY)
    ..a<$core.List<$core.int>>(
        3, _omitFieldNames ? '' : 'serverMessageId', $pb.PbFieldType.OY)
    ..a<$fixnum.Int64>(
        4, _omitFieldNames ? '' : 'serverSequence', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..aOB(5, _omitFieldNames ? '' : 'alreadyCommitted')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DurableAck clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DurableAck copyWith(void Function(DurableAck) updates) =>
      super.copyWith((message) => updates(message as DurableAck)) as DurableAck;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use DurableAck() / DurableAck.new instead')
  static DurableAck create() => DurableAck._();
  static $pb.GeneratedMessage $_createMessage() => DurableAck._();
  @$core.override
  DurableAck createEmptyInstance() => DurableAck._();
  @$core.pragma('dart2js:noInline')
  static DurableAck getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<DurableAck>(DurableAck.$_createMessage);
  static DurableAck? _defaultInstance;

  @$pb.TagNumber(1)
  $core.List<$core.int> get conversationId => $_getN(0);
  @$pb.TagNumber(1)
  set conversationId($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasConversationId() => $_has(0);
  @$pb.TagNumber(1)
  void clearConversationId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.List<$core.int> get clientMessageId => $_getN(1);
  @$pb.TagNumber(2)
  set clientMessageId($core.List<$core.int> value) => $_setBytes(1, value);
  @$pb.TagNumber(2)
  $core.bool hasClientMessageId() => $_has(1);
  @$pb.TagNumber(2)
  void clearClientMessageId() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.List<$core.int> get serverMessageId => $_getN(2);
  @$pb.TagNumber(3)
  set serverMessageId($core.List<$core.int> value) => $_setBytes(2, value);
  @$pb.TagNumber(3)
  $core.bool hasServerMessageId() => $_has(2);
  @$pb.TagNumber(3)
  void clearServerMessageId() => $_clearField(3);

  @$pb.TagNumber(4)
  $fixnum.Int64 get serverSequence => $_getI64(3);
  @$pb.TagNumber(4)
  set serverSequence($fixnum.Int64 value) => $_setInt64(3, value);
  @$pb.TagNumber(4)
  $core.bool hasServerSequence() => $_has(3);
  @$pb.TagNumber(4)
  void clearServerSequence() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.bool get alreadyCommitted => $_getBF(4);
  @$pb.TagNumber(5)
  set alreadyCommitted($core.bool value) => $_setBool(4, value);
  @$pb.TagNumber(5)
  $core.bool hasAlreadyCommitted() => $_has(4);
  @$pb.TagNumber(5)
  void clearAlreadyCommitted() => $_clearField(5);
}

class SyncRequest extends $pb.GeneratedMessage {
  factory SyncRequest({
    $core.List<$core.int>? conversationId,
    $core.List<$core.int>? opaqueCursor,
    $core.int? limit,
  }) {
    final result = SyncRequest._();
    if (conversationId != null) result.conversationId = conversationId;
    if (opaqueCursor != null) result.opaqueCursor = opaqueCursor;
    if (limit != null) result.limit = limit;
    return result;
  }

  SyncRequest._();

  factory SyncRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SyncRequest()..mergeFromBuffer(data, registry);
  factory SyncRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SyncRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SyncRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'securemesh.transport.v1'),
      createEmptyInstance: SyncRequest.$_createMessage)
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'conversationId', $pb.PbFieldType.OY)
    ..a<$core.List<$core.int>>(
        2, _omitFieldNames ? '' : 'opaqueCursor', $pb.PbFieldType.OY)
    ..aI(3, _omitFieldNames ? '' : 'limit', fieldType: $pb.PbFieldType.OU3)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SyncRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SyncRequest copyWith(void Function(SyncRequest) updates) =>
      super.copyWith((message) => updates(message as SyncRequest))
          as SyncRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use SyncRequest() / SyncRequest.new instead')
  static SyncRequest create() => SyncRequest._();
  static $pb.GeneratedMessage $_createMessage() => SyncRequest._();
  @$core.override
  SyncRequest createEmptyInstance() => SyncRequest._();
  @$core.pragma('dart2js:noInline')
  static SyncRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<SyncRequest>(
          SyncRequest.$_createMessage);
  static SyncRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.List<$core.int> get conversationId => $_getN(0);
  @$pb.TagNumber(1)
  set conversationId($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasConversationId() => $_has(0);
  @$pb.TagNumber(1)
  void clearConversationId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.List<$core.int> get opaqueCursor => $_getN(1);
  @$pb.TagNumber(2)
  set opaqueCursor($core.List<$core.int> value) => $_setBytes(1, value);
  @$pb.TagNumber(2)
  $core.bool hasOpaqueCursor() => $_has(1);
  @$pb.TagNumber(2)
  void clearOpaqueCursor() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.int get limit => $_getIZ(2);
  @$pb.TagNumber(3)
  set limit($core.int value) => $_setUnsignedInt32(2, value);
  @$pb.TagNumber(3)
  $core.bool hasLimit() => $_has(2);
  @$pb.TagNumber(3)
  void clearLimit() => $_clearField(3);
}

class SyncResponse extends $pb.GeneratedMessage {
  factory SyncResponse({
    $core.List<$core.int>? conversationId,
    $core.Iterable<EncryptedEnvelope>? messages,
    $core.List<$core.int>? nextCursor,
    $core.bool? hasMore,
    $fixnum.Int64? peerProcessedSequence,
  }) {
    final result = SyncResponse._();
    if (conversationId != null) result.conversationId = conversationId;
    if (messages != null) result.messages.addAll(messages);
    if (nextCursor != null) result.nextCursor = nextCursor;
    if (hasMore != null) result.hasMore = hasMore;
    if (peerProcessedSequence != null)
      result.peerProcessedSequence = peerProcessedSequence;
    return result;
  }

  SyncResponse._();

  factory SyncResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SyncResponse()..mergeFromBuffer(data, registry);
  factory SyncResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SyncResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SyncResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'securemesh.transport.v1'),
      createEmptyInstance: SyncResponse.$_createMessage)
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'conversationId', $pb.PbFieldType.OY)
    ..pPM<EncryptedEnvelope>(2, _omitFieldNames ? '' : 'messages',
        subBuilder: EncryptedEnvelope.$_createMessage)
    ..a<$core.List<$core.int>>(
        3, _omitFieldNames ? '' : 'nextCursor', $pb.PbFieldType.OY)
    ..aOB(4, _omitFieldNames ? '' : 'hasMore')
    ..a<$fixnum.Int64>(
        5, _omitFieldNames ? '' : 'peerProcessedSequence', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SyncResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SyncResponse copyWith(void Function(SyncResponse) updates) =>
      super.copyWith((message) => updates(message as SyncResponse))
          as SyncResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use SyncResponse() / SyncResponse.new instead')
  static SyncResponse create() => SyncResponse._();
  static $pb.GeneratedMessage $_createMessage() => SyncResponse._();
  @$core.override
  SyncResponse createEmptyInstance() => SyncResponse._();
  @$core.pragma('dart2js:noInline')
  static SyncResponse getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<SyncResponse>(
          SyncResponse.$_createMessage);
  static SyncResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $core.List<$core.int> get conversationId => $_getN(0);
  @$pb.TagNumber(1)
  set conversationId($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasConversationId() => $_has(0);
  @$pb.TagNumber(1)
  void clearConversationId() => $_clearField(1);

  @$pb.TagNumber(2)
  $pb.PbList<EncryptedEnvelope> get messages => $_getList(1);

  @$pb.TagNumber(3)
  $core.List<$core.int> get nextCursor => $_getN(2);
  @$pb.TagNumber(3)
  set nextCursor($core.List<$core.int> value) => $_setBytes(2, value);
  @$pb.TagNumber(3)
  $core.bool hasNextCursor() => $_has(2);
  @$pb.TagNumber(3)
  void clearNextCursor() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.bool get hasMore => $_getBF(3);
  @$pb.TagNumber(4)
  set hasMore($core.bool value) => $_setBool(3, value);
  @$pb.TagNumber(4)
  $core.bool hasHasMore() => $_has(3);
  @$pb.TagNumber(4)
  void clearHasMore() => $_clearField(4);

  @$pb.TagNumber(5)
  $fixnum.Int64 get peerProcessedSequence => $_getI64(4);
  @$pb.TagNumber(5)
  set peerProcessedSequence($fixnum.Int64 value) => $_setInt64(4, value);
  @$pb.TagNumber(5)
  $core.bool hasPeerProcessedSequence() => $_has(4);
  @$pb.TagNumber(5)
  void clearPeerProcessedSequence() => $_clearField(5);
}

class ProcessedAck extends $pb.GeneratedMessage {
  factory ProcessedAck({
    $core.List<$core.int>? conversationId,
    $fixnum.Int64? highestContiguousPersistedSequence,
  }) {
    final result = ProcessedAck._();
    if (conversationId != null) result.conversationId = conversationId;
    if (highestContiguousPersistedSequence != null)
      result.highestContiguousPersistedSequence =
          highestContiguousPersistedSequence;
    return result;
  }

  ProcessedAck._();

  factory ProcessedAck.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ProcessedAck()..mergeFromBuffer(data, registry);
  factory ProcessedAck.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ProcessedAck()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ProcessedAck',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'securemesh.transport.v1'),
      createEmptyInstance: ProcessedAck.$_createMessage)
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'conversationId', $pb.PbFieldType.OY)
    ..a<$fixnum.Int64>(
        2,
        _omitFieldNames ? '' : 'highestContiguousPersistedSequence',
        $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ProcessedAck clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ProcessedAck copyWith(void Function(ProcessedAck) updates) =>
      super.copyWith((message) => updates(message as ProcessedAck))
          as ProcessedAck;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use ProcessedAck() / ProcessedAck.new instead')
  static ProcessedAck create() => ProcessedAck._();
  static $pb.GeneratedMessage $_createMessage() => ProcessedAck._();
  @$core.override
  ProcessedAck createEmptyInstance() => ProcessedAck._();
  @$core.pragma('dart2js:noInline')
  static ProcessedAck getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ProcessedAck>(
          ProcessedAck.$_createMessage);
  static ProcessedAck? _defaultInstance;

  @$pb.TagNumber(1)
  $core.List<$core.int> get conversationId => $_getN(0);
  @$pb.TagNumber(1)
  set conversationId($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasConversationId() => $_has(0);
  @$pb.TagNumber(1)
  void clearConversationId() => $_clearField(1);

  @$pb.TagNumber(2)
  $fixnum.Int64 get highestContiguousPersistedSequence => $_getI64(1);
  @$pb.TagNumber(2)
  set highestContiguousPersistedSequence($fixnum.Int64 value) =>
      $_setInt64(1, value);
  @$pb.TagNumber(2)
  $core.bool hasHighestContiguousPersistedSequence() => $_has(1);
  @$pb.TagNumber(2)
  void clearHighestContiguousPersistedSequence() => $_clearField(2);
}

class Error extends $pb.GeneratedMessage {
  factory Error({
    $core.int? code,
    $core.String? stableCode,
    $core.int? retryAfterMs,
    $core.String? safeDetails,
  }) {
    final result = Error._();
    if (code != null) result.code = code;
    if (stableCode != null) result.stableCode = stableCode;
    if (retryAfterMs != null) result.retryAfterMs = retryAfterMs;
    if (safeDetails != null) result.safeDetails = safeDetails;
    return result;
  }

  Error._();

  factory Error.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Error()..mergeFromBuffer(data, registry);
  factory Error.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Error()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Error',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'securemesh.transport.v1'),
      createEmptyInstance: Error.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'code', fieldType: $pb.PbFieldType.OU3)
    ..aOS(2, _omitFieldNames ? '' : 'stableCode')
    ..aI(3, _omitFieldNames ? '' : 'retryAfterMs',
        fieldType: $pb.PbFieldType.OU3)
    ..aOS(4, _omitFieldNames ? '' : 'safeDetails')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Error clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Error copyWith(void Function(Error) updates) =>
      super.copyWith((message) => updates(message as Error)) as Error;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Error() / Error.new instead')
  static Error create() => Error._();
  static $pb.GeneratedMessage $_createMessage() => Error._();
  @$core.override
  Error createEmptyInstance() => Error._();
  @$core.pragma('dart2js:noInline')
  static Error getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Error>(Error.$_createMessage);
  static Error? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get code => $_getIZ(0);
  @$pb.TagNumber(1)
  set code($core.int value) => $_setUnsignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasCode() => $_has(0);
  @$pb.TagNumber(1)
  void clearCode() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get stableCode => $_getSZ(1);
  @$pb.TagNumber(2)
  set stableCode($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasStableCode() => $_has(1);
  @$pb.TagNumber(2)
  void clearStableCode() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.int get retryAfterMs => $_getIZ(2);
  @$pb.TagNumber(3)
  set retryAfterMs($core.int value) => $_setUnsignedInt32(2, value);
  @$pb.TagNumber(3)
  $core.bool hasRetryAfterMs() => $_has(2);
  @$pb.TagNumber(3)
  void clearRetryAfterMs() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.String get safeDetails => $_getSZ(3);
  @$pb.TagNumber(4)
  set safeDetails($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasSafeDetails() => $_has(3);
  @$pb.TagNumber(4)
  void clearSafeDetails() => $_clearField(4);
}

class CallSignal extends $pb.GeneratedMessage {
  factory CallSignal({
    $core.List<$core.int>? conversationId,
    $core.List<$core.int>? senderDeviceId,
    $core.List<$core.int>? recipientDeviceId,
    $core.List<$core.int>? payload,
  }) {
    final result = CallSignal._();
    if (conversationId != null) result.conversationId = conversationId;
    if (senderDeviceId != null) result.senderDeviceId = senderDeviceId;
    if (recipientDeviceId != null) result.recipientDeviceId = recipientDeviceId;
    if (payload != null) result.payload = payload;
    return result;
  }

  CallSignal._();

  factory CallSignal.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CallSignal()..mergeFromBuffer(data, registry);
  factory CallSignal.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CallSignal()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CallSignal',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'securemesh.transport.v1'),
      createEmptyInstance: CallSignal.$_createMessage)
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'conversationId', $pb.PbFieldType.OY)
    ..a<$core.List<$core.int>>(
        2, _omitFieldNames ? '' : 'senderDeviceId', $pb.PbFieldType.OY)
    ..a<$core.List<$core.int>>(
        3, _omitFieldNames ? '' : 'recipientDeviceId', $pb.PbFieldType.OY)
    ..a<$core.List<$core.int>>(
        4, _omitFieldNames ? '' : 'payload', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CallSignal clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CallSignal copyWith(void Function(CallSignal) updates) =>
      super.copyWith((message) => updates(message as CallSignal)) as CallSignal;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use CallSignal() / CallSignal.new instead')
  static CallSignal create() => CallSignal._();
  static $pb.GeneratedMessage $_createMessage() => CallSignal._();
  @$core.override
  CallSignal createEmptyInstance() => CallSignal._();
  @$core.pragma('dart2js:noInline')
  static CallSignal getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CallSignal>(CallSignal.$_createMessage);
  static CallSignal? _defaultInstance;

  @$pb.TagNumber(1)
  $core.List<$core.int> get conversationId => $_getN(0);
  @$pb.TagNumber(1)
  set conversationId($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasConversationId() => $_has(0);
  @$pb.TagNumber(1)
  void clearConversationId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.List<$core.int> get senderDeviceId => $_getN(1);
  @$pb.TagNumber(2)
  set senderDeviceId($core.List<$core.int> value) => $_setBytes(1, value);
  @$pb.TagNumber(2)
  $core.bool hasSenderDeviceId() => $_has(1);
  @$pb.TagNumber(2)
  void clearSenderDeviceId() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.List<$core.int> get recipientDeviceId => $_getN(2);
  @$pb.TagNumber(3)
  set recipientDeviceId($core.List<$core.int> value) => $_setBytes(2, value);
  @$pb.TagNumber(3)
  $core.bool hasRecipientDeviceId() => $_has(2);
  @$pb.TagNumber(3)
  void clearRecipientDeviceId() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.List<$core.int> get payload => $_getN(3);
  @$pb.TagNumber(4)
  set payload($core.List<$core.int> value) => $_setBytes(3, value);
  @$pb.TagNumber(4)
  $core.bool hasPayload() => $_has(3);
  @$pb.TagNumber(4)
  void clearPayload() => $_clearField(4);
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
