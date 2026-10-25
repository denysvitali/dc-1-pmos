import http.server,threading,tempfile,subprocess,time,signal,hashlib
from pathlib import Path
import unittest,shutil,textwrap

class AriaResumeTest(unittest.TestCase):
 @unittest.skipUnless(shutil.which("aria2c"), "aria2c is not installed")
 def test_real_interruption_resume(self):
  payload=bytes(range(256))*32768
  ranges=[]
  class Handler(http.server.BaseHTTPRequestHandler):
   def log_message(self,*args): pass
   def do_GET(self):
    header=self.headers.get('Range');start=int(header.split('=')[1].split('-')[0]) if header else 0
    ranges.append(start)
    end=int(header.split('-')[1]) if header and header.split('-')[1] else len(payload)-1
    end=min(end,len(payload)-1)
    self.send_response(206 if header else 200)
    self.send_header('Content-Length',str(end-start+1));self.send_header('Accept-Ranges','bytes')
    if header:self.send_header('Content-Range',f'bytes {start}-{end}/{len(payload)}')
    self.end_headers()
    try:
     for offset in range(start,end+1,65536):
      self.wfile.write(payload[offset:min(offset+65536,end+1)]);self.wfile.flush();time.sleep(.01)
    except (BrokenPipeError,ConnectionResetError): pass
  server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
  threading.Thread(target=server.serve_forever,daemon=True).start()
  with tempfile.TemporaryDirectory() as d:
   command=['aria2c','--no-conf=true','--continue=true','--file-allocation=none','--auto-save-interval=1','--dir='+d,'--out=image.partial',f'http://127.0.0.1:{server.server_port}/image']
   p=subprocess.Popen(command,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
   time.sleep(.6);p.send_signal(signal.SIGINT);p.wait(timeout=10)
   assert Path(d,'image.partial.aria2').exists()
   ranges.clear()
   subprocess.run(command,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True,timeout=20)
   assert any(start>0 for start in ranges),ranges
   assert hashlib.sha256(Path(d,'image.partial').read_bytes()).digest()==hashlib.sha256(payload).digest()
   print('Real aria2 interruption/resume passed: nonzero Range request, complete SHA256 match')
  server.shutdown()
  server.server_close()

 @unittest.skipUnless(shutil.which("aria2c"), "aria2c is not installed")
 def test_manager_stop_and_resume(self):
  payload=bytes(range(256))*131072
  ranges=[]
  class Handler(http.server.BaseHTTPRequestHandler):
   def log_message(self,*args): pass
   def do_GET(self):
    header=self.headers.get('Range');start=int(header.split('=')[1].split('-')[0]) if header else 0
    ranges.append(start)
    end=int(header.split('-')[1]) if header and header.split('-')[1] else len(payload)-1
    end=min(end,len(payload)-1)
    self.send_response(206 if header else 200)
    self.send_header('Content-Length',str(end-start+1));self.send_header('Accept-Ranges','bytes')
    if header:self.send_header('Content-Range',f'bytes {start}-{end}/{len(payload)}')
    self.end_headers()
    try:
     for offset in range(start,end+1,65536):
      self.wfile.write(payload[offset:min(offset+65536,end+1)]);self.wfile.flush();time.sleep(.05)
    except (BrokenPipeError,ConnectionResetError): pass
  server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
  threading.Thread(target=server.serve_forever,daemon=True).start()
  code = """
  import importlib.util,sys,threading
  from pathlib import Path
  spec=importlib.util.spec_from_file_location('backend','/usr/local/lib/dc1-waydroid-setup/backend.py');b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)
  threading.Thread(target=b.listen_for_stop,daemon=True).start()
  pin={'filename':'test.zip','url':sys.argv[2],'id':sys.argv[3],'size':int(sys.argv[4]),'romtype':'TEST'}
  try: b.download(pin,Path(sys.argv[1]))
  except b.SetupError as error: print(error,flush=True);sys.exit(1)
  """
  with tempfile.TemporaryDirectory() as d:
   code = textwrap.dedent(code).replace('/usr/local/lib/dc1-waydroid-setup/backend.py', str(Path(__file__).with_name('backend.py').resolve()))
   command=['python3','-u','-c',code,d,f'http://127.0.0.1:{server.server_port}/image',hashlib.sha256(payload).hexdigest(),str(len(payload))]
   p=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
   for line in p.stdout:
    if line.startswith('Downloading TEST:'):
     p.stdin.write('STOP_DOWNLOAD\n');p.stdin.flush();break
   out=p.communicate(timeout=15)[0]
   assert p.returncode==1 and 'Download paused.' in out,out
   assert Path(d,'test.partial.aria2').exists()
   ranges.clear()
   result=subprocess.run(command,input='',capture_output=True,text=True,timeout=30)
   assert result.returncode==0,result.stdout+result.stderr
   assert any(start>0 for start in ranges),ranges
   assert Path(d,'test.zip').read_bytes()==payload
   print('Manager STOP_DOWNLOAD protocol: aria2 stopped, metadata retained, resumed Range and SHA256 passed')
  server.shutdown()
  server.server_close()

if __name__ == "__main__": unittest.main()
