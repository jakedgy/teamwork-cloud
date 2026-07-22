package health

import (
	"context"
	"encoding/json"
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
	started  chan<- struct{}
	release  <-chan struct{}
}

func (c fakeChecker) Name() string     { return c.name }
func (c fakeChecker) Endpoint() string { return c.endpoint }

func (c fakeChecker) Check(ctx context.Context) error {
	if c.started != nil {
		select {
		case c.started <- struct{}{}:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	if c.release != nil {
		select {
		case <-c.release:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	if c.delay > 0 {
		select {
		case <-time.After(c.delay):
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	return c.err
}

func newMonitor(t *testing.T, checkers []Checker, timeout time.Duration) *Monitor {
	t.Helper()
	monitor, err := NewMonitor(checkers, timeout)
	if err != nil {
		t.Fatalf("NewMonitor() error = %v", err)
	}
	return monitor
}

func TestMonitorCheckNowRunsChecksConcurrently(t *testing.T) {
	started := make(chan struct{}, 2)
	release := make(chan struct{})
	monitor := newMonitor(t, []Checker{
		fakeChecker{name: "cassandra", endpoint: "cassandra:9042", started: started, release: release},
		fakeChecker{name: "zookeeper", endpoint: "zookeeper:2181", started: started, release: release},
	}, time.Second)
	done := make(chan struct{})
	go func() {
		monitor.CheckNow(context.Background())
		close(done)
	}()

	for range 2 {
		select {
		case <-started:
		case <-time.After(time.Second):
			t.Fatal("checks did not both start before either was released")
		}
	}
	close(release)
	<-done
}

func TestMonitorCheckNowMarksSuccessfulChecksReady(t *testing.T) {
	monitor := newMonitor(t, []Checker{
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
	monitor := newMonitor(t, []Checker{
		fakeChecker{name: "artemis", endpoint: "artemis:61616", err: errors.New("broker refused connection")},
	}, time.Second)

	monitor.CheckNow(context.Background())
	result := monitor.Snapshot()[0]
	if result.Status != StatusUnavailable {
		t.Fatalf("Status = %q, want %q", result.Status, StatusUnavailable)
	}
	if result.Error != "check failed" {
		t.Fatalf("Error = %q, want generic failure", result.Error)
	}
	if !result.LastSuccessAt.IsZero() {
		t.Fatalf("LastSuccessAt = %s, want zero", result.LastSuccessAt)
	}
}

func TestMonitorCheckNowReportsTimeout(t *testing.T) {
	monitor := newMonitor(t, []Checker{
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
	monitor := newMonitor(t, []Checker{checker}, time.Second)

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
	monitor := newMonitor(t, []Checker{
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

func TestMonitorCheckNowDoesNotExposeCheckerErrorText(t *testing.T) {
	secret := "password=correct-horse token=abc123\n" + strings.Repeat("x", 200)
	monitor := newMonitor(t, []Checker{
		fakeChecker{name: "artemis", endpoint: "artemis:61616", err: errors.New(secret)},
	}, time.Second)

	monitor.CheckNow(context.Background())
	result := monitor.Snapshot()[0]
	if result.Error != "check failed" {
		t.Fatalf("Error = %q, want generic failure", result.Error)
	}
	if strings.Contains(result.Error, "password") || strings.Contains(result.Error, "abc123") {
		t.Fatalf("Error exposed checker secret: %q", result.Error)
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
	monitor := newMonitor(t, []Checker{recordingChecker{checks: checks}}, time.Second)
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

func TestResultJSONOmitsZeroLastSuccessAt(t *testing.T) {
	monitor := newMonitor(t, []Checker{fakeChecker{name: "cassandra", endpoint: "cassandra:9042"}}, time.Second)
	assertLastSuccessAtOmitted(t, monitor.Snapshot()[0])

	failed := newMonitor(t, []Checker{fakeChecker{name: "artemis", endpoint: "artemis:61616", err: errors.New("failed")}}, time.Second)
	failed.CheckNow(context.Background())
	assertLastSuccessAtOmitted(t, failed.Snapshot()[0])
}

func TestResultJSONIncludesLastSuccessAtAfterSuccess(t *testing.T) {
	monitor := newMonitor(t, []Checker{fakeChecker{name: "cassandra", endpoint: "cassandra:9042"}}, time.Second)
	monitor.CheckNow(context.Background())

	encoded, err := json.Marshal(monitor.Snapshot()[0])
	if err != nil {
		t.Fatalf("json.Marshal() error = %v", err)
	}
	var value map[string]any
	if err := json.Unmarshal(encoded, &value); err != nil {
		t.Fatalf("json.Unmarshal() error = %v", err)
	}
	if _, ok := value["lastSuccessAt"]; !ok {
		t.Fatalf("JSON = %s, missing lastSuccessAt after successful check", encoded)
	}
}

func assertLastSuccessAtOmitted(t *testing.T, result Result) {
	t.Helper()
	encoded, err := json.Marshal(result)
	if err != nil {
		t.Fatalf("json.Marshal() error = %v", err)
	}
	var value map[string]any
	if err := json.Unmarshal(encoded, &value); err != nil {
		t.Fatalf("json.Unmarshal() error = %v", err)
	}
	if _, ok := value["lastSuccessAt"]; ok {
		t.Fatalf("JSON = %s, unexpectedly contains zero lastSuccessAt", encoded)
	}
}

func TestNewMonitorRejectsInvalidConfiguration(t *testing.T) {
	tests := []struct {
		name     string
		checkers []Checker
		timeout  time.Duration
	}{
		{name: "empty checker name", checkers: []Checker{fakeChecker{endpoint: "cassandra:9042"}}, timeout: time.Second},
		{name: "duplicate checker name", checkers: []Checker{fakeChecker{name: "cassandra"}, fakeChecker{name: "cassandra"}}, timeout: time.Second},
		{name: "zero timeout", checkers: []Checker{fakeChecker{name: "cassandra"}}, timeout: 0},
		{name: "negative timeout", checkers: []Checker{fakeChecker{name: "cassandra"}}, timeout: -time.Second},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if monitor, err := NewMonitor(test.checkers, test.timeout); err == nil || monitor != nil {
				t.Fatalf("NewMonitor() = %v, %v; want nil monitor and error", monitor, err)
			}
		})
	}
}
