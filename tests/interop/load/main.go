package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"log/slog"
	"math/rand/v2"
	"os"
	"slices"
	"sync"
	"sync/atomic"
	"time"

	"github.com/df-mc/go-nethernet"
	"github.com/df-mc/go-nethernet/endpoint"
)

// Drives many connections against an HTTP signaling endpoint, or serves an echo endpoint with go-nethernet.
func main() {
	mode := flag.String("mode", "load", "load or serve")
	addr := flag.String("addr", "127.0.0.1:18760", "endpoint address")
	connections := flag.Int("n", 100, "connections")
	rate := flag.Int("rate", 20, "messages per second per connection")
	duration := flag.Duration("duration", 10*time.Second, "traffic duration")
	dialers := flag.Int("dialers", 16, "concurrent dials")
	flag.Parse()
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError})))
	if *mode == "serve" {
		serve(*addr)
		return
	}
	load(*addr, *connections, *rate, *duration, *dialers)
}

func serve(addr string) {
	handler, err := endpoint.Serve(addr)
	if err != nil {
		fail(err)
	}
	listener, err := nethernet.ListenConfig{AllowAnonymous: true, DisableTrickleICE: true}.Listen(handler)
	if err != nil {
		fail(err)
	}
	for {
		conn, err := listener.Accept()
		if err != nil {
			fail(err)
		}
		c := conn.(*nethernet.Conn)
		for _, r := range []nethernet.MessageReliability{nethernet.MessageReliabilityReliable, nethernet.MessageReliabilityUnreliable} {
			go func() {
				for {
					data, err := c.Receive(r)
					if err != nil {
						return
					}
					if _, err := c.Send(data, r); err != nil {
						return
					}
				}
			}()
		}
	}
}

// Same size mix as the stress harness bedrock profile.
func payloadSize(sequence uint64) int {
	switch s := sequence % 100; {
	case s < 35:
		return 32
	case s < 60:
		return 64
	case s < 75:
		return 96
	case s < 85:
		return 128
	case s < 92:
		return 256
	case s < 96:
		return 512
	case s < 99:
		return 1400
	default:
		return 8192
	}
}

type stats struct {
	sent, received, unreliableSent, unreliableReceived, corrupt, reordered atomic.Int64
	mu                                                                     sync.Mutex
	rtts                                                                   []time.Duration
}

func load(addr string, n, rate int, duration time.Duration, dialers int) {
	start := time.Now()
	conns := make([]*nethernet.Conn, n)
	var failed atomic.Int64
	var next atomic.Int64
	var wg sync.WaitGroup
	for range dialers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := int(next.Add(1) - 1); i < n; i = int(next.Add(1) - 1) {
				for attempt := 0; ; attempt++ {
					ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
					conn, err := (nethernet.Dialer{DisableTrickleICE: true}).DialContext(ctx, "http://"+addr, endpoint.NewClient())
					cancel()
					if err == nil {
						conns[i] = conn
						break
					}
					if attempt == 20 {
						failed.Add(1)
						break
					}
					time.Sleep(100 * time.Millisecond)
				}
			}
		}()
	}
	wg.Wait()
	setup := time.Since(start)
	fmt.Println("TRAFFIC_START")

	var s stats
	epoch := time.Now()
	stop := epoch.Add(duration)
	var traffic sync.WaitGroup
	for _, conn := range conns {
		if conn == nil {
			continue
		}
		var lastReliable atomic.Uint64
		for _, r := range []nethernet.MessageReliability{nethernet.MessageReliabilityReliable, nethernet.MessageReliabilityUnreliable} {
			go func() {
				var local []time.Duration
				defer func() { s.mu.Lock(); s.rtts = append(s.rtts, local...); s.mu.Unlock() }()
				for {
					data, err := conn.Receive(r)
					if err != nil {
						return
					}
					if len(data) < 16 || len(data) != payloadSize(binary.LittleEndian.Uint64(data)) {
						s.corrupt.Add(1)
						continue
					}
					sequence := binary.LittleEndian.Uint64(data)
					if r == nethernet.MessageReliabilityReliable {
						if sequence <= lastReliable.Load() {
							s.reordered.Add(1)
						}
						lastReliable.Store(sequence)
						s.received.Add(1)
					} else {
						s.unreliableReceived.Add(1)
					}
					local = append(local, time.Since(epoch)-time.Duration(binary.LittleEndian.Uint64(data[8:])))
				}
			}()
		}
		traffic.Add(1)
		go func() {
			defer traffic.Done()
			if rate == 0 {
				time.Sleep(time.Until(stop))
				return
			}
			interval := time.Second / time.Duration(rate)
			time.Sleep(time.Duration(rand.Int64N(int64(interval))))
			buffer := make([]byte, 8192)
			for sequence := uint64(1); time.Now().Before(stop); sequence++ {
				size := payloadSize(sequence)
				binary.LittleEndian.PutUint64(buffer, sequence)
				binary.LittleEndian.PutUint64(buffer[8:], uint64(time.Since(epoch)))
				r := nethernet.MessageReliabilityReliable
				if sequence%10 == 0 {
					r = nethernet.MessageReliabilityUnreliable
				}
				if _, err := conn.Send(buffer[:size], r); err != nil {
					return
				}
				if r == nethernet.MessageReliabilityReliable {
					s.sent.Add(1)
				} else {
					s.unreliableSent.Add(1)
				}
				time.Sleep(interval)
			}
		}()
	}
	traffic.Wait()
	for deadline := time.Now().Add(5 * time.Second); s.received.Load() < s.sent.Load() && time.Now().Before(deadline); {
		time.Sleep(10 * time.Millisecond)
	}
	fmt.Println("TRAFFIC_END")
	for _, conn := range conns {
		if conn != nil {
			conn.Close()
		}
	}
	time.Sleep(200 * time.Millisecond)

	s.mu.Lock()
	slices.Sort(s.rtts)
	percentile := func(p int) float64 {
		if len(s.rtts) == 0 {
			return 0
		}
		return float64(s.rtts[min(len(s.rtts)-1, len(s.rtts)*p/100)].Microseconds())
	}
	result, _ := json.Marshal(map[string]any{
		"connections": n, "dial_failures": failed.Load(), "setup_ms": setup.Milliseconds(),
		"reliable_sent": s.sent.Load(), "reliable_received": s.received.Load(),
		"unreliable_sent": s.unreliableSent.Load(), "unreliable_received": s.unreliableReceived.Load(),
		"corrupt": s.corrupt.Load(), "reordered": s.reordered.Load(),
		"rtt_p50_us": percentile(50), "rtt_p95_us": percentile(95), "rtt_p99_us": percentile(99),
	})
	s.mu.Unlock()
	fmt.Println(string(result))
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
