package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"sync/atomic"
	"time"
)

const (
	logMagic      = "OCL1"
	recordHeader  = 18
	recordMax     = 16 * 1024
	partialFlag   = 1
	streamStdout  = 1
	streamStderr  = 2
	partialFlush  = 100 * time.Millisecond
	logRecordsCap = 256
)

var logName = regexp.MustCompile(`^([0-9]{10})\.log$`)

type logRecord struct {
	Stream byte
	Flags  byte
	Run    uint32
	Time   int64
	Data   []byte
}

func (record logRecord) encode() []byte {
	out := make([]byte, recordHeader+len(record.Data))
	out[0] = record.Stream
	out[1] = record.Flags
	binary.BigEndian.PutUint32(out[2:6], record.Run)
	binary.BigEndian.PutUint64(out[6:14], uint64(record.Time))
	binary.BigEndian.PutUint32(out[14:18], uint32(len(record.Data)))
	copy(out[recordHeader:], record.Data)
	return out
}

// decodeLogs reads one log file: the magic, then records until EOF.
func decodeLogs(reader io.Reader) ([]logRecord, error) {
	magic := make([]byte, len(logMagic))
	if _, err := io.ReadFull(reader, magic); err != nil {
		return nil, fmt.Errorf("read magic: %w", err)
	}
	if string(magic) != logMagic {
		return nil, errors.New("bad log magic")
	}
	var records []logRecord
	header := make([]byte, recordHeader)
	for {
		if _, err := io.ReadFull(reader, header); err != nil {
			if errors.Is(err, io.EOF) {
				return records, nil
			}
			return records, err
		}
		size := binary.BigEndian.Uint32(header[14:18])
		stream := header[0]
		if size == 0 || size > recordMax || (stream != streamStdout && stream != streamStderr) || header[1]&^partialFlag != 0 {
			return records, errors.New("malformed log record")
		}
		data := make([]byte, size)
		if _, err := io.ReadFull(reader, data); err != nil {
			return records, io.ErrUnexpectedEOF
		}
		records = append(records, logRecord{
			Stream: stream,
			Flags:  header[1],
			Run:    binary.BigEndian.Uint32(header[2:6]),
			Time:   int64(binary.BigEndian.Uint64(header[6:14])),
			Data:   data,
		})
	}
}

// Logger owns the log directory. One goroutine writes records in the order
// the stream copiers send them.
type Logger struct {
	dir      string
	maxSize  int64
	maxFiles int
	discard  bool
	records  chan logRecord
	done     chan struct{}
	file     *os.File
	number   uint64
	size     int64
	failing  bool
	dropped  uint64
	// lastRun is the newest run in the file being continued.
	lastRun uint32
}

func openLogger(dir string, spec LogSpec) (*Logger, error) {
	logger := &Logger{
		dir:      dir,
		maxSize:  spec.MaxSize,
		maxFiles: spec.MaxFiles,
		discard:  spec.Driver == "none",
		records:  make(chan logRecord, logRecordsCap),
		done:     make(chan struct{}),
	}
	if !logger.discard {
		if err := logger.openCurrent(); err != nil {
			return nil, err
		}
	}
	go logger.loop()
	return logger, nil
}

func (logger *Logger) send(record logRecord) {
	logger.records <- record
}

// Close writes every queued record, then syncs and closes the file.
func (logger *Logger) Close() error {
	close(logger.records)
	<-logger.done
	if logger.file == nil {
		return nil
	}
	syncErr := logger.file.Sync()
	closeErr := logger.file.Close()
	if logger.dropped > 0 {
		warn("dropped %d log records", logger.dropped)
	}
	return errors.Join(syncErr, closeErr)
}

func (logger *Logger) loop() {
	defer close(logger.done)
	for record := range logger.records {
		if logger.discard {
			continue
		}
		logger.write(record)
	}
}

func (logger *Logger) write(record logRecord) {
	if logger.file == nil {
		if err := logger.openNext(); err != nil {
			logger.drop(err)
			return
		}
	}
	data := record.encode()
	written, err := logger.file.Write(data)
	if err != nil || written != len(data) {
		// Never leave a torn record: cut the file back to the last whole one.
		_ = logger.file.Truncate(logger.size)
		_, _ = logger.file.Seek(logger.size, io.SeekStart)
		if err == nil {
			err = io.ErrShortWrite
		}
		logger.drop(err)
		return
	}
	logger.failing = false
	logger.size += int64(written)
	if logger.size >= logger.maxSize {
		// The next record opens the next file.
		_ = logger.file.Sync()
		_ = logger.file.Close()
		logger.file = nil
	}
}

func (logger *Logger) drop(err error) {
	logger.dropped++
	if !logger.failing {
		warn("log write failed: %v", err)
		logger.failing = true
	}
}

func (logger *Logger) numbers() ([]uint64, error) {
	entries, err := os.ReadDir(logger.dir)
	if err != nil {
		return nil, err
	}
	var numbers []uint64
	for _, entry := range entries {
		match := logName.FindStringSubmatch(entry.Name())
		if match == nil || !entry.Type().IsRegular() {
			continue
		}
		number, err := strconv.ParseUint(match[1], 10, 64)
		if err == nil && number > 0 {
			numbers = append(numbers, number)
		}
	}
	slices.Sort(numbers)
	return numbers, nil
}

