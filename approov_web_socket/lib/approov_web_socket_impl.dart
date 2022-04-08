// @dart=2.9

part of approov_web_socket;

const String _webSocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const String _clientNoContextTakeover = "client_no_context_takeover";
const String _serverNoContextTakeover = "server_no_context_takeover";
const String _clientMaxWindowBits = "client_max_window_bits";
const String _serverMaxWindowBits = "server_max_window_bits";

// Matches _WebSocketOpcode.
class _WebSocketMessageType {
  static const int NONE = 0;
  static const int TEXT = 1;
  static const int BINARY = 2;
}

class _WebSocketOpcode {
  static const int CONTINUATION = 0;
  static const int TEXT = 1;
  static const int BINARY = 2;
  static const int RESERVED_3 = 3;
  static const int RESERVED_4 = 4;
  static const int RESERVED_5 = 5;
  static const int RESERVED_6 = 6;
  static const int RESERVED_7 = 7;
  static const int CLOSE = 8;
  static const int PING = 9;
  static const int PONG = 10;
  static const int RESERVED_B = 11;
  static const int RESERVED_C = 12;
  static const int RESERVED_D = 13;
  static const int RESERVED_E = 14;
  static const int RESERVED_F = 15;
}

class _EncodedString {
  final List<int> bytes;
  _EncodedString(this.bytes);
}

/**
 *  Stores the header and integer value derived from negotiation of
 *  client_max_window_bits and server_max_window_bits. headerValue will be
 *  set in the Websocket response headers.
 */
class _CompressionMaxWindowBits {
  String headerValue;
  int maxWindowBits;
  _CompressionMaxWindowBits(this.headerValue, this.maxWindowBits);
  String toString() => headerValue;
}

/**
 * The web socket protocol transformer handles the protocol byte stream
 * which is supplied through the `handleData`. As the protocol is processed,
 * it'll output frame data as either a List<int> or String.
 *
 * Important information about usage: Be sure you use cancelOnError, so the
 * socket will be closed when the processor encounter an error. Not using it
 * will lead to undefined behaviour.
 */
