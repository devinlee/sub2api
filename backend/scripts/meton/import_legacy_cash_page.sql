-- 运行方用只可执行 accept_legacy_cash_page 的隔离迁移角色连接原来源，传入受信的原账号映射、库身份及 S2 截点。
-- after_order 从零起，后续页取上一页返回的 next；提交应答不明时原样重跑原页。
\set ON_ERROR_STOP on
BEGIN ISOLATION LEVEL READ COMMITTED;
SET LOCAL synchronous_commit=on;
SELECT meton_ledger.accept_legacy_cash_page(:'origin'::jsonb,:'cutoff'::uuid,:'after_order'::bigint,:'page_size'::integer) AS receipt \gset
COMMIT;
\echo :receipt
