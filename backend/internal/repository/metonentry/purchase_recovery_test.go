//go:build meton_managed

package metonentry

import (
	"context"
	"database/sql"
	"encoding/json"
	"os"
	"testing"
	"time"
)

/** 实际恢复副本上的原处理器：只验新增恢复结果，不重跑签名、下单或退款矩阵。 */
func TestRecoveredPurchaseKeepsOriginalDisposition(t *testing.T) {
	tag := os.Getenv("METON_S324_RUN")
	if tag == "" {
		t.Skip("需要独立恢复副本")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	admin, err := sql.Open("postgres", "host=127.0.0.1 port=5432 user=postgres dbname=s324_restored sslmode=disable")
	if err != nil {
		t.Fatal(err)
	}
	defer admin.Close()
	var actual, system string
	if err = admin.QueryRowContext(ctx, "SELECT fixture,meton_ledger.notification_system_id() FROM s324_guard").Scan(&actual, &system); err != nil || actual != tag {
		t.Fatal("不是本轮恢复副本", err)
	}
	writer, err := sql.Open("postgres", "host=127.0.0.1 port=5432 user=s313_post dbname=s324_restored sslmode=disable")
	if err != nil {
		t.Fatal(err)
	}
	defer writer.Close()
	for _, name := range []string{"posted", "received", "unobserved"} {
		t.Run(name, func(t *testing.T) {
			var origin, facts []byte
			var environment, source string
			if err := admin.QueryRowContext(ctx, "SELECT origin,facts,environment,source FROM s324_cases WHERE name=$1", name).Scan(&origin, &facts, &environment, &source); err != nil {
				t.Fatal(err)
			}
			proof := &purchaseProof{Origin: origin}
			if err := json.Unmarshal(facts, &proof.Notice); err != nil {
				t.Fatal(err)
			}
			worker := &purchaseWorker{source: writer, n: &cashNoticeStore{cfg: notificationConfig{
				Environment: environment, Source: source, Epoch: 2, SourceSystem: system,
			}}}
			want := purchaseOutcome{"review", "original_disposition_missing"}
			if name == "posted" {
				want = purchaseOutcome{"posted", "original_purchase"}
			}
			for repeat := 0; repeat < 2; repeat++ {
				if got := worker.post(ctx, proof); got != want {
					t.Fatalf("恢复结果 %v，预期 %v", got, want)
				}
			}
		})
	}
}
