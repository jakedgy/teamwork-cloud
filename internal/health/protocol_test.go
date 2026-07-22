package health

import (
	"bufio"
	"context"
	"errors"
	"io"
	"net"
	"strings"
	"testing"
	"time"
)

type fakeCassandraQuery struct {
	err error
}

func (q fakeCassandraQuery) Exec() error { return q.err }

type fakeCassandraSession struct {
	query  string
	closed bool
	err    error
}

func (s *fakeCassandraSession) Query(statement string, _ ...any) CassandraQuery {
	s.query = statement
	return fakeCassandraQuery{err: s.err}
}

func (s *fakeCassandraSession) Close() { s.closed = true }

func TestCassandraCheckQueriesSystemLocalAndClosesSession(t *testing.T) {
	session := &fakeCassandraSession{}
	checker := newCassandraChecker("cassandra.example:9042", func(context.Context) (CassandraSession, error) {
		return session, nil
	})

	if err := checker.Check(context.Background()); err != nil {
		t.Fatalf("Check() error = %v", err)
	}
	if session.query != "SELECT release_version FROM system.local" {
		t.Fatalf("query = %q", session.query)
	}
	if !session.closed {
		t.Fatal("session was not closed")
	}
	if checker.Name() != "cassandra" || checker.Endpoint() != "cassandra.example:9042" {
		t.Fatalf("checker identity = %q, %q", checker.Name(), checker.Endpoint())
	}
}

func TestCassandraCheckClosesSessionAfterQueryFailure(t *testing.T) {
	session := &fakeCassandraSession{err: errors.New("database detail")}
	checker := newCassandraChecker("cassandra:9042", func(context.Context) (CassandraSession, error) {
		return session, nil
	})

	err := checker.Check(context.Background())
	if err == nil || err.Error() != "cassandra check failed" {
		t.Fatalf("Check() error = %v, want sanitized error", err)
	}
	if !session.closed {
		t.Fatal("session was not closed")
	}
}

func TestCassandraCheckPreservesCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	checker := newCassandraChecker("cassandra:9042", func(ctx context.Context) (CassandraSession, error) {
		return nil, ctx.Err()
	})

	if err := checker.Check(ctx); !errors.Is(err, context.Canceled) {
		t.Fatalf("Check() error = %v, want context.Canceled", err)
	}
}

func TestNewCassandraCheckerRejectsMalformedEndpoint(t *testing.T) {
	if _, err := NewCassandraChecker("missing-port"); err == nil {
		t.Fatal("NewCassandraChecker() error = nil, want malformed endpoint error")
	}
}

func TestZooKeeperCheckExchangesRuokImok(t *testing.T) {
	endpoint, done := serveOnce(t, func(conn net.Conn) {
		request := make([]byte, 4)
		if _, err := io.ReadFull(conn, request); err != nil {
			t.Errorf("read request: %v", err)
			return
		}
		if string(request) != "ruok" {
			t.Errorf("request = %q, want ruok", request)
			return
		}
		_, _ = io.WriteString(conn, "imok")
	})

	checker := NewZooKeeperChecker(endpoint)
	if err := checker.Check(context.Background()); err != nil {
		t.Fatalf("Check() error = %v", err)
	}
	<-done
	if checker.Name() != "zookeeper" || checker.Endpoint() != endpoint {
		t.Fatalf("checker identity = %q, %q", checker.Name(), checker.Endpoint())
	}
}

func TestZooKeeperCheckRejectsMalformedResponse(t *testing.T) {
	endpoint, done := serveOnce(t, func(conn net.Conn) { _, _ = io.WriteString(conn, "nope") })
	err := NewZooKeeperChecker(endpoint).Check(context.Background())
	<-done
	if err == nil || err.Error() != "zookeeper protocol check failed" {
		t.Fatalf("Check() error = %v, want sanitized protocol error", err)
	}
}

func TestZooKeeperCheckReportsRefusalWithoutInternalDetails(t *testing.T) {
	endpoint := refusedEndpoint(t)
	err := NewZooKeeperChecker(endpoint).Check(context.Background())
	if err == nil || err.Error() != "zookeeper connection failed" {
		t.Fatalf("Check() error = %v, want sanitized connection error", err)
	}
}

func TestZooKeeperCheckHonorsCancellation(t *testing.T) {
	endpoint, accepted := serveUntilClientCloses(t)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- NewZooKeeperChecker(endpoint).Check(ctx) }()
	<-accepted
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("Check() error = %v, want context.Canceled", err)
		}
	case <-time.After(time.Second):
		t.Fatal("Check did not return after cancellation")
	}
}

