package cmdrunner

import (
	"context"
	"fmt"
	"strings"
	"sync"
)

// Call records one invocation made through a Fake.
type Call struct {
	Name  string
	Args  []string
	Stdin []byte
}

// Line renders the call the way a naive logger would, so tests can assert
// that no secret would have appeared in such a log.
func (c Call) Line() string {
	return c.Name + " " + strings.Join(c.Args, " ")
}

// Fake is a Runner for tests. Func, when set, produces the reply; otherwise
// every call succeeds with empty output.
type Fake struct {
	Func func(name string, args []string, stdin []byte) ([]byte, error)

	mu    sync.Mutex
	calls []Call
}

// Run implements Runner.
func (f *Fake) Run(_ context.Context, name string, args []string, stdin []byte) ([]byte, error) {
	f.mu.Lock()
	f.calls = append(f.calls, Call{Name: name, Args: append([]string(nil), args...), Stdin: append([]byte(nil), stdin...)})
	f.mu.Unlock()
	if f.Func == nil {
		return nil, nil
	}
	return f.Func(name, args, stdin)
}

// Calls returns a copy of everything Run has seen.
func (f *Fake) Calls() []Call {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]Call(nil), f.calls...)
}

// FindCall returns the first recorded call to name.
func (f *Fake) FindCall(name string) (Call, error) {
	for _, c := range f.Calls() {
		if c.Name == name {
			return c, nil
		}
	}
	return Call{}, fmt.Errorf("no call to %q", name)
}
