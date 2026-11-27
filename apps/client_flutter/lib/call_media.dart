import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:material_ui/material_ui.dart';

typedef CallSignal = Map<String, dynamic>;

abstract interface class CallMedia {
  Future<void> open(
    bool video,
    void Function(CallSignal) ice,
    void Function(bool) connected,
    VoidCallback failed,
  );
  Future<String> offer();
  Future<String> answer(String remote);
  Future<void> remoteAnswer(String remote);
  Future<void> candidate(CallSignal signal);
  void enableMicrophone(bool enabled);
  void enableCamera(bool enabled);
  Widget videoView();
  Future<void> close();
}

class DirectMedia implements CallMedia {
  rtc.RTCPeerConnection? _peer;
  rtc.MediaStream? _capture;
  rtc.RTCVideoRenderer? _remote;
  bool _closed = false;
  Timer? _disconnected;

  void _active() {
    if (_closed) throw StateError('closed');
  }

  static Future<void> _release(rtc.MediaStream stream) async {
    for (final track in stream.getTracks()) {
      try {
        await track.stop();
      } catch (_) {}
    }
    await stream.dispose();
  }

  @override
  Future<void> open(
    bool video,
    void Function(CallSignal) ice,
    void Function(bool) connected,
    VoidCallback failed,
  ) async {
    _active();
    if (video) {
      final view = rtc.RTCVideoRenderer();
      await view.initialize();
      if (_closed) {
        await view.dispose();
        _active();
      }
      _remote = view;
    }
    // No public discovery or relay service. Native ICE gathering begins only
    // after the MLS peer has accepted the specific audio/video invitation.
    final pc = await rtc.createPeerConnection({
      'iceServers': <Map<String, dynamic>>[],
      'iceCandidatePoolSize': 0,
      'sdpSemantics': 'unified-plan',
      'bundlePolicy': 'max-bundle',
    });
    if (_closed) {
      await pc.close();
      await pc.dispose();
      _active();
    }
    _peer = pc;
    pc.onIceCandidate = (candidate) {
      if (_closed ||
          candidate.candidate == null ||
          candidate.candidate!.isEmpty ||
          candidate.sdpMid == null ||
          candidate.sdpMLineIndex == null) {
        return;
      }
      ice({
        'kind': 'ice',
        'candidate': candidate.candidate,
        'mid': candidate.sdpMid,
        'line': candidate.sdpMLineIndex,
      });
    };
    pc.onTrack = (track) {
      if (!_closed && track.track.kind == 'video' && track.streams.isNotEmpty) {
        _remote?.srcObject = track.streams.first;
      }
    };
    pc.onConnectionState = (state) {
      if (_closed) return;
      _disconnected?.cancel();
      switch (state) {
        case rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          connected(true);
        case rtc.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          connected(false);
          _disconnected = Timer(const Duration(seconds: 8), failed);
        case rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        case rtc.RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          failed();
        default:
          break;
      }
    };
    final stream = await rtc.navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': video
          ? {
              'facingMode': 'user',
              'width': {'ideal': 320},
              'height': {'ideal': 240},
              'frameRate': {'ideal': 15},
            }
          : false,
    });
    if (_closed) {
      await _release(stream);
      _active();
    }
    _capture = stream;
    if (stream.getAudioTracks().isEmpty ||
        (video && stream.getVideoTracks().isEmpty)) {
      throw StateError('capture unavailable');
    }
    for (final t in stream.getTracks()) {
      _active();
      await pc.addTrack(t, stream);
    }
  }

  @override
  Future<String> offer() async {
    final pc = _peer!;
    final local = await pc.createOffer();
    _active();
    await pc.setLocalDescription(local);
    return local.sdp!;
  }

  @override
  Future<String> answer(String remote) async {
    final pc = _peer!;
    await pc.setRemoteDescription(rtc.RTCSessionDescription(remote, 'offer'));
    _active();
    final local = await pc.createAnswer();
    _active();
    await pc.setLocalDescription(local);
    return local.sdp!;
  }

  @override
  Future<void> remoteAnswer(String remote) =>
      _peer!.setRemoteDescription(rtc.RTCSessionDescription(remote, 'answer'));
  @override
  Future<void> candidate(CallSignal s) => _peer!.addCandidate(
    rtc.RTCIceCandidate(s['candidate'], s['mid'], s['line']),
  );
  @override
  void enableMicrophone(bool enabled) {
    for (final track
        in _capture?.getAudioTracks() ?? <rtc.MediaStreamTrack>[]) {
      track.enabled = enabled;
    }
  }

  @override
  void enableCamera(bool enabled) {
    for (final track
        in _capture?.getVideoTracks() ?? <rtc.MediaStreamTrack>[]) {
      track.enabled = enabled;
    }
  }

  @override
  Widget videoView() => _remote == null
      ? const SizedBox.shrink()
      : rtc.RTCVideoView(
          _remote!,
          objectFit: rtc.RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
        );

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _disconnected?.cancel();
    final pc = _peer, stream = _capture, renderer = _remote;
    _peer = null;
    _capture = null;
    _remote = null;
    if (pc != null) {
      pc.onIceCandidate = null;
      pc.onConnectionState = null;
      pc.onTrack = null;
    }
    // Stop capture first, even when closing the transport or texture fails.
    if (stream != null) {
      try {
        await _release(stream);
      } catch (_) {}
    }
    if (pc != null) {
      try {
        await pc.close();
      } catch (_) {}
      try {
        await pc.dispose();
      } catch (_) {}
    }
    if (renderer != null) {
      try {
        renderer.srcObject = null;
      } finally {
        await renderer.dispose();
      }
    }
  }
}
