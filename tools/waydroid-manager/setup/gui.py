#!/usr/bin/env python3
"""Native GTK4 front end for the Waydroid userspace setup helper."""
import os
import re
from pathlib import Path
import subprocess
import threading
import sys

try:
    import gi
    gi.require_version('Gtk', '4.0')
    from gi.repository import Gtk, Gio, GLib, Gdk, Pango
except (ImportError, ValueError):
    sys.exit('Install gtk4.0 and py3-gobject3, then launch Waydroid Manager again.')

HERE = Path(__file__).resolve().parent
BACKEND = str(HERE/'backend.py')

class SetupApp(Gtk.Application):
    def __init__(self):
        super().__init__(application_id='io.github.muness.WaydroidSetup', flags=Gio.ApplicationFlags.DEFAULT_FLAGS)
        self.busy = False
        self.operation_process = None
        self.paused = False
        self.last_operation = 'No setup attempted.'
        self.connect('activate', self.activate)

    def activate(self, *_):
        if self.get_active_window():
            self.get_active_window().present(); return
        self.window = Gtk.ApplicationWindow(application=self, title='Waydroid Manager')
        self.window.set_icon_name('io.github.muness.WaydroidManager')
        self.window.set_default_size(1100, 850)
        self.window.maximize()
        self.window.add_css_class('waydroid-setup')
        css = Gtk.CssProvider()
        css.load_from_data(b"""
            .waydroid-setup { font-size: 18px; }
            .waydroid-setup .title-1 { font-size: 28px; }
            .waydroid-setup button, .waydroid-setup dropdown { min-height: 56px; }
            .waydroid-setup progressbar trough, .waydroid-setup progressbar progress { min-height: 18px; border-radius: 9px; }
            .waydroid-setup expander > title { min-height: 48px; }
            .waydroid-setup textview { font-size: 15px; }
        """)
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        self.window.connect('close-request', lambda *_: self.busy)
        header = Gtk.HeaderBar()
        self.window.set_titlebar(header)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        for edge in ('top', 'bottom', 'start', 'end'):
            getattr(box, 'set_margin_' + edge)(24)
        self.window.set_child(box)
        self.title = Gtk.Label(label='Android on your DC-1', xalign=0)
        self.title.add_css_class('title-1'); box.append(self.title)
        # This status area stays outside the scroller, including on small screens.
        self.status = Gtk.Label(label='Ready to check your system.', xalign=0, wrap=True, selectable=True)
        box.append(self.status)
        self.progress = Gtk.ProgressBar(show_text=True)
        self.progress.set_ellipsize(Pango.EllipsizeMode.END)
        self.progress.set_text('Ready')
        box.append(self.progress)
        self.progress_detail = Gtk.Label(xalign=0, wrap=True, selectable=True)
        box.append(self.progress_detail)
        self.stop_button = Gtk.Button(label='Stop download')
        self.stop_button.set_size_request(-1, 64)
        self.stop_button.set_visible(False)
        self.stop_button.connect('clicked', self.stop_download)
        box.append(self.stop_button)
        self.determinate = False
        GLib.timeout_add(200, self.pulse_progress)
        outer = Gtk.ScrolledWindow(vexpand=True, hscrollbar_policy=Gtk.PolicyType.NEVER)
        box.append(outer)
        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        outer.set_child(content)
        self.guidance = Gtk.Label(xalign=0, wrap=True, selectable=True)
        content.append(self.guidance)
        self.choice = Gtk.DropDown.new_from_strings(['Vanilla — no Google apps', 'GApps — Google Play'])
        self.choice.set_size_request(-1, 64)
        content.append(self.choice)
        self.choice_note = Gtk.Label(xalign=0, wrap=True)
        content.append(self.choice_note)
        self.choice.connect('notify::selected', self.explain_choice)
        self.explain_choice()
        actions = Gtk.Grid(column_spacing=16, row_spacing=16, column_homogeneous=True)
        content.append(actions)
        self.actions = actions
        self.buttons = []
        for index, (label, callback) in enumerate([('Set up Android', self.setup), ('Open Android', self.launch), ('Check / report', self.check), ('Remove Android…', self.confirm_remove)]):
            button = Gtk.Button(label=label, hexpand=True)
            button.set_size_request(-1, 64)
            button.connect('clicked', callback)
            if label == 'Set up Android': button.add_css_class('suggested-action')
            self.buttons.append(button); actions.attach(button, index % 2, index // 2, 1, 1)
        info = Gtk.Expander(label='Help and requirements')
        info_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        info_box.append(Gtk.Label(label='Requires the Waydroid kernel and 6 GiB free. Downloads 1–1.5 GB. Interpreter mode avoids the Android crash but slows apps. Existing Android data is left alone.', xalign=0, wrap=True))
        info_box.append(Gtk.Label(label='GApps includes Google services and may require device registration. Vanilla can use F-Droid or Aurora Store.', xalign=0, wrap=True))
        info_box.append(Gtk.LinkButton.new_with_label('https://github.com/muness/alpine-desktop-apps/tree/main/experiments/waydroid', 'Kernel setup and recovery guide'))
        info_box.append(Gtk.LinkButton.new_with_label('https://docs.waydro.id/faq/google-play-certification', 'Google Play registration instructions'))
        info.set_child(info_box); content.append(info)
        self.text = Gtk.TextView(editable=False, monospace=True, wrap_mode=Gtk.WrapMode.WORD_CHAR)
        for edge in ('top', 'bottom', 'left', 'right'):
            getattr(self.text, 'set_' + edge + '_margin')(12)
        scroll = Gtk.ScrolledWindow(min_content_height=220)
        scroll.set_child(self.text)
        self.details = Gtk.Expander(label='Detailed log and diagnostic report')
        self.details.set_child(scroll); content.append(self.details)
        self.copy = Gtk.Button(label='Copy diagnostic report')
        self.copy.set_size_request(-1, 64)
        self.copy.connect('clicked', self.copy_report); content.append(self.copy)
        self.window.present()
        self.check()

    def set_busy(self, value):
        self.busy = value
        self.stop_button.set_visible(False)
        self.progress.set_visible(value)
        self.progress_detail.set_visible(value)
        for button in self.buttons: button.set_sensitive(not value)
        self.copy.set_sensitive(not value)
        self.choice.set_sensitive(not value)
        if value:
            self.determinate = False
            self.progress.set_fraction(0)
            self.progress.set_text('Working…')
            self.progress_detail.set_text('')

    def pulse_progress(self):
        if self.busy and not self.determinate:
            self.progress.pulse()
        return True

    def stop_download(self, *_):
        process = self.operation_process
        if process is not None and process.poll() is None and process.stdin:
            try:
                process.stdin.write('STOP_DOWNLOAD\n'); process.stdin.flush()
                self.stop_button.set_sensitive(False)
                self.status.set_text('Stopping the download and saving progress…')
            except (BrokenPipeError, OSError):
                self.stop_button.set_visible(False)

    def append(self, text):
        if text in ('DOWNLOAD_ACTIVE', 'DOWNLOAD_INACTIVE'):
            self.stop_button.set_visible(text == 'DOWNLOAD_ACTIVE' and self.busy)
            self.stop_button.set_sensitive(True)
            return False
        match = re.match(r'Downloading ([^:]+): (\d+)% (.*)', text)
        if match:
            self.determinate = True
            self.progress.set_fraction(min(100, int(match[2])) / 100)
            self.progress.set_text(f'{match[1]} download — {match[2]}%')
            self.progress_detail.set_text(match[3])
            self.status.set_text('Downloading Android images. Time remaining is an estimate for this file.')
            # Keep the diagnostic log readable rather than adding every refresh.
            return False
        if self.busy and text and '\n' not in text:
            self.determinate = False
            self.progress.set_fraction(0)
            self.progress.set_text('Working…')
            self.status.set_text(text)
            self.progress_detail.set_text('')
        buffer = self.text.get_buffer()
        buffer.insert(buffer.get_end_iter(), text + '\n')
        return False

    def task(self, argv, action):
        if self.busy: return
        self.set_busy(True)
        self.text.get_buffer().set_text('')
        self.status.set_text('Authenticate in the system prompt to begin.' if action in ('setup', 'remove') else 'Checking your system…')
        def work():
            lines = []
            report_text = ''
            code = 1
            try:
                process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
                self.operation_process = process
                for line in process.stdout:
                    line = line.rstrip(); lines.append(line)
                    GLib.idle_add(self.append, line)
                code = process.wait()
                if action == 'report': report_text = '\n'.join(lines)
                if action in ('setup', 'remove') and code in (126, 127):
                    message = 'Administrator authentication was cancelled or unavailable. No operation started.'
                elif code:
                    message = next((line.removeprefix('ERROR: ') for line in reversed(lines) if line.startswith('ERROR: ')), 'Operation stopped. Copy the report for help, then retry.')
                else:
                    message = 'Setup complete. Open Android to start your session.' if action == 'setup' else ('Android removed. See the report for what was retained.' if action == 'remove' else 'Report ready. Review it before sharing.')
                if action == 'launch' and code == 0:
                    message = 'Android has finished booting. Switch to its window to continue.'
                if action in ('setup', 'remove', 'launch'):
                    # Backend output consists only of authored status lines.
                    self.last_operation = '\n'.join(lines[-12:]) or message
                    diagnostic = subprocess.run(['/usr/bin/python3', BACKEND, 'report'], capture_output=True, text=True, timeout=30)
                    report_text = diagnostic.stdout
                    GLib.idle_add(self.append, '\n' + diagnostic.stdout)
            except (OSError, subprocess.TimeoutExpired):
                message = 'Could not run the helper. Reinstall Waydroid Manager and retry.'
            GLib.idle_add(self.finish, message, report_text, action, code)
        threading.Thread(target=work, daemon=True).start()

    def explain_choice(self, *_):
        self.choice_note.set_text(
            'Google Play and Google services. Device registration may be required.'
            if self.choice.get_selected() == 1 else
            'No Google services. Install Android APKs directly, or add F-Droid or Aurora Store.')

    def apply_report(self, report):
        fields = dict(line.split(': ', 1) for line in report.splitlines() if ': ' in line)
        present = fields.get('Android config') == 'present'
        packaged = fields.get('waydroid', '').startswith('waydroid-')
        ready = present and packaged and fields.get('Interpreter settings') == 'set' and fields.get('Container service') == 'active'
        kernel = fields.get('Kernel requirements') == 'passed'
        self.title.set_text('Android is installed' if ready else 'Finish Android setup' if present else 'Install Android')
        self.guidance.set_text(
            'Open Android to use your apps. Its first startup can take a few minutes. Manage Google accounts and the on-screen keyboard in Android Settings.' if ready else
            'An Android configuration exists, but setup checks are incomplete. Review the diagnostic report before retrying; your data is retained.' if present else
            'Choose an Android image, then tap Set up Android. You need 6 GiB free; downloads resume if interrupted.' if kernel else
            'The running kernel has not passed the requirements check. Open the setup guide below before installing Android.')
        self.choice.set_visible(not present)
        self.choice.set_sensitive(not self.paused and not self.busy)
        self.choice_note.set_visible(not present)
        setup, launch, _, remove = self.buttons
        setup.set_visible(not ready)
        self.actions.remove(launch)
        self.actions.attach(launch, 0 if ready else 1, 0, 2 if ready else 1, 1)
        setup.set_label('Resume setup' if self.paused else 'Retry setup' if present else 'Set up Android')
        setup.set_sensitive(kernel and not self.busy)
        launch.set_sensitive(present and packaged and not self.busy)
        remove.set_sensitive((present or packaged) and not self.busy)
        launch.remove_css_class('suggested-action')
        if ready: launch.add_css_class('suggested-action')
        return ready

    def finish(self, message, report='', action='', code=0):
        self.operation_process = None
        if action == 'remove' and code == 0: self.paused = False
        if action == 'setup': self.paused = 'Download paused.' in message
        self.set_busy(False)
        ready = self.apply_report(report) if report else False
        if action == 'report' and code == 0:
            message = 'Open Android when you’re ready.' if ready else 'Checks complete. Follow the next step below.'
        if action == 'setup' and code == 0:
            message = 'Setup finished. Open Android to continue.'
        self.status.set_text(message)
        self.progress.set_fraction(0)
        self.progress.set_text('Stopped' if code or 'stopped' in message.lower() else 'Finished')
        if code: self.details.set_expanded(True)
        return False

    def check(self, *_):
        self.task(['/usr/bin/python3', BACKEND, 'report'], 'report')

    def setup(self, *_):
        variant = 'gapps' if self.choice.get_selected() == 1 else 'vanilla'
        self.task(['/usr/bin/pkexec', '/usr/bin/python3', BACKEND, 'setup', '--variant', variant], 'setup')

    def confirm_remove(self, *_):
        dialog = Gtk.Dialog(title='Remove Android?', transient_for=self.window, modal=True)
        dialog.add_css_class('waydroid-setup')
        dialog.set_default_size(640, 360)
        dialog.add_button('Cancel', Gtk.ResponseType.CANCEL)
        dialog.set_default_response(Gtk.ResponseType.CANCEL)
        remove_button = dialog.add_button('Remove Android', Gtk.ResponseType.ACCEPT)
        remove_button.add_css_class('destructive-action')
        content = dialog.get_content_area()
        for edge in ('top', 'bottom', 'start', 'end'):
            getattr(content, 'set_margin_' + edge)(20)
        content.set_spacing(16)
        content.append(Gtk.Label(label='This stops Android and removes its packages.\nThe Linux kernel and recovery files stay installed.', wrap=True, xalign=0))
        erase = Gtk.CheckButton(label='Also delete Android apps, data and downloaded images')
        content.append(erase)
        content.append(Gtk.Label(label='Leave unchecked to keep your data. Deletion cannot be undone.\nOnly this desktop user’s Android data is selected.', wrap=True, xalign=0))
        def response(widget, response_id):
            wipe = erase.get_active(); widget.destroy()
            if response_id == Gtk.ResponseType.ACCEPT:
                command = ['/usr/bin/pkexec', '/usr/bin/python3', BACKEND, 'remove']
                if wipe: command.append('--erase-data')
                self.task(command, 'remove')
        dialog.connect('response', response)
        dialog.present()

    def launch(self, *_):
        self.task(['/usr/bin/python3', BACKEND, 'launch'], 'launch')

    def copy_report(self, *_):
        buffer = self.text.get_buffer()
        content = buffer.get_text(buffer.get_start_iter(), buffer.get_end_iter(), True)
        self.window.get_clipboard().set(content + '\n\nLast setup attempt:\n' + self.last_operation)
        self.status.set_text('Report copied. Add what you expected and what happened before posting.')

if __name__ == '__main__':
    sys.exit(SetupApp().run(sys.argv))