// openCurrent continues the newest file if it is whole and below max_size.
func (logger *Logger) openCurrent() error {
	numbers, err := logger.numbers()
	if err != nil {
		return err
	}
	if len(numbers) == 0 {
		return logger.openNext()
	}
	logger.number = numbers[len(numbers)-1]
	path := logger.path(logger.number)
	file, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		return logger.openNext()
	}
	records, decodeErr := decodeLogsFile(file)
	if len(records) > 0 {
		logger.lastRun = records[len(records)-1].Run
	}
	info, statErr := file.Stat()
	if decodeErr != nil || statErr != nil || info.Size() >= logger.maxSize {
		file.Close()
		if decodeErr != nil {
			warn("log file %s is damaged after %d records; starting a new file", path, len(records))
		}
		return logger.openNext()
	}
	if _, err := file.Seek(0, io.SeekEnd); err != nil {
		file.Close()
		return err
	}
	logger.file = file
	logger.size = info.Size()
	return nil
}

func decodeLogsFile(file *os.File) ([]logRecord, error) {
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return nil, err
	}
	return decodeLogs(file)
}

func (logger *Logger) openNext() error {
	logger.number++
	file, err := os.OpenFile(logger.path(logger.number), os.O_RDWR|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	if _, err := file.Write([]byte(logMagic)); err != nil {
		file.Close()
		return err
	}
	logger.file = file
	logger.size = int64(len(logMagic))
	logger.prune()
	return nil
}

func (logger *Logger) prune() {
	numbers, err := logger.numbers()
	if err != nil {
		return
	}
	for len(numbers) > logger.maxFiles {
		_ = os.Remove(logger.path(numbers[0]))
		numbers = numbers[1:]
	}
}

func (logger *Logger) path(number uint64) string {
	return filepath.Join(logger.dir, fmt.Sprintf("%010d.log", number))
}

// copier turns one output pipe into log records: split at newlines and at
// 16 KiB, with trailing bytes flushed as a partial record after 100 ms.
type copier struct {
	reader  *os.File
	stream  byte
	run     uint32
	logger  *Logger
	drainBy atomic.Int64
	done    chan struct{}
}

func startCopier(reader *os.File, stream byte, run uint32, logger *Logger) *copier {
	c := &copier{reader: reader, stream: stream, run: run, logger: logger, done: make(chan struct{})}
	go c.loop()
	return c
}

// drain ends the copier at the deadline even if a descendant keeps the pipe open.
func (c *copier) drain(deadline time.Time) {
	c.drainBy.Store(deadline.UnixNano())
	_ = c.reader.SetReadDeadline(deadline)
	<-c.done
	c.reader.Close()
}

func (c *copier) loop() {
	defer close(c.done)
	buffer := make([]byte, recordMax)
	var pending []byte
	var pendingAt time.Time
	for {
		deadline := time.Time{}
		if len(pending) > 0 {
			deadline = pendingAt.Add(partialFlush)
		}
		if drainBy := c.drainBy.Load(); drainBy != 0 {
			at := time.Unix(0, drainBy)
			if deadline.IsZero() || at.Before(deadline) {
				deadline = at
			}
		}
		_ = c.reader.SetReadDeadline(deadline)
		size, err := c.reader.Read(buffer)
		now := time.Now()
		if size > 0 {
			if len(pending) == 0 {
				pendingAt = now
			}
			pending = append(pending, buffer[:size]...)
			pending = c.emitLines(pending, now)
			if len(pending) == 0 {
				pendingAt = time.Time{}
			}
		}
		if err == nil {
			continue
		}
		if errors.Is(err, os.ErrDeadlineExceeded) {
			if len(pending) > 0 && !now.Before(pendingAt.Add(partialFlush)) {
				c.emit(pending, partialFlag, pendingAt)
				pending = nil
			}
			if drainBy := c.drainBy.Load(); drainBy != 0 && !now.Before(time.Unix(0, drainBy)) {
				break
			}
			continue
		}
		break
	}
	if len(pending) > 0 {
		c.emit(pending, partialFlag, pendingAt)
	}
}

func (c *copier) emitLines(pending []byte, now time.Time) []byte {
	for {
		index := bytes.IndexByte(pending, '\n')
		if index < 0 {
			break
		}
		line := pending[:index+1]
		for len(line) > recordMax {
			c.emit(line[:recordMax], partialFlag, now)
			line = line[recordMax:]
		}
		c.emit(line, 0, now)
		pending = pending[index+1:]
	}
	for len(pending) >= recordMax {
		c.emit(pending[:recordMax], partialFlag, now)
		pending = pending[recordMax:]
	}
	return slices.Clone(pending)
}

func (c *copier) emit(data []byte, flags byte, at time.Time) {
	c.logger.send(logRecord{
		Stream: c.stream,
		Flags:  flags,
		Run:    c.run,
		Time:   at.UnixNano(),
		Data:   slices.Clone(data),
	})
}
