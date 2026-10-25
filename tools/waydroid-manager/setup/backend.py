#!/usr/bin/env python3
"""Opt-in Waydroid userspace setup. Never installs a kernel or writes boot slots."""
import argparse
import configparser
import fcntl
import gzip
import hashlib
import json
import os
from pathlib import Path
import platform
import pwd
import shutil
import subprocess
import sys
import re
import signal
import threading
import time
from urllib.parse import urlsplit
import zipfile

HERE = Path(__file__).resolve().parent
STATE = Path('/var/lib/dc1-waydroid-setup')
CACHE = Path('/var/cache/dc1-waydroid-setup')
IMAGES = Path('/usr/share/waydroid-extra/images')
CFG = Path('/var/lib/waydroid/waydroid.cfg')
VERSION = '1'
MODULE_FILE = Path('/etc/modules-load.d/dc1-waydroid-setup.conf')
NFT_LINK = Path('/etc/nftables.d/51_waydroid.nft')

class SetupError(Exception):
    pass

def emit(message):
    print(message, flush=True)

def run(argv, timeout=120):
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        raise SetupError(f'{Path(argv[0]).name}: could not complete within {timeout}s. Check the service or network and retry.') from None
    if result.returncode:
        # Raw command output can include local paths, account details or network data.
        raise SetupError(f'{Path(argv[0]).name} exited {result.returncode} during the step above. Run that command locally for its full output.')
    return result.stdout

def requirements():
    return dict(line.split('=', 1) for line in (HERE/'waydroid.config').read_text().splitlines()
                if line.startswith('CONFIG_'))

def read_config():
    for path in (Path('/proc/config.gz'), Path('/boot/config-' + platform.release())):
        try:
            data = gzip.decompress(path.read_bytes()).decode() if path.suffix == '.gz' else path.read_text()
            return dict(line.split('=', 1) for line in data.splitlines() if line.startswith('CONFIG_'))
        except (OSError, UnicodeError):
            continue
    return None

def missing_config(config, required):
    # A built-in implementation also satisfies a modular requirement.
    return [key for key, value in required.items()
            if config.get(key) not in ({'y', 'm'} if value == 'm' else {'y'})]

def preflight():
    if platform.machine() != 'aarch64':
        raise SetupError('This setup targets aarch64 Linux. No changes made.')
    if not Path('/run/systemd/system').exists():
        raise SetupError('This setup requires systemd. No changes made.')
    config = read_config()
    if config is None:
        raise SetupError('Cannot read the running kernel config. Copy its full build .config to /boot/config-<running kernel release>, then retry. See the setup guide.')
    missing = missing_config(config, requirements())
    if missing:
        raise SetupError('Kernel support missing: ' + ', '.join(missing) + '. Follow the kernel/recovery guide, reboot, then retry.')
    if shutil.which('apk') is None:
        raise SetupError('APK package manager not found. This setup requires Alpine/Nura.')

def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

class DownloadControl:
    def __init__(self):
        self.lock = threading.Lock()
        self.process = None
        self.stopped = False

    def attach(self, process):
        with self.lock:
            self.process = process
            self.stopped = False

    def detach(self):
        with self.lock:
            self.process = None

    def stop(self):
        with self.lock:
            if self.process is not None and self.process.poll() is None:
                self.stopped = True
                try:
                    self.process.send_signal(signal.SIGINT)
                except ProcessLookupError:
                    pass

CONTROL = DownloadControl()

def listen_for_stop():
    # Commands act only on the current downloader, never package installation.
    for line in sys.stdin:
        if line.strip() == 'STOP_DOWNLOAD':
            CONTROL.stop()

