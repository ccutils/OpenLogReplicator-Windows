"""Package the current source snapshot and pinned third-party sources, without local secrets."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import zipfile

root = Path(__file__).resolve().parents[1]
stage = root/'dist/OpenLogReplicator-Windows-connectors'
prefix = 'OpenLogReplicator-Windows/'
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest().upper()
def git(*args, cwd=root): return subprocess.check_output(['git',*args], cwd=cwd)
files = sorted(set(git('ls-files','--cached','--others','--exclude-standard','-z').decode().split('\0'))-{''})
for name in files:
    if any(part in {'.git','test-results','vendor','dist'} for part in Path(name).parts) or name.endswith('.local.json') or 'id_ed25519' in name or name=='.ssh-known-hosts':
        raise RuntimeError(f'Unsafe source path: {name}')
snapshot = hashlib.sha256()
for name in files:
    snapshot.update(name.encode()+b'\0'+(root/name).read_bytes()+b'\0')
info = {
    'product':'OpenLogReplicator-Windows v1.9.0 connectors x64',
    'baseline_commit':git('rev-parse','HEAD').decode().strip(),
    'source_state':'working tree snapshot including post-baseline connector changes',
    'source_snapshot_sha256':snapshot.hexdigest().upper(),
    'enabled':['OCI','file','Kafka/SCRAM','Protobuf','TCP Stream','ZeroMQ'],
    'disabled':['Prometheus'],
    'target':'Windows Server 2012 R2 x64 and later; native /MT; subsystem 6.03',
    'executables':{p.name:sha(p) for p in sorted((stage/'bin').glob('*.exe'))},
    'oracle_runtime_redistributed':False,
}
(stage/'BUILDINFO.json').write_text(json.dumps(info,indent=2)+'\n',encoding='utf-8')
dependencies=['rapidjson','librdkafka','openssl','protobuf','libzmq']
dep_info={d:git('rev-parse','HEAD',cwd=root/'vendor'/d).decode().strip() for d in dependencies}
runtime = root/'dist/OpenLogReplicator-Windows-v1.9.0-connectors-x64.zip'
source = root/'dist/OpenLogReplicator-Windows-v1.9.0-connectors-source.zip'
with zipfile.ZipFile(runtime,'w',zipfile.ZIP_DEFLATED,compresslevel=9) as z:
    for path in sorted(stage.rglob('*')):
        if path.name.endswith('.local.json') or path.suffix.lower()=='.dll': raise RuntimeError('Unexpected runtime file')
        z.write(path,prefix+path.relative_to(stage).as_posix())
with tempfile.TemporaryDirectory(dir=root/'build-deps') as temporary:
    with zipfile.ZipFile(source,'w',zipfile.ZIP_DEFLATED,compresslevel=9) as z:
        for name in files: z.write(root/name,prefix+name)
        z.writestr(prefix+'BUILDINFO.json',json.dumps(info,indent=2)+'\n')
        z.writestr(prefix+'third-party/SOURCES.json',json.dumps(dep_info,indent=2)+'\n')
        for dependency in dependencies:
            archive=Path(temporary)/(dependency+'.zip')
            subprocess.run(['git','archive','--format=zip',f'--prefix={dependency}/',f'--output={archive}','HEAD'],cwd=root/'vendor'/dependency,check=True)
            z.write(archive,prefix+'third-party/'+archive.name,compress_type=zipfile.ZIP_STORED)
for path in [runtime,source]:
    with zipfile.ZipFile(path) as z:
        if z.testzip() is not None: raise RuntimeError('Archive CRC failure')
    digest=sha(path)
    Path(str(path)+'.sha256').write_text(digest+'  '+path.name+'\n',encoding='ascii')
    print(json.dumps({'file':str(path),'bytes':path.stat().st_size,'sha256':digest}))
