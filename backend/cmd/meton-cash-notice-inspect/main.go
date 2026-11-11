//go:build meton_managed

// 原资金通知离线核验；没有服务启动、数据库连接或支付派发入口。
package main

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/Wei-Shaw/sub2api/internal/repository/metonentry"
)

/** main 只经 stdin 接收私有材料，输出不含原正文；任何缺证结果都以非零退出。 */
func main() {
	if len(os.Args) != 1 {
		fmt.Fprintln(os.Stderr, "离线核验不接受连接或执行参数")
		os.Exit(2)
	}
	result, err := metonentry.InspectCashNoticeMaterials(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "原现金通知材料无法核验")
		os.Exit(2)
	}
	if json.NewEncoder(os.Stdout).Encode(result) != nil || !result.AllVerified {
		os.Exit(2)
	}
}
