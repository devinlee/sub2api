//go:build meton_managed

// 旧退款维护入口使用分开的来源和归档角色。商户请求始终由原支付服务负责。
package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/lib/pq"
)

type oldOrder struct {
	Order    int64           `json:"order"`
	Manifest json.RawMessage `json:"manifest"`
}
type request struct {
	Owner      json.RawMessage `json:"owner"`
	Cutoff     string          `json:"cutoff"`
	Activation string          `json:"activation"`
	Review     string          `json:"review"`
	Evidence   string          `json:"evidence"`
	Orders     []oldOrder      `json:"orders"`
}
type material struct {
	Scope  json.RawMessage `json:"scope"`
	Target json.RawMessage `json:"target"`
	Permit string          `json:"permit"`
}
type outcome struct {
	State string            `json:"state"`
	Items []json.RawMessage `json:"items,omitempty"`
}

/** input 只读指定的本地文件，连接秘密和带签章的归还材料均不回显。 */
func input(path string, limit int64) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil || int64(len(b)) > limit {
		return nil, errors.New("本机维护输入过大或读取失败")
	}
	return b, nil
}
func connect(path string) (*sql.DB, error) {
	b, err := input(path, 8192)
	if err != nil {
		return nil, err
	}
	if len(b) == 0 {
		return nil, errors.New("缺少数据库配置")
	}
	return sql.Open("postgres", strings.TrimSpace(string(b)))
}

/** inspect 只按原账号、截点和原订单读取，结果未知时可独立使用。 */
func inspect(ctx context.Context, db *sql.DB, r request) (outcome, error) {
	out := outcome{State: "observed"}
	for _, o := range r.Orders {
		var v []byte
		err := db.QueryRowContext(ctx, "SELECT meton_ledger.find_legacy_refund_return($1,$2,$3)", string(r.Owner), r.Cutoff, o.Order).Scan(&v)
		if err != nil {
			return outcome{}, err
		}
		if v == nil {
			v = []byte("null")
		}
		out.Items = append(out.Items, v)
	}
	return out, nil
}

/** collect 在归档事务中取得所有原交易锁。归档批准必须先持久提交，随后才会交付带签章的凭据。 */
func collect(ctx context.Context, src *sql.DB, archive *sql.Tx, r request) ([]json.RawMessage, string, error) {
	var result []json.RawMessage
	state := "proved"
	for _, o := range r.Orders {
		var raw []byte
		err := src.QueryRowContext(ctx, "SELECT meton_ledger.legacy_refund_review_material($1,$2,$3)", string(r.Owner), r.Cutoff, o.Order).Scan(&raw)
		if err != nil {
			return nil, "", err
		}
		var m material
		if len(raw) == 0 || json.Unmarshal(raw, &m) != nil || m.Permit == "" {
			return nil, "review", nil
		}
		if err = archive.QueryRowContext(ctx, "SELECT meton_inbox.review_legacy_refund_return($1,$2,$3,$4)", string(m.Scope), string(m.Target), m.Permit, string(o.Manifest)).Scan(&raw); err != nil {
			return nil, "", err
		}
		var answer struct{ State string }
		if err = json.Unmarshal(raw, &answer); err != nil {
			return nil, "", err
		}
		switch answer.State {
		case "proved":
			result = append(result, json.RawMessage(raw))
		case "recorded":
			state = "recorded"
		case "review", "evidence_pending", "writers_pending":
			return nil, answer.State, nil
		default:
			return nil, "", errors.New("归档回执不完整")
		}
	}
	return result, state, nil
}

/** apply 保持归档原号锁直至来源提交。来源提交应答丢失后只查原决定，不重新创建现金尝试。 */
func apply(ctx context.Context, src *sql.DB, mode string, r request, proofs []json.RawMessage) error {
	tx, err := src.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if mode == "prepare" {
		for i, o := range r.Orders {
			var id string
			err = tx.QueryRowContext(ctx, "SELECT meton_ledger.accept_legacy_refund_return($1,$2,$3,$4)", string(r.Owner), r.Cutoff, o.Order, string(proofs[i])).Scan(&id)
			if err != nil {
				return err
			}
		}
	} else {
		raw, err := json.Marshal(proofs)
		if err != nil {
			return err
		}
		var id string
		err = tx.QueryRowContext(ctx, "SELECT meton_ledger.open_legacy_refunds($1,$2,$3,$4,$5,$6)", string(r.Owner), r.Cutoff, r.Activation, r.Review, r.Evidence, string(raw)).Scan(&id)
		if err != nil {
			return err
		}
	}
	return tx.Commit()
}

func execute(ctx context.Context, src, external *sql.DB, mode string, r request) (outcome, error) {
	if len(r.Orders) == 0 || len(r.Orders) > 100 || len(r.Owner) == 0 {
		return outcome{}, errors.New("缺少原账号和订单")
	}
	sort.Slice(r.Orders, func(i, j int) bool { return r.Orders[i].Order < r.Orders[j].Order })
	for i, o := range r.Orders {
		if o.Order <= 0 || i > 0 && r.Orders[i-1].Order == o.Order {
			return outcome{}, errors.New("原订单号重复或无效")
		}
	}
	if mode == "status" {
		return inspect(ctx, src, r)
	}
	if mode != "apply" && mode != "prepare" {
		return outcome{}, errors.New("模式须为 prepare、apply 或 status")
	}
	for pass := 0; pass < 2; pass++ {
		archive, err := external.BeginTx(ctx, nil)
		if err != nil {
			return outcome{}, err
		}
		proofs, state, err := collect(ctx, src, archive, r)
		if err != nil {
			archive.Rollback()
			return outcome{}, err
		}
		if state == "recorded" {
			if err = archive.Commit(); err != nil {
				return outcome{}, err
			}
			continue
		}
		if state != "proved" {
			archive.Rollback()
			return outcome{State: state}, nil
		}
		err = apply(ctx, src, mode, r, proofs)
		if err != nil {
			archive.Rollback()
			return outcome{}, err
		}
		// 来源已提交，归档本次只读证明。两边最终均能按原号重查。
		if err = archive.Commit(); err != nil {
			return outcome{}, err
		}
		return inspect(ctx, src, r)
	}
	return outcome{State: "evidence_pending"}, nil
}
func run() error {
	mode := flag.String("mode", "status", "prepare、apply 或 status")
	config := flag.String("request", "", "本机原订单审核文件")
	source := flag.String("source-dsn-file", "", "来源受限连接文件")
	archive := flag.String("archive-dsn-file", "", "截点外复核连接文件")
	flag.Parse()
	raw, err := input(*config, 2<<20)
	if err != nil {
		return err
	}
	var r request
	if err = json.Unmarshal(raw, &r); err != nil {
		return errors.New("原单审核文件格式不符")
	}
	src, err := connect(*source)
	if err != nil {
		return err
	}
	defer src.Close()
	var ext *sql.DB
	if *mode != "status" {
		ext, err = connect(*archive)
		if err != nil {
			return err
		}
		defer ext.Close()
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	result, err := execute(ctx, src, ext, *mode, r)
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(result)
}
func main() {
	if err := run(); err != nil {
		// 驱动错误可能包含连接资料。只交付状态；原号的查询决定下一步。
		var dbError *pq.Error
		if errors.As(err, &dbError) {
			fmt.Fprintf(os.Stderr, "数据库状态 %s。\n", dbError.Code)
		}
		fmt.Fprintln(os.Stderr, "旧退款操作未获确认，请按原账号和原订单查询。")
		os.Exit(1)
	}
}
