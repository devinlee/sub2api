//go:build unit && meton_managed

package server

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/pkg/metonobserve"
)

var observationScope = metonobserve.Scope{Environment: "s2-isolated", Source: "s2-managed", Epoch: 1}

type observationRecord struct{ message, snapshot string }
type observationLog struct {
	mu               sync.Mutex
	records          []observationRecord
	entered, release chan struct{}
	once             sync.Once
}

func (h *observationLog) Enabled(context.Context, slog.Level) bool { return true }
func (h *observationLog) WithAttrs([]slog.Attr) slog.Handler       { return h }
func (h *observationLog) WithGroup(string) slog.Handler            { return h }
func (h *observationLog) Handle(_ context.Context, r slog.Record) error {
	if r.Message != "meton_source_rejections" && r.Message != "meton_source_observation_retired" {
		return nil
	}
	v := observationRecord{message: r.Message}
	r.Attrs(func(a slog.Attr) bool {
		if a.Key == "snapshot" {
			v.snapshot = a.Value.String()
		}
		return true
	})
	if h.entered != nil && r.Message == "meton_source_rejections" {
		h.once.Do(func() { close(h.entered); <-h.release })
	}
	h.mu.Lock()
	h.records = append(h.records, v)
	h.mu.Unlock()
	return nil
}
func (h *observationLog) values() []observationRecord {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]observationRecord(nil), h.records...)
}
func observationLogger(t *testing.T, h *observationLog) {
	t.Helper()
	old := slog.Default()
	slog.SetDefault(slog.New(h))
	t.Cleanup(func() { slog.SetDefault(old) })
}
func observationWait(t *testing.T, f func() bool) {
	t.Helper()
	until := time.Now().Add(4 * time.Second)
	for time.Now().Before(until) {
		if f() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("observation condition timed out")
}
func observationSnapshot(t *testing.T, h *observationLog, predicate func(metonobserve.Snapshot) bool) metonobserve.Snapshot {
	t.Helper()
	var found metonobserve.Snapshot
	observationWait(t, func() bool {
		for _, r := range h.values() {
			if r.snapshot != "" {
				var s metonobserve.Snapshot
				if json.Unmarshal([]byte(r.snapshot), &s) == nil && predicate(s) {
					found = s
					return true
				}
			}
		}
		return false
	})
	return found
}
func observationEnvironment(t *testing.T) {
	t.Helper()
	for k, v := range map[string]string{"FUNDS_MODE": "s2-source-v1", "ENVIRONMENT": "s2-isolated", "SOURCE": "s2-managed", "EPOCH": "1", "CREATE_KEY_ID": strings.Repeat("1", 24), "READ_KEY_ID": strings.Repeat("2", 24), "OBSERVATION_CONFIG": "", "GIFT_CONFIG": "", "STATEMENT_CONFIG": "", "TEXT_CONFIG": ""} {
		t.Setenv("METON_MANAGED_"+k, v)
	}
}
func observationConfig(t *testing.T) (string, []byte) {
	t.Helper()
	raw, err := json.Marshal(sourceObservationConfig{FormatVersion: 1, Environment: observationScope.Environment, Source: observationScope.Source, Epoch: 1, Replica: "source-one", IntervalMS: 1000})
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "observation.json")
	if err = os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("METON_MANAGED_OBSERVATION_CONFIG", path)
	return path, raw
}
func observationCanInstall(t *testing.T) {
	t.Helper()
	collector, err := metonobserve.Install(observationScope, "probe")
	if err != nil {
		t.Fatal("observer leaked", err)
	}
	collector.Close()
}

/** 默认关闭；异常配置和半途装配失败都不能残留活动观察器，也不能启动新数据库连接。 */
func TestRejectionObservationManagedConfiguration(t *testing.T) {
	observationEnvironment(t)
	log := &observationLog{}
	observationLogger(t, log)
	ingress, err := ProvideMetonTextIngress(nil, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	ingress.Close()
	observationCanInstall(t)
	path, raw := observationConfig(t)
	for _, bad := range []string{"", `{}`, strings.Repeat(" ", 4097), strings.Replace(string(raw), `"epoch":1`, `"epoch":1,"epoch":1`, 1), strings.Replace(string(raw), `"epoch":1`, `"Epoch":1`, 1), strings.Replace(string(raw), `"epoch":1`, `"epoch":2`, 1), strings.Replace(string(raw), `"source-one"`, `"user/request"`, 1), strings.Replace(string(raw), `1000`, `999`, 1), strings.Replace(string(raw), `1000`, `60001`, 1), strings.TrimSuffix(string(raw), "}") + `,"secret":"synthetic"}`} {
		if err = os.WriteFile(path, []byte(bad), 0600); err != nil {
			t.Fatal(err)
		}
		close, err := openMetonSourceObservation()
		close()
		if !errors.Is(err, metonobserve.ErrConfiguration) {
			t.Fatal("invalid config accepted")
		}
		observationCanInstall(t)
	}
	if err = os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal(err)
	}
	for _, badPath := range []string{"relative.json", path + ".missing", filepath.Dir(path)} {
		t.Setenv("METON_MANAGED_OBSERVATION_CONFIG", badPath)
		close, err := openMetonSourceObservation()
		close()
		if err == nil {
			t.Fatal("invalid path accepted")
		}
		observationCanInstall(t)
	}
	link := path + ".link"
	if err = os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	t.Setenv("METON_MANAGED_OBSERVATION_CONFIG", link)
	close, err := openMetonSourceObservation()
	close()
	if err == nil {
		t.Fatal("symlink accepted")
	}
	observationCanInstall(t)
	t.Setenv("METON_MANAGED_OBSERVATION_CONFIG", path)
	for _, name := range []string{"GIFT", "STATEMENT", "TEXT"} {
		t.Run(name, func(t *testing.T) {
			t.Setenv("METON_MANAGED_"+name+"_CONFIG", "not-a-file")
			ingress, err := ProvideMetonTextIngress(nil, nil, nil)
			if err == nil {
				ingress.Close()
				t.Fatal("invalid ingress accepted")
			}
			observationCanInstall(t)
		})
	}
}

