//go:build meton_managed

package metonentry

import (
	"context"
	"crypto/x509"
	"database/sql"
	"encoding/pem"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/repository/metonledger"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/lib/pq"
)

type configuration struct {
	FormatVersion          int               `json:"format_version"`
	Environment            string            `json:"environment"`
	Source                 string            `json:"source"`
	Epoch                  int64             `json:"epoch"`
	CaptureProvider        bool              `json:"capture_provider,omitempty"`
	Gateways               map[string]string `json:"gateways"`
	ReserveDSNFile         string            `json:"reserve_dsn_file"`
	SendDSNFile            string            `json:"send_dsn_file"`
	CompleteDSNFile        string            `json:"complete_dsn_file"`
	InspectDSNFile         string            `json:"inspect_dsn_file"`
	ExecutionReadDSNFile   string            `json:"execution_read_dsn_file,omitempty"`
	ExecutionCancelDSNFile string            `json:"execution_cancel_dsn_file,omitempty"`
	Routes                 []struct {
		Group    int64                 `json:"group"`
		Profiles []metonexecution.Spec `json:"profiles"`
	} `json:"routes"`
}

const ReserveFunction = "meton_ledger.reserve_execution_text(text,text,bigint,jsonb,text,text,bigint,jsonb)"
const ProviderReserveFunction = "meton_ledger.reserve_provider_execution_text(text,text,bigint,jsonb,text,text,bigint,jsonb,jsonb)"
const SendFunction = "meton_ledger.claim_execution_text(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,text,bigint,text,jsonb)"
const CompleteFunction = "meton_ledger.complete_execution_text(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,text,jsonb,jsonb)"
const InspectFunction = "meton_ledger.find_execution_result(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid)"

func readFile(base, name string, maximum int64) ([]byte, error) {
	if name == "" {
		return nil, service.ErrMetonClosed
	}
	if !filepath.IsAbs(name) {
		name = filepath.Join(base, name)
	}
	f, err := os.Open(name)
	if err != nil {
		return nil, service.ErrMetonClosed
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > maximum {
		return nil, service.ErrMetonClosed
	}
	data, err := io.ReadAll(io.LimitReader(f, maximum+1))
	if err != nil || len(data) == 0 || int64(len(data)) > maximum {
		return nil, service.ErrMetonClosed
	}
	return data, nil
}

/** Open 只在显式配置时装配；不安装迁移、不改账户或权限，配置不完整时启动失败。 */
func Open(path string, keys KeyReader, groups GroupReader) (*Admission, func(), error) {
	base := filepath.Dir(path)
	raw, err := readFile("", path, 1024*1024)
	if err != nil {
		return nil, func() {}, err
	}
	var cfg configuration
	source, valid := service.CurrentMetonKeySource()
	if metonexecution.DecodeStrict(raw, &cfg) != nil || cfg.FormatVersion != 2 || !valid || cfg.Environment != source.Environment || cfg.Source != source.Source || cfg.Epoch != source.Epoch ||
		len(cfg.Routes) == 0 || len(cfg.Routes) > 256 {
		return nil, func() {}, service.ErrMetonClosed
	}
	certificates := map[string]*x509.Certificate{}
	for id, path := range cfg.Gateways {
		raw, err := readFile(base, path, 65536)
		if err != nil {
			return nil, func() {}, err
		}
		block, rest := pem.Decode(raw)
		if block == nil || block.Type != "CERTIFICATE" || len(bytesTrim(rest)) != 0 {
			return nil, func() {}, service.ErrMetonClosed
		}
		cert, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			return nil, func() {}, service.ErrMetonClosed
		}
		certificates[id] = cert
	}
	verifier, err := metondispatch.NewVerifier(cfg.Environment, cfg.Source, cfg.Epoch, certificates)
	if err != nil {
		return nil, func() {}, service.ErrMetonClosed
	}
	routes := []Route{}
	for _, item := range cfg.Routes {
		route := Route{Group: item.Group}
		if len(item.Profiles) > 128 {
			return nil, func() {}, service.ErrMetonClosed
		}
		for _, spec := range item.Profiles {
			p, e := metonexecution.NewProfile(spec)
			if e != nil {
				return nil, func() {}, e
			}
			route.Profiles = append(route.Profiles, p)
		}
		routes = append(routes, route)
	}
	pools := []*sql.DB{}
	closePools := func() {
		for _, db := range pools {
			_ = db.Close()
		}
	}
	failed := true
	defer func() {
		if failed {
			closePools()
		}
	}()
	identities := []string{}
	roles := []string{}
	permissions := []string{ReserveFunction, SendFunction, CompleteFunction, InspectFunction}
	if cfg.CaptureProvider {
		permissions[0] = ProviderReserveFunction
	}
	names := []string{cfg.ReserveDSNFile, cfg.SendDSNFile, cfg.CompleteDSNFile, cfg.InspectDSNFile}
	// 新能力必须成对配置；已有四池模式只保留其原范围，不用旧连接冒充取消权。
	control := cfg.ExecutionReadDSNFile != "" || cfg.ExecutionCancelDSNFile != ""
	if control {
		managed, available := service.MetonSource()
		_, readable := managed.ModelReadID()
		_, cancellable := managed.ModelCancelID()
		if !available || !readable || !cancellable || cfg.ExecutionReadDSNFile == "" || cfg.ExecutionCancelDSNFile == "" {
			return nil, func() {}, service.ErrMetonClosed
		}
		names = append(names, cfg.ExecutionReadDSNFile, cfg.ExecutionCancelDSNFile)
		permissions = append(permissions, ExecutionReadFunction, ExecutionCancelFunction)
	}
	for i, name := range names {
		raw, err := readFile(base, name, 32768)
		if err != nil {
			return nil, func() {}, err
		}
		db, err := sql.Open("postgres", strings.TrimSpace(string(raw)))
		if err != nil {
			return nil, func() {}, service.ErrMetonClosed
		}
		pools = append(pools, db)
		db.SetMaxOpenConns(16)
		db.SetMaxIdleConns(4)
		db.SetConnMaxLifetime(5 * time.Minute)
		identity, role, e := checkPool(db, permissions[i])
		if e != nil {
			return nil, func() {}, e
		}
		identities = append(identities, identity)
		roles = append(roles, role)
	}
	seenRoles := map[string]bool{}
	for i, role := range roles {
		if identities[0] != identities[i] || seenRoles[role] {
			return nil, func() {}, service.ErrMetonClosed
		}
		seenRoles[role] = true
	}
	reserve, err := metonledger.NewTextLedger(pools[0])
	if err != nil {
		return nil, func() {}, err
	}
	send, err := metonledger.NewTextLedger(pools[1])
	if err != nil {
		return nil, func() {}, err
	}
	complete, err := metonledger.NewTextLedger(pools[2])
	if err != nil {
		return nil, func() {}, err
	}
	inspect, err := metonledger.NewTextLedger(pools[3])
	if err != nil {
		return nil, func() {}, err
	}
	admission, err := New(verifier, keys, groups, reserve, send, complete, inspect, routes)
	if err != nil {
		return nil, func() {}, err
	}
	admission.captureProvider = cfg.CaptureProvider
	if control {
		admission.Control, err = NewOriginalExecutionControl(pools[4], pools[5])
		if err != nil {
			return nil, func() {}, err
		}
	}
	failed = false
	return admission, closePools, nil
}

