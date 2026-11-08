//go:build meton_managed && dispatch_integration && unit

package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"strings"

	"github.com/lib/pq"
)

type jointClaimGate struct {
	entered bool
	release chan struct{}
}
type jointConnector struct {
	driver.Connector
	fixture *jointFixture
}
type jointConnection struct {
	driver.Conn
	fixture *jointFixture
}

/** 只在领取 SQL 前暂停真实驱动，便于让独立取消事务先提交；不替换查询、参数、角色或数据库结果。 */
func (f *jointFixture) claimDB() *sql.DB {
	connector, err := pq.NewConnector("host=source-db port=5432 dbname=s2_grants sslmode=disable user=s2_execution_send")
	if err != nil {
		f.t.Fatal(err)
	}
	db := sql.OpenDB(&jointConnector{Connector: connector, fixture: f})
	f.t.Cleanup(func() { _ = db.Close() })
	return db
}
func (c *jointConnector) Connect(ctx context.Context) (driver.Conn, error) {
	conn, err := c.Connector.Connect(ctx)
	if err != nil {
		return nil, err
	}
	return &jointConnection{Conn: conn, fixture: c.fixture}, nil
}
func (c *jointConnection) QueryContext(ctx context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	if strings.HasPrefix(query, "SELECT meton_ledger.claim_execution_text(") && len(args) == 13 {
		operation, _ := args[7].Value.(string)
		c.fixture.mu.Lock()
		gate := c.fixture.claims[operation]
		if gate != nil {
			gate.entered = true
		}
		c.fixture.mu.Unlock()
		if gate != nil {
			select {
			case <-gate.release:
			case <-ctx.Done():
				return nil, ctx.Err()
			}
		}
	}
	return c.Conn.(driver.QueryerContext).QueryContext(ctx, query, args)
}

/** 取消走已经验收的受限函数，仅能取消原账号的原 H；管理员连接只用于读回原关联。 */
func (f *jointFixture) cancelSource(ctx context.Context, user, operation string) (any, error) {
	f.mu.Lock()
	origin, ok := f.origins[user]
	f.mu.Unlock()
	if !ok {
		return nil, errors.New("unknown cancellation owner")
	}
	var request, caller, state string
	if err := f.admin.QueryRowContext(ctx, "SELECT request_id,caller FROM meton_ledger.text_requests WHERE source_marker=$1 AND operation_id=$2", origin.Marker, operation).Scan(&request, &caller); err != nil {
		return nil, err
	}
	db := jointDB(f.t, "s2_cancel")
	defer db.Close()
	err := db.QueryRowContext(ctx, "SELECT state FROM meton_ledger.cancel_unsent_text($1,'synthetic-model-access',1,$2,$3,$4,$5,$6,$7)", f.env, user, origin.Account, origin.Marker, caller, operation, request).Scan(&state)
	return map[string]string{"state": state}, err
}

/** 合成上游接受 SDK 的标准文字消息结构，不修改实际请求正文或生产输入验证。 */
func jointText(raw json.RawMessage) string {
	var text string
	if json.Unmarshal(raw, &text) == nil {
		return text
	}
	var parts []struct {
		Text    string
		Content json.RawMessage
	}
	if json.Unmarshal(raw, &parts) != nil {
		return ""
	}
	for _, part := range parts {
		if part.Text != "" {
			return part.Text
		}
		if text = jointText(part.Content); text != "" {
			return text
		}
	}
	return ""
}