/** 配置、代次或身份密钥轮换后旧采集器退役；恢复旧配置不能复活，显式重建更换观察编号。 */
func TestRejectionObservationConfigurationRetirement(t *testing.T) {
	for _, change := range []string{"file", "epoch", "key"} {
		t.Run(change, func(t *testing.T) {
			observationEnvironment(t)
			log := &observationLog{}
			observationLogger(t, log)
			path, raw := observationConfig(t)
			closeOld, err := openMetonSourceObservation()
			if err != nil {
				t.Fatal(err)
			}
			defer closeOld()
			before := observationSnapshot(t, log, func(s metonobserve.Snapshot) bool { return s.Scope == observationScope })
			switch change {
			case "file":
				if err = os.WriteFile(path, []byte(`{}`), 0600); err != nil {
					t.Fatal(err)
				}
			case "epoch":
				t.Setenv("METON_MANAGED_EPOCH", "2")
			case "key":
				t.Setenv("METON_MANAGED_READ_KEY_ID", strings.Repeat("3", 24))
			}
			observationWait(t, func() bool {
				for _, v := range log.values() {
					if v.message == "meton_source_observation_retired" {
						return true
					}
				}
				return false
			})
			closeOld()
			if err = os.WriteFile(path, raw, 0600); err != nil {
				t.Fatal(err)
			}
			t.Setenv("METON_MANAGED_EPOCH", "1")
			t.Setenv("METON_MANAGED_READ_KEY_ID", strings.Repeat("2", 24))
			// 自动退役后保持关闭；恢复配置只允许新的显式装配，不能带回旧累计值。
			metonobserve.Record(observationScope, metonobserve.RepeatAttempt)
			observationCanInstall(t)
			closeNew, err := openMetonSourceObservation()
			if err != nil {
				t.Fatal(err)
			}
			defer closeNew()
			closeOld()
			metonobserve.Record(observationScope, metonobserve.RepeatAttempt)
			after := observationSnapshot(t, log, func(s metonobserve.Snapshot) bool {
				return s.Boot != before.Boot && s.Counts[metonobserve.RepeatAttempt].Value == 1
			})
			if after.Scope != before.Scope || after.StartedAt.Before(before.StartedAt) {
				t.Fatal("new observation identity invalid")
			}
			closeNew()
			closeNew()
			observationCanInstall(t)
		})
	}
}

/** 慢日志只能阻塞后台输出；请求计数与关闭继续完成，迟到旧日志仍带旧编号且旧关闭不伤新实例。 */
func TestRejectionObservationSlowLoggerAndHostClose(t *testing.T) {
	observationEnvironment(t)
	log := &observationLog{entered: make(chan struct{}), release: make(chan struct{})}
	var release sync.Once
	defer release.Do(func() { close(log.release) })
	observationLogger(t, log)
	observationConfig(t)
	ingress, err := ProvideMetonTextIngress(nil, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer ingress.Close()
	select {
	case <-log.entered:
	case <-time.After(3 * time.Second):
		t.Fatal("logger not reached")
	}
	done := make(chan struct{})
	go func() {
		for i := 0; i < 1000; i++ {
			metonobserve.Record(observationScope, metonobserve.RepeatAttempt)
		}
		ingress.Close()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("slow logging blocked requests or close")
	}
	next, err := metonobserve.Install(observationScope, "replacement")
	if err != nil {
		t.Fatal(err)
	}
	defer next.Close()
	ingress.Close()
	metonobserve.Record(observationScope, metonobserve.RepeatAttempt)
	release.Do(func() { close(log.release) })
	old := observationSnapshot(t, log, func(s metonobserve.Snapshot) bool { return true })
	current, ok := next.Snapshot()
	if !ok || current.Boot == old.Boot || current.Counts[metonobserve.RepeatAttempt].Value != 1 {
		t.Fatal("late old close removed replacement")
	}
}