func TestArtemisCheckSendsRawConnectHeadersAndAcceptsConnected(t *testing.T) {
	password := "se:cr\\et"
	endpoint, done := serveOnce(t, func(conn net.Conn) {
		frame, err := bufio.NewReader(conn).ReadString(0)
		if err != nil {
			t.Errorf("read frame: %v", err)
			return
		}
		for _, expected := range []string{
			"CONNECT\n", "accept-version:1.2\n", "login:user:name\n",
			"passcode:se:cr\\et\n", "\n\x00",
		} {
			if !strings.Contains(frame, expected) {
				t.Errorf("CONNECT frame missing %q: %q", expected, frame)
			}
		}
		_, _ = io.WriteString(conn, "CONNECTED\r\nversion:1.2\r\nserver:broker:name\\value\r\n\r\n\x00")
	})

	checker := NewArtemisChecker(endpoint, "user:name", password)
	if err := checker.Check(context.Background()); err != nil {
		t.Fatalf("Check() error = %v", err)
	}
	<-done
	if checker.Name() != "artemis" || checker.Endpoint() != endpoint {
		t.Fatalf("checker identity = %q, %q", checker.Name(), checker.Endpoint())
	}
}

func TestArtemisCheckRejectsCredentialLineBreaksBeforeDial(t *testing.T) {
	tests := []struct {
		name     string
		user     string
		password string
	}{
		{name: "login newline", user: "user\nadmin", password: "secret"},
		{name: "login carriage return", user: "user\radmin", password: "secret"},
		{name: "passcode newline", user: "user", password: "secret\nheader:value"},
		{name: "passcode carriage return", user: "user", password: "secret\rheader:value"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			err := NewArtemisChecker("127.0.0.1:1", test.user, test.password).Check(context.Background())
			if err == nil || err.Error() != "artemis credentials invalid" {
				t.Fatalf("Check() error = %v, want sanitized credential error", err)
			}
			if strings.Contains(err.Error(), test.user) || strings.Contains(err.Error(), test.password) {
				t.Fatalf("Check() error leaked credential: %v", err)
			}
		})
	}
}

func TestArtemisCheckValidatesConnectedHeaders(t *testing.T) {
	tests := []struct {
		name     string
		response string
	}{
		{name: "missing version", response: "CONNECTED\nserver:broker\n\n\x00"},
		{name: "wrong version", response: "CONNECTED\nversion:1.1\n\n\x00"},
		{name: "malformed header", response: "CONNECTED\nversion:1.2\nmalformed\n\n\x00"},
		{name: "missing blank line", response: "CONNECTED\nversion:1.2\x00"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			endpoint, done := serveOnce(t, func(conn net.Conn) {
				_, _ = bufio.NewReader(conn).ReadString(0)
				_, _ = io.WriteString(conn, test.response)
			})
			err := NewArtemisChecker(endpoint, "artemis", "secret").Check(context.Background())
			<-done
			if err == nil || err.Error() != "artemis protocol check failed" {
				t.Fatalf("Check() error = %v, want sanitized protocol error", err)
			}
		})
	}
}

func TestArtemisCheckRejectsMalformedAndOversizedResponses(t *testing.T) {
	tests := []struct {
		name     string
		response string
	}{
		{name: "malformed", response: "ERROR\nmessage:password is bad\n\nsecret-body\x00"},
		{name: "oversized", response: "CONNECTED\n" + strings.Repeat("x", 8192) + "\x00"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			endpoint, done := serveOnce(t, func(conn net.Conn) {
				_, _ = bufio.NewReader(conn).ReadString(0)
				_, _ = io.WriteString(conn, test.response)
			})
			password := "correct-horse-battery-staple"
			err := NewArtemisChecker(endpoint, "artemis", password).Check(context.Background())
			<-done
			if err == nil || err.Error() != "artemis protocol check failed" {
				t.Fatalf("Check() error = %v, want sanitized protocol error", err)
			}
			if strings.Contains(err.Error(), password) || strings.Contains(err.Error(), "secret-body") {
				t.Fatalf("Check() error leaked secret or broker body: %v", err)
			}
		})
	}
}

func TestArtemisCheckReportsRefusalWithoutPassword(t *testing.T) {
	password := "do-not-leak"
	err := NewArtemisChecker(refusedEndpoint(t), "artemis", password).Check(context.Background())
	if err == nil || err.Error() != "artemis connection failed" || strings.Contains(err.Error(), password) {
		t.Fatalf("Check() error = %v, want sanitized connection error", err)
	}
}

func TestArtemisCheckHonorsCancellation(t *testing.T) {
	endpoint, accepted := serveUntilClientCloses(t)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- NewArtemisChecker(endpoint, "artemis", "secret").Check(ctx) }()
	<-accepted
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("Check() error = %v, want context.Canceled", err)
		}
	case <-time.After(time.Second):
		t.Fatal("Check did not return after cancellation")
	}
}

func serveOnce(t *testing.T, serve func(net.Conn)) (string, <-chan struct{}) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		defer listener.Close()
		conn, err := listener.Accept()
		if err != nil {
			t.Errorf("accept: %v", err)
			return
		}
		defer conn.Close()
		serve(conn)
	}()
	return listener.Addr().String(), done
}

func serveUntilClientCloses(t *testing.T) (string, <-chan struct{}) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	accepted := make(chan struct{})
	go func() {
		defer listener.Close()
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		close(accepted)
		_, _ = io.Copy(io.Discard, conn)
		_ = conn.Close()
	}()
	return listener.Addr().String(), accepted
}

func refusedEndpoint(t *testing.T) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	endpoint := listener.Addr().String()
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	return endpoint
}
