// exec_socket_bridge is the guest-side helper for Transport.ExecBridge.
// Stdin carries bytes to the Unix peer. Stdout starts with OCB1, followed by
// frames with a one-byte type and a four-byte big-endian length. Type 0 carries
// at most 16 KiB of data. Type 1 carries no bytes and ends the output only.
package main

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"time"
)

const (
	dataFrame = 0
	eofFrame  = 1
	frameSize = 16 * 1024
)

func main() {
	if len(os.Args) != 2 || !filepath.IsAbs(os.Args[1]) {
		fmt.Fprintln(os.Stderr, "usage: exec_socket_bridge /absolute/unix/socket")
		os.Exit(2)
	}

	if err := bridge(os.Args[1], os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func bridge(path string, input io.Reader, output io.Writer) error {
	dialer := net.Dialer{Timeout: 5 * time.Second}
	connection, err := dialer.Dial("unix", path)
	if err != nil {
		return fmt.Errorf("dial engine: %w", err)
	}
	defer connection.Close()

	peer := connection.(*net.UnixConn)
	if err := write(output, []byte("OCB1")); err != nil {
		return fmt.Errorf("write protocol header: %w", err)
	}

	done := make(chan error, 2)
	go func() {
		if _, err := io.Copy(peer, input); err != nil {
			done <- fmt.Errorf("forward input: %w", err)
			return
		}
		if err := peer.CloseWrite(); err != nil {
			done <- fmt.Errorf("half-close peer input: %w", err)
			return
		}
		done <- nil
	}()
	go func() {
		done <- forwardOutput(output, peer)
	}()

	for range 2 {
		if err := <-done; err != nil {
			return err
		}
	}
	return nil
}

func forwardOutput(output io.Writer, peer io.Reader) error {
	frame := make([]byte, frameSize+5)
	for {
		size, err := peer.Read(frame[5:])
		if size > 0 {
			frame[0] = dataFrame
			binary.BigEndian.PutUint32(frame[1:5], uint32(size))
			if err := write(output, frame[:size+5]); err != nil {
				return fmt.Errorf("forward peer output: %w", err)
			}
		}

		if errors.Is(err, io.EOF) {
			frame[0] = eofFrame
			clear(frame[1:5])
			return write(output, frame[:5])
		}
		if err != nil {
			return fmt.Errorf("read peer output: %w", err)
		}
	}
}

func write(output io.Writer, data []byte) error {
	size, err := output.Write(data)
	if err == nil && size != len(data) {
		return io.ErrShortWrite
	}
	return err
}
