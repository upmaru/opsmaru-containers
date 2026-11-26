package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// TestMain lets the exit-code tests run main in a child process.
func TestMain(m *testing.M) {
	if os.Getenv("EXEC_SOCKET_BRIDGE_MAIN") == "1" {
		os.Args = append([]string{"exec_socket_bridge"}, os.Args[len(os.Args)-countArgs():]...)
		main()
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func countArgs() int {
	switch os.Getenv("EXEC_SOCKET_BRIDGE_ARGS") {
	case "0":
		return 0
	default:
		return 1
	}
}

// listen starts a Unix peer in a private directory and returns its path and
// the next accepted connection.
func listen(t *testing.T) (string, <-chan *net.UnixConn) {
	t.Helper()
	// A short directory: Unix socket paths are limited to about 104 bytes.
	dir, err := os.MkdirTemp("", "ocb")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	path := filepath.Join(dir, "engine.sock")
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })

	accepted := make(chan *net.UnixConn, 1)
	go func() {
		connection, err := listener.AcceptUnix()
		if err == nil {
			accepted <- connection
		}
	}()
	return path, accepted
}

type frame struct {
	kind byte
	data []byte
}

// readFrames decodes helper output after checking the header.
func readFrames(t *testing.T, output io.Reader) <-chan frame {
	t.Helper()
	frames := make(chan frame, 64)
	go func() {
		defer close(frames)
		header := make([]byte, 4)
		if _, err := io.ReadFull(output, header); err != nil || string(header) != "OCB1" {
			frames <- frame{kind: 255, data: header}
			return
		}
		for {
			head := make([]byte, 5)
			if _, err := io.ReadFull(output, head); err != nil {
				return
			}
			size := binary.BigEndian.Uint32(head[1:])
			data := make([]byte, size)
			if _, err := io.ReadFull(output, data); err != nil {
				return
			}
			frames <- frame{kind: head[0], data: data}
		}
	}()
	return frames
}

func next(t *testing.T, frames <-chan frame) frame {
	t.Helper()
	select {
	case f, ok := <-frames:
		if !ok {
			t.Fatal("output ended without a frame")
		}
		return f
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for a frame")
	}
	return frame{}
}

type run struct {
	input  *io.PipeWriter
	frames <-chan frame
	done   chan error
	peer   *net.UnixConn
}

func start(t *testing.T) run {
	t.Helper()
	path, accepted := listen(t)
	inputReader, input := io.Pipe()
	output, outputWriter := io.Pipe()
	done := make(chan error, 1)

	go func() {
		err := bridge(path, inputReader, outputWriter)
		outputWriter.Close()
		done <- err
	}()

	frames := readFrames(t, output)
	var peer *net.UnixConn
	select {
	case peer = <-accepted:
	case <-time.After(5 * time.Second):
		t.Fatal("bridge never dialed the peer")
	}
	t.Cleanup(func() { peer.Close() })
	return run{input: input, frames: frames, done: done, peer: peer}
}

func wait(t *testing.T, done <-chan error) error {
	t.Helper()
	select {
	case err := <-done:
		return err
	case <-time.After(5 * time.Second):
		t.Fatal("bridge did not finish")
	}
	return nil
}

func TestHeaderAndFrameBounds(t *testing.T) {
	r := start(t)
	payload := bytes.Repeat([]byte("x"), 3*frameSize+7)

	go func() {
		r.peer.Write(payload)
		r.peer.CloseWrite()
	}()

	var received []byte
	for {
		f := next(t, r.frames)
		if f.kind == 255 {
			t.Fatalf("bad header %q", f.data)
		}
		if f.kind == eofFrame {
			if len(f.data) != 0 {
				t.Fatalf("EOF frame carried %d bytes", len(f.data))
			}
			break
		}
		if f.kind != dataFrame || len(f.data) < 1 || len(f.data) > frameSize {
			t.Fatalf("frame type %d with %d bytes", f.kind, len(f.data))
		}
		received = append(received, f.data...)
	}
	if !bytes.Equal(received, payload) {
		t.Fatalf("received %d bytes, want %d", len(received), len(payload))
	}

	r.input.Close()
	if err := wait(t, r.done); err != nil {
		t.Fatal(err)
	}
}

