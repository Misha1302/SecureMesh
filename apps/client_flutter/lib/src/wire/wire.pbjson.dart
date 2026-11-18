// This is a generated file - do not edit.
//
// Generated from wire.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports
// ignore_for_file: unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use frameKindDescriptor instead')
const FrameKind$json = {
  '1': 'FrameKind',
  '2': [
    {'1': 'FRAME_KIND_UNSPECIFIED', '2': 0},
    {'1': 'HELLO', '2': 1},
    {'1': 'AUTH', '2': 2},
    {'1': 'SEND_ENCRYPTED', '2': 3},
    {'1': 'DURABLE_ACK', '2': 4},
    {'1': 'SYNC_REQUEST', '2': 5},
    {'1': 'SYNC_RESPONSE', '2': 6},
    {'1': 'PROCESSED_ACK', '2': 7},
    {'1': 'SERVER_ERROR', '2': 8},
    {'1': 'PING', '2': 9},
    {'1': 'PONG', '2': 10},
    {'1': 'CALL_SIGNAL', '2': 11},
  ],
};

/// Descriptor for `FrameKind`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List frameKindDescriptor = $convert.base64Decode(
    'CglGcmFtZUtpbmQSGgoWRlJBTUVfS0lORF9VTlNQRUNJRklFRBAAEgkKBUhFTExPEAESCAoEQV'
    'VUSBACEhIKDlNFTkRfRU5DUllQVEVEEAMSDwoLRFVSQUJMRV9BQ0sQBBIQCgxTWU5DX1JFUVVF'
    'U1QQBRIRCg1TWU5DX1JFU1BPTlNFEAYSEQoNUFJPQ0VTU0VEX0FDSxAHEhAKDFNFUlZFUl9FUl'
    'JPUhAIEggKBFBJTkcQCRIICgRQT05HEAoSDwoLQ0FMTF9TSUdOQUwQCw==');

@$core.Deprecated('Use envelopeKindDescriptor instead')
const EnvelopeKind$json = {
  '1': 'EnvelopeKind',
  '2': [
    {'1': 'ENVELOPE_KIND_UNSPECIFIED', '2': 0},
    {'1': 'MLS_APPLICATION', '2': 1},
    {'1': 'MLS_PROPOSAL', '2': 2},
    {'1': 'MLS_COMMIT', '2': 3},
    {'1': 'MLS_WELCOME', '2': 4},
  ],
};

/// Descriptor for `EnvelopeKind`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List envelopeKindDescriptor = $convert.base64Decode(
    'CgxFbnZlbG9wZUtpbmQSHQoZRU5WRUxPUEVfS0lORF9VTlNQRUNJRklFRBAAEhMKD01MU19BUF'
    'BMSUNBVElPThABEhAKDE1MU19QUk9QT1NBTBACEg4KCk1MU19DT01NSVQQAxIPCgtNTFNfV0VM'
    'Q09NRRAE');

@$core.Deprecated('Use frameDescriptor instead')
const Frame$json = {
  '1': 'Frame',
  '2': [
    {'1': 'protocol_version', '3': 1, '4': 1, '5': 13, '10': 'protocolVersion'},
    {'1': 'request_id', '3': 2, '4': 1, '5': 12, '10': 'requestId'},
    {
      '1': 'kind',
      '3': 3,
      '4': 1,
      '5': 14,
      '6': '.securemesh.transport.v1.FrameKind',
      '10': 'kind'
    },
    {
      '1': 'hello',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.securemesh.transport.v1.Hello',
      '9': 0,
      '10': 'hello'
    },
    {
      '1': 'auth',
      '3': 5,
      '4': 1,
      '5': 11,
      '6': '.securemesh.transport.v1.Auth',
      '9': 0,
      '10': 'auth'
    },
    {
      '1': 'encrypted',
      '3': 6,
      '4': 1,
      '5': 11,
      '6': '.securemesh.transport.v1.EncryptedEnvelope',
      '9': 0,
      '10': 'encrypted'
    },
    {
      '1': 'durable_ack',
      '3': 7,
      '4': 1,
      '5': 11,
      '6': '.securemesh.transport.v1.DurableAck',
      '9': 0,
      '10': 'durableAck'
    },
    {
      '1': 'sync_request',
      '3': 8,
      '4': 1,
      '5': 11,
      '6': '.securemesh.transport.v1.SyncRequest',
      '9': 0,
      '10': 'syncRequest'
    },
    {
      '1': 'sync_response',
      '3': 9,
      '4': 1,
      '5': 11,
      '6': '.securemesh.transport.v1.SyncResponse',
      '9': 0,
      '10': 'syncResponse'
    },
    {
      '1': 'processed_ack',
      '3': 10,
      '4': 1,
      '5': 11,
      '6': '.securemesh.transport.v1.ProcessedAck',
      '9': 0,
      '10': 'processedAck'
    },
    {
      '1': 'server_error',
      '3': 11,
      '4': 1,
      '5': 11,
      '6': '.securemesh.transport.v1.Error',
      '9': 0,
      '10': 'serverError'
    },
    {
      '1': 'call_signal',
      '3': 12,
      '4': 1,
      '5': 11,
      '6': '.securemesh.transport.v1.CallSignal',
      '9': 0,
      '10': 'callSignal'
    },
  ],
  '8': [
    {'1': 'payload'},
  ],
};

