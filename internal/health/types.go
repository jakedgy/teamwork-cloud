package health

import (
	"context"
	"time"
)

// Checker reports the reachability of one dependency. Check must honor context
// cancellation and deadlines.
type Checker interface {
	Name() string
	Endpoint() string
	Check(context.Context) error
}

// Status describes the most recent dependency check outcome.
type Status string

const (
	StatusStarting    Status = "starting"
	StatusReady       Status = "ready"
	StatusUnavailable Status = "unavailable"
)

// Result is the current health state for one dependency.
type Result struct {
	Name          string    `json:"name"`
	Endpoint      string    `json:"endpoint"`
	Status        Status    `json:"status"`
	CheckedAt     time.Time `json:"checkedAt"`
	LastSuccessAt time.Time `json:"lastSuccessAt,omitempty,omitzero"`
	LatencyMillis int64     `json:"latencyMillis"`
	Error         string    `json:"error,omitempty"`
}
