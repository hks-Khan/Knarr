#!/usr/bin/env python3
"""Package the candidate binary as a synthetic-only, unentitled QA app."""
import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--binary', default='outputs/Knarr.app/Contents/MacOS/Knarr')
args = parser.parse_args()
root = Path.cwd().resolve()
binary = (root / args.binary).resolve()
app = root / 'outputs/Knarr QA.app'
if not binary.is_file():
    raise SystemExit('후보 Knarr 실행 파일이 없습니다: ' + str(binary))
# Only this script's generated QA bundle is replaced; never touch an installed app.
if app.exists():
    if not (app / 'Contents/Info.plist').is_file() or plistlib.loads((app / 'Contents/Info.plist').read_bytes()).get('CFBundleIdentifier') != 'com.kyen.knarr.qa':
        raise SystemExit('기존 경로가 QA 번들이 아니므로 보존합니다: ' + str(app))
    shutil.rmtree(app)
macos = app / 'Contents/MacOS'
resources = app / 'Contents/Resources'
macos.mkdir(parents=True)
resources.mkdir(parents=True)
shutil.copy2(binary, macos / 'Knarr')
shutil.copy2(root / 'Assets/Knarr.icns', resources / 'Knarr.icns')
data = root / 'outputs/qa-candidate/data'
data.mkdir(parents=True, exist_ok=True)
info = dict(CFBundleIdentifier='com.kyen.knarr.qa', CFBundleName='Knarr QA', CFBundleDisplayName='Knarr QA',
            CFBundleExecutable='Knarr', CFBundleIconFile='Knarr.icns', CFBundlePackageType='APPL',
            CFBundleShortVersionString='0.1', CFBundleVersion='approval-r3', CFBundleDevelopmentRegion='ko',
            CFBundleLocalizations=['ko'], LSMinimumSystemVersion='14.0', NSHighResolutionCapable=True,
            NSPrincipalClass='NSApplication', LSEnvironment=dict(KNARR_DATA_DIRECTORY=str(data),
            KNARR_SKIP_JITDECK_IMPORT='1', KNARR_MOBILE='0'))
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
(data / 'fixture.json').write_text(json.dumps(dict(source='SampleKnarrStore(qaProjectPath:animated:)',
    project=str(root / 'outputs/qa-candidate/project'), awaitingApprovalIssue='qa-approval', proposalVersion=1,
    changingCard='npc-repeat', syntheticOnly=True, databaseCopied=False, ompStarted=False, cloudKitStarted=False), indent=2) + '\n')
subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', str(app)], check=True)
subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(app)], check=True)
print('QA bundle: ' + str(app))
print('Synthetic only: no OMP, authentication, production database or CloudKit access')