/// Descriptor for `Frame`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List frameDescriptor = $convert.base64Decode(
    'CgVGcmFtZRIpChBwcm90b2NvbF92ZXJzaW9uGAEgASgNUg9wcm90b2NvbFZlcnNpb24SHQoKcm'
    'VxdWVzdF9pZBgCIAEoDFIJcmVxdWVzdElkEjYKBGtpbmQYAyABKA4yIi5zZWN1cmVtZXNoLnRy'
    'YW5zcG9ydC52MS5GcmFtZUtpbmRSBGtpbmQSNgoFaGVsbG8YBCABKAsyHi5zZWN1cmVtZXNoLn'
    'RyYW5zcG9ydC52MS5IZWxsb0gAUgVoZWxsbxIzCgRhdXRoGAUgASgLMh0uc2VjdXJlbWVzaC50'
    'cmFuc3BvcnQudjEuQXV0aEgAUgRhdXRoEkoKCWVuY3J5cHRlZBgGIAEoCzIqLnNlY3VyZW1lc2'
    'gudHJhbnNwb3J0LnYxLkVuY3J5cHRlZEVudmVsb3BlSABSCWVuY3J5cHRlZBJGCgtkdXJhYmxl'
    'X2FjaxgHIAEoCzIjLnNlY3VyZW1lc2gudHJhbnNwb3J0LnYxLkR1cmFibGVBY2tIAFIKZHVyYW'
    'JsZUFjaxJJCgxzeW5jX3JlcXVlc3QYCCABKAsyJC5zZWN1cmVtZXNoLnRyYW5zcG9ydC52MS5T'
    'eW5jUmVxdWVzdEgAUgtzeW5jUmVxdWVzdBJMCg1zeW5jX3Jlc3BvbnNlGAkgASgLMiUuc2VjdX'
    'JlbWVzaC50cmFuc3BvcnQudjEuU3luY1Jlc3BvbnNlSABSDHN5bmNSZXNwb25zZRJMCg1wcm9j'
    'ZXNzZWRfYWNrGAogASgLMiUuc2VjdXJlbWVzaC50cmFuc3BvcnQudjEuUHJvY2Vzc2VkQWNrSA'
    'BSDHByb2Nlc3NlZEFjaxJDCgxzZXJ2ZXJfZXJyb3IYCyABKAsyHi5zZWN1cmVtZXNoLnRyYW5z'
    'cG9ydC52MS5FcnJvckgAUgtzZXJ2ZXJFcnJvchJGCgtjYWxsX3NpZ25hbBgMIAEoCzIjLnNlY3'
    'VyZW1lc2gudHJhbnNwb3J0LnYxLkNhbGxTaWduYWxIAFIKY2FsbFNpZ25hbEIJCgdwYXlsb2Fk');

