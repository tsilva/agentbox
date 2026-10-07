package main

import (
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type roundTrip func(*http.Request) (*http.Response, error)

func (f roundTrip) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func creds(runtime string) credentials {
	return credentials{Runtime: runtime, Key: "provider-secret-canary", Token: strings.Repeat("a", 64)}
}

func TestSocketReadiness(t *testing.T) {
	path := filepath.Join(t.TempDir(), "api.sock")
	if err := run([]string{"probe-unix", path}); err == nil {
		t.Fatal("missing socket reported ready")
	}
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	if err := run([]string{"probe-unix", path}); err != nil {
		t.Fatal(err)
	}
}

func TestRoutesAndCredentials(t *testing.T) {
	for _, runtime := range []string{"claude", "codex"} {
		t.Run(runtime, func(t *testing.T) {
			c := creds(runtime)
			path := "/v1/responses"
			if runtime == "claude" {
				path = "/v1/messages"
			}
			calls := 0
			betaStatus := 403
			if runtime == "claude" {
				betaStatus = 200
			}
			h := brokerHandler(c, roundTrip(func(r *http.Request) (*http.Response, error) {
				calls++
				if r.URL.Host != upstream(c).Host || r.Host != upstream(c).Host {
					t.Fatal("host overridden")
				}
				if r.Header.Get("Cookie") != "" || r.Header.Get("X-Forwarded-Host") != "" {
					t.Fatal("ambient headers forwarded")
				}
				if runtime == "claude" && (r.Header.Get("X-Api-Key") != c.Key || r.Header.Get("Authorization") != "") {
					t.Fatal("incorrect Claude credentials")
				}
				if runtime == "codex" && r.Header.Get("Authorization") != "Bearer "+c.Key {
					t.Fatal("incorrect Codex credentials")
				}
				return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader("data: hello\n\n"))}, nil
			}))
			for _, test := range []struct {
				method, path, token, body string
				status                    int
			}{
				{"POST", path, c.Token, "{}", 200},
				{"POST", path + "?beta=true", c.Token, "{}", betaStatus},
				{"POST", path + "?beta=false", c.Token, "{}", 403},
				{"POST", path + "?beta=true&url=http://evil.example", c.Token, "{}", 403},
				{"POST", path, "wrong", "{}", 401},
				{"CONNECT", "api.openai.com:443", c.Token, "{}", 403},
				{"POST", path + "?url=http://169.254.169.254", c.Token, "{}", 403},
				{"POST", "http://evil.example/v1/responses", c.Token, "{}", 403},
				{"POST", "/shutdown", c.Token, "{}", 403},
				{"POST", path, c.Token, "invalid", 400},
				{"POST", path, c.Token, strings.Repeat("x", maxBody+1), 413},
			} {
				r := httptest.NewRequest(test.method, test.path, strings.NewReader(test.body))
				r.Header.Set("Authorization", "Bearer "+test.token)
				r.Header.Set("Cookie", "host-session")
				r.Header.Set("X-Api-Key", "attacker-key")
				w := httptest.NewRecorder()
				h.ServeHTTP(w, r)
				if w.Code != test.status {
					t.Fatalf("%s %s: %d, want %d", test.method, test.path, w.Code, test.status)
				}
				if strings.Contains(w.Body.String(), c.Key) {
					t.Fatal("provider key exposed")
				}
			}
			expectedCalls := 1
			if runtime == "claude" {
				expectedCalls++
			}
			if calls != expectedCalls {
				t.Fatalf("unexpected upstream calls: %d", calls)
			}
		})
	}
}

func TestProviderRedirectFailsClosed(t *testing.T) {
	c := creds("codex")
	h := brokerHandler(c, roundTrip(func(r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 302, Header: http.Header{"Location": []string{"https://evil.example"}}, Body: io.NopCloser(strings.NewReader(""))}, nil
	}))
	r := httptest.NewRequest("POST", "/v1/responses", strings.NewReader("{}"))
	r.Header.Set("Authorization", "Bearer "+c.Token)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 502 || w.Header().Get("Location") != "" {
		t.Fatal("redirect escaped broker")
	}
}

func TestConcurrentRequestBound(t *testing.T) {
	c := creds("codex")
	entered := make(chan struct{}, 4)
	release := make(chan struct{})
	h := brokerHandler(c, roundTrip(func(r *http.Request) (*http.Response, error) {
		entered <- struct{}{}
		<-release
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader("{}"))}, nil
	}))
	done := make(chan struct{}, 4)
	request := func() *httptest.ResponseRecorder {
		r := httptest.NewRequest("POST", "/v1/responses", strings.NewReader("{}"))
		r.Header.Set("Authorization", "Bearer "+c.Token)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	for i := 0; i < 4; i++ {
		go func() { request(); done <- struct{}{} }()
	}
	for i := 0; i < 4; i++ {
		<-entered
	}
	if request().Code != 429 {
		t.Fatal("concurrency limit missing")
	}
	close(release)
	for i := 0; i < 4; i++ {
		<-done
	}
}

func TestRelayMissingBrokerFailsClosed(t *testing.T) {
	r := httptest.NewRequest("POST", "/v1/responses", strings.NewReader("{}"))
	w := httptest.NewRecorder()
	relayHandler("/nonexistent/agentbox.sock", strings.Repeat("a", 64)).ServeHTTP(w, r)
	if w.Code != 502 {
		t.Fatal("missing broker did not fail closed")
	}
}

func TestStreamingFlushesBeforeCompletion(t *testing.T) {
	c := creds("codex")
	reader, writer := io.Pipe()
	release := make(chan struct{})
	defer reader.Close()
	defer writer.Close()
	h := brokerHandler(c, roundTrip(func(r *http.Request) (*http.Response, error) {
		go func() {
			_, _ = writer.Write([]byte("data: first\n\n"))
			<-release
			_ = writer.Close()
		}()
		return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": []string{"text/event-stream"}}, Body: reader}, nil
	}))
	server := httptest.NewServer(h)
	defer server.Close()
	defer close(release)
	request, _ := http.NewRequest("POST", server.URL+"/v1/responses", strings.NewReader("{}"))
	request.Header.Set("Authorization", "Bearer "+c.Token)
	client := &http.Client{Timeout: 2 * time.Second}
	response, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	data := make([]byte, len("data: first\n\n"))
	if _, err := io.ReadFull(response.Body, data); err != nil {
		t.Fatal(err)
	}
	if string(data) != "data: first\n\n" {
		t.Fatal("stream was buffered or changed")
	}
}
