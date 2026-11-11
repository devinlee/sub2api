//go:build meton_managed && gift_integration

package server

import (
	"database/sql"
	"encoding/json"
	"github.com/Wei-Shaw/sub2api/internal/repository/metonentry"
	_ "github.com/lib/pq"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

/** 独立赠送装配不要求模型可调用；多余身份权限、错角色和损坏配置均不能开放。 */
func TestMetonGiftClosureConfiguration(t *testing.T) {
	for k, v := range map[string]string{"ENVIRONMENT": "s2-isolated", "SOURCE": "s2-managed", "EPOCH": "1", "FUNDS_MODE": "s2-source-v1",
		"CREATE_KEY_ID": strings.Repeat("1", 24), "READ_KEY_ID": strings.Repeat("2", 24), "GIFT_READ_KEY_ID": strings.Repeat("b", 24), "GIFT_CLOSE_KEY_ID": strings.Repeat("c", 24), "TEXT_CONFIG": ""} {
		t.Setenv("METON_MANAGED_"+k, v)
	}
	t.Setenv("METON_MANAGED_GIFT_CONFIG", "")
	empty, err := ProvideMetonTextIngress(nil, nil, nil)
	if err != nil || empty.GiftClosure != nil {
		t.Fatal("implicit gift module")
	}
	empty.Close()
	dir := t.TempDir()
	config := filepath.Join(dir, "config.json")
	for _, role := range []string{"s2_gift_read", "s2_gift_close", "s2_original_read", "s2_original_cancel", "postgres"} {
		if os.WriteFile(filepath.Join(dir, role+".dsn"), []byte("host=127.0.0.1 dbname=s2_grants user="+role+" sslmode=disable"), 0600) != nil {
			t.Fatal("write fixture")
		}
	}
	cfg := map[string]any{"format_version": 1, "environment": "s2-isolated", "source": "s2-managed", "epoch": 1, "read_dsn_file": "s2_gift_read.dsn", "close_dsn_file": "s2_gift_close.dsn"}
	t.Setenv("METON_MANAGED_GIFT_CONFIG", config)
	open := func(want bool) {
		t.Helper()
		raw, _ := json.Marshal(cfg)
		if os.WriteFile(config, raw, 0600) != nil {
			t.Fatal("write config")
		}
		value, e := ProvideMetonTextIngress(nil, nil, nil)
		if e == nil {
			defer value.Close()
			defer value.Close()
		}
		if want {
			if e != nil || value == nil || value.GiftClosure == nil || value.Authenticate != nil {
				t.Fatal("gift-only composition", e)
			}
		} else if e == nil {
			t.Fatal("unsafe gift composition")
		}
	}
	open(true)
	for _, field := range []string{"read_dsn_file", "close_dsn_file"} {
		original := cfg[field]
		for _, bad := range []string{"", "missing.dsn", "postgres.dsn", "s2_original_read.dsn", "s2_gift_read.dsn", "s2_gift_close.dsn"} {
			if bad == original {
				continue
			}
			cfg[field] = bad
			open(false)
		}
		cfg[field] = original
	}
	for _, field := range []string{"format_version", "epoch"} {
		cfg[field] = 2
		open(false)
		cfg[field] = 1
	}
	t.Run("overlapping-identity", func(t *testing.T) { t.Setenv("METON_MANAGED_MODEL_READ_KEY_ID", strings.Repeat("c", 24)); open(false) })
	db, e := sql.Open("postgres", "host=127.0.0.1 dbname=s2_grants user=postgres sslmode=disable")
	if e != nil {
		t.Fatal(e)
	}
	defer db.Close()
	for _, permission := range []string{metonentry.GiftReadFunction, "public.meton_issue_managed_key(text,text,bigint,jsonb,timestamptz,text)"} {
		if _, e = db.Exec("GRANT EXECUTE ON FUNCTION " + permission + " TO s2_gift_close"); e != nil {
			t.Fatal(e)
		}
		open(false)
		if _, e = db.Exec("REVOKE EXECUTE ON FUNCTION " + permission + " FROM s2_gift_close"); e != nil {
			t.Fatal(e)
		}
	}
}