@$core.Deprecated('Use helloDescriptor instead')
const Hello$json = {
  '1': 'Hello',
  '2': [
    {
      '1': 'supported_versions',
      '3': 1,
      '4': 3,
      '5': 13,
      '10': 'supportedVersions'
    },
    {'1': 'client_device_id', '3': 2, '4': 1, '5': 12, '10': 'clientDeviceId'},
    {
      '1': 'opaque_resume_token',
      '3': 3,
      '4': 1,
      '5': 12,
      '10': 'opaqueResumeToken'
    },
    {
      '1': 'max_frame_bytes_supported',
      '3': 4,
      '4': 1,
      '5': 13,
      '10': 'maxFrameBytesSupported'
    },
  ],
};

/// Descriptor for `Hello`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List helloDescriptor = $convert.base64Decode(
    'CgVIZWxsbxItChJzdXBwb3J0ZWRfdmVyc2lvbnMYASADKA1SEXN1cHBvcnRlZFZlcnNpb25zEi'
    'gKEGNsaWVudF9kZXZpY2VfaWQYAiABKAxSDmNsaWVudERldmljZUlkEi4KE29wYXF1ZV9yZXN1'
    'bWVfdG9rZW4YAyABKAxSEW9wYXF1ZVJlc3VtZVRva2VuEjkKGW1heF9mcmFtZV9ieXRlc19zdX'
    'Bwb3J0ZWQYBCABKA1SFm1heEZyYW1lQnl0ZXNTdXBwb3J0ZWQ=');

@$core.Deprecated('Use authDescriptor instead')
const Auth$json = {
  '1': 'Auth',
  '2': [
    {'1': 'access_token', '3': 1, '4': 1, '5': 12, '10': 'accessToken'},
  ],
};

/// Descriptor for `Auth`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List authDescriptor = $convert
    .base64Decode('CgRBdXRoEiEKDGFjY2Vzc190b2tlbhgBIAEoDFILYWNjZXNzVG9rZW4=');

@$core.Deprecated('Use encryptedEnvelopeDescriptor instead')
const EncryptedEnvelope$json = {
  '1': 'EncryptedEnvelope',
  '2': [
    {'1': 'conversation_id', '3': 1, '4': 1, '5': 12, '10': 'conversationId'},
    {
      '1': 'client_message_id',
      '3': 2,
      '4': 1,
      '5': 12,
      '10': 'clientMessageId'
    },
    {'1': 'sender_device_id', '3': 3, '4': 1, '5': 12, '10': 'senderDeviceId'},
    {'1': 'mls_epoch', '3': 4, '4': 1, '5': 4, '10': 'mlsEpoch'},
    {
      '1': 'envelope_kind',
      '3': 5,
      '4': 1,
      '5': 14,
      '6': '.securemesh.transport.v1.EnvelopeKind',
      '10': 'envelopeKind'
    },
    {
      '1': 'opaque_ciphertext',
      '3': 6,
      '4': 1,
      '5': 12,
      '10': 'opaqueCiphertext'
    },
    {
      '1': 'ciphertext_sha256',
      '3': 7,
      '4': 1,
      '5': 12,
      '10': 'ciphertextSha256'
    },
    {'1': 'server_sequence', '3': 8, '4': 1, '5': 4, '10': 'serverSequence'},
    {
      '1': 'server_message_id',
      '3': 9,
      '4': 1,
      '5': 12,
      '10': 'serverMessageId'
    },
  ],
};

/// Descriptor for `EncryptedEnvelope`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List encryptedEnvelopeDescriptor = $convert.base64Decode(
    'ChFFbmNyeXB0ZWRFbnZlbG9wZRInCg9jb252ZXJzYXRpb25faWQYASABKAxSDmNvbnZlcnNhdG'
    'lvbklkEioKEWNsaWVudF9tZXNzYWdlX2lkGAIgASgMUg9jbGllbnRNZXNzYWdlSWQSKAoQc2Vu'
    'ZGVyX2RldmljZV9pZBgDIAEoDFIOc2VuZGVyRGV2aWNlSWQSGwoJbWxzX2Vwb2NoGAQgASgEUg'
    'htbHNFcG9jaBJKCg1lbnZlbG9wZV9raW5kGAUgASgOMiUuc2VjdXJlbWVzaC50cmFuc3BvcnQu'
    'djEuRW52ZWxvcGVLaW5kUgxlbnZlbG9wZUtpbmQSKwoRb3BhcXVlX2NpcGhlcnRleHQYBiABKA'
    'xSEG9wYXF1ZUNpcGhlcnRleHQSKwoRY2lwaGVydGV4dF9zaGEyNTYYByABKAxSEGNpcGhlcnRl'
    'eHRTaGEyNTYSJwoPc2VydmVyX3NlcXVlbmNlGAggASgEUg5zZXJ2ZXJTZXF1ZW5jZRIqChFzZX'
    'J2ZXJfbWVzc2FnZV9pZBgJIAEoDFIPc2VydmVyTWVzc2FnZUlk');