func TestOutputEOFBeforeInputEOF(t *testing.T) {
	r := start(t)

	r.peer.Write([]byte("out"))
	r.peer.CloseWrite()
	if f := next(t, r.frames); f.kind != dataFrame || string(f.data) != "out" {
		t.Fatalf("got %d %q", f.kind, f.data)
	}
	if f := next(t, r.frames); f.kind != eofFrame {
		t.Fatalf("got frame type %d, want EOF", f.kind)
	}

	// Input still reaches the peer after output has ended.
	go func() {
		r.input.Write([]byte("late input"))
		r.input.Close()
	}()
	got, err := io.ReadAll(r.peer)
	if err != nil || string(got) != "late input" {
		t.Fatalf("peer read %q, %v", got, err)
	}
	if err := wait(t, r.done); err != nil {
		t.Fatal(err)
	}
}

func TestInputEOFBeforeOutputEOF(t *testing.T) {
	r := start(t)

	go func() {
		r.input.Write([]byte("request"))
		r.input.Close()
	}()
	got, err := io.ReadAll(r.peer)
	if err != nil || string(got) != "request" {
		t.Fatalf("peer read %q, %v", got, err)
	}

	// Output still flows after the peer saw input EOF.
	r.peer.Write([]byte("response"))
	r.peer.CloseWrite()
	if f := next(t, r.frames); f.kind != dataFrame || string(f.data) != "response" {
		t.Fatalf("got %d %q", f.kind, f.data)
	}
	if f := next(t, r.frames); f.kind != eofFrame {
		t.Fatalf("got frame type %d, want EOF", f.kind)
	}
	if err := wait(t, r.done); err != nil {
		t.Fatal(err)
	}
}

func runMain(t *testing.T, stdin io.Reader, args ...string) (int, []byte) {
	t.Helper()
	command := exec.Command(os.Args[0], append([]string{"-test.run=^$"}, args...)...)
	command.Env = append(os.Environ(), "EXEC_SOCKET_BRIDGE_MAIN=1")
	if len(args) == 0 {
		command.Env = append(command.Env, "EXEC_SOCKET_BRIDGE_ARGS=0")
	}
	command.Stdin = stdin
	var stdout bytes.Buffer
	command.Stdout = &stdout
	err := command.Run()

	var exit *exec.ExitError
	switch {
	case err == nil:
		return 0, stdout.Bytes()
	case errors.As(err, &exit):
		return exit.ExitCode(), stdout.Bytes()
	default:
		t.Fatal(err)
	}
	return -1, nil
}

func TestExitCodes(t *testing.T) {
	t.Run("0 after both directions end", func(t *testing.T) {
		path, accepted := listen(t)
		go func() {
			peer := <-accepted
			defer peer.Close()
			io.ReadAll(peer)
			peer.Write([]byte("bye"))
			peer.CloseWrite()
		}()

		code, stdout := runMain(t, bytes.NewReader([]byte("hi")), path)
		want := append([]byte("OCB1"), 0, 0, 0, 0, 3)
		want = append(want, []byte("bye")...)
		want = append(want, eofFrame, 0, 0, 0, 0)
		if code != 0 || !bytes.Equal(stdout, want) {
			t.Fatalf("exit %d, stdout %q", code, stdout)
		}
	})

	t.Run("1 when the peer cannot be dialed", func(t *testing.T) {
		missing := filepath.Join(t.TempDir(), "missing.sock")
		if code, stdout := runMain(t, nil, missing); code != 1 || len(stdout) != 0 {
			t.Fatalf("exit %d, stdout %q", code, stdout)
		}
	})

	t.Run("2 for a relative socket path", func(t *testing.T) {
		if code, _ := runMain(t, nil, "relative.sock"); code != 2 {
			t.Fatalf("exit %d", code)
		}
	})

	t.Run("2 without a socket path", func(t *testing.T) {
		if code, _ := runMain(t, nil); code != 2 {
			t.Fatalf("exit %d", code)
		}
	})
}