class _WebSocketProtocolTransformer extends StreamTransformerBase<List<int>,
        dynamic /*List<int>|_WebSocketPing|_WebSocketPong*/ >
    implements EventSink<List<int>> {
  static const int START = 0;
  static const int LEN_FIRST = 1;
  static const int LEN_REST = 2;
  static const int MASK = 3;
  static const int PAYLOAD = 4;
  static const int CLOSED = 5;
  static const int FAILURE = 6;
  static const int FIN = 0x80;
  static const int RSV1 = 0x40;
  static const int RSV2 = 0x20;
  static const int RSV3 = 0x10;
  static const int OPCODE = 0xF;

  int _state = START;
  bool _fin = false;
  bool _compressed = false;
  int _opcode = -1;
  int _len = -1;
  bool _masked = false;
  int _remainingLenBytes = -1;
  int _remainingMaskingKeyBytes = 4;
  int _remainingPayloadBytes = -1;
  int _unmaskingIndex = 0;
  int _currentMessageType = _WebSocketMessageType.NONE;
  int closeCode = io.WebSocketStatus.NO_STATUS_RECEIVED;
  String closeReason = "";

  EventSink<
      dynamic /*List<int>|_WebSocketPing|_WebSocketPong*/ > /*?*/ _eventSink;

  final bool _serverSide;
  final Uint8List _maskingBytes = Uint8List(4);
  final BytesBuilder _payload = new BytesBuilder(copy: false);

  _WebSocketPerMessageDeflate /*?*/ _deflate;
  _WebSocketProtocolTransformer([this._serverSide = false, this._deflate]);

  Stream<dynamic /*List<int>|_WebSocketPing|_WebSocketPong*/ > bind(
      Stream<List<int>> stream) {
    return new Stream.eventTransformed(stream, (EventSink eventSink) {
      if (_eventSink != null) {
        throw new StateError("WebSocket transformer already used.");
      }
      _eventSink = eventSink;
      return this;
    });
  }

  void addError(Object error, [StackTrace /*?*/ stackTrace]) {
    // TODO(40614): Remove once non-nullability is sound.
    ArgumentError.checkNotNull(error, "error");
    _eventSink /*!*/ .addError(error, stackTrace);
  }

  void close() {
    _eventSink /*!*/ .close();
  }

  /**
   * Process data received from the underlying communication channel.
   */
  void add(List<int> bytes) {
    var buffer = bytes is Uint8List ? bytes : new Uint8List.fromList(bytes);
    int index = 0;
    int lastIndex = buffer.length;
    if (_state == CLOSED) {
      throw new WebSocketException("Data on closed connection");
    }
    if (_state == FAILURE) {
      throw new WebSocketException("Data on failed connection");
    }
    while ((index < lastIndex) && _state != CLOSED && _state != FAILURE) {
      int byte = buffer[index];
      if (_state <= LEN_REST) {
        if (_state == START) {
          _fin = (byte & FIN) != 0;

          if ((byte & (RSV2 | RSV3)) != 0) {
            // The RSV2, RSV3 bits must both be zero.
            throw new WebSocketException("Protocol error");
          }

          _opcode = (byte & OPCODE);

          if (_opcode != _WebSocketOpcode.CONTINUATION) {
            if ((byte & RSV1) != 0) {
              _compressed = true;
            } else {
              _compressed = false;
            }
          }

          if (_opcode <= _WebSocketOpcode.BINARY) {
            if (_opcode == _WebSocketOpcode.CONTINUATION) {
              if (_currentMessageType == _WebSocketMessageType.NONE) {
                throw new WebSocketException("Protocol error");
              }
            } else {
              assert(_opcode == _WebSocketOpcode.TEXT ||
                  _opcode == _WebSocketOpcode.BINARY);
              if (_currentMessageType != _WebSocketMessageType.NONE) {
                throw new WebSocketException("Protocol error");
              }
              _currentMessageType = _opcode;
            }
          } else if (_opcode >= _WebSocketOpcode.CLOSE &&
              _opcode <= _WebSocketOpcode.PONG) {
            // Control frames cannot be fragmented.
            if (!_fin) throw new WebSocketException("Protocol error");
          } else {
            throw new WebSocketException("Protocol error");
          }
          _state = LEN_FIRST;
        } else if (_state == LEN_FIRST) {
          _masked = (byte & 0x80) != 0;
          _len = byte & 0x7F;
          if (_isControlFrame() && _len > 125) {
            throw new WebSocketException("Protocol error");
          }
          if (_len == 126) {
            _len = 0;
            _remainingLenBytes = 2;
            _state = LEN_REST;
          } else if (_len == 127) {
            _len = 0;
            _remainingLenBytes = 8;
            _state = LEN_REST;
          } else {
            assert(_len < 126);
            _lengthDone();
          }
        } else {
          assert(_state == LEN_REST);
          _len = _len << 8 | byte;
          _remainingLenBytes--;
          if (_remainingLenBytes == 0) {
            _lengthDone();
          }
        }
      } else {
        if (_state == MASK) {
          _maskingBytes[4 - _remainingMaskingKeyBytes--] = byte;
          if (_remainingMaskingKeyBytes == 0) {
            _maskDone();
          }
        } else {
          assert(_state == PAYLOAD);
          // The payload is not handled one byte at a time but in blocks.
          int payloadLength = min(lastIndex - index, _remainingPayloadBytes);
          _remainingPayloadBytes -= payloadLength;
          // Unmask payload if masked.
          if (_masked) {
            _unmask(index, payloadLength, buffer);
          }
          // Control frame and data frame share _payloads.
          _payload.add(new Uint8List.view(
              buffer.buffer, buffer.offsetInBytes + index, payloadLength));
          index += payloadLength;
          if (_isControlFrame()) {
            if (_remainingPayloadBytes == 0) _controlFrameEnd();
          } else {
            if (_currentMessageType != _WebSocketMessageType.TEXT &&
                _currentMessageType != _WebSocketMessageType.BINARY) {
              throw new WebSocketException("Protocol error");
            }
            if (_remainingPayloadBytes == 0) _messageFrameEnd();
          }

          // Hack - as we always do index++ below.
          index--;
        }
      }

      // Move to the next byte.
      index++;
    }
  }

  void _unmask(int index, int length, Uint8List buffer) {
    const int BLOCK_SIZE = 16;
    // Skip Int32x4-version if message is small.
    if (length >= BLOCK_SIZE) {
      // Start by aligning to 16 bytes.
      final int startOffset = BLOCK_SIZE - (index & 15);
      final int end = index + startOffset;
      for (int i = index; i < end; i++) {
        buffer[i] ^= _maskingBytes[_unmaskingIndex++ & 3];
      }
      index += startOffset;
      length -= startOffset;
      final int blockCount = length ~/ BLOCK_SIZE;
      if (blockCount > 0) {
        // Create mask block.
        int mask = 0;
        for (int i = 3; i >= 0; i--) {
          mask = (mask << 8) | _maskingBytes[(_unmaskingIndex + i) & 3];
        }
        Int32x4 blockMask = new Int32x4(mask, mask, mask, mask);
        Int32x4List blockBuffer = new Int32x4List.view(
            buffer.buffer, buffer.offsetInBytes + index, blockCount);
        for (int i = 0; i < blockBuffer.length; i++) {
          blockBuffer[i] ^= blockMask;
        }
        final int bytes = blockCount * BLOCK_SIZE;
        index += bytes;
        length -= bytes;
      }
    }
    // Handle end.
    final int end = index + length;
    for (int i = index; i < end; i++) {
      buffer[i] ^= _maskingBytes[_unmaskingIndex++ & 3];
    }
  }

  void _lengthDone() {
    if (_masked) {
      if (!_serverSide) {
        throw new WebSocketException("Received masked frame from server");
      }
      _state = MASK;
    } else {
      if (_serverSide) {
        throw new WebSocketException("Received unmasked frame from client");
      }
      _remainingPayloadBytes = _len;
      _startPayload();
    }
  }

  void _maskDone() {
    _remainingPayloadBytes = _len;
    _startPayload();
  }

  void _startPayload() {
    // If there is no actual payload perform perform callbacks without
    // going through the PAYLOAD state.
    if (_remainingPayloadBytes == 0) {
      if (_isControlFrame()) {
        switch (_opcode) {
          case _WebSocketOpcode.CLOSE:
            _state = CLOSED;
            _eventSink /*!*/ .close();
            break;
          case _WebSocketOpcode.PING:
            _eventSink /*!*/ .add(new _WebSocketPing());
            break;
          case _WebSocketOpcode.PONG:
            _eventSink /*!*/ .add(new _WebSocketPong());
            break;
        }
        _prepareForNextFrame();
      } else {
        _messageFrameEnd();
      }
    } else {
      _state = PAYLOAD;
    }
  }

  void _messageFrameEnd() {
    if (_fin) {
      var bytes = _payload.takeBytes();
      var deflate = _deflate;
      if (deflate != null && _compressed) {
        bytes = deflate.processIncomingMessage(bytes);
      }

      switch (_currentMessageType) {
        case _WebSocketMessageType.TEXT:
          _eventSink /*!*/ .add(utf8.decode(bytes));
          break;
        case _WebSocketMessageType.BINARY:
          _eventSink /*!*/ .add(bytes);
          break;
      }
      _currentMessageType = _WebSocketMessageType.NONE;
    }
    _prepareForNextFrame();
  }

  void _controlFrameEnd() {
    switch (_opcode) {
      case _WebSocketOpcode.CLOSE:
        closeCode = WebSocketStatus.noStatusReceived;
        var payload = _payload.takeBytes();
        if (payload.length > 0) {
          if (payload.length == 1) {
            throw new WebSocketException("Protocol error");
          }
          closeCode = payload[0] << 8 | payload[1];
          if (closeCode == WebSocketStatus.noStatusReceived) {
            throw new WebSocketException("Protocol error");
          }
          if (payload.length > 2) {
            closeReason = utf8.decode(payload.sublist(2));
          }
        }
        _state = CLOSED;
        _eventSink /*!*/ .close();
        break;

      case _WebSocketOpcode.PING:
        _eventSink /*!*/ .add(new _WebSocketPing(_payload.takeBytes()));
        break;

      case _WebSocketOpcode.PONG:
        _eventSink /*!*/ .add(new _WebSocketPong(_payload.takeBytes()));
        break;
    }
    _prepareForNextFrame();
  }

  bool _isControlFrame() {
    return _opcode == _WebSocketOpcode.CLOSE ||
        _opcode == _WebSocketOpcode.PING ||
        _opcode == _WebSocketOpcode.PONG;
  }

  void _prepareForNextFrame() {
    if (_state != CLOSED && _state != FAILURE) _state = START;
    _fin = false;
    _opcode = -1;
    _len = -1;
    _remainingLenBytes = -1;
    _remainingMaskingKeyBytes = 4;
    _remainingPayloadBytes = -1;
    _unmaskingIndex = 0;
  }
}

