package service

import (
	"context"
	"encoding/json"
	"os"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonmodel"
	"github.com/google/uuid"
)

type MetonModelReadStore interface {
	OriginalModel(context.Context, MetonManagedSource, uuid.UUID, string, uuid.UUID, *uuid.UUID) (json.RawMessage, error)
}

/** ModelReadID 独立于账号、会话和赠送权限。没有来源模式或专用密钥时不能降级到原生模型接口。 */
func (s MetonManagedSource) ModelReadID() (string, bool) {
	id := os.Getenv("METON_MANAGED_MODEL_READ_KEY_ID")
	if os.Getenv("METON_MANAGED_FUNDS_MODE") != "s2-source-v1" || !metonKeyID.MatchString(id) || id == s.CreateKeyID || id == s.ReadKeyID {
		return "", false
	}
	for _, key := range []string{"FUNDS_READ", "ISSUE", "INSPECT", "ROTATE", "CLOSE", "GRANT_WRITE", "GRANT_READ", "MODEL_CANCEL"} {
		if id == os.Getenv("METON_MANAGED_"+key+"_KEY_ID") {
			return "", false
		}
	}
	return id, true
}

/** OriginalModel 只查询固定原操作，缺仓储或归属不符时关闭，不借其他管理权限补造记录。 */
func (s *adminServiceImpl) OriginalModel(ctx context.Context, source MetonManagedSource, creation uuid.UUID, caller string, operation uuid.UUID, event *uuid.UUID) (json.RawMessage, error) {
	live, available := MetonSource()
	_, readable := source.ModelReadID()
	repo, ok := s.userRepo.(MetonModelReadStore)
	if !available || !readable || live != source || !ok || creation == uuid.Nil || operation == uuid.Nil ||
		(caller != "meton.chat.v1" && caller != "meton.oc07.v1") || event != nil && *event == uuid.Nil {
		return nil, ErrMetonClosed
	}
	raw, err := repo.OriginalModel(ctx, source, creation, caller, operation, event)
	if err != nil {
		return nil, ErrMetonClosed
	}
	if len(raw) == 0 {
		return nil, nil
	}
	var normalized []byte
	if event == nil {
		a, err := metonmodel.ReadAdmission(raw)
		if err != nil || a.AcceptedEpoch > source.Epoch || a.Origin.Environment != source.Environment || a.Origin.Source != source.Source || a.Origin.Caller != caller || a.Origin.OperationID != operation.String() {
			return nil, ErrMetonClosed
		}
		normalized, err = json.Marshal(a)
		if err != nil {
			return nil, ErrMetonClosed
		}
	} else {
		f, err := metonmodel.ReadFee(raw)
		if err != nil || f.Origin.Environment != source.Environment || f.Origin.Source != source.Source || f.Origin.Caller != caller || f.Origin.OperationID != operation.String() || f.Item.EventID != event.String() {
			return nil, ErrMetonClosed
		}
		normalized, err = json.Marshal(f)
		if err != nil {
			return nil, ErrMetonClosed
		}
	}
	if current, ok := MetonSource(); !ok || current != source {
		return nil, ErrMetonClosed
	}
	return normalized, nil
}
