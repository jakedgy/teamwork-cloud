package health

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"
)

// Monitor aggregates the health of a fixed set of dependency checkers.
type Monitor struct {
	checkers []monitorChecker
	timeout  time.Duration

	mu      sync.RWMutex
	results map[string]Result
}

type monitorChecker struct {
	checker Checker
	name    string
}

// NewMonitor creates a monitor with each dependency in its starting state.
func NewMonitor(checkers []Checker, timeout time.Duration) (*Monitor, error) {
	if timeout <= 0 {
		return nil, errors.New("health check timeout must be positive")
	}

	monitor := &Monitor{
		timeout: timeout,
		results: make(map[string]Result, len(checkers)),
	}
	for _, checker := range checkers {
		if checker == nil {
			return nil, errors.New("health checker must not be nil")
		}
		name := checker.Name()
		if strings.TrimSpace(name) == "" {
			return nil, errors.New("health checker name must not be empty")
		}
		if _, exists := monitor.results[name]; exists {
			return nil, fmt.Errorf("duplicate health checker name %q", name)
		}
		endpoint := checker.Endpoint()
		monitor.checkers = append(monitor.checkers, monitorChecker{
			checker: checker,
			name:    name,
		})
		monitor.results[name] = Result{
			Name:     name,
			Endpoint: endpoint,
			Status:   StatusStarting,
		}
	}
	return monitor, nil
}

// CheckNow runs all dependency checks concurrently and records their outcomes.
func (m *Monitor) CheckNow(ctx context.Context) {
	var checks sync.WaitGroup
	checks.Add(len(m.checkers))
	for _, checker := range m.checkers {
		go func(checker monitorChecker) {
			defer checks.Done()

			checkContext, cancel := context.WithTimeout(ctx, m.timeout)
			defer cancel()
			started := time.Now()
			err := checker.checker.Check(checkContext)
			checkedAt := time.Now()

			m.record(checker, checkedAt, time.Since(started), err)
		}(checker)
	}
	checks.Wait()
}

func (m *Monitor) record(checker monitorChecker, checkedAt time.Time, latency time.Duration, err error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	result := m.results[checker.name]
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
		} else if errors.Is(err, context.Canceled) {
			result.Error = "check canceled"
		} else {
			result.Error = "check failed"
		}
	}
	m.results[checker.name] = result
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