class _WebSocketPing {
  final List<int> /*?*/ payload;
  _WebSocketPing([this.payload = null]);
}

class _WebSocketPong {
  final List<int> /*?*/ payload;
  _WebSocketPong([this.payload = null]);
}

class _WebSocketPerMessageDeflate {
  bool serverNoContextTakeover;
  bool clientNoContextTakeover;
  int clientMaxWindowBits;
  int serverMaxWindowBits;
  bool serverSide;

  RawZLibFilter /*?*/ decoder;
  RawZLibFilter /*?*/ encoder;

  _WebSocketPerMessageDeflate(
      {this.clientMaxWindowBits = _ApproovWebSocketImpl.DEFAULT_WINDOW_BITS,
      this.serverMaxWindowBits = _ApproovWebSocketImpl.DEFAULT_WINDOW_BITS,
      this.serverNoContextTakeover = false,
      this.clientNoContextTakeover = false,
      this.serverSide = false});

  RawZLibFilter _ensureDecoder() => decoder ??= new RawZLibFilter.inflateFilter(
      windowBits: serverSide ? clientMaxWindowBits : serverMaxWindowBits,
      raw: true);

  RawZLibFilter _ensureEncoder() => encoder ??= new RawZLibFilter.deflateFilter(
      windowBits: serverSide ? serverMaxWindowBits : clientMaxWindowBits,
      raw: true);

