package health

import (
	"context"
	"errors"
	"sort"
	"sync"
	"time"
	"unicode"
)

// Monitor aggregates the health of a fixed set of dependency checkers.
type Monitor struct {
	checkers []Checker
	timeout  time.Duration

	mu      sync.RWMutex
	results map[string]Result
}

// NewMonitor creates a monitor with each dependency in its starting state.
func NewMonitor(checkers []Checker, timeout time.Duration) *Monitor {
	monitor := &Monitor{
		checkers: append([]Checker(nil), checkers...),
		timeout:  timeout,
		results:  make(map[string]Result, len(checkers)),
	}
	for _, checker := range checkers {
		monitor.results[checker.Name()] = Result{
			Name:     checker.Name(),
			Endpoint: checker.Endpoint(),
			Status:   StatusStarting,
		}
	}
	return monitor
}

// CheckNow runs all dependency checks concurrently and records their outcomes.
func (m *Monitor) CheckNow(ctx context.Context) {
	var checks sync.WaitGroup
	checks.Add(len(m.checkers))
	for _, checker := range m.checkers {
		go func(checker Checker) {
			defer checks.Done()

			checkContext, cancel := context.WithTimeout(ctx, m.timeout)
			defer cancel()
			started := time.Now()
			err := checker.Check(checkContext)
			checkedAt := time.Now()

			m.record(checker, checkedAt, time.Since(started), err)
		}(checker)
	}
	checks.Wait()
}

func (m *Monitor) record(checker Checker, checkedAt time.Time, latency time.Duration, err error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	result := m.results[checker.Name()]
	result.CheckedAt = checkedAt
	result.LatencyMillis = latency.Milliseconds()
	if err == nil {
		result.Status = StatusReady
		result.LastSuccessAt = checkedAt
		result.Error = ""
	} else {
		result.Status = StatusUnavailable
		if errors.Is(err, context.DeadlineExceeded) {
			result.Error = "check timed out"
		} else {
			result.Error = safeError(err.Error())
		}
	}
	m.results[checker.Name()] = result
}

// Run checks dependencies immediately, then at interval, until ctx is canceled.
func (m *Monitor) Run(ctx context.Context, interval time.Duration) {
	m.CheckNow(ctx)
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			m.CheckNow(ctx)
		}
	}
}

// Snapshot returns a name-sorted copy of the latest dependency results.
func (m *Monitor) Snapshot() []Result {
	m.mu.RLock()
	results := make([]Result, 0, len(m.results))
	for _, result := range m.results {
		results = append(results, result)
	}
	m.mu.RUnlock()

	sort.Slice(results, func(i, j int) bool {
		return results[i].Name < results[j].Name
	})
	return results
}

func safeError(message string) string {
	const maxPrintable = 160
	output := make([]rune, 0, maxPrintable)
	for _, char := range message {
		if !unicode.IsPrint(char) {
			continue
		}
		output = append(output, char)
		if len(output) == maxPrintable {
			break
		}
	}
	return string(output)
}
