# Internal HTTP/2 transport fork

Source: Dart http2 2.3.1, BSD license retained in LICENSE. Original per-file
hashes are recorded in UPSTREAM.json. This internal copy allows a publishable
SDK without a path dependency or a modified user package cache.

Patch: src/streams/stream_handler.dart ignores HEADERS for closed local streams
on a client after Connection has decoded HPACK. Headers for idle streams remain
a protocol error. The upstream http2 dev dependency remains an independent
server for TLS interoperability tests. This is not a claim of full HTTP/2 audit.

Only constant_identifier_names is ignored in files retaining upstream constants;
all other SDK analyzer diagnostics remain enabled. The regression is
 test/h2_early_cancel_test.dart, using the unmodified pub http2 server.
Original code copyright and BSD redistribution conditions remain in LICENSE
and each source header. No user package cache is modified.

Second protocol patch: src/flowcontrol/connection_queues.dart debits connection
credit for ignored DATA before returning it, keeping the local mirror stable.
Regression: test/h2_ignored_data_test.dart and raw TLS DATA case in
 test/h2_late_headers_test.dart. Padded DATA accounting is supplemented by the patch below.

Padding patch: connection_queues.dart uses full DATA payload length, with
DataMessage.flowControlLength carrying that count to stream_queues.dart.
Padding credit is returned immediately; application bytes on consumption.
Raw TLS and queue tests cover both active and reset streams. Other frame/flow
control combinations are still under audit.

Empty ignored DATA consumes no credit and emits no WINDOW_UPDATE, avoiding
an invalid zero delta. Covered by the queue and raw TLS empty-frame tests.
