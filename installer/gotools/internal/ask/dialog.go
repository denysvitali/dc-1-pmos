package ask

// The dc1-ask <-> PID 1 dialog protocol.
//
// PID 1 owns the panel (see internal/drm): only a DRM atomic commit lights it,
// and a SECOND modeset blackens it, so the touch UI cannot modeset a buffer of
// its own. Instead the dialogs run inside PID 1, drawing into the surface it
// already committed; dc1-ask is now a thin client that forwards its argv over
// this socket and relays the answer. The CLI contract is unchanged: tui.sh
// still calls `dc1-ask menu TITLE OPT...` and reads the exit code plus stdout,
// and exit 2 still means "UI unusable, fall back to USB".

import (
	"encoding/json"
	"net"
)

// DialogSocket is where dc1-ask reaches PID 1. It lives under /tmp because the
// installer initramfs mounts /tmp as a tmpfs and does not mount /run.
const DialogSocket = "/tmp/dc1-ask.sock"

// DialogRequest carries the client's argv verbatim, so the dispatch logic stays
// in one place (run): the server hands these args straight to Screen.Run.
type DialogRequest struct {
	Args []string `json:"args"`
}

// DialogResponse is the answer in the shape the old subprocess printed it: the
// exit code, the stdout bytes, and the stderr bytes. ask.Main writes Out to
// stdout and Err to stderr, then returns RC, so tui.sh cannot tell the
// difference between the subprocess and the in-process path.
type DialogResponse struct {
	RC  int    `json:"rc"`
	Out string `json:"out"`
	Err string `json:"err"`
}

// Forward runs one dialog request against PID 1's server and reports whether
// the exchange worked at all (ok=false: no server, no answer). It is what lets
// a second applet -- dc1-debug -- drive the same on-panel screens tui.sh uses
// without a second implementation of the socket protocol.
func Forward(args []string) (DialogResponse, bool) {
	return dialog(DialogSocket, args)
}

// dialog performs one request against the dialog server at path. ok is false
// when the server is not reachable or the response cannot be read, which is
// Main's signal to exit 2 -- the callers' "fall back to USB" path.
func dialog(path string, args []string) (DialogResponse, bool) {
	conn, err := net.Dial("unix", path)
	if err != nil {
		return DialogResponse{}, false
	}
	defer conn.Close()
	if err := json.NewEncoder(conn).Encode(DialogRequest{Args: args}); err != nil {
		return DialogResponse{}, false
	}
	var resp DialogResponse
	if err := json.NewDecoder(conn).Decode(&resp); err != nil {
		return DialogResponse{}, false
	}
	return resp, true
}
