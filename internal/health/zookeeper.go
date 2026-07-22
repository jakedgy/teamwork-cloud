package health

import (
	"context"
	"errors"
	"io"
	"net"
)

// ZooKeeperChecker performs the ZooKeeper four-letter health exchange.
type ZooKeeperChecker struct {
	endpoint string
	dialer   net.Dialer
}

func NewZooKeeperChecker(endpoint string) *ZooKeeperChecker {
	return &ZooKeeperChecker{endpoint: endpoint}
}

func (c *ZooKeeperChecker) Name() string     { return "zookeeper" }
func (c *ZooKeeperChecker) Endpoint() string { return c.endpoint }

func (c *ZooKeeperChecker) Check(ctx context.Context) error {
	conn, err := c.dialer.DialContext(ctx, "tcp", c.endpoint)
	if err != nil {
		return sanitizedCheckError(ctx, "zookeeper connection failed")
	}
	defer conn.Close()
	stop := bindConnectionToContext(ctx, conn)
	defer stop()

	if _, err := io.WriteString(conn, "ruok"); err != nil {
		return sanitizedCheckError(ctx, "zookeeper protocol check failed")
	}
	response := make([]byte, 4)
	if _, err := io.ReadFull(conn, response); err != nil || string(response) != "imok" {
		return sanitizedCheckError(ctx, "zookeeper protocol check failed")
	}
	return nil
}

func sanitizedCheckError(ctx context.Context, message string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	return errors.New(message)
}

func bindConnectionToContext(ctx context.Context, conn net.Conn) func() {
	if deadline, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(deadline)
	}
	done := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			_ = conn.Close()
		case <-done:
		}
	}()
	return func() { close(done) }
}
