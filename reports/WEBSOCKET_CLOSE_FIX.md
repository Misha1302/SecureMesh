# Native WSS close regression

The first native severe seed 7 delivered all 400 unique IDs and drained outboxes in 404.695 seconds, but the Dart process remained alive. Its progress reporter had stopped, the result file existed, and ss showed one owned socket in CLOSE_WAIT (PID 432143, FD 20, peer 127.0.0.1:15990). This was not accepted as a completed trial. The owned child was terminated with SIGTERM after diagnosis; the parent/make failed. Raw data and failure are retained as native-netem-severe-close-fail-7-200.json and v2-native-severe-close-fail.txt.

The installed Dart SDK source (.local/flutter/bin/cache/dart-sdk/lib/_http/websocket_impl.dart) shows that cancelling the incoming WebSocket subscription clears its raw subscription. WebSocket.close only attaches its drain when that raw subscription is available. MeshTransport cancelled first, then called close; on packet loss this left the incoming close/EOF path unavailable.

MeshTransport now lets WebSocket.close own the reader and its close timeout. Existing socket-identity guards reject late abandoned application frames. A normal goingAway close is sent; incoming subscription cancellation is no longer performed separately. No message/ciphertext/ACK semantics or TLS verification was changed.

The real TLS fault test now closes active WSS connections while the proxy drops close frames. Python requires the entire Dart child to exit within 45 seconds; it cannot accept printed PASS from a hanging process. v2-native-close-regression.txt exits 0 with all eleven message IDs exactly once, real WSS/HTTPS fault cases, and bounded child termination. Full GPRS/severe are being rerun against the final source/binary set; prior performance figures alone do not clear this changed-source gate.

PRODUCTION_APPROVED=false. This addresses a transport resource leak, not the outstanding dependency advisories or the complete mixed-fault matrix.