func bytesTrim(raw []byte) []byte { return []byte(strings.TrimSpace(string(raw))) }

/** checkPool 检查有效权限而非角色名称；任一数据库所有者、裸写或额外资金函数都不能作为运行池。 */
func checkPool(db *sql.DB, permission string) (string, string, error) {
	return checkPoolPermissions(db, []string{permission})
}

/** checkPoolPermissions 复用原单权限检查；多函数仅允许本模块列出的固定集合。 */
func checkPoolPermissions(db *sql.DB, permissions []string) (string, string, error) {
	if db == nil || len(permissions) == 0 {
		return "", "", service.ErrMetonClosed
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var identity, role string
	var allowed bool
	err := db.QueryRowContext(ctx, `SELECT current_database()||'@'||coalesce(inet_server_addr()::text,'local')||':'||coalesce(inet_server_port()::text,'local'),current_user,
 NOT pg_is_in_recovery() AND current_setting('transaction_read_only')='off'
 AND EXISTS(SELECT 1 FROM pg_roles WHERE rolname=current_user AND NOT rolsuper AND NOT rolcreaterole AND NOT rolcreatedb AND NOT rolreplication AND NOT rolbypassrls)
 AND NOT EXISTS(SELECT 1 FROM unnest($1::text[]) allowed(signature) WHERE to_regprocedure(signature) IS NULL OR NOT has_function_privilege(current_user,signature,'EXECUTE'))
 AND NOT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='meton_ledger' AND NOT EXISTS(SELECT 1 FROM unnest($1::text[]) allowed(signature) WHERE p.oid=to_regprocedure(signature)) AND has_function_privilege(current_user,p.oid,'EXECUTE'))
 AND NOT EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('public','meton_ledger') AND c.relkind IN ('r','p') AND
  (has_table_privilege(current_user,c.oid,'INSERT,UPDATE,DELETE,TRUNCATE,TRIGGER') OR has_any_column_privilege(current_user,c.oid,'INSERT,UPDATE')))
 AND NOT has_schema_privilege(current_user,'meton_ledger','CREATE') AND NOT has_schema_privilege(current_user,'public','CREATE')`, pq.Array(permissions)).Scan(&identity, &role, &allowed)
	if err != nil || !allowed {
		return "", "", errors.New("managed text database role rejected")
	}
	return identity, role, nil
}
