//go:build meton_managed

// 原审核材料离线核验；不启动后台或恢复历史审核人员的执行资格。
package main

import (
	"encoding/json"
	"fmt"
	"github.com/Wei-Shaw/sub2api/internal/repository/metonentry"
	"os"
)

/** main 从私有 stdin 取原材料，仅交付计数，原材料及历史身份不回显。 */
func main() {
	if len(os.Args) != 1 {
		fmt.Fprintln(os.Stderr, "离线审核核验不接受执行参数")
		os.Exit(2)
	}
	result, err := metonentry.InspectCashReviewMaterials(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "原审核材料无法核验")
		os.Exit(2)
	}
	if json.NewEncoder(os.Stdout).Encode(result) != nil || !result.AllVerified {
		os.Exit(2)
	}
}