  Uint8List processIncomingMessage(List<int> msg) {
    var decoder = _ensureDecoder();

    var data = <int>[];
    data.addAll(msg);
    data.addAll(const [0x00, 0x00, 0xff, 0xff]);

    decoder.process(data, 0, data.length);
    final result = new BytesBuilder();
    List<int> out;

    while (true) {
      final out = decoder.processed();
      if (out == null) break;
      result.add(out);
    }

    if ((serverSide && clientNoContextTakeover) ||
        (!serverSide && serverNoContextTakeover)) {
      this.decoder = null;
    }

    return result.takeBytes();
  }

  List<int> processOutgoingMessage(List<int> msg) {
    var encoder = _ensureEncoder();
    var result = <int>[];
    Uint8List buffer;

    if (msg is! Uint8List) {
      for (var i = 0; i < msg.length; i++) {
        if (msg[i] < 0 || 255 < msg[i]) {
          throw new ArgumentError("List element is not a byte value "
              "(value ${msg[i]} at index $i)");
        }
      }
      buffer = new Uint8List.fromList(msg);
    } else {
      buffer = msg;
    }

    encoder.process(buffer, 0, buffer.length);

    while (true) {
      final out = encoder.processed();
      if (out == null) break;
      result.addAll(out);
    }

    if ((!serverSide && clientNoContextTakeover) ||
        (serverSide && serverNoContextTakeover)) {
      this.encoder = null;
    }

    if (result.length > 4) {
      result = result.sublist(0, result.length - 4);
    }

    // RFC 7692 7.2.3.6. "Generating an Empty Fragment" says that if the
    // compression library doesn't generate any data when the bufer is empty,
    // then an empty uncompressed deflate block is used for this purpose. The
    // 0x00 block has the BFINAL header bit set to 0 and the BTYPE header set to
    // 00 along with 5 bits of padding. This block decodes to zero bytes.
    if (result.length == 0) {
      return [0x00];
    }

    return result;
  }
}

// TODO(ajohnsen): Make this transformer reusable.
class _WebSocketOutgoingTransformer
    extends StreamTransformerBase<dynamic, List<int>> implements EventSink {
  final _ApproovWebSocketImpl webSocket;
  EventSink<List<int>> /*?*/ _eventSink;

  _WebSocketPerMessageDeflate /*?*/ _deflateHelper;

  _WebSocketOutgoingTransformer(this.webSocket)
      : _deflateHelper = webSocket._deflate;

  Stream<List<int>> bind(Stream stream) {
    return new Stream<List<int>>.eventTransformed(stream,
        (EventSink<List<int>> eventSink) {
      if (_eventSink != null) {
        throw new StateError("WebSocket transformer already used");
      }
      _eventSink = eventSink;
      return this;
    });
  }

  void add(message) {
    if (message is _WebSocketPong) {
      addFrame(_WebSocketOpcode.PONG, message.payload);
      return;
    }
    if (message is _WebSocketPing) {
      addFrame(_WebSocketOpcode.PING, message.payload);
      return;
    }
    List<int> /*?*/ data;
    int opcode;
    if (message != null) {
      List<int> messageData;
      if (message is String) {
        opcode = _WebSocketOpcode.TEXT;
        messageData = utf8.encode(message);
      } else if (message is List<int>) {
        opcode = _WebSocketOpcode.BINARY;
        messageData = message;
      } else if (message is _EncodedString) {
        opcode = _WebSocketOpcode.TEXT;
        messageData = message.bytes;
      } else {
        throw new ArgumentError(message);
      }
      var deflateHelper = _deflateHelper;
      if (deflateHelper != null) {
        messageData = deflateHelper.processOutgoingMessage(messageData);
      }
      data = messageData;
    } else {
      opcode = _WebSocketOpcode.TEXT;
    }
    addFrame(opcode, data);
  }

  void addError(Object error, [StackTrace /*?*/ stackTrace]) {
    // TODO(40614): Remove once non-nullability is sound.
    ArgumentError.checkNotNull(error, "error");
    _eventSink /*!*/ .addError(error, stackTrace);
  }

  void close() {
    int /*?*/ code = webSocket._outCloseCode;
    String /*?*/ reason = webSocket._outCloseReason;
    List<int> /*?*/ data;
    if (code != null) {
      data = [
        (code >> 8) & 0xFF,
        code & 0xFF,
        if (reason != null) ...utf8.encode(reason)
      ];
    }
    addFrame(_WebSocketOpcode.CLOSE, data);
    _eventSink /*!*/ .close();
  }

  void addFrame(int opcode, List<int> /*?*/ data) {
    createFrame(
            opcode,
            data,
            webSocket._serverSide,
            _deflateHelper != null &&
                (opcode == _WebSocketOpcode.TEXT ||
                    opcode == _WebSocketOpcode.BINARY))
        .forEach((e) {
      _eventSink /*!*/ .add(e);
    });
  }

  static Iterable<List<int>> createFrame(
      int opcode, List<int> /*?*/ data, bool serverSide, bool compressed) {
    bool mask = !serverSide; // Masking not implemented for server.
    int dataLength = data == null ? 0 : data.length;
    // Determine the header size.
    int headerSize = (mask) ? 6 : 2;
    if (dataLength > 65535) {
      headerSize += 8;
    } else if (dataLength > 125) {
      headerSize += 2;
    }
    Uint8List header = new Uint8List(headerSize);
    int index = 0;

    // Set FIN and opcode.
    var hoc = _WebSocketProtocolTransformer.FIN |
        (compressed ? _WebSocketProtocolTransformer.RSV1 : 0) |
        (opcode & _WebSocketProtocolTransformer.OPCODE);

    header[index++] = hoc;
    // Determine size and position of length field.
    int lengthBytes = 1;
    if (dataLength > 65535) {
      header[index++] = 127;
      lengthBytes = 8;
    } else if (dataLength > 125) {
      header[index++] = 126;
      lengthBytes = 2;
    }
    // Write the length in network byte order into the header.
    for (int i = 0; i < lengthBytes; i++) {
      header[index++] = dataLength >> (((lengthBytes - 1) - i) * 8) & 0xFF;
    }
    if (mask) {
      header[1] |= 1 << 7;
      var maskBytes = _CryptoUtils.getRandomBytes(4);
      header.setRange(index, index + 4, maskBytes);
      index += 4;
      if (data != null) {
        Uint8List list;
        // If this is a text message just do the masking inside the
        // encoded data.
        if (opcode == _WebSocketOpcode.TEXT && data is Uint8List) {
          list = data;
        } else {
          if (data is Uint8List) {
            list = new Uint8List.fromList(data);
          } else {
            list = new Uint8List(data.length);
            for (int i = 0; i < data.length; i++) {
              if (data[i] < 0 || 255 < data[i]) {
                throw new ArgumentError("List element is not a byte value "
                    "(value ${data[i]} at index $i)");
              }
              list[i] = data[i];
            }
          }
        }
        const int BLOCK_SIZE = 16;
        int blockCount = list.length ~/ BLOCK_SIZE;
        if (blockCount > 0) {
          // Create mask block.
          int mask = 0;
          for (int i = 3; i >= 0; i--) {
            mask = (mask << 8) | maskBytes[i];
          }
          Int32x4 blockMask = new Int32x4(mask, mask, mask, mask);
          Int32x4List blockBuffer =
              new Int32x4List.view(list.buffer, list.offsetInBytes, blockCount);
          for (int i = 0; i < blockBuffer.length; i++) {
            blockBuffer[i] ^= blockMask;
          }
        }
        // Handle end.
        for (int i = blockCount * BLOCK_SIZE; i < list.length; i++) {
          list[i] ^= maskBytes[i & 3];
        }
        data = list;
      }
    }
    assert(index == headerSize);
    if (data == null) {
      return [header];
    } else {
      return [header, data];
    }
  }
}

