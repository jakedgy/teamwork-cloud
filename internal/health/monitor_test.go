package health

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

type fakeChecker struct {
	name     string
	endpoint string
	delay    time.Duration
	err      error
}

func (c fakeChecker) Name() string     { return c.name }
func (c fakeChecker) Endpoint() string { return c.endpoint }

func (c fakeChecker) Check(ctx context.Context) error {
	if c.delay > 0 {
		select {
		case <-time.After(c.delay):
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	return c.err
}

func TestMonitorCheckNowRunsChecksConcurrently(t *testing.T) {
	monitor := NewMonitor([]Checker{
		fakeChecker{name: "cassandra", endpoint: "cassandra:9042", delay: 80 * time.Millisecond},
		fakeChecker{name: "zookeeper", endpoint: "zookeeper:2181", delay: 80 * time.Millisecond},
	}, time.Second)

	started := time.Now()
	monitor.CheckNow(context.Background())
	if elapsed := time.Since(started); elapsed >= 140*time.Millisecond {
		t.Fatalf("CheckNow took %s; checks did not complete concurrently", elapsed)
	}
}

func TestMonitorCheckNowMarksSuccessfulChecksReady(t *testing.T) {
	monitor := NewMonitor([]Checker{
		fakeChecker{name: "cassandra", endpoint: "cassandra:9042"},
	}, time.Second)

	monitor.CheckNow(context.Background())
	result := monitor.Snapshot()[0]
	if result.Status != StatusReady {
		t.Fatalf("Status = %q, want %q", result.Status, StatusReady)
	}
	if result.LastSuccessAt.IsZero() {
		t.Fatal("LastSuccessAt was not recorded")
	}
	if !result.CheckedAt.Equal(result.LastSuccessAt) {
		t.Fatalf("CheckedAt = %s, LastSuccessAt = %s; want equal timestamps", result.CheckedAt, result.LastSuccessAt)
	}
	if result.Error != "" {
		t.Fatalf("Error = %q, want empty", result.Error)
	}
}

func TestMonitorCheckNowMarksFailedChecksUnavailable(t *testing.T) {
	monitor := NewMonitor([]Checker{
		fakeChecker{name: "artemis", endpoint: "artemis:61616", err: errors.New("broker refused connection")},
	}, time.Second)

	monitor.CheckNow(context.Background())
	result := monitor.Snapshot()[0]
	if result.Status != StatusUnavailable {
		t.Fatalf("Status = %q, want %q", result.Status, StatusUnavailable)
	}
	if result.Error != "broker refused connection" {
		t.Fatalf("Error = %q, want check error", result.Error)
	}
	if !result.LastSuccessAt.IsZero() {
		t.Fatalf("LastSuccessAt = %s, want zero", result.LastSuccessAt)
	}
}

func TestMonitorCheckNowReportsTimeout(t *testing.T) {
	monitor := NewMonitor([]Checker{
		fakeChecker{name: "zookeeper", endpoint: "zookeeper:2181", delay: 100 * time.Millisecond},
	}, 10*time.Millisecond)

	monitor.CheckNow(context.Background())
	result := monitor.Snapshot()[0]
	if result.Status != StatusUnavailable {
		t.Fatalf("Status = %q, want %q", result.Status, StatusUnavailable)
	}
	if result.Error != "check timed out" {
		t.Fatalf("Error = %q, want %q", result.Error, "check timed out")
	}
}

func TestMonitorCheckNowPreservesLastSuccessAfterFailure(t *testing.T) {
	checker := &fakeChecker{name: "cassandra", endpoint: "cassandra:9042"}
	monitor := NewMonitor([]Checker{checker}, time.Second)

	monitor.CheckNow(context.Background())
	lastSuccess := monitor.Snapshot()[0].LastSuccessAt
	checker.err = errors.New("connection refused")
	monitor.CheckNow(context.Background())

	result := monitor.Snapshot()[0]
	if result.Status != StatusUnavailable {
		t.Fatalf("Status = %q, want %q", result.Status, StatusUnavailable)
	}
	if !result.LastSuccessAt.Equal(lastSuccess) {
		t.Fatalf("LastSuccessAt = %s, want preserved %s", result.LastSuccessAt, lastSuccess)
	}
}

func TestMonitorSnapshotReturnsNameSortedDefensiveCopy(t *testing.T) {
	monitor := NewMonitor([]Checker{
		fakeChecker{name: "zookeeper", endpoint: "zookeeper:2181"},
		fakeChecker{name: "artemis", endpoint: "artemis:61616"},
		fakeChecker{name: "cassandra", endpoint: "cassandra:9042"},
	}, time.Second)

	snapshot := monitor.Snapshot()
	if got, want := []string{snapshot[0].Name, snapshot[1].Name, snapshot[2].Name}, []string{"artemis", "cassandra", "zookeeper"}; got[0] != want[0] || got[1] != want[1] || got[2] != want[2] {
		t.Fatalf("Snapshot names = %v, want %v", got, want)
	}
	snapshot[0].Name = "changed"
	snapshot[0].Status = StatusReady

	again := monitor.Snapshot()
	if again[0].Name != "artemis" || again[0].Status != StatusStarting {
		t.Fatalf("Snapshot mutation affected monitor state: %+v", again[0])
	}
}

func TestMonitorCheckNowLimitsErrorsToPrintableCharacters(t *testing.T) {
	monitor := NewMonitor([]Checker{
		fakeChecker{name: "artemis", endpoint: "artemis:61616", err: errors.New(strings.Repeat("x", 200) + "\nsecret")},
	}, time.Second)

	monitor.CheckNow(context.Background())
	result := monitor.Snapshot()[0]
	if len([]rune(result.Error)) != 160 {
		t.Fatalf("Error length = %d, want 160", len([]rune(result.Error)))
	}
	if strings.ContainsAny(result.Error, "\n\r\t") {
		t.Fatalf("Error contains non-printable characters: %q", result.Error)
	}
}

type recordingChecker struct {
	checks chan<- struct{}
}

func (c recordingChecker) Name() string     { return "cassandra" }
func (c recordingChecker) Endpoint() string { return "cassandra:9042" }
func (c recordingChecker) Check(context.Context) error {
	c.checks <- struct{}{}
	return nil
}

func TestMonitorRunChecksImmediatelyAndOnEachTick(t *testing.T) {
	checks := make(chan struct{}, 2)
	monitor := NewMonitor([]Checker{recordingChecker{checks: checks}}, time.Second)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		monitor.Run(ctx, 10*time.Millisecond)
		close(done)
	}()

	for range 2 {
		select {
		case <-checks:
		case <-time.After(time.Second):
			t.Fatal("monitor did not check immediately and on the next tick")
		}
	}
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("Run did not stop after context cancellation")
	}
}
