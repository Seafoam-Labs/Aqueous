"""Bounded IPC client for isolated compositor tests; no subprocess transport."""
import json
import socket

MAX_FRAME = 4259840


class Client:
    def __init__(self, path):
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.settimeout(5)
        self.socket.connect(str(path))
        self.buffer = bytearray()
        self.counter = 0
        self.session = None
        self.capabilities = self.call('hello')['result']
        self.session = self.capabilities['session']

    def close(self):
        self.socket.close()

    def frame(self, op, params=None, **extra):
        self.counter += 1
        frame = dict(ipc=1, id=str(self.counter), op=op, params=params or {})
        if self.session:
            frame['session'] = self.session
        frame.update(extra)
        return frame

    def send(self, frame):
        self.socket.sendall(json.dumps(frame, ensure_ascii=False).encode() + b'\n')

    def receive(self):
        while b'\n' not in self.buffer:
            data = self.socket.recv(4096)
            if not data:
                raise EOFError('IPC disconnected before complete frame')
            self.buffer.extend(data)
            if len(self.buffer) > MAX_FRAME + 4096:
                raise ValueError('oversized IPC frame')
        line, _, rest = self.buffer.partition(b'\n')
        self.buffer = bytearray(rest)
        if len(line) > MAX_FRAME:
            raise ValueError('oversized IPC frame')
        return json.loads(line)

    def call(self, op, params=None, ok=True, **extra):
        request = self.frame(op, params, **extra)
        self.send(request)
        response = self.receive()
        assert response['ipc'] == 1 and response['id'] == request['id'], response
        assert response['ok'] == ok, response
        return response

    def snapshot(self):
        return self.call('snapshot')['result']['batch']

    def command(self, action, fields=None, ok=True):
        return self.call('command', dict(action=action, fields=fields or {}), ok=ok)

    def ack(self, event):
        return self.call('ack', dict(delivery=event['delivery']))