class _WebSocketConsumer implements StreamConsumer {
  final _ApproovWebSocketImpl webSocket;
  final Socket socket;
  StreamController /*?*/ _controller;
  StreamSubscription /*?*/ _subscription;
  bool _issuedPause = false;
  bool _closed = false;
  Completer _closeCompleter = new Completer<WebSocket>();
  Completer /*?*/ _completer;

  _WebSocketConsumer(this.webSocket, this.socket);

  void _onListen() {
    _subscription?.cancel();
  }

  void _onPause() {
    var subscription = _subscription;
    if (subscription != null) {
      subscription.pause();
    } else {
      _issuedPause = true;
    }
  }

  void _onResume() {
    var subscription = _subscription;
    if (subscription != null) {
      subscription.resume();
    } else {
      _issuedPause = false;
    }
  }

  void _cancel() {
    var subscription = _subscription;
    if (subscription != null) {
      _subscription = null;
      subscription.cancel();
    }
  }

  StreamController _ensureController() {
    var controller = _controller;
    if (controller != null) return controller;
    controller = _controller = new StreamController(
        sync: true,
        onPause: _onPause,
        onResume: _onResume,
        onCancel: _onListen);
    var stream = controller.stream
        .transform(new _WebSocketOutgoingTransformer(webSocket));
    socket.addStream(stream).then((_) {
      _done();
      _closeCompleter.complete(webSocket);
    }, onError: (Object error, StackTrace stackTrace) {
      _closed = true;
      _cancel();
      if (error is ArgumentError) {
        if (!_done(error, stackTrace)) {
          _closeCompleter.completeError(error, stackTrace);
        }
      } else {
        _done();
        _closeCompleter.complete(webSocket);
      }
    });
    return controller;
  }

  bool _done([Object /*?*/ error, StackTrace /*?*/ stackTrace]) {
    var completer = _completer;
    if (completer == null) return false;
    if (error != null) {
      completer.completeError(error, stackTrace);
    } else {
      completer.complete(webSocket);
    }
    _completer = null;
    return true;
  }

