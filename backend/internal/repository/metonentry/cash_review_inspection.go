//go:build meton_managed

package metonentry

import (
	"crypto/cipher"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"io"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/google/uuid"
)

type cashReviewProof struct {
	Kind      string    `json:"kind"`
	Reference uuid.UUID `json:"reference"`
	Operation uuid.UUID `json:"operation"`
	KeyRef    string    `json:"key_ref"`
	Route     string    `json:"route"`
	Facts     string    `json:"facts"`
	Size      int       `json:"size_bytes"`
}

type cashReviewMaterialRoute struct {
	Deployment      string    `json:"deployment"`
	Source          string    `json:"source"`
	Epoch           int64     `json:"epoch"`
	KeyRef          uuid.UUID `json:"keyRef"`
	SourceSystem    string    `json:"sourceSystem"`
	InboxSystem     string    `json:"inboxSystem"`
	Channel         string    `json:"channel"`
	CashEnvironment string    `json:"cashEnvironment"`
	Merchant        string    `json:"merchant"`
	App             string    `json:"app"`
}

/** openOriginalReview 只解封本来的审核事实和材料摘要；历史批准不成为新的支付或当前人员权限。 */
func openOriginalReview(p cashReviewProof, key cipher.AEAD, sealed []byte) bool {
	kind := payerReview
	if p.Kind == "alternative" {
		kind = alternativeReview
	} else if p.Kind == "dispute" {
		kind = cashDisputeReview
	}
	digest := sha256.Sum256([]byte(p.Facts))
	aad, _, err := reviewMaterialAAD(kind, json.RawMessage(p.Route), p.Reference, p.Operation, p.KeyRef, hex.EncodeToString(digest[:]))
	if err != nil || len(sealed) < key.NonceSize()+key.Overhead() {
		return false
	}
	raw, err := key.Open(nil, sealed[:key.NonceSize()], sealed[key.NonceSize():], aad)
	if err != nil {
		return false
	}
	defer clear(raw)
	var value struct {
		Version  int    `json:"format_version"`
		Facts    string `json:"facts"`
		Material []byte `json:"material"`
	}
	if metonexecution.DecodeStrict(raw, &value) != nil {
		return false
	}
	defer clear(value.Material)
	if value.Version != 1 || value.Facts != p.Facts || len(value.Material) == 0 || len(value.Material) > 512*1024 {
		return false
	}
	// 事实形状和结论权限由原写入权威决定；恢复只核对原类型、原事项和材料字节，不重新批准业务。
	var facts map[string]json.RawMessage
	if metonexecution.DecodeStrict([]byte(value.Facts), &facts) != nil {
		return false
	}
	var materialHash, reference string
	var version int
	field := "refund"
	if p.Kind == "dispute" {
		field = "id"
	}
	if json.Unmarshal(facts["materialHash"], &materialHash) != nil || json.Unmarshal(facts[field], &reference) != nil ||
		json.Unmarshal(facts["format"], &version) != nil || version != 1 || reference != p.Reference.String() {
		return false
	}
	actual := sha256.Sum256(value.Material)
	return materialHash == hex.EncodeToString(actual[:])
}

/** InspectCashReviewMaterials 原审核材料有自己的格式和密钥用途，复用有界输入及计数回执，不连接库或渠道。 */
func InspectCashReviewMaterials(reader io.Reader) (CashNoticeInspection, error) {
	bad := func() (CashNoticeInspection, error) { return CashNoticeInspection{}, service.ErrMetonClosed }
	var size uint32
	if binary.Read(reader, binary.BigEndian, &size) != nil || size == 0 || size > 1024*1024 {
		return bad()
	}
	raw := make([]byte, size)
	defer clear(raw)
	if _, err := io.ReadFull(reader, raw); err != nil {
		return bad()
	}
	var input struct {
		Version int                       `json:"format_version"`
		Kind    string                    `json:"kind"`
		Scope   CashNoticeInspectionScope `json:"scope"`
		Keys    map[string][]byte         `json:"keys"`
		Proofs  []cashReviewProof         `json:"proofs"`
	}
	if metonexecution.DecodeStrict(raw, &input) != nil {
		return bad()
	}
	defer func() {
		for _, key := range input.Keys {
			clear(key)
		}
	}()
	scope := input.Scope
	if input.Version != 1 || input.Kind != "meton.s3.cash-review-inspection.v1" || len(input.Proofs) == 0 || len(input.Proofs) > 64 || len(input.Keys) > 256 ||
		!inspectionName.MatchString(scope.Environment) || !inspectionName.MatchString(scope.Source) || scope.Epoch < 1 ||
		!pgSystemNumber.MatchString(scope.SourceSystem) || !pgSystemNumber.MatchString(scope.InboxSystem) || scope.SourceSystem == scope.InboxSystem ||
		scope.Channel != "wechatpay" || (scope.CashEnvironment != "isolated" && scope.CashEnvironment != "live") || !inspectionName.MatchString(scope.Merchant) || !inspectionName.MatchString(scope.App) {
		return bad()
	}
	keys := map[string]cipher.AEAD{}
	for ref, value := range input.Keys {
		if !noticeKeyRef.MatchString(ref) {
			return bad()
		}
		key, err := parseCashRecoveryKey(value)
		if err != nil {
			return bad()
		}
		keys[ref] = key
	}
	total := 0
	seen := map[string]bool{}
	for _, p := range input.Proofs {
		identity := p.Kind + "/" + p.Reference.String() + "/" + p.Operation.String()
		if (p.Kind != "payer" && p.Kind != "alternative" && p.Kind != "dispute") || p.Reference == uuid.Nil || p.Operation == uuid.Nil ||
			!noticeKeyRef.MatchString(p.KeyRef) || len(p.Route) == 0 || len(p.Route) > 8192 || len(p.Facts) == 0 || len(p.Facts) > 8192 ||
			p.Size < 29 || p.Size > 1572864 || seen[identity] {
			return bad()
		}
		seen[identity] = true
		total += p.Size
		if total > 16*1024*1024 {
			return bad()
		}
	}
	result := CashNoticeInspection{Version: 1, State: "original_reviews_checked", Proofs: len(input.Proofs)}
	for _, p := range input.Proofs {
		sealed := make([]byte, p.Size)
		if _, err := io.ReadFull(reader, sealed); err != nil {
			return bad()
		}
		var route cashReviewMaterialRoute
		if metonexecution.DecodeStrict([]byte(p.Route), &route) != nil || route.KeyRef == uuid.Nil || route.Epoch < 1 || route.Epoch > scope.Epoch {
			result.Review++
		} else if route.Deployment != scope.Environment || route.Source != scope.Source || route.SourceSystem != scope.SourceSystem ||
			route.InboxSystem != scope.InboxSystem || route.Channel != scope.Channel || route.CashEnvironment != scope.CashEnvironment ||
			route.Merchant != scope.Merchant || route.App != scope.App {
			result.Foreign++
		} else if keys[p.KeyRef] == nil {
			result.MissingKey++
		} else if !openOriginalReview(p, keys[p.KeyRef], sealed) {
			result.Review++
		} else {
			result.Verified++
		}
		clear(sealed)
	}
	var trailing [1]byte
	if n, err := reader.Read(trailing[:]); n != 0 || err != io.EOF {
		return bad()
	}
	result.AllVerified = result.Verified == result.Proofs
	return result, nil
}
