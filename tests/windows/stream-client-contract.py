"""An independent TCP peer checks the packaged client's 64-bit positions and final ACK."""
import json
from pathlib import Path
import socket
import struct
import subprocess
import threading
import OraProtoBuf_pb2 as pb

root=Path(__file__).resolve().parents[2]
server=socket.socket()
server.bind(('127.0.0.1',0))
server.listen(1)
server.settimeout(15)
errors=[]
scn=65077219000
def peer():
    try:
        connection,_=server.accept()
        with connection:
            connection.settimeout(15)
            def exact(n):
                raw=b''
                while len(raw)<n:
                    part=connection.recv(n-len(raw))
                    if not part: raise EOFError()
                    raw+=part
                return raw
            def receive():
                size,=struct.unpack('<I',exact(4))
                return pb.RedoRequest.FromString(exact(size))
            def send(raw): connection.sendall(struct.pack('<I',len(raw))+raw)
            assert receive().code==pb.INFO
            send(pb.RedoResponse(code=pb.READY).SerializeToString())
            request=receive()
            assert request.code==pb.START and request.scn==2**64-1
            send(pb.RedoResponse(code=pb.REPLICATE,scn=scn).SerializeToString())
            for idx,op in enumerate(['begin','c','commit'],1):
                send(json.dumps({'c_scn':scn,'c_idx':idx,'payload':[{'op':op}]}).encode())
            request=receive()
            assert request.code==pb.CONFIRM and request.c_scn==scn and request.c_idx==2
            assert receive().code==pb.INFO
            send(pb.RedoResponse(code=pb.REPLICATE,c_scn=scn,c_idx=2).SerializeToString())
    except BaseException as error: errors.append(error)
thread=threading.Thread(target=peer)
thread.start()
process=subprocess.run([str(root/'dist/OpenLogReplicator-Windows-connectors/bin/StreamClient.exe'),'network',f'127.0.0.1:{server.getsockname()[1]}','ORCL','json','now','--max-messages','3'],capture_output=True,timeout=25)
thread.join(15)
server.close()
assert not thread.is_alive() and not errors, (errors,process.returncode,process.stderr,process.stdout)
assert process.returncode==0 and b'final confirmation acknowledged' in process.stderr+process.stdout, process.stderr
print('PASS packaged StreamClient: empty READY, START, 64-bit SCN, CONFIRM index, observed ACK, exit 0')
