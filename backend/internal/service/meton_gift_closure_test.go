//go:build meton_managed

package service

import (
	"context"
	"strings"
	"testing"
)

func TestMetonGiftClosurePermissionIsolation(t *testing.T) {
	for k, v := range map[string]string{"ENVIRONMENT": "s2-isolated", "SOURCE": "s2-managed", "EPOCH": "1", "FUNDS_MODE": "s2-source-v1",
		"CREATE_KEY_ID": strings.Repeat("1", 24), "READ_KEY_ID": strings.Repeat("2", 24), "GIFT_READ_KEY_ID": strings.Repeat("b", 24), "GIFT_CLOSE_KEY_ID": strings.Repeat("c", 24)} {
		t.Setenv("METON_MANAGED_"+k, v)
	}
	source, ok := MetonSource()
	if !ok {
		t.Fatal("fixture source")
	}
	if _, ok = source.GiftClosureKeyID(true); !ok {
		t.Fatal("separate identities rejected")
	}
	if _, err := (*MetonGiftClosure)(nil).Execute(context.Background(), source, "inspect", MetonGiftRequest{}); err == nil {
		t.Fatal("missing runtime")
	}
	for _, name := range []string{"CREATE", "READ", "FUNDS_READ", "ISSUE", "INSPECT", "ROTATE", "CLOSE", "GRANT_WRITE", "GRANT_READ", "MODEL_READ", "MODEL_CANCEL", "GIFT_READ"} {
		t.Run(name, func(t *testing.T) {
			t.Setenv("METON_MANAGED_"+name+"_KEY_ID", strings.Repeat("c", 24))
			if _, ok := source.GiftClosureKeyID(true); ok {
				t.Fatal("shared identity accepted")
			}
		})
	}
	t.Setenv("METON_MANAGED_FUNDS_MODE", "s1-closed-v1")
	if _, ok := source.GiftClosureKeyID(false); ok {
		t.Fatal("old mode accepted")
	}
}
