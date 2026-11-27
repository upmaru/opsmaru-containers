package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestRecordRoundTrip(t *testing.T) {
	records := []logRecord{
		{Stream: streamStdout, Run: 7, Time: 1_700_000_000_123_456_789, Data: []byte("out\n")},
		{Stream: streamStderr, Flags: partialFlag, Run: 7, Time: 2, Data: []byte{0xff, 0, 'x'}},
	}
	var buffer bytes.Buffer
	buffer.WriteString(logMagic)
	for _, record := range records {
		buffer.Write(record.encode())
	}
	decoded, err := decodeLogs(bytes.NewReader(buffer.Bytes()))
	if err != nil || len(decoded) != 2 {
		t.Fatalf("%v %v", decoded, err)
	}
	for i := range records {
		if decoded[i].Stream != records[i].Stream || decoded[i].Flags != records[i].Flags ||
			decoded[i].Run != records[i].Run || decoded[i].Time != records[i].Time ||
			!bytes.Equal(decoded[i].Data, records[i].Data) {
			t.Errorf("record %d: %+v", i, decoded[i])
		}
	}
	if _, err := decodeLogs(bytes.NewReader(buffer.Bytes()[:buffer.Len()-1])); err == nil {
		t.Error("torn record accepted")
	}
	if _, err := decodeLogs(strings.NewReader("NOPE")); err == nil {
		t.Error("bad magic accepted")
	}
}

func TestCopierSplitsAndFlushesPartials(t *testing.T) {
	dir := t.TempDir()
	logger, err := openLogger(dir, LogSpec{Driver: "local", MaxSize: 1 << 20, MaxFiles: 2})
	if err != nil {
		t.Fatal(err)
	}
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	c := startCopier(reader, streamStdout, 1, logger)

	long := strings.Repeat("a", recordMax+10) + "\n"
	write(t, writer, "one\ntwo\n"+long+"tail")
	time.Sleep(3 * partialFlush)
	write(t, writer, "-more\n")
	writer.Close()
	c.drain(time.Now().Add(time.Second))
	if err := logger.Close(); err != nil {
		t.Fatal(err)
	}

	records := readAll(t, dir)
	got := make([]string, len(records))
	for i, record := range records {
		mark := ""
		if record.Flags&partialFlag != 0 {
			mark = "~"
		}
		got[i] = mark + summarize(record.Data)
	}
	want := []string{"one\n", "two\n", "~a*16384", "a*10\n", "~tail", "-more\n"}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("got %q want %q", got, want)
	}
}

func TestDrainEndsWhileADescendantHoldsThePipe(t *testing.T) {
	dir := t.TempDir()
	logger, err := openLogger(dir, LogSpec{Driver: "local", MaxSize: 1 << 20, MaxFiles: 1})
	if err != nil {
		t.Fatal(err)
	}
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer writer.Close()
	c := startCopier(reader, streamStderr, 1, logger)
	write(t, writer, "held")
	start := time.Now()
	c.drain(time.Now().Add(300 * time.Millisecond))
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Fatalf("drain took %v", elapsed)
	}
	logger.Close()
	if records := readAll(t, dir); len(records) != 1 || string(records[0].Data) != "held" || records[0].Flags != partialFlag {
		t.Fatalf("%+v", records)
	}
}

func TestRotationKeepsNumberedFiles(t *testing.T) {
	dir := t.TempDir()
	spec := LogSpec{Driver: "local", MaxSize: minLogSize, MaxFiles: 3}
	logger, err := openLogger(dir, spec)
	if err != nil {
		t.Fatal(err)
	}
	line := []byte(strings.Repeat("x", 1000) + "\n")
	for i := 0; i < 40; i++ {
		logger.send(logRecord{Stream: streamStdout, Run: 1, Time: int64(i), Data: line})
	}
	logger.Close()

	names := logNames(t, dir)
	if len(names) != 3 {
		t.Fatalf("kept %v", names)
	}
	for _, name := range names {
		info, _ := os.Stat(filepath.Join(dir, name))
		if info.Size() > minLogSize+int64(recordHeader+len(line)) {
			t.Errorf("%s is %d bytes", name, info.Size())
		}
	}
	if names[2] != "0000000008.log" {
		t.Fatalf("newest %v", names)
	}

	// A new logger continues the newest file and reports its run.
	logger, err = openLogger(dir, spec)
	if err != nil {
		t.Fatal(err)
	}
	if logger.lastRun != 1 || logger.number != 9 {
		t.Fatalf("continued %d run %d", logger.number, logger.lastRun)
	}
	logger.Close()
}

func TestDamagedFileStartsANewOne(t *testing.T) {
	dir := t.TempDir()
	mustWrite(t, filepath.Join(dir, "0000000004.log"), logMagic+"garbage")
	logger, err := openLogger(dir, LogSpec{Driver: "local", MaxSize: 1 << 20, MaxFiles: 5})
	if err != nil {
		t.Fatal(err)
	}
	logger.send(logRecord{Stream: streamStdout, Run: 1, Time: 1, Data: []byte("ok\n")})
	logger.Close()
	if names := logNames(t, dir); len(names) != 2 || names[1] != "0000000005.log" {
		t.Fatalf("%v", names)
	}
}

func TestNoneDriverWritesNothing(t *testing.T) {
	dir := t.TempDir()
	logger, err := openLogger(dir, LogSpec{Driver: "none", MaxSize: minLogSize, MaxFiles: 1})
	if err != nil {
		t.Fatal(err)
	}
	logger.send(logRecord{Stream: streamStdout, Run: 1, Time: 1, Data: []byte("x\n")})
	logger.Close()
	if names := logNames(t, dir); len(names) != 0 {
		t.Fatalf("%v", names)
	}
}

func write(t *testing.T, file *os.File, data string) {
	t.Helper()
	if _, err := file.WriteString(data); err != nil {
		t.Fatal(err)
	}
}

func logNames(t *testing.T, dir string) []string {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, entry := range entries {
		if logName.MatchString(entry.Name()) {
			names = append(names, entry.Name())
		}
	}
	return names
}

func readAll(t *testing.T, dir string) []logRecord {
	t.Helper()
	var all []logRecord
	for _, name := range logNames(t, dir) {
		file, err := os.Open(filepath.Join(dir, name))
		if err != nil {
			t.Fatal(err)
		}
		records, err := decodeLogs(file)
		file.Close()
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		all = append(all, records...)
	}
	return all
}

func summarize(data []byte) string {
	body := bytes.TrimSuffix(data, []byte("\n"))
	suffix := string(data[len(body):])
	if len(body) >= 10 && bytes.Count(body, body[:1]) == len(body) {
		return string(body[:1]) + "*" + strconv.Itoa(len(body)) + suffix
	}
	return string(data)
}
