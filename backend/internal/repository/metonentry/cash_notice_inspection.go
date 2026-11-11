//go:build meton_managed

package metonentry

import (
	"crypto/cipher"
	"encoding/binary"
	"encoding/hex"
	"io"
	"regexp"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/service"
)

/** CashNoticeInspectionScope 由范围外的固定材料确定原写入范围；旧代次只用于验真，不成为当前执行资格。 */
type CashNoticeInspectionScope struct {
	Environment     string `json:"environment"`
	Source          string `json:"source"`
	Epoch           int64  `json:"epoch"`
	SourceSystem    string `json:"source_system"`
	InboxSystem     string `json:"inbox_system"`
	Channel         string `json:"channel"`
	CashEnvironment string `json:"cash_environment"`
	Merchant        string `json:"merchant"`
	App             string `json:"app"`
}

/** CashNoticeProofHeader 只描述后续密文字节，不包含文件路径、数据库连接或执行票据。 */
type CashNoticeProofHeader struct {
	Kind     string `json:"kind"`
	Delivery string `json:"delivery"`
	KeyRef   string `json:"key_ref"`
	Digest   string `json:"digest"`
	Size     int    `json:"size_bytes"`
}

type cashNoticeInspectionInput struct {
	Version int                       `json:"format_version"`
	Kind    string                    `json:"kind"`
	Scope   CashNoticeInspectionScope `json:"scope"`
	Keys    map[string][]byte         `json:"keys"`
	Proofs  []CashNoticeProofHeader   `json:"proofs"`
}

/** CashNoticeInspection 返回批次计数，不回显商户、账号、通知正文或密钥；验真不授予任何恢复执行权。 */
type CashNoticeInspection struct {
	Version                   int    `json:"format_version"`
	State                     string `json:"state"`
	Proofs                    int    `json:"proofs"`
	Verified                  int    `json:"verified"`
	MissingKey                int    `json:"missing_key"`
	Review                    int    `json:"review"`
	Foreign                   int    `json:"foreign"`
	AllVerified               bool   `json:"all_verified"`
	FinancialCoverageVerified bool   `json:"financial_coverage_verified"`
	CredentialsRestored       bool   `json:"credentials_restored"`
	ExecutionAuthorized       bool   `json:"execution_authorized"`
	DeletionAuthorized        bool   `json:"deletion_authorized"`
	FormalOpeningAuthorized   bool   `json:"formal_opening_authorized"`
}

var inspectionName = regexp.MustCompile(`^[A-Za-z0-9_.:-]{1,192}$`)

/** InspectCashNoticeMaterials 只读有界帧并复用原 openProof。密文单独分帧以容纳原 1 MiB 通知，不放宽原部署 JSON 解析预算。 */
func InspectCashNoticeMaterials(reader io.Reader) (CashNoticeInspection, error) {
	bad := func() (CashNoticeInspection, error) { return CashNoticeInspection{}, service.ErrMetonClosed }
	var length uint32
	if binary.Read(reader, binary.BigEndian, &length) != nil || length == 0 || length > 256*1024 {
		return bad()
	}
	raw := make([]byte, length)
	defer clear(raw)
	if _, err := io.ReadFull(reader, raw); err != nil {
		return bad()
	}
	var input cashNoticeInspectionInput
	if metonexecution.DecodeStrict(raw, &input) != nil {
		return bad()
	}
	defer func() {
		for _, key := range input.Keys {
			clear(key)
		}
	}()
	c := input.Scope
	if input.Version != 1 || input.Kind != "meton.s3.cash-notice-inspection.v1" || len(input.Proofs) == 0 || len(input.Proofs) > 128 ||
		len(input.Keys) > 256 || !inspectionName.MatchString(c.Environment) || !inspectionName.MatchString(c.Source) || c.Epoch < 1 ||
		!pgSystemNumber.MatchString(c.SourceSystem) || !pgSystemNumber.MatchString(c.InboxSystem) || c.SourceSystem == c.InboxSystem ||
		c.Channel != "wechatpay" || (c.CashEnvironment != "isolated" && c.CashEnvironment != "live") || !inspectionName.MatchString(c.Merchant) || !inspectionName.MatchString(c.App) {
		return bad()
	}
	w := &purchaseWorker{n: &cashNoticeStore{cfg: notificationConfig{Environment: c.Environment, Source: c.Source, Epoch: c.Epoch,
		SourceSystem: c.SourceSystem, InboxSystem: c.InboxSystem, Route: service.CheckoutPaymentRoute{Channel: c.Channel, Environment: c.CashEnvironment, Merchant: c.Merchant, App: c.App}}},
		keys: map[string]cipher.AEAD{}}
	for ref, rawKey := range input.Keys {
		if !noticeKeyRef.MatchString(ref) {
			return bad()
		}
		key, err := parseCashRecoveryKey(rawKey)
		if err != nil {
			return bad()
		}
		w.keys[ref] = key
	}
	seen := map[string]bool{}
	total := 0
	for _, proof := range input.Proofs {
		identity := proof.Kind + "\x00" + proof.Delivery + "\x00" + proof.Digest
		digest, err := hex.DecodeString(proof.Digest)
		if (proof.Kind != "payment" && proof.Kind != "payment_query" && proof.Kind != "refund") || !inspectionName.MatchString(proof.Delivery) ||
			!noticeKeyRef.MatchString(proof.KeyRef) || err != nil || len(digest) != 32 || hex.EncodeToString(digest) != proof.Digest ||
			proof.Size < 28 || proof.Size > 2*1024*1024 || seen[identity] {
			return bad()
		}
		seen[identity] = true
		total += proof.Size
		if total > 16*1024*1024 {
			return bad()
		}
	}
	out := CashNoticeInspection{Version: 1, State: "original_notices_checked", Proofs: len(input.Proofs)}
	for _, proof := range input.Proofs {
		sealed := make([]byte, proof.Size)
		if _, err := io.ReadFull(reader, sealed); err != nil {
			return bad()
		}
		digest, _ := hex.DecodeString(proof.Digest)
		original, failed := w.openProof(proof.Kind, proof.Delivery, proof.KeyRef, digest, sealed)
		clear(sealed)
		if failed == nil {
			clear(original.basis)
			out.Verified++
		} else if failed.state == "retry" {
			out.MissingKey++
		} else if failed.state == "foreign" {
			out.Foreign++
		} else {
			out.Review++
		}
	}
	// 额外尾部可能是错误拼接的第二批材料，不能只验证首批后忽略它。
	var trailing [1]byte
	if n, err := reader.Read(trailing[:]); n != 0 || err != io.EOF {
		return bad()
	}
	out.AllVerified = out.Verified == out.Proofs
	return out, nil
}