def download(pin, directory):
    directory.mkdir(parents=True, exist_ok=True)
    target = directory/pin['filename']
    if target.exists():
        if target.stat().st_size == pin['size'] and sha(target) == pin['id']:
            emit('Verified cached ' + pin['filename'])
            return target
        raise SetupError('Cached archive failed verification: ' + pin['filename'] + '. Remove that file from the setup cache and retry.')
    partial = target.with_suffix('.partial')
    url = pin['url']
    parsed = urlsplit(url)
    # Use SourceForge's download endpoint, not its browser landing page.
    match = re.fullmatch(r'/projects/([^/]+)/files/(.+)/download', parsed.path)
    if parsed.hostname == 'sourceforge.net' and match:
        url = f'https://downloads.sourceforge.net/project/{match[1]}/{match[2]}'
    command = ['aria2c', '--no-conf=true', '--continue=true', '--max-connection-per-server=4',
               '--split=4', '--min-split-size=8M', '--file-allocation=none',
               '--auto-file-renaming=false', '--allow-overwrite=false',
               '--max-tries=5', '--retry-wait=2', '--connect-timeout=15', '--timeout=30',
               '--lowest-speed-limit=100K', '--auto-save-interval=1',
               '--summary-interval=2', '--enable-color=false', '--human-readable=false',
               '--console-log-level=warn', '--download-result=hide',
               '--dir=' + str(directory), '--out=' + partial.name, url]
    process = None
    previous_handler = signal.getsignal(signal.SIGTERM)
    def interrupted(*_):
        raise SetupError('Download stopped. Partial data is retained; retry to resume.')
    try:
        signal.signal(signal.SIGTERM, interrupted)
        emit('Connecting with aria2; existing partial downloads will resume')
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        CONTROL.attach(process)
        emit('DOWNLOAD_ACTIVE')
        for line in process.stdout:
            # Only expose numeric progress, never raw downloader URLs or errors.
            match = re.search(r'\[#\w+ (\d+)B?/(\d+)B?\((\d+)%\).*?DL:(\d+)B?(?:.*?ETA:([^\]\s]+))?', line)
            if match:
                done, total, percent, rate = map(int, match.group(1, 2, 3, 4))
                eta = match[5] or 'estimating'
                emit(f"Downloading {pin['romtype']}: {min(percent, 100)}% "
                     f"({done / 1024**2:.1f} / {total / 1024**2:.1f} MiB) · "
                     f"{rate / 1024:.0f} KiB/s · {eta} left")
        result = process.wait()
        CONTROL.detach()
        emit('DOWNLOAD_INACTIVE')
        if CONTROL.stopped:
            raise SetupError('Download paused. Your progress is saved. Tap Resume setup to continue.')
        if result:
            raise SetupError('Download failed after aria2 retries. Partial data is retained; retry to resume.')
        emit('Verifying SHA256: ' + pin['filename'])
        if partial.stat().st_size != pin['size'] or sha(partial) != pin['id']:
            partial.unlink(missing_ok=True)
            Path(str(partial) + '.aria2').unlink(missing_ok=True)
            raise SetupError('Download checksum failed: ' + pin['filename'] + '. Retry to download it again.')
        partial.replace(target)
        Path(str(partial) + '.aria2').unlink(missing_ok=True)
        return target
    except FileNotFoundError:
        raise SetupError('aria2 or its download file is missing. Reinstall Waydroid Setup and retry.') from None
    finally:
        CONTROL.detach()
        if process is not None and process.poll() is None:
            process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait()
        signal.signal(signal.SIGTERM, previous_handler)

def extract_image(archive, name, directory):
    directory.mkdir(parents=True, exist_ok=True)
    destination = directory/name
    temporary = directory/(name + '.setup-partial')
    try:
        with zipfile.ZipFile(archive) as z:
            matches = [i for i in z.infolist() if i.filename == name]
            if len(matches) != 1:
                raise SetupError('Verified archive does not contain exactly one ' + name)
            with z.open(matches[0]) as source, temporary.open('wb') as output:
                shutil.copyfileobj(source, output, 1024 * 1024)
        if destination.exists():
            if sha(destination) != sha(temporary):
                raise SetupError(name + ' already exists with different contents. Back up the existing Android installation before replacing images.')
        else:
            temporary.chmod(0o644)
            temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)

def configure(path):
    c = configparser.ConfigParser(interpolation=None)
    c.read(path)
    if not c.has_section('waydroid'):
        raise SetupError('Waydroid initialization did not create its configuration.')
    if not c.has_section('properties'):
        c.add_section('properties')
    c['properties']['dalvik.vm.extra-opts'] = '-Xint'
    c['properties']['dalvik.vm.usejit'] = 'false'
    temporary = path.with_suffix('.setup-tmp')
    with temporary.open('w') as stream:
        c.write(stream)
    temporary.chmod(0o644)
    temporary.replace(path)

