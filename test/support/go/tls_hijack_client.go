// tls_hijack_client is a test-only Go TLS client for the Cowboy fixture. The
// Docker CLI hijacks over Go's crypto/tls, and only a Go client sends a TLS
// close_notify with tls.Conn.CloseWrite while keeping its read side open.
// OTP clients close both directions themselves.
//
// Usage: tls_hijack_client ADDR CAFILE MODE
//
//	MODE engine-first: read output to EOF, then send "late-input" and CloseWrite.
//	MODE client-first: send "client-input", CloseWrite, then read to EOF.
//
// Every observation is printed as one line on stdout: HEAD, OUTPUT, READ,
// WROTE, CLOSEWRITE, each with a Go-quoted value.
package main

import (
	"bufio"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"time"
)

func main() {
	if len(os.Args) != 4 {
		fmt.Fprintln(os.Stderr, "usage: tls_hijack_client ADDR CAFILE MODE")
		os.Exit(2)
	}
	if err := run(os.Args[1], os.Args[2], os.Args[3]); err != nil {
		fmt.Println("FAIL", strconv.Quote(err.Error()))
		os.Exit(1)
	}
}

func run(addr, cafile, mode string) error {
	pem, err := os.ReadFile(cafile)
	if err != nil {
		return err
	}
	pool := x509.NewCertPool()
	pool.AppendCertsFromPEM(pem)

	conn, err := tls.Dial("tcp", addr, &tls.Config{
		RootCAs:    pool,
		ServerName: "localhost",
		MinVersion: tls.VersionTLS13,
		NextProtos: []string{"http/1.1"},
	})
	if err != nil {
		return err
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(10 * time.Second))

	body := `{"Detach":false,"Tty":false}`
	request := "POST /v1.57/exec/fixture/start HTTP/1.1\r\nHost: docker\r\n" +
		"Content-Type: application/json\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n" +
		"Content-Length: " + strconv.Itoa(len(body)) + "\r\n\r\n" + body
	if _, err := io.WriteString(conn, request); err != nil {
		return err
	}

	reader := bufio.NewReader(conn)
	var head strings.Builder
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			return fmt.Errorf("read head: %w", err)
		}
		head.WriteString(line)
		if line == "\r\n" {
			break
		}
	}
	fmt.Println("HEAD", strconv.Quote(head.String()))

	switch mode {
	case "engine-first":
		output, err := io.ReadAll(reader)
		fmt.Println("OUTPUT", strconv.Quote(string(output)))
		fmt.Println("READ", strconv.Quote(errorText(err)))
		_, err = io.WriteString(conn, "late-input")
		fmt.Println("WROTE", strconv.Quote(errorText(err)))
		err = conn.CloseWrite()
		fmt.Println("CLOSEWRITE", strconv.Quote(errorText(err)))
		// Hold the connection until the server ends it.
		_, _ = io.Copy(io.Discard, reader)
	case "client-first":
		_, err := io.WriteString(conn, "client-input")
		fmt.Println("WROTE", strconv.Quote(errorText(err)))
		err = conn.CloseWrite()
		fmt.Println("CLOSEWRITE", strconv.Quote(errorText(err)))
		output, err := io.ReadAll(reader)
		fmt.Println("OUTPUT", strconv.Quote(string(output)))
		fmt.Println("READ", strconv.Quote(errorText(err)))
	default:
		return fmt.Errorf("unknown mode %q", mode)
	}
	return nil
}

func errorText(err error) string {
	if err == nil {
		return "ok"
	}
	return err.Error()
}
