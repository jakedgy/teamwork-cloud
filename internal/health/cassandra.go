package health

import (
	"context"
	"errors"
	"net"
	"strconv"
	"time"

	"github.com/gocql/gocql"
)

const cassandraQuery = "SELECT release_version FROM system.local"

// CassandraSession is the small portion of a Cassandra session used by the
// health check.
type CassandraSession interface {
	Query(string, ...any) CassandraQuery
	Close()
}

// CassandraQuery is the executable query used by the health check.
type CassandraQuery interface {
	Exec() error
}

type cassandraSessionFactory func(context.Context) (CassandraSession, error)

// CassandraChecker performs a read-only CQL health query.
type CassandraChecker struct {
	endpoint   string
	newSession cassandraSessionFactory
}

// NewCassandraChecker creates a checker for one host:port endpoint.
func NewCassandraChecker(endpoint string) (*CassandraChecker, error) {
	host, portText, err := net.SplitHostPort(endpoint)
	if err != nil || host == "" {
		return nil, errors.New("invalid cassandra endpoint")
	}
	port, err := strconv.Atoi(portText)
	if err != nil || port < 1 || port > 65535 {
		return nil, errors.New("invalid cassandra endpoint")
	}

	return newCassandraChecker(endpoint, func(ctx context.Context) (CassandraSession, error) {
		timeout := 3 * time.Second
		if deadline, ok := ctx.Deadline(); ok {
			remaining := time.Until(deadline)
			if remaining <= 0 {
				return nil, ctx.Err()
			}
			if remaining < timeout {
				timeout = remaining
			}
		}
		cluster := gocql.NewCluster(host)
		cluster.Port = port
		cluster.ConnectTimeout = timeout
		cluster.Timeout = timeout
		cluster.NumConns = 1
		cluster.DisableInitialHostLookup = true
		session, err := cluster.CreateSession()
		if err != nil {
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			return nil, err
		}
		return gocqlSession{session: session, ctx: ctx}, nil
	}), nil
}

func newCassandraChecker(endpoint string, factory cassandraSessionFactory) *CassandraChecker {
	return &CassandraChecker{endpoint: endpoint, newSession: factory}
}

func (c *CassandraChecker) Name() string     { return "cassandra" }
func (c *CassandraChecker) Endpoint() string { return c.endpoint }

func (c *CassandraChecker) Check(ctx context.Context) error {
	session, err := c.newSession(ctx)
	if err != nil {
		return sanitizedCheckError(ctx, "cassandra check failed")
	}
	defer session.Close()
	if err := session.Query(cassandraQuery).Exec(); err != nil {
		return sanitizedCheckError(ctx, "cassandra check failed")
	}
	return nil
}

type gocqlSession struct {
	session *gocql.Session
	ctx     context.Context
}

func (s gocqlSession) Query(statement string, values ...any) CassandraQuery {
	return s.session.Query(statement, values...).WithContext(s.ctx)
}

func (s gocqlSession) Close() { s.session.Close() }
