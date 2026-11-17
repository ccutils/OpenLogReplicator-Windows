"""Independent consumer: Python socket/pyzmq and protoc-generated control schema."""
import argparse
import json
import socket
import struct
import time
from pathlib import Path
import OraProtoBuf_pb2 as pb

p = argparse.ArgumentParser()
p.add_argument('--transport', choices=['network', 'zeromq'], required=True)
p.add_argument('--format', choices=['json', 'protobuf'], required=True)
p.add_argument('--port', type=int, required=True)
p.add_argument('--base', type=int, required=True)
p.add_argument('--output', required=True)
a = p.parse_args()
out = Path(a.output)
out.mkdir(parents=True, exist_ok=True)

class Connection:
    def __init__(self):
        if a.transport == 'network':
            self.s = socket.create_connection(('127.0.0.1', a.port), 15)
            self.s.settimeout(90)
        else:
            import zmq
            self.z = zmq.Context()
            self.s = self.z.socket(zmq.PAIR)
            self.s.setsockopt(zmq.RCVTIMEO, 90000)
            self.s.setsockopt(zmq.SNDTIMEO, 15000)
            self.s.setsockopt(zmq.LINGER, 0)
            self.s.connect(f'tcp://127.0.0.1:{a.port}')
    def send(self, message):
        raw = message.SerializeToString()
        if a.transport == 'network': self.s.sendall(struct.pack('<I', len(raw)) + raw)
        else: self.s.send(raw)
    def exact(self, size):
        data = bytearray()
        while len(data) < size:
            part = self.s.recv(size-len(data))
            if not part: raise EOFError('server closed stream')
            data.extend(part)
        return bytes(data)
    def receive(self):
        if a.transport == 'zeromq': return self.s.recv()
        size, = struct.unpack('<I', self.exact(4))
        if size == 0xffffffff: size, = struct.unpack('<Q', self.exact(8))
        if size > 64*1024*1024: raise ValueError('oversized frame')
        return self.exact(size)
    def control(self, code, db='ORCL', **fields):
        self.send(pb.RedoRequest(code=code, database_name=db, **fields))
        return pb.RedoResponse.FromString(self.receive())
    def close(self):
        self.s.close()
        if a.transport == 'zeromq': self.z.term()

c = Connection()
assert c.control(pb.INFO, db='WRONG_DATABASE').code == pb.INVALID_DATABASE
assert c.control(pb.INFO).code == pb.READY
assert c.control(pb.START, scn=2**64-1).code == pb.REPLICATE
(out/'ready').write_text('ready', encoding='utf-8')
events = []
raw_messages = []
for i in range(12):
    raw = c.receive()
    (out/f'message-{i:02}.bin').write_bytes(raw)
    if a.format == 'json':
        message = json.loads(raw)
        raw_messages.append(message)
        for payload in message['payload']:
            if payload['op'] in ['c','u','d']: events.append(payload)
        last = (message['c_scn'], message['c_idx']-1)
    else:
        message = pb.RedoResponse.FromString(raw)
        from google.protobuf.json_format import MessageToDict
        raw_messages.append(MessageToDict(message, preserving_proto_field_name=True))
        for payload in message.payload:
            if payload.op in [pb.INSERT,pb.UPDATE,pb.DELETE]:
                def columns(values):
                    result = {}
                    for v in values:
                        kind = v.WhichOneof('datum')
                        result[v.name] = getattr(v,kind) if kind else None
                    return result
                events.append({'op': {pb.INSERT:'c',pb.UPDATE:'u',pb.DELETE:'d'}[payload.op],
                               'before': columns(payload.before), 'after': columns(payload.after)})
        last = (message.c_scn, message.c_idx-1)
assert [e['op'] for e in events] == ['c','u','c','d'], events
assert int(events[0]['after']['ID']) == a.base+1
assert events[0]['after']['VALUE'] == 'stream-first'
assert events[0]['after'].get('OPTIONAL_VALUE') is None
assert events[1]['after']['VALUE'] == '\u4e2d\u6587'
assert events[1]['after']['OPTIONAL_VALUE'] == 'stream-updated'
assert int(events[2]['after']['ID']) == a.base+2
assert events[2]['after']['VALUE'] == 'stream-retained'
assert int(events[3]['before']['ID']) == a.base+1
# INFO follows CONFIRM in transport order, making the server's acknowledgement observable.
c.send(pb.RedoRequest(code=pb.CONFIRM, database_name='ORCL', c_scn=last[0], c_idx=last[1]))
ack = c.control(pb.INFO)
assert ack.code == pb.REPLICATE and (ack.c_scn,ack.c_idx) >= last, (ack,last)
c.close()
time.sleep(1)
c = Connection()
status = c.control(pb.INFO)
assert status.code == pb.REPLICATE and (status.c_scn,status.c_idx) >= last
assert c.control(pb.CONTINUE, c_scn=last[0], c_idx=last[1]).code == pb.REPLICATE
assert c.control(pb.INFO).code == pb.REPLICATE
c.close()
summary = {'transport':a.transport,'format':a.format,'messages':12,'dml':4,
           'last_confirmed':last,'server_confirmed':[ack.c_scn,ack.c_idx],
           'checks':['invalid database','start','insert/update/delete','unicode','null','rollback absence','confirm','reconnect/continue']}
(out/'messages.json').write_text(json.dumps(raw_messages,ensure_ascii=False,indent=2),encoding='utf-8')
(out/'verification.json').write_text(json.dumps(summary,indent=2),encoding='utf-8')
print(json.dumps(summary))
