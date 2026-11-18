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

import 'package:protobuf/protobuf.dart' as $pb;

class FrameKind extends $pb.ProtobufEnum {
  static const FrameKind FRAME_KIND_UNSPECIFIED =
      FrameKind._(0, _omitEnumNames ? '' : 'FRAME_KIND_UNSPECIFIED');
  static const FrameKind HELLO = FrameKind._(1, _omitEnumNames ? '' : 'HELLO');
  static const FrameKind AUTH = FrameKind._(2, _omitEnumNames ? '' : 'AUTH');
  static const FrameKind SEND_ENCRYPTED =
      FrameKind._(3, _omitEnumNames ? '' : 'SEND_ENCRYPTED');
  static const FrameKind DURABLE_ACK =
      FrameKind._(4, _omitEnumNames ? '' : 'DURABLE_ACK');
  static const FrameKind SYNC_REQUEST =
      FrameKind._(5, _omitEnumNames ? '' : 'SYNC_REQUEST');
  static const FrameKind SYNC_RESPONSE =
      FrameKind._(6, _omitEnumNames ? '' : 'SYNC_RESPONSE');
  static const FrameKind PROCESSED_ACK =
      FrameKind._(7, _omitEnumNames ? '' : 'PROCESSED_ACK');
  static const FrameKind SERVER_ERROR =
      FrameKind._(8, _omitEnumNames ? '' : 'SERVER_ERROR');
  static const FrameKind PING = FrameKind._(9, _omitEnumNames ? '' : 'PING');
  static const FrameKind PONG = FrameKind._(10, _omitEnumNames ? '' : 'PONG');
  static const FrameKind CALL_SIGNAL =
      FrameKind._(11, _omitEnumNames ? '' : 'CALL_SIGNAL');

  static const $core.List<FrameKind> values = <FrameKind>[
    FRAME_KIND_UNSPECIFIED,
    HELLO,
    AUTH,
    SEND_ENCRYPTED,
    DURABLE_ACK,
    SYNC_REQUEST,
    SYNC_RESPONSE,
    PROCESSED_ACK,
    SERVER_ERROR,
    PING,
    PONG,
    CALL_SIGNAL,
  ];

  static final $core.List<FrameKind?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 11);
  static FrameKind? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const FrameKind._(super.value, super.name);
}

class EnvelopeKind extends $pb.ProtobufEnum {
  static const EnvelopeKind ENVELOPE_KIND_UNSPECIFIED =
      EnvelopeKind._(0, _omitEnumNames ? '' : 'ENVELOPE_KIND_UNSPECIFIED');
  static const EnvelopeKind MLS_APPLICATION =
      EnvelopeKind._(1, _omitEnumNames ? '' : 'MLS_APPLICATION');
  static const EnvelopeKind MLS_PROPOSAL =
      EnvelopeKind._(2, _omitEnumNames ? '' : 'MLS_PROPOSAL');
  static const EnvelopeKind MLS_COMMIT =
      EnvelopeKind._(3, _omitEnumNames ? '' : 'MLS_COMMIT');
  static const EnvelopeKind MLS_WELCOME =
      EnvelopeKind._(4, _omitEnumNames ? '' : 'MLS_WELCOME');

  static const $core.List<EnvelopeKind> values = <EnvelopeKind>[
    ENVELOPE_KIND_UNSPECIFIED,
    MLS_APPLICATION,
    MLS_PROPOSAL,
    MLS_COMMIT,
    MLS_WELCOME,
  ];

  static final $core.List<EnvelopeKind?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 4);
  static EnvelopeKind? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const EnvelopeKind._(super.value, super.name);
}

const $core.bool _omitEnumNames =
    $core.bool.fromEnvironment('protobuf.omit_enum_names');