  Future addStream(Stream stream) {
    if (_closed) {
      stream.listen(null).cancel();
      return new Future.value(webSocket);
    }
    _ensureController();
    var completer = _completer = new Completer();
    var subscription = _subscription = stream.listen((data) {
      _controller /*!*/ .add(data);
    }, onDone: _done, onError: _done, cancelOnError: true);
    if (_issuedPause) {
      subscription.pause();
      _issuedPause = false;
    }
    return completer.future;
  }

  Future close() {
    _ensureController().close();

    return _closeCompleter.future
        .then((_) => socket.close().catchError((_) {}).then((_) => webSocket));
  }

  void add(data) {
    if (_closed) return;
    var controller = _ensureController();
    // Stop sending message if _controller has been closed.
    // https://github.com/dart-lang/sdk/issues/37441
    if (controller.isClosed) return;
    controller.add(data);
  }

  void closeSocket() {
    _closed = true;
    _cancel();
    close();
  }
}

// See websocket_impl.dart _WebSocketImpl
class _ApproovWebSocketImpl extends Stream
    with _ServiceObject
    implements io.WebSocket {
  // Use default Map so we keep order.
  static Map<int, io.WebSocket> _webSockets = new Map<int, io.WebSocket>();
  static const int DEFAULT_WINDOW_BITS = 15;
  static const String PER_MESSAGE_DEFLATE = "permessage-deflate";

  /**final**/ String /*?*/ protocol;

  /**final**/ StreamController _controller;
  StreamSubscription /*?*/ _subscription;
  /*late*/ StreamSink _sink;

  /**final**/ Socket _socket;
  /**final**/ bool _serverSide;
  int _readyState = io.WebSocket.connecting;
  bool _writeClosed = false;
  int /*?*/ _closeCode;
  String /*?*/ _closeReason;
  Duration /*?*/ _pingInterval;
  Timer /*?*/ _pingTimer;
  /*late*/ _WebSocketConsumer _consumer;

  int /*?*/ _outCloseCode;
  String /*?*/ _outCloseReason;
  Timer /*?*/ _closeTimer;
  _WebSocketPerMessageDeflate /*?*/ _deflate;

  static final io.HttpClient _httpClient = HttpClient();

  _ApproovWebSocketImpl();

  static Future<io.WebSocket> connect(
      String url,
      Iterable<String> /*?*/ protocols,
      Map<String, dynamic> /*?*/ headers,
      String configString,
      {CompressionOptions compression =
          ApproovCompressionOptions.compressionDefault,
      String approovHeader}) {
    Uri uri = Uri.parse(url);
    if (uri.scheme != "ws" && uri.scheme != "wss") {
      throw new WebSocketException("Unsupported URL scheme '${uri.scheme}'");
    }

    Random random = new Random();
    // Generate 16 random bytes.
    Uint8List nonceData = new Uint8List(16);
    for (int i = 0; i < 16; i++) {
      nonceData[i] = random.nextInt(256);
    }
    String nonce = _CryptoUtils.bytesToBase64(nonceData);

    ApproovService.initialize(configString);
    ApproovService.setApproovHeader(approovHeader, '');
    ApproovHttpClient httpClient = ApproovHttpClient();

    uri = uri.replace(scheme: uri.scheme == "wss" ? "https" : "http");
    return httpClient.openUrl("GET", uri).then((request) {
      if (uri.userInfo != null && !uri.userInfo.isEmpty) {
        // If the URL contains user information use that for basic
        // authorization.
        String auth = _CryptoUtils.bytesToBase64(utf8.encode(uri.userInfo));
        request.headers.set(HttpHeaders.authorizationHeader, "Basic $auth");
      }
      if (headers != null) {
        headers.forEach((field, value) => request.headers.add(field, value));
      }
      // Setup the initial handshake.
      request.headers
        ..set(HttpHeaders.connectionHeader, "Upgrade")
        ..set(HttpHeaders.upgradeHeader, "websocket")
        ..set("Sec-WebSocket-Key", nonce)
        ..set("Cache-Control", "no-cache")
        ..set("Sec-WebSocket-Version", "13");
      if (protocols != null) {
        request.headers.add("Sec-WebSocket-Protocol", protocols.toList());
      }
      if (compression.enabled) {
        if (!(compression is ApproovCompressionOptions)) {
          throw new WebSocketException(
              "ApproovWebSocket must use ApproovCompressionOptions");
        }
        request.headers.add("Sec-WebSocket-Extensions",
            (compression as ApproovCompressionOptions)._createHeader());
      }
      return request.close();
    }).then((response) {
      Never error(String message) {
        // Flush data.
        response.detachSocket().then((socket) {
          socket.destroy();
        });
        throw new WebSocketException(message);
      }

      var connectionHeader = response.headers[HttpHeaders.connectionHeader];
      if (response.statusCode != HttpStatus.switchingProtocols ||
          connectionHeader == null ||
          !connectionHeader.any((value) => value.toLowerCase() == "upgrade") ||
          response.headers
                  .value(HttpHeaders.upgradeHeader) /*!*/ .toLowerCase() !=
              "websocket") {
        error("Connection to '$uri' was not upgraded to websocket");
      }
      String /*?*/ accept = response.headers.value("Sec-WebSocket-Accept");
      if (accept == null) {
        error("Response did not contain a 'Sec-WebSocket-Accept' header");
      }
      _SHA1 sha1 = new _SHA1();
      sha1.add("$nonce$_webSocketGUID".codeUnits);
      List<int> expectedAccept = sha1.close();
      List<int> receivedAccept = _CryptoUtils.base64StringToBytes(accept);
      if (expectedAccept.length != receivedAccept.length) {
        error("Response header 'Sec-WebSocket-Accept' is the wrong length");
      }
      for (int i = 0; i < expectedAccept.length; i++) {
        if (expectedAccept[i] != receivedAccept[i]) {
          error("Bad response 'Sec-WebSocket-Accept' header");
        }
      }
      var protocol = response.headers.value('Sec-WebSocket-Protocol');

      _WebSocketPerMessageDeflate /*?*/ deflate =
          negotiateClientCompression(response, compression);

      return response.detachSocket().then<io.WebSocket>((socket) =>
          new _ApproovWebSocketImpl._fromSocket(
              socket, protocol, compression, false, deflate));
    });
  }

  static _WebSocketPerMessageDeflate /*?*/ negotiateClientCompression(
      HttpClientResponse response, CompressionOptions compression) {
    String extensionHeader =
        response.headers.value('Sec-WebSocket-Extensions') ?? "";

    var hv = HeaderValue.parse(extensionHeader, valueSeparator: ',');

    if (compression.enabled && hv.value == PER_MESSAGE_DEFLATE) {
      var serverNoContextTakeover =
          hv.parameters.containsKey(_serverNoContextTakeover);
      var clientNoContextTakeover =
          hv.parameters.containsKey(_clientNoContextTakeover);

      int getWindowBits(String type) {
        var o = hv.parameters[type];
        if (o == null) {
          return DEFAULT_WINDOW_BITS;
        }

        return int.tryParse(o) ?? DEFAULT_WINDOW_BITS;
      }

      return new _WebSocketPerMessageDeflate(
          clientMaxWindowBits: getWindowBits(_clientMaxWindowBits),
          serverMaxWindowBits: getWindowBits(_serverMaxWindowBits),
          clientNoContextTakeover: clientNoContextTakeover,
          serverNoContextTakeover: serverNoContextTakeover);
    }

    return null;
  }

  _ApproovWebSocketImpl._fromSocket(
      this._socket, this.protocol, CompressionOptions compression,
      [this._serverSide = false, _WebSocketPerMessageDeflate /*?*/ deflate])
      : _controller = new StreamController(sync: true) {
    _consumer = new _WebSocketConsumer(this, _socket);
    _sink = new _StreamSinkImpl(_consumer);
    _readyState = io.WebSocket.open;
    _deflate = deflate;

    var transformer = new _WebSocketProtocolTransformer(_serverSide, deflate);
    var subscription = _subscription = transformer.bind(_socket).listen((data) {
      if (data is _WebSocketPing) {
        if (!_writeClosed) _consumer.add(new _WebSocketPong(data.payload));
      } else if (data is _WebSocketPong) {
        // Simply set pingInterval, as it'll cancel any timers.
        pingInterval = _pingInterval;
      } else {
        _controller.add(data);
      }
    }, onError: (Object error, StackTrace stackTrace) {
      _closeTimer?.cancel();
      if (error is FormatException) {
        _close(WebSocketStatus.invalidFramePayloadData);
      } else {
        _close(WebSocketStatus.protocolError);
      }
      // An error happened, set the close code set above.
      _closeCode = _outCloseCode;
      _closeReason = _outCloseReason;
      _controller.close();
    }, onDone: () {
      _closeTimer?.cancel();
      if (_readyState == io.WebSocket.open) {
        _readyState = io.WebSocket.closing;
        if (!_isReservedStatusCode(transformer.closeCode)) {
          _close(transformer.closeCode, transformer.closeReason);
        } else {
          _close();
        }
        _readyState = io.WebSocket.closed;
      }
      // Protocol close, use close code from transformer.
      _closeCode = transformer.closeCode;
      _closeReason = transformer.closeReason;
      _controller.close();
    }, cancelOnError: true);
    subscription.pause();
    _controller
      ..onListen = subscription.resume
      ..onCancel = () {
        _subscription /*!*/ .cancel();
        _subscription = null;
      }
      ..onPause = subscription.pause
      ..onResume = subscription.resume;

    _webSockets[_serviceId] = this;
  }

  StreamSubscription listen(void onData(message) /*?*/,
      {Function /*?*/ onError, void onDone() /*?*/, bool /*?*/ cancelOnError}) {
    return _controller.stream.listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  Duration /*?*/ get pingInterval => _pingInterval;

  void set pingInterval(Duration /*?*/ interval) {
    if (_writeClosed) return;
    _pingTimer?.cancel();
    _pingInterval = interval;

    if (interval == null) return;

    _pingTimer = new Timer(interval, () {
      if (_writeClosed) return;
      _consumer.add(new _WebSocketPing());
      _pingTimer = new Timer(interval, () {
        _closeTimer?.cancel();
        // No pong received.
        _close(WebSocketStatus.goingAway);
        _closeCode = _outCloseCode;
        _closeReason = _outCloseReason;
        _controller.close();
      });
    });
  }

  int get readyState => _readyState;

  String get extensions => "";
  int /*?*/ get closeCode => _closeCode;
  String /*?*/ get closeReason => _closeReason;

  void add(data) {
    _sink.add(data);
  }

  void addUtf8Text(List<int> bytes) {
    // TODO(40614): Remove once non-nullability is sound.
    ArgumentError.checkNotNull(bytes, "bytes");
    _sink.add(new _EncodedString(bytes));
  }

  void addError(Object error, [StackTrace /*?*/ stackTrace]) {
    _sink.addError(error, stackTrace);
  }

  Future addStream(Stream stream) => _sink.addStream(stream);
  Future get done => _sink.done;

  Future close([int /*?*/ code, String /*?*/ reason]) {
    if (_isReservedStatusCode(code)) {
      throw new WebSocketException("Reserved status code $code");
    }
    if (_outCloseCode == null) {
      _outCloseCode = code;
      _outCloseReason = reason;
    }
    if (!_controller.isClosed) {
      // If a close has not yet been received from the other end then
      //   1) make sure to listen on the stream so the close frame will be
      //      processed if received.
      //   2) set a timer terminate the connection if a close frame is
      //      not received.
      if (!_controller.hasListener && _subscription != null) {
        _controller.stream.drain().catchError((_) => {});
      }
      if (_closeTimer == null) {
        // When closing the web-socket, we no longer accept data.
        _closeTimer = new Timer(const Duration(seconds: 5), () {
          // Reuse code and reason from the local close.
          _closeCode = _outCloseCode;
          _closeReason = _outCloseReason;
          _subscription?.cancel();
          _controller.close();
          _webSockets.remove(_serviceId);
        });
      }
    }
    return _sink.close();
  }

  static String /*?*/ get userAgent => _httpClient.userAgent;

  static set userAgent(String /*?*/ userAgent) {
    _httpClient.userAgent = userAgent;
  }

  void _close([int /*?*/ code, String /*?*/ reason]) {
    if (_writeClosed) return;
    if (_outCloseCode == null) {
      _outCloseCode = code;
      _outCloseReason = reason;
    }
    _writeClosed = true;
    _consumer.closeSocket();
    _webSockets.remove(_serviceId);
  }

  String get _serviceTypePath => 'io/websockets';
  String get _serviceTypeName => 'WebSocket';

  Map<String, dynamic> _toJSON(bool ref) {
    var name = '${_socket.address.host}:${_socket.port}';
    var r = <String, dynamic>{
      'id': _servicePath,
      'type': _serviceType(ref),
      'name': name,
      'user_name': name,
    };
    if (ref) {
      return r;
    }
    try {
      r['socket'] = (_socket as dynamic)._toJSON(true);
    } catch (_) {
      r['socket'] = {
        'id': _servicePath,
        'type': '@Socket',
        'name': 'UserSocket',
        'user_name': 'UserSocket',
      };
    }
    return r;
  }

  static bool _isReservedStatusCode(int /*?*/ code) {
    return code != null &&
        (code < WebSocketStatus.normalClosure ||
            code == WebSocketStatus.reserved1004 ||
            code == WebSocketStatus.noStatusReceived ||
            code == WebSocketStatus.abnormalClosure ||
            (code > WebSocketStatus.internalServerError &&
                code < WebSocketStatus.reserved1015) ||
            (code >= WebSocketStatus.reserved1015 && code < 3000));
  }

  Stream _stream;

  @override
  Stream<dynamic /*String|List<int>*/ > get stream =>
      _stream ??= _socket.asBroadcastStream();
}

// See http_impl.dart _ServiceObject
// TODO(ajohnsen): Use other way of getting a unique id.
int _nextServiceId = 1;

abstract class _ServiceObject {
  int __serviceId = 0;
  int get _serviceId {
    if (__serviceId == 0) __serviceId = _nextServiceId++;
    return __serviceId;
  }

  Map _toJSON(bool ref);

  String get _servicePath => "$_serviceTypePath/$_serviceId";

  String get _serviceTypePath;

  String get _serviceTypeName;

  String _serviceType(bool ref) {
    if (ref) return "@$_serviceTypeName";
    return _serviceTypeName;
  }
}
