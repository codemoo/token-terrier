// Package sse broadcasts UsageSnapshot frames to subscribed HTTP clients
// over server-sent events.
package sse

import (
	"context"
	"sync"
	"time"

	"github.com/codemoo/token-terrier/server-go/internal/wire"
)

// Hub is a per-provider SSE broadcaster. Frames published into it fan out
// to every subscriber's bounded buffer; slow subscribers drop oldest events
// rather than blocking the broadcaster.
type Hub struct {
	mu                sync.Mutex
	clients           map[int]*client
	latestSnapshot    *wire.SSEEvent
	heartbeatInterval time.Duration
	closed            bool
	nextID            int
}

// client owns one subscriber's send channel. Each client carries its own
// mutex so the multiple-producer / single-consumer model (broadcaster +
// heartbeat goroutine → client.out, SSE handler ← client.out) avoids the
// classic "send on closed channel" panic without serializing producers
// across clients.
type client struct {
	mu     sync.Mutex
	out    chan wire.SSEEvent
	cancel context.CancelFunc
	closed bool // protected by mu; mu also guards close(out) so `send` and
	// `close` are mutually exclusive on this client.
}

// send is best-effort: drops oldest then re-enqueues if the buffer is full
// (matches Swift's bufferingNewest(1) policy). Returns silently when the
// client is already closed.
func (c *client) send(event wire.SSEEvent) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return
	}
	select {
	case c.out <- event:
	default:
		select {
		case <-c.out:
		default:
		}
		select {
		case c.out <- event:
		default:
		}
	}
}

// shutdown closes the client's send channel and cancels its heartbeat ctx.
// Idempotent — safe to call from both unsubscribe and Hub.Close.
func (c *client) shutdown() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return
	}
	c.closed = true
	if c.cancel != nil {
		c.cancel()
	}
	close(c.out)
}

// NewHub builds a Hub with a 10s heartbeat (matching the Swift default).
func NewHub() *Hub {
	return &Hub{
		clients:           map[int]*client{},
		heartbeatInterval: 10 * time.Second,
	}
}

// Subscribe registers a new client and returns a channel of SSE events plus
// an unsubscribe func. The most recent snapshot (if any) is delivered first
// so freshly connected clients see state immediately. The supplied context
// cancels heartbeats and removes the client when the HTTP request goes
// away.
func (h *Hub) Subscribe(ctx context.Context) (<-chan wire.SSEEvent, func()) {
	out := make(chan wire.SSEEvent, 1)
	if h.checkAndStoreNewClient(ctx, out) == nil {
		// Hub already closed — return a finished stream so the caller's
		// `for await` exits cleanly.
		close(out)
		return out, func() {}
	}
	subCtx, cancel := context.WithCancel(ctx)
	c := h.bindClient(out, cancel)
	if c == nil {
		// Race: closed between checkAndStoreNewClient and bindClient.
		cancel()
		return out, func() {}
	}

	// Deliver the cached latest snapshot if one exists.
	h.mu.Lock()
	cached := h.latestSnapshot
	h.mu.Unlock()
	if cached != nil {
		c.send(*cached)
	}

	// Per-client heartbeat keeps idle SSE connections from being culled
	// by intermediate proxies that drop quiet TCP streams.
	go func() {
		t := time.NewTicker(h.heartbeatInterval)
		defer t.Stop()
		for {
			select {
			case <-subCtx.Done():
				return
			case <-t.C:
				c.send(wire.HeartbeatEvent())
			}
		}
	}()

	// Drop the client when its ctx fires (HTTP disconnect or Hub close).
	go func() {
		<-subCtx.Done()
		h.mu.Lock()
		var id int = -1
		for k, cl := range h.clients {
			if cl == c {
				id = k
				break
			}
		}
		if id >= 0 {
			delete(h.clients, id)
		}
		h.mu.Unlock()
		c.shutdown()
	}()

	return out, cancel
}

// checkAndStoreNewClient atomically validates Hub state. Returns the client
// stub if Hub is open, nil if closed.
func (h *Hub) checkAndStoreNewClient(ctx context.Context, out chan wire.SSEEvent) *client {
	_ = ctx
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.closed {
		return nil
	}
	// Returns a non-nil sentinel; the actual client is built in bindClient.
	return &client{}
}

// bindClient creates the real client + registers it. Returns nil if Hub
// closed between checkAndStoreNewClient and now.
func (h *Hub) bindClient(out chan wire.SSEEvent, cancel context.CancelFunc) *client {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.closed {
		return nil
	}
	id := h.nextID
	h.nextID++
	c := &client{out: out, cancel: cancel}
	h.clients[id] = c
	return c
}

// PublishSnapshot stores the snapshot as the latest and fans out to clients.
func (h *Hub) PublishSnapshot(snapshot wire.UsageSnapshot) error {
	event, err := wire.SnapshotEvent(snapshot)
	if err != nil {
		return err
	}
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		return nil
	}
	h.latestSnapshot = &event
	clients := make([]*client, 0, len(h.clients))
	for _, c := range h.clients {
		clients = append(clients, c)
	}
	h.mu.Unlock()
	for _, c := range clients {
		c.send(event)
	}
	return nil
}

// PublishAuthExpired emits the state-transition event without changing the
// cached latest snapshot — clients use this to trigger re-login UX while
// the underlying state-bearing snapshot remains the source of truth.
func (h *Hub) PublishAuthExpired(provider wire.Provider, seq int, state wire.ProviderState) {
	event := wire.AuthExpiredEvent(provider, seq, state)
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		return
	}
	clients := make([]*client, 0, len(h.clients))
	for _, c := range h.clients {
		clients = append(clients, c)
	}
	h.mu.Unlock()
	for _, c := range clients {
		c.send(event)
	}
}

// ClientCount returns the live subscriber count (debug + tests).
func (h *Hub) ClientCount() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.clients)
}

// Close terminates every client and stops accepting new ones.
func (h *Hub) Close() {
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		return
	}
	h.closed = true
	clients := make([]*client, 0, len(h.clients))
	for _, c := range h.clients {
		clients = append(clients, c)
	}
	h.clients = map[int]*client{}
	h.mu.Unlock()
	for _, c := range clients {
		c.shutdown()
	}
}
