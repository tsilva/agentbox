// agentbox's broker holds provider keys outside the agent's namespaces.
// The relay listens only on loopback and reaches the broker over a Unix socket.
package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
)

const maxBody = 8 << 20

type credentials struct {
	Runtime string `json:"runtime"`
	Key     string `json:"key"`
	Token   string `json:"token"`
}

func loadCredentials(path string) (credentials, error) {
	var c credentials
	b, err := os.ReadFile(path)
	if err != nil {
		return c, err
	}
	err = json.Unmarshal(b, &c)
	if err != nil || c.Key == "" || len(c.Token) < 32 || (c.Runtime != "claude" && c.Runtime != "codex") {
		return c, errors.New("invalid broker credentials")
	}
	return c, nil
}

func upstream(c credentials) *url.URL {
	host := "api.openai.com"
	if c.Runtime == "claude" {
		host = "api.anthropic.com"
	}
	return &url.URL{Scheme: "https", Host: host}
}

func allowed(runtime, method, path string) bool {
	if runtime == "codex" {
		return method == "POST" && path == "/v1/responses"
	}
	return method == "POST" && (path == "/v1/messages" || path == "/v1/messages/count_tokens")
}

// No caller-controlled host, credentials, redirect target, or transport proxy
// reaches the upstream. Tests replace the transport, never the production host.
func brokerHandler(c credentials, transport http.RoundTripper) http.Handler {
	if transport == nil {
		transport = &http.Transport{Proxy: nil, TLSHandshakeTimeout: 10 * time.Second,
			ResponseHeaderTimeout: 60 * time.Second, MaxIdleConnsPerHost: 4}
	}
	p := httputil.NewSingleHostReverseProxy(upstream(c))
	p.Transport = transport
	p.FlushInterval = -1
	p.ErrorLog = log.New(io.Discard, "", 0)
	p.ErrorHandler = func(w http.ResponseWriter, _ *http.Request, _ error) { http.Error(w, "provider unavailable", 502) }
	p.ModifyResponse = func(r *http.Response) error {
		if r.StatusCode >= 300 && r.StatusCode < 400 {
			return errors.New("provider redirect rejected")
		}
		// Neither cookies nor redirect headers become another authentication path.
		r.Header.Del("Set-Cookie")
		r.Header.Del("Location")
		return nil
	}
	director := p.Director
	p.Director = func(r *http.Request) {
		director(r)
		r.Host = upstream(c).Host
		beta, version, contentType := r.Header.Get("Anthropic-Beta"), r.Header.Get("Anthropic-Version"), r.Header.Get("Content-Type")
		r.Header = make(http.Header)
		r.Header.Set("Content-Type", contentType)
		if c.Runtime == "claude" {
			r.Header.Set("X-Api-Key", c.Key)
			if version == "" {
				version = "2023-06-01"
			}
			r.Header.Set("Anthropic-Version", version)
			if beta != "" {
				r.Header.Set("Anthropic-Beta", beta)
			}
		} else {
			r.Header.Set("Authorization", "Bearer "+c.Key)
		}
	}
	slots := make(chan struct{}, 4)
	var requests atomic.Int64
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte("Bearer "+c.Token)) != 1 {
			http.Error(w, "unauthorized", 401)
			return
		}
		// Claude's native client uses this fixed beta query on messages routes.
		queryAllowed := r.URL.RawQuery == "" || (c.Runtime == "claude" && r.URL.RawQuery == "beta=true")
		if r.URL.IsAbs() || !queryAllowed || r.URL.RawPath != "" || !allowed(c.Runtime, r.Method, r.URL.Path) {
			http.Error(w, "route denied", 403)
			return
		}
		if requests.Add(1) > 2000 {
			http.Error(w, "session request limit", 429)
			return
		}
		select {
		case slots <- struct{}{}:
			defer func() { <-slots }()
		default:
			http.Error(w, "busy", 429)
			return
		}
		if r.ContentLength > maxBody {
			http.Error(w, "request too large", 413)
			return
		}
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBody))
		if err != nil {
			http.Error(w, "request too large", 413)
			return
		}
		if !json.Valid(body) {
			http.Error(w, "invalid JSON", 400)
			return
		}
		r.Body = io.NopCloser(strings.NewReader(string(body)))
		r.ContentLength = int64(len(body))
		// A provider cannot hold a concurrency slot forever.
		ctx, cancel := context.WithTimeout(r.Context(), 30*time.Minute)
		defer cancel()
		p.ServeHTTP(w, r.WithContext(ctx))
	})
}

func relayHandler(socket, token string) http.Handler {
	p := httputil.NewSingleHostReverseProxy(&url.URL{Scheme: "http", Host: "broker"})
	p.Transport = &http.Transport{Proxy: nil, DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{Timeout: 5 * time.Second}).DialContext(ctx, "unix", socket)
	}, ResponseHeaderTimeout: 60 * time.Second}
	p.FlushInterval = -1
	p.ErrorLog = log.New(io.Discard, "", 0)
	director := p.Director
	p.Director = func(r *http.Request) { director(r); r.Header.Set("Authorization", "Bearer "+token) }
	p.ErrorHandler = func(w http.ResponseWriter, _ *http.Request, _ error) { http.Error(w, "broker unavailable", 502) }
	return p
}

func serve(listener net.Listener, handler http.Handler) error {
	srv := &http.Server{Handler: handler, ReadHeaderTimeout: 10 * time.Second, ReadTimeout: 30 * time.Second,
		IdleTimeout: 30 * time.Second, MaxHeaderBytes: 32 << 10, ErrorLog: log.New(io.Discard, "", 0)}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() { <-ctx.Done(); _ = srv.Close() }()
	err := srv.Serve(listener)
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

func run(args []string) error {
	if len(args) == 2 && (args[0] == "probe" || args[0] == "probe-unix") {
		network := "tcp"
		if args[0] == "probe-unix" {
			network = "unix"
		}
		conn, err := net.DialTimeout(network, args[1], time.Second)
		if err == nil {
			_ = conn.Close()
		}
		return err
	}
	if len(args) == 3 && args[0] == "broker" {
		c, err := loadCredentials(args[2])
		if err != nil {
			return err
		}
		listener, err := net.Listen("unix", args[1])
		if err != nil {
			return err
		}
		defer listener.Close()
		defer os.Remove(args[1])
		if err = os.Chmod(args[1], 0600); err != nil {
			return err
		}
		return serve(listener, brokerHandler(c, nil))
	}
	if len(args) == 2 && args[0] == "relay" {
		token := os.Getenv("AGENTBOX_BROKER_TOKEN")
		if len(token) < 32 {
			return errors.New("missing session token")
		}
		listener, err := net.Listen("tcp", "127.0.0.1:18080")
		if err != nil {
			return err
		}
		return serve(listener, relayHandler(args[1], token))
	}
	return errors.New("usage: agentbox-broker broker <socket> <credentials> | relay <socket> | probe <address> | probe-unix <socket>")
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "agentbox broker failed")
		os.Exit(1)
	}
}