@$core.Deprecated('Use durableAckDescriptor instead')
const DurableAck$json = {
  '1': 'DurableAck',
  '2': [
    {'1': 'conversation_id', '3': 1, '4': 1, '5': 12, '10': 'conversationId'},
    {
      '1': 'client_message_id',
      '3': 2,
      '4': 1,
      '5': 12,
      '10': 'clientMessageId'
    },
    {
      '1': 'server_message_id',
      '3': 3,
      '4': 1,
      '5': 12,
      '10': 'serverMessageId'
    },
    {'1': 'server_sequence', '3': 4, '4': 1, '5': 4, '10': 'serverSequence'},
    {
      '1': 'already_committed',
      '3': 5,
      '4': 1,
      '5': 8,
      '10': 'alreadyCommitted'
    },
  ],
};

/// Descriptor for `DurableAck`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List durableAckDescriptor = $convert.base64Decode(
    'CgpEdXJhYmxlQWNrEicKD2NvbnZlcnNhdGlvbl9pZBgBIAEoDFIOY29udmVyc2F0aW9uSWQSKg'
    'oRY2xpZW50X21lc3NhZ2VfaWQYAiABKAxSD2NsaWVudE1lc3NhZ2VJZBIqChFzZXJ2ZXJfbWVz'
    'c2FnZV9pZBgDIAEoDFIPc2VydmVyTWVzc2FnZUlkEicKD3NlcnZlcl9zZXF1ZW5jZRgEIAEoBF'
    'IOc2VydmVyU2VxdWVuY2USKwoRYWxyZWFkeV9jb21taXR0ZWQYBSABKAhSEGFscmVhZHlDb21t'
    'aXR0ZWQ=');

@$core.Deprecated('Use syncRequestDescriptor instead')
const SyncRequest$json = {
  '1': 'SyncRequest',
  '2': [
    {'1': 'conversation_id', '3': 1, '4': 1, '5': 12, '10': 'conversationId'},
    {'1': 'opaque_cursor', '3': 2, '4': 1, '5': 12, '10': 'opaqueCursor'},
    {'1': 'limit', '3': 3, '4': 1, '5': 13, '10': 'limit'},
  ],
};

/// Descriptor for `SyncRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List syncRequestDescriptor = $convert.base64Decode(
    'CgtTeW5jUmVxdWVzdBInCg9jb252ZXJzYXRpb25faWQYASABKAxSDmNvbnZlcnNhdGlvbklkEi'
    'MKDW9wYXF1ZV9jdXJzb3IYAiABKAxSDG9wYXF1ZUN1cnNvchIUCgVsaW1pdBgDIAEoDVIFbGlt'
    'aXQ=');

@$core.Deprecated('Use syncResponseDescriptor instead')
const SyncResponse$json = {
  '1': 'SyncResponse',
  '2': [
    {'1': 'conversation_id', '3': 1, '4': 1, '5': 12, '10': 'conversationId'},
    {
      '1': 'messages',
      '3': 2,
      '4': 3,
      '5': 11,
      '6': '.securemesh.transport.v1.EncryptedEnvelope',
      '10': 'messages'
    },
    {'1': 'next_cursor', '3': 3, '4': 1, '5': 12, '10': 'nextCursor'},
    {'1': 'has_more', '3': 4, '4': 1, '5': 8, '10': 'hasMore'},
  ],
};

