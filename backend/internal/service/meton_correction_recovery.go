package service

// CorrectionKeyHistory 是外部部署输入，仅列公开 ID。数据库的管理账户和实际鉴权仍归原存储。
type CorrectionKeyHistory struct {
	FormatVersion int                       `json:"format_version"`
	Environment   string                    `json:"environment"`
	Source        string                    `json:"source"`
	Generations   []CorrectionKeyGeneration `json:"generations"`
}

type CorrectionKeyGeneration struct {
	Epoch     int64  `json:"epoch"`
	ReadID    string `json:"read_id"`
	ApproveID string `json:"approve_id"`
	ApplyID   string `json:"apply_id"`
}

type correctionHistory struct {
	epochs  map[int64]bool
	retired map[string]bool
}

/** 从独立历史复制可读代次。一个已用 ID 不能被另一个角色或新恢复代次重新接纳。 */
func (h *CorrectionKeyHistory) verified(source MetonManagedSource, current correctionIDs) (*correctionHistory, bool) {
	if h == nil {
		if source.Epoch == 1 {
			return &correctionHistory{epochs: map[int64]bool{1: true}}, true
		}
		return nil, false
	}
	n := len(h.Generations)
	if h.FormatVersion != 1 || h.Environment != source.Environment || h.Source != source.Source || n == 0 ||
		h.Generations[0].Epoch != 1 || h.Generations[n-1].Epoch != source.Epoch {
		return nil, false
	}
	seen := map[string]bool{}
	retired := map[string]bool{}
	epochs := map[int64]bool{}
	var previous int64
	for i, g := range h.Generations {
		if previous >= g.Epoch {
			return nil, false
		}
		previous = g.Epoch
		epochs[g.Epoch] = true
		ids := correctionIDs{g.ReadID, g.ApproveID, g.ApplyID}
		if i == n-1 && ids != current {
			return nil, false
		}
		if ids == (correctionIDs{}) {
			continue
		}
		for _, id := range []string{ids.read, ids.approve, ids.apply} {
			if !metonKeyID.MatchString(id) || seen[id] {
				return nil, false
			}
			seen[id] = true
			if i < n-1 {
				retired[id] = true
			}
		}
	}
	return &correctionHistory{epochs: epochs, retired: retired}, true
}