def setup(variant="vanilla"):
    if variant not in ('vanilla', 'gapps'):
        raise SetupError('Choose vanilla or gapps.')
    if os.geteuid() != 0:
        raise SetupError('Setup needs administrator access. Open the GUI or use pkexec.')
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (STATE/'lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SetupError('Another setup is running. Wait for it to finish.') from None
        emit('Checking kernel and host requirements')
        choice = STATE/'variant'
        if choice.exists() and choice.read_text().strip() != variant:
            raise SetupError('This setup already started with another image choice. It will not switch images or erase Android data.')
        if (STATE/'complete').exists():
            emit('Setup already completed. Use Check / report to inspect it, or Open Android to launch.')
            return
        if CFG.exists() and not (STATE/'started').exists():
            raise SetupError('An existing Android installation was found. It has not been changed. Use Check / report and Open Android; this installer only initializes a new installation.')
        preflight()
        if shutil.disk_usage('/var').free < 6 * 1024**3:
            raise SetupError('At least 6 GiB free under /var is required for downloads and images.')
        choice.write_text(variant + '\n')
        (STATE/'started').touch(mode=0o600)
        emit('Installing Alpine Waydroid packages (apk add)')
        run(['apk', 'add', 'waydroid', 'waydroid-systemd', 'waydroid-nftrules'], 600)
        emit('Stopping and masking Android during setup')
        run(['systemctl', 'mask', '--now', 'waydroid-container.service'])
        pins = json.loads((HERE/('images-gapps.json' if variant == 'gapps' else 'images.json')).read_text())
        for kind, pin in pins.items():
            archive = download(pin, CACHE)
            emit('Extracting verified ' + kind + ' image')
            extract_image(archive, kind + '.img', IMAGES)
        emit('Initializing Android from verified local images')
        if not CFG.exists():
            run(['waydroid', 'init', '-s', variant.upper()], 600)
        emit('Applying interpreter settings and readable config permissions')
        configure(CFG)
        run(['waydroid', 'upgrade', '-o'], 180)
        CFG.chmod(0o644)
        emit('Loading network modules')
        modules = ('iptable_filter', 'iptable_nat', 'iptable_mangle', 'iptable_raw',
                     'ip6table_filter', 'ip6table_nat', 'ip6table_mangle', 'ip6table_raw')
        for name in modules:
            run(['modprobe', name])
        module_file = MODULE_FILE
        module_text = '\n'.join(modules) + '\n'
        if module_file.exists() and module_file.read_text() != module_text:
            raise SetupError('The setup module list was customized. Review it before retrying.')
        module_file.parent.mkdir(parents=True, exist_ok=True)
        module_file.write_text(module_text)
        module_file.chmod(0o644)
        emit('Checking Waydroid firewall rules')
        rule = Path('/usr/share/nftables.avail/51_waydroid.nft')
        link = NFT_LINK
        if link.exists() or link.is_symlink():
            if link.resolve() != rule and link.read_bytes() != rule.read_bytes():
                raise SetupError('A different 51_waydroid.nft already exists. Review it locally; setup will not overwrite it.')
        else:
            link.parent.mkdir(parents=True, exist_ok=True)
            link.symlink_to(rule)
        run(['nft', '-c', '-f', str(rule)])
        rules = run(['nft', 'list', 'ruleset'])
        if 'Allow incoming network traffic from WayDroid' not in rules:
            run(['nft', '-f', str(rule)])
        emit('Enabling the container service')
        run(['systemctl', 'unmask', 'waydroid-container.service'])
        run(['systemctl', 'enable', '--now', 'waydroid-container.service'])
        (STATE/'complete').write_text(VERSION + '\n')
        emit('Setup complete. Open Android as your desktop user; first startup can take two minutes.')

def mounted_under(paths, mountinfo=None):
    text = Path('/proc/self/mountinfo').read_text() if mountinfo is None else mountinfo
    targets = [str(p) for p in paths]
    for line in text.splitlines():
        fields = line.split()
        if len(fields) < 5:
            continue
        point = fields[4].replace(r'\040', ' ').replace(r'\134', '\\')
        if any(point == p or point.startswith(p + '/') for p in targets):
            return True
    return False

def remove_tree(path):
    # Fixed paths only; unlink a symlink rather than following its target.
    if path.is_symlink():
        path.unlink()
    elif path.exists():
        if not shutil.rmtree.avoids_symlink_attacks:
            raise SetupError('This Python cannot safely remove directory trees.')
        shutil.rmtree(path)

def remove(erase_data=False):
    if os.geteuid() != 0:
        raise SetupError('Removal needs administrator access. Use the GUI or pkexec.')
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (STATE/'lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SetupError('Another setup operation is running. Wait for it to finish.') from None
        data_paths = [Path('/var/lib/waydroid')]
        if erase_data:
            uid = os.environ.get('PKEXEC_UID') or os.environ.get('SUDO_UID')
            if not uid or not uid.isdigit() or int(uid) == 0:
                raise SetupError('Data deletion must be launched by the desktop user through pkexec or sudo.')
            home = Path(pwd.getpwuid(int(uid)).pw_dir)
            if home == Path('/') or home == Path('/root') or not home.is_absolute():
                raise SetupError('Cannot identify a safe desktop-user data directory.')
            user_data = home/'.local/share/waydroid'
            if not user_data.resolve().is_relative_to(home.resolve()):
                raise SetupError('Android data resolves outside the desktop home. Review the symlinks before deleting it.')
            data_paths.append(user_data)
        emit('Stopping the Android container')
        active = subprocess.run(['systemctl', 'show', 'waydroid-container.service', '--property=LoadState', '--value'], capture_output=True, text=True)
        if active.returncode == 0 and active.stdout.strip() != 'not-found':
            run(['systemctl', 'stop', 'waydroid-container.service'])
            run(['systemctl', 'disable', 'waydroid-container.service'])
        if mounted_under(data_paths + [IMAGES]):
            raise SetupError('Android mounts are still active. Stop all Waydroid sessions and retry. No files have been deleted.')
        emit('Removing the Waydroid packages')
        installed = []
        for name in ('waydroid', 'waydroid-systemd', 'waydroid-nftrules'):
            if subprocess.run(['apk', 'info', '-e', name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
                installed.append(name)
        if installed:
            run(['apk', 'del', *installed], 300)
        link = NFT_LINK
        if link.is_symlink() and os.readlink(link) == '/usr/share/nftables.avail/51_waydroid.nft':
            link.unlink()
        # Only remove the exact module file written by this installer.
        module_file = MODULE_FILE
        expected = '\n'.join(('iptable_filter', 'iptable_nat', 'iptable_mangle', 'iptable_raw',
                              'ip6table_filter', 'ip6table_nat', 'ip6table_mangle', 'ip6table_raw')) + '\n'
        if module_file.exists() and module_file.read_text() == expected:
            module_file.unlink()
        (STATE/'complete').unlink(missing_ok=True)
        if erase_data:
            emit('Deleting Android apps and data for the invoking desktop user')
            for path in data_paths:
                remove_tree(path)
            for name in ('system.img', 'vendor.img'):
                (IMAGES/name).unlink(missing_ok=True)
            remove_tree(CACHE)
            (STATE/'started').unlink(missing_ok=True)
            (STATE/'variant').unlink(missing_ok=True)
            emit('Android removed, including apps, data and downloaded images. The Linux kernel and recovery files are unchanged.')
        else:
            emit('Android removed. Apps, data and images are retained. The Linux kernel and recovery files are unchanged.')


def report():
    # Deliberately constructed from non-personal fields. No journals, app lists,
    # device identifiers, hostnames, addresses, accounts or config contents.
    lines = ['Waydroid setup report v' + VERSION, 'Architecture: ' + platform.machine(),
             'Kernel: ' + platform.release(),
             'systemd: ' + ('present' if Path('/run/systemd/system').exists() else 'absent')]
    cfg = read_config()
    lines.append('Kernel requirements: ' + ('unreadable' if cfg is None else
                 ', '.join(missing_config(cfg, requirements())) or 'passed'))
    for pkg in ('waydroid', 'waydroid-systemd', 'waydroid-nftrules'):
        try:
            output = run(['apk', 'list', '--installed', pkg]).strip().splitlines()
            # Accept only the requested package's version line.
            value = next((line.split()[0] for line in output if line.startswith(pkg + '-') and ' [installed]' in line), 'not installed')
        except SetupError:
            value = 'unavailable'
        lines.append(pkg + ': ' + value)
    try:
        value = run(['systemctl', 'show', 'waydroid-container.service', '--property=ActiveState', '--value']).strip()
        if value not in ('active', 'inactive', 'failed', 'activating', 'deactivating', 'reloading'):
            value = 'unknown'
    except SetupError:
        value = 'unavailable'
    lines.append('Container service: ' + value)
    lines.append('Android config: ' + ('present' if CFG.exists() else 'absent'))
    if CFG.exists():
        lines.append('Config readable by desktop user: ' + ('yes' if os.access(CFG, os.R_OK) else 'no'))
        try:
            c = configparser.ConfigParser(interpolation=None); c.read(CFG)
            ok = c.get('properties', 'dalvik.vm.extra-opts', fallback='') == '-Xint' and c.get('properties', 'dalvik.vm.usejit', fallback='') == 'false'
            lines.append('Interpreter settings: ' + ('set' if ok else 'not set'))
        except (OSError, configparser.Error):
            lines.append('Interpreter settings: unreadable')
    return '\n'.join(lines)

def stop_android():
    emit('Closing Android apps and stopping the session…')
    run(['waydroid', 'session', 'stop'], timeout=30)
    status = run(['waydroid', 'status'], timeout=10)
    if not re.search(r'^Session:\s+STOPPED\s*$', status, re.MULTILINE):
        raise SetupError('Android has not confirmed it stopped. Check the report and retry.')
    emit('Android stopped. Your installed apps and data are retained. Open Android to start it again.')

def launch_android(timeout=180):
    if not os.environ.get('WAYLAND_DISPLAY'):
        raise SetupError('Open the manager from your Wayland desktop session.')
    emit('Starting Android. First startup can take a few minutes.')
    process = subprocess.Popen(['waydroid', 'show-full-ui'], stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, start_new_session=True)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        code = process.poll()
        if code is not None and code != 0:
            raise SetupError('Android could not open. Check the diagnostic report and container service, then retry.')
        try:
            result = subprocess.run(['waydroid', 'prop', 'get', 'sys.boot_completed'],
                                    capture_output=True, text=True,
                                    timeout=max(0.1, min(5, deadline - time.monotonic())))
            if result.returncode == 0 and result.stdout.strip() == '1':
                emit('Android has finished booting. Switch to its window to continue.')
                return
        except subprocess.TimeoutExpired:
            pass
        time.sleep(min(2, max(0, deadline - time.monotonic())))
    raise SetupError('Android has not finished booting after three minutes. It may still be starting; copy the report for help or try Open Android again. Your apps and data are unchanged.')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['setup', 'check', 'report', 'remove', 'launch', 'stop'])
    parser.add_argument('--variant', choices=['vanilla', 'gapps'], default='vanilla', help='Image choice for a new installation only')
    parser.add_argument('--erase-data', action='store_true', help='With remove: also delete Android apps/data for the invoking user and images')
    args = parser.parse_args()
    if args.erase_data and args.action != 'remove':
        parser.error('--erase-data is only valid with remove')
    try:
        if args.action == 'setup':
            if not sys.stdin.isatty():
                threading.Thread(target=listen_for_stop, daemon=True).start()
            setup(args.variant)
        elif args.action == 'launch': launch_android()
        elif args.action == 'stop': stop_android()
        elif args.action == 'remove': remove(args.erase_data)
        elif args.action == 'check':
            preflight(); emit('Kernel and host requirements passed.')
        else: emit(report())
    except (SetupError, OSError, configparser.Error, zipfile.BadZipFile) as error:
        # SetupError messages are authored; unexpected OS errors can expose paths.
        emit('ERROR: ' + (str(error) if isinstance(error, SetupError) else 'Local file operation failed. Check permissions and free space, then retry.'))
        return 1
    return 0

if __name__ == '__main__':
    sys.exit(main())