/// Descriptor for `SyncResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List syncResponseDescriptor = $convert.base64Decode(
    'CgxTeW5jUmVzcG9uc2USJwoPY29udmVyc2F0aW9uX2lkGAEgASgMUg5jb252ZXJzYXRpb25JZB'
    'JGCghtZXNzYWdlcxgCIAMoCzIqLnNlY3VyZW1lc2gudHJhbnNwb3J0LnYxLkVuY3J5cHRlZEVu'
    'dmVsb3BlUghtZXNzYWdlcxIfCgtuZXh0X2N1cnNvchgDIAEoDFIKbmV4dEN1cnNvchIZCghoYX'
    'NfbW9yZRgEIAEoCFIHaGFzTW9yZQ==');

@$core.Deprecated('Use processedAckDescriptor instead')
const ProcessedAck$json = {
  '1': 'ProcessedAck',
  '2': [
    {'1': 'conversation_id', '3': 1, '4': 1, '5': 12, '10': 'conversationId'},
    {
      '1': 'highest_contiguous_persisted_sequence',
      '3': 2,
      '4': 1,
      '5': 4,
      '10': 'highestContiguousPersistedSequence'
    },
  ],
};

/// Descriptor for `ProcessedAck`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List processedAckDescriptor = $convert.base64Decode(
    'CgxQcm9jZXNzZWRBY2sSJwoPY29udmVyc2F0aW9uX2lkGAEgASgMUg5jb252ZXJzYXRpb25JZB'
    'JRCiVoaWdoZXN0X2NvbnRpZ3VvdXNfcGVyc2lzdGVkX3NlcXVlbmNlGAIgASgEUiJoaWdoZXN0'
    'Q29udGlndW91c1BlcnNpc3RlZFNlcXVlbmNl');

@$core.Deprecated('Use errorDescriptor instead')
const Error$json = {
  '1': 'Error',
  '2': [
    {'1': 'code', '3': 1, '4': 1, '5': 13, '10': 'code'},
    {'1': 'stable_code', '3': 2, '4': 1, '5': 9, '10': 'stableCode'},
    {'1': 'retry_after_ms', '3': 3, '4': 1, '5': 13, '10': 'retryAfterMs'},
    {'1': 'safe_details', '3': 4, '4': 1, '5': 9, '10': 'safeDetails'},
  ],
};

/// Descriptor for `Error`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List errorDescriptor = $convert.base64Decode(
    'CgVFcnJvchISCgRjb2RlGAEgASgNUgRjb2RlEh8KC3N0YWJsZV9jb2RlGAIgASgJUgpzdGFibG'
    'VDb2RlEiQKDnJldHJ5X2FmdGVyX21zGAMgASgNUgxyZXRyeUFmdGVyTXMSIQoMc2FmZV9kZXRh'
    'aWxzGAQgASgJUgtzYWZlRGV0YWlscw==');

@$core.Deprecated('Use callSignalDescriptor instead')
const CallSignal$json = {
  '1': 'CallSignal',
  '2': [
    {'1': 'conversation_id', '3': 1, '4': 1, '5': 12, '10': 'conversationId'},
    {'1': 'sender_device_id', '3': 2, '4': 1, '5': 12, '10': 'senderDeviceId'},
    {
      '1': 'recipient_device_id',
      '3': 3,
      '4': 1,
      '5': 12,
      '10': 'recipientDeviceId'
    },
    {'1': 'payload', '3': 4, '4': 1, '5': 12, '10': 'payload'},
  ],
};

/// Descriptor for `CallSignal`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List callSignalDescriptor = $convert.base64Decode(
    'CgpDYWxsU2lnbmFsEicKD2NvbnZlcnNhdGlvbl9pZBgBIAEoDFIOY29udmVyc2F0aW9uSWQSKA'
    'oQc2VuZGVyX2RldmljZV9pZBgCIAEoDFIOc2VuZGVyRGV2aWNlSWQSLgoTcmVjaXBpZW50X2Rl'
    'dmljZV9pZBgDIAEoDFIRcmVjaXBpZW50RGV2aWNlSWQSGAoHcGF5bG9hZBgEIAEoDFIHcGF5bG'
    '9hZA==');
