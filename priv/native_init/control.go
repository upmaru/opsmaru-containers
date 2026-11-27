package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"time"
)

const (
	controlLimit   = 4096
	controlTimeout = 5 * time.Second
)

type controlRequest struct {
	Op      string `json:"op"`
	Signal  string `json:"signal,omitempty"`
	Timeout *int   `json:"timeout,omitempty"`
}

type controlResponse struct {
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
}

type controlCall struct {
	request controlRequest
	reply   chan controlResponse
}

// serveControl accepts one request per connection and hands it to the init
// loop, which owns the child.
func serveControl(path string, calls chan<- controlCall) (net.Listener, error) {
	_ = os.Remove(path)
	listener, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(path, 0o600); err != nil {
		listener.Close()
		return nil, err
	}
	go func() {
		for {
			connection, err := listener.Accept()
			if err != nil {
				return
			}
			go handleControl(connection, calls)
		}
	}()
	return listener, nil
}

func handleControl(connection net.Conn, calls chan<- controlCall) {
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(controlTimeout))
	line, err := bufio.NewReader(io.LimitReader(connection, controlLimit)).ReadBytes('\n')
	response := controlResponse{}
	var request controlRequest
	switch {
	case err != nil:
		response.Error = "read request: " + err.Error()
	case json.Unmarshal(line, &request) != nil:
		response.Error = "malformed request"
	default:
		reply := make(chan controlResponse, 1)
		select {
		case calls <- controlCall{request, reply}:
			response = <-reply
		case <-time.After(controlTimeout):
			response.Error = "init is busy"
		}
	}
	data, _ := json.Marshal(response)
	_, _ = connection.Write(append(data, '\n'))
}

func callControl(path string, request controlRequest) error {
	connection, err := net.DialTimeout("unix", path, controlTimeout)
	if err != nil {
		return fmt.Errorf("container is not running: %w", err)
	}
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(2 * controlTimeout))
	data, _ := json.Marshal(request)
	if _, err := connection.Write(append(data, '\n')); err != nil {
		return err
	}
	line, err := bufio.NewReader(io.LimitReader(connection, controlLimit)).ReadBytes('\n')
	if err != nil {
		return fmt.Errorf("read reply: %w", err)
	}
	var response controlResponse
	if err := json.Unmarshal(line, &response); err != nil {
		return errors.New("malformed reply")
	}
	if !response.OK {
		return errors.New(response.Error)
	}
	return nil
}

func runKill(paths Paths, args []string) int {
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "usage: init kill SIGNAL")
		return 2
	}
	if _, err := parseSignal(args[0]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 2
	}
	if err := callControl(paths.Control, controlRequest{Op: "kill", Signal: args[0]}); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	return 0
}

func runStop(paths Paths, args []string) int {
	flags := flag.NewFlagSet("stop", flag.ContinueOnError)
	signal := flags.String("signal", "", "stop signal; the spec's stop_signal when empty")
	timeout := flags.Int("timeout", 10, "seconds before SIGKILL; negative waits forever")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 {
		return 2
	}
	if *signal != "" {
		if _, err := parseSignal(*signal); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 2
		}
	}
	if err := callControl(paths.Control, controlRequest{Op: "stop", Signal: *signal, Timeout: timeout}); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	return 0
}
