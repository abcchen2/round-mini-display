#!/usr/bin/env python3
"""Package built public 1.75 images for Windows and macOS; never flash hardware."""
from pathlib import Path
import argparse,hashlib,json,re,shutil,stat,struct,subprocess,sys,zipfile

REPO=Path(__file__).resolve().parents[1]
FW=REPO/'firmware'
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def require(ok,message):
    if not ok:raise ValueError(message)
def clean_output(folder,parent):
    require(folder.resolve().is_relative_to(parent.resolve()) and folder.resolve()!=parent.resolve(),'Unsafe package directory')
    if folder.exists():shutil.rmtree(folder)
    folder.mkdir(parents=True)
def checksums(folder):
    p=folder/'SHA256SUMS.txt'
    p.write_text(''.join(digest(f)+'  '+f.relative_to(folder).as_posix()+'\n' for f in sorted(folder.rglob('*')) if f.is_file() and f!=p),'utf-8',newline='\n')
def archive(folder,output,unix=False):
    with zipfile.ZipFile(output,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
        for p in sorted(folder.rglob('*')):
            if not p.is_file():continue
            name=folder.name+'/'+p.relative_to(folder).as_posix()
            if unix:
                entry=zipfile.ZipInfo(name);entry.create_system=3;entry.compress_type=zipfile.ZIP_DEFLATED
                entry.external_attr=(stat.S_IFREG|(0o755 if p.suffix=='.command' or p.name=='esptool' else 0o644))<<16
                z.writestr(entry,p.read_bytes())
            else:z.write(p,name)
    with zipfile.ZipFile(output) as z:require(z.testzip() is None,'Bad ZIP CRC')

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tools-dir',type=Path,required=True,help='Windows tools directory: official esptool.exe and notices')
    parser.add_argument('--mac-tools-dir',type=Path,help='Optional tools directory with macos-arm64/ and macos-amd64/')
    args=parser.parse_args()
    source=FW/'boards/175/MotoNav'
    version=(FW/'RELEASE_VERSION').read_text('utf-8').strip()
    require(re.fullmatch(r'\d+\.\d+\.\d+(?:-[A-Za-z0-9][A-Za-z0-9.-]*)?',version),'Invalid version')
    require(f'#define FW_VERSION "v{version}"' in (source/'src/core/FirmwareConfig.h').read_text('utf-8'),'Source/version mismatch')
    require('rebel' not in version.lower() and not list(source.rglob('*Rebel*')),'Private boot resource found')
    require('RebelBootAsset' not in (source/'BootAnimation.h').read_text('utf-8'),'Private boot include found')
    dist=FW/'dist/175/panel0';prefix=f'MotoNav_universal_1.75_v{version}_panel0'
    manifest_path=dist/(prefix+'_manifest.json');manifest=json.loads(manifest_path.read_text('utf-8'))
    require(manifest['firmware']==version,'Image version mismatch')
    images={}
    for item in manifest['files']:
        require(Path(item['file']).name==item['file'],'Unsafe image path')
        p=dist/item['file'];require(p.stat().st_size==item['bytes'] and digest(p)==item['sha256'],'Image checksum mismatch')
        require(('v'+version+'\0').encode() in p.read_bytes(),'Wrong binary version')
        images['app' if '_app_' in p.name else 'full']=p
    app=images['app'].read_bytes();full=images['full'].read_bytes()
    require(app[0]==0xe9 and struct.unpack_from('<H',app,12)[0]==9 and len(app)<=0x300000,'Wrong app target/size')
    require(full[0]==0xe9 and full[0x8000:0x8002]==b'\xaaP' and full[0x10000:]==app,'Wrong partition/application offset')
    require(not any(tag in app for tag in [b'RASTERJOB',b'RASTERPROFILE',b'FRAMESTALL',b'RebelBootAsset']),'Diagnostic/private image found')
    out=REPO/'output/firmware'/version;out.mkdir(parents=True,exist_ok=True)
    win=out/f'MotoNav-1.75-v{version}-Universal-Flasher';clean_output(win,out)
    shutil.copytree(FW/'windows-flasher',win,dirs_exist_ok=True)
    shutil.copytree(args.tools_dir.resolve(),win/'tools')
    require((win/'tools/esptool.exe').is_file(),'Missing Windows esptool')
    panel={'label':'1.75 AMOLED 原面板'}
    for kind,p in images.items():
        target=win/'firmware/panel0'/p.name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,target)
        panel[kind]={'path':target.relative_to(win).as_posix(),'bytes':target.stat().st_size,'sha256':digest(target).upper()}
    bundle={'schema':1,'platform':'universal','boards':[{'id':'175','label':'微雪 ESP32-S3-Touch-AMOLED-1.75（466×466）','versions':[{'label':f'v{version} · 通用开机 · 分步收图 · 安卓/iOS共用','version':version,'panels':[panel]}]}]}
    (win/'firmware-manifest.json').write_text(json.dumps(bundle,ensure_ascii=False,indent=2)+'\n','utf-8')
    if sys.platform=='win32':subprocess.run([sys.executable,str(FW/'tests/verify_windows_package.py'),str(win)],check=True)
    checksums(win);win_zip=out/(win.name+'.zip');archive(win,win_zip)
    assets=[win_zip]
    if args.mac_tools_dir:
        mac=out/f'MotoNav-1.75-v{version}-macOS-OneClick';clean_output(mac,out)
        shutil.copytree(FW/'macos-flasher',mac,dirs_exist_ok=True)
        shutil.copytree(args.mac_tools_dir.resolve(),mac/'tools')
        tool_meta=json.loads((mac/'工具来源与校验.json').read_text('utf-8'))
        for tool in tool_meta['tools']:
            p=mac/'tools'/('macos-'+tool['arch'])/'esptool'
            require(digest(p)==tool['toolSha256'],'Mac native tool hash mismatch')
            expected_cpu=0x100000c if tool['arch']=='arm64' else 0x1000007
            require(struct.unpack_from('<II',p.read_bytes())==(0xfeedfacf,expected_cpu),'Mac native architecture mismatch')
        for p in images.values():
            target=mac/'firmware'/p.name;target.parent.mkdir(exist_ok=True);shutil.copy2(p,target)
        shutil.copy2(manifest_path,mac/'firmware/manifest.json')
        for p in mac.glob('*.command'):
            raw=p.read_bytes();require(raw.startswith(b'#!/bin/zsh\n') and b'\r' not in raw,'Mac entry must use LF')
            if p.name=='一键烧录.command':require(version.encode() in raw,'Stale Mac version')
        for kind,p in images.items():require((mac/'firmware'/p.name).read_bytes()==(win/panel[kind]['path']).read_bytes(),'Windows/Mac images differ')
        checksums(mac);mac_zip=out/(mac.name+'.zip');archive(mac,mac_zip,unix=True);assets.append(mac_zip)
    flat=out/f'MotoNav-universal-firmware-{version}.zip'
    with zipfile.ZipFile(flat,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
        for p in [*images.values(),manifest_path]:z.write(p,'firmware/dist/175/panel0/'+p.name)
    assets.append(flat)
    source_zip=out/f'MotoNav-Firmware-Source-1.75-v{version}.zip'
    files=[]
    for name in ['firmware/boards/175','firmware/libraries','firmware/tests','firmware/windows-flasher','firmware/macos-flasher','licenses']:
        files.extend(p for p in (REPO/name).rglob('*') if p.is_file() and not any(x in p.parts for x in ['__pycache__','.build','build']) and p.suffix not in ['.pyc','.exe','.pdb'])
    files.extend(REPO/name for name in ['.gitattributes','LICENSE.md','firmware/README.md','firmware/RELEASE_VERSION','firmware/build.py','firmware/build.ps1','firmware/package_flasher.py','docs/RELEASE-IOS-FIRMWARE-2026-11-01.md','docs/VERIFY-IOS-FIRMWARE-2026-11-01.json'])
    with zipfile.ZipFile(source_zip,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
        for p in sorted(set(files)):
            require('rebelboot' not in p.name.lower(),'Private source asset found')
            entry=zipfile.ZipInfo('MotoNav/'+p.relative_to(REPO).as_posix());entry.create_system=3;entry.compress_type=zipfile.ZIP_DEFLATED
            entry.external_attr=(stat.S_IFREG|(0o755 if p.suffix=='.command' else 0o644))<<16;z.writestr(entry,p.read_bytes())
    assets.append(source_zip)
    record={'version':version,'genericBoot':True,'windowsMacImagesIdentical':bool(args.mac_tools_dir),'files':{p.name:{'bytes':p.stat().st_size,'sha256':digest(p)} for p in assets}}
    (out/'release-assets.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n','utf-8')
    (out/'SHA256SUMS.txt').write_text(''.join(digest(p)+'  '+p.name+'\n' for p in assets),'utf-8')
    print(json.dumps({'out':str(out),'assets':[p.name for p in assets],'windowsMacImagesIdentical':bool(args.mac_tools_dir)},ensure_ascii=False))

if __name__=='__main__':main()
