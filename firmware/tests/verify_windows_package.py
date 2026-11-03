"""Exercise the package's real VerifyOnly path; never open a serial device."""
from pathlib import Path
import json,subprocess,sys

package=Path(sys.argv[1]).resolve()
command=['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',str(package/'flash.ps1'),'-VerifyOnly']
def run(label,success):
    r=subprocess.run(command,capture_output=True)
    if (r.returncode==0)!=success:raise RuntimeError(label+': '+r.stdout.decode('utf-8',errors='replace')+r.stderr.decode('utf-8',errors='replace'))
    print('PASS '+label,flush=True)
run('native Windows tool and valid firmware verification',True)
manifest_path=package/'firmware-manifest.json';original=manifest_path.read_bytes();manifest=json.loads(original)
entry=manifest['boards'][0]['versions'][0]['panels'][0]['app'];app=(package/entry['path']).resolve()
assert app.is_relative_to((package/'firmware').resolve())
data=app.read_bytes()
try:
    bad=bytearray(data);bad[80]^=1;app.write_bytes(bad);run('corrupt firmware rejected',False)
finally:app.write_bytes(data)
try:
    entry['path']='../outside.bin';manifest_path.write_text(json.dumps(manifest),'utf-8');run('outside firmware path rejected',False)
finally:manifest_path.write_bytes(original)
run('restored Windows package still verifies',True)
