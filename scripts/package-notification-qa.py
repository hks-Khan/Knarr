#!/usr/bin/env python3
"""Package only the synthetic notification probe, never the installed Knarr app."""
from pathlib import Path
import plistlib
import shutil
import subprocess

root = Path.cwd().resolve()
binary = root / '.build/debug/knarr-notification-qa'
app = root / 'outputs/Knarr Notification QA.app'
data = root / 'outputs/native-notifications-qa'
if not binary.is_file():
    raise SystemExit('먼저 swift build --product knarr-notification-qa를 실행하세요.')
if app.exists():
    info = app / 'Contents/Info.plist'
    if not info.is_file() or plistlib.loads(info.read_bytes()).get('CFBundleIdentifier') != 'com.kyen.knarr.notifications.qa':
        raise SystemExit('기존 경로가 이 QA 앱이 아니므로 보존합니다.')
    shutil.rmtree(app)
macos = app / 'Contents/MacOS'
resources = app / 'Contents/Resources'
macos.mkdir(parents=True)
resources.mkdir(parents=True)
data.mkdir(parents=True, exist_ok=True)
shutil.copy2(binary, macos / 'knarr-notification-qa')
# Same default policy resource as the real adapter; no runtime/authentication files.
shutil.copytree(root / 'Sources/KnarrCore/Resources/hird', resources / 'hird')
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
    CFBundleIdentifier='com.kyen.knarr.notifications.qa', CFBundleName='Knarr Notification QA',
    CFBundleDisplayName='Knarr Notification QA', CFBundleExecutable='knarr-notification-qa',
    CFBundlePackageType='APPL', CFBundleShortVersionString='0.1', CFBundleVersion='1',
    NSPrincipalClass='NSApplication', LSMinimumSystemVersion='14.0',
    KnarrNotificationQARoot=str(data))))
subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', str(app)], check=True, timeout=30)
subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(app)], check=True, timeout=30)
print('Synthetic QA app: ' + str(app))
print('Evidence: ' + str(data / 'events.jsonl'))
print('No OMP / CloudKit / live database / signing store access')
