//go:build meton_managed && statement_integration

package server

import (
	"database/sql"
	"encoding/json"
	"github.com/gin-gonic/gin"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

/** 新只读池独立装配；配置损坏、权限过大或代次不符不会借用原生连接。 */
func TestMetonStatementConfiguration(t *testing.T) {
	for k, v := range map[string]string{"ENVIRONMENT": "s2-isolated", "SOURCE": "s2-managed", "EPOCH": "1", "FUNDS_MODE": "s2-source-v1", "CREATE_KEY_ID": strings.Repeat("1", 24), "READ_KEY_ID": strings.Repeat("2", 24), "STATEMENT_READ_KEY_ID": strings.Repeat("d", 24), "TEXT_CONFIG": "", "GIFT_CONFIG": "", "STATEMENT_CONFIG": ""} {
		t.Setenv("METON_MANAGED_"+k, v)
	}
	entry, err := ProvideMetonTextIngress(nil, nil)
	if err != nil || entry.Statements != nil {
		t.Fatal("default not closed")
	}
	entry.Close()
	entry.Close()
	dir := t.TempDir()
	file := filepath.Join(dir, "query.json")
	dsn := filepath.Join(dir, "query.dsn")
	cfg := map[string]any{"format_version": 1, "environment": "s2-isolated", "source": "s2-managed", "epoch": 1, "read_dsn_file": "query.dsn"}
	raw, _ := json.Marshal(cfg)
	if os.WriteFile(file, raw, 0600) != nil || os.WriteFile(dsn, []byte("host=127.0.0.1 dbname=s2_grants user=s2_statement sslmode=disable"), 0600) != nil {
		t.Fatal("fixture write")
	}
	t.Setenv("METON_MANAGED_STATEMENT_CONFIG", file)
	entry, err = ProvideMetonTextIngress(nil, nil)
	if err != nil || entry.Statements == nil || entry.Authenticate != nil || entry.GiftClosure != nil {
		t.Fatal("query did not assemble", err)
	}
	entry.Close()
	entry.Close()
	db, e := sql.Open("postgres", "host=127.0.0.1 dbname=s2_grants user=postgres sslmode=disable")
	if e != nil {
		t.Fatal(e)
	}
	defer db.Close()
	for _, pair := range [][2]string{{"GRANT SELECT ON users TO s2_statement", "REVOKE SELECT ON users FROM s2_statement"}, {"GRANT UPDATE(balance) ON users TO s2_statement", "REVOKE UPDATE(balance) ON users FROM s2_statement"}, {"GRANT EXECUTE ON FUNCTION meton_ledger.statement_parts(uuid) TO s2_statement", "REVOKE EXECUTE ON FUNCTION meton_ledger.statement_parts(uuid) FROM s2_statement"}} {
		if _, e = db.Exec(pair[0]); e != nil {
			t.Fatal(e)
		}
		v, e := ProvideMetonTextIngress(nil, nil)
		_, restore := db.Exec(pair[1])
		if restore != nil {
			t.Fatal(restore)
		}
		if e == nil {
			v.Close()
			t.Fatal("extra privilege admitted")
		}
	}
	t.Setenv("METON_MANAGED_EPOCH", "2")
	if v, e := ProvideMetonTextIngress(nil, nil); e == nil {
		v.Close()
		t.Fatal("old configuration admitted")
	}
	t.Setenv("METON_MANAGED_EPOCH", "1")
	if os.WriteFile(dsn, []byte("host=127.0.0.1 dbname=s2_grants user=postgres sslmode=disable"), 0600) != nil {
		t.Fatal("fixture write")
	}
	if v, e := ProvideMetonTextIngress(nil, nil); e == nil {
		v.Close()
		t.Fatal("superuser admitted")
	}
}

/** 两个只读 POST 有明确入口；普通写入路径不因新增查询而放行。 */
func TestMetonStatementIngress(t *testing.T) {
	for _, method := range []string{"POST", "GET", "DELETE"} {
		for _, action := range []string{"open", "page", "write"} {
			r := gin.New()
			r.Use(metonManagedIngress())
			r.Handle(method, "/api/v1/admin/meton/managed-accounts/:operation/statements/"+action, func(c *gin.Context) { c.Status(204) })
			w := httptest.NewRecorder()
			r.ServeHTTP(w, httptest.NewRequest(method, "/api/v1/admin/meton/managed-accounts/a/statements/"+action, nil))
			want := 403
			if method == "POST" && action != "write" {
				want = 204
			}
			if w.Code != want {
				t.Fatalf("%s %s %d", method, action, w.Code)
			}
		}
	}
}
