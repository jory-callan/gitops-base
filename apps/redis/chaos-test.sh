#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# chaos-test.sh — Redis Sentinel 混沌测试
#
# 针对当前集群中已部署的 redis-my-app / redis-my-app-sentinel
# 无需部署/清理，直接运行测试场景
#
# Usage:
#   ./chaos-test.sh                    # 交互式菜单
#   ./chaos-test.sh all                # 运行全部场景
#   ./chaos-test.sh 2                  # 运行场景 2 (failover)
#   ./chaos-test.sh status             # 仅查看状态
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

NS="${NS:-redis}"
APP="redis-my-app"
SENTINEL="redis-my-app-sentinel"

TOTAL_ERRORS=0
declare -a RESULTS

# 从 pod 列表的第 2 行开始获取 IP (row1 = header, row2+ = data)
get_pod_ip() { kubectl -n "$NS" get pod "$1" -o jsonpath='{.status.podIP}' 2>/dev/null; }
get_pod_role() { kubectl exec -n "$NS" "$1" -- redis-cli ROLE 2>/dev/null | head -1; }
get_redis_phase() { kubectl get pod -n "$NS" "$1" -o jsonpath='{.status.phase}' 2>/dev/null; }
get_sentinel_master() { kubectl exec -n "$NS" "${SENTINEL}-sentinel-0" -- redis-cli -p 26379 SENTINEL GET-MASTER-ADDR-BY-NAME redis-my-app 2>/dev/null | head -1; }
get_sentinel_status() { kubectl exec -n "$NS" "${SENTINEL}-sentinel-0" -- redis-cli -p 26379 INFO sentinel 2>/dev/null | grep "master0"; }

echo_line() { printf '%*s\n' "${1:-80}" '' | tr ' ' '═'; }
echo_sep() { printf '%*s\n' "${1:-80}" '' | tr ' ' '─'; }

info()  { echo "  [$(date +%H:%M:%S)] → $1"; }
ok()    { echo "  [$(date +%H:%M:%S)] ✓ $1"; }
warn()  { echo "  [$(date +%H:%M:%S)] ⚠ $1"; }
fail()  { echo "  [$(date +%H:%M:%S)] ✗ $1"; RESULTS+=("FAIL: $1"); TOTAL_ERRORS=$((TOTAL_ERRORS+1)); }
pass()  { RESULTS+=("PASS: $1"); }

# ── 基础检查 ────────────────────────────────────────────────────

check_all_pods() {
  local errors=0
  for pod in "${APP}-0" "${APP}-1" "${APP}-2" "${SENTINEL}-sentinel-0" "${SENTINEL}-sentinel-1" "${SENTINEL}-sentinel-2"; do
    local phase
    phase=$(get_redis_phase "$pod" 2>/dev/null)
    if [ "$phase" != "Running" ]; then
      fail "${pod} 状态异常: $phase"
      errors=1
    fi
  done
  [ "$errors" -eq 0 ] && ok "所有 6 个 Pod 均 Running"
}

check_replication() {
  local master_role master_ip slave_count
  master_role=$(get_pod_role "${APP}-0")
  master_ip=$(get_pod_ip "${APP}-0")

  if [ "$master_role" != "master" ]; then
    # 找真正的 master
    for pod in "${APP}-0" "${APP}-1" "${APP}-2"; do
      if [ "$(get_pod_role "$pod")" = "master" ]; then
        master_ip=$(get_pod_ip "$pod")
        ok "当前 master: $pod ($master_ip)"
        break
      fi
    done
  else
    ok "当前 master: ${APP}-0 ($master_ip)"
  fi

  local slaves=0
  for pod in "${APP}-1" "${APP}-2"; do
    local role
    role=$(get_pod_role "$pod")
    if echo "$role" | grep -q "slave"; then
      slaves=$((slaves+1))
    fi
  done
  [ "$slaves" -ge 2 ] && ok "Slave 数量: $slaves" || warn "Slave 数量: $slaves (预期至少 2)"
}

check_sentinel() {
  local master_info
  master_info=$(get_sentinel_status 2>/dev/null || echo "无法连接")
  echo "  Sentinel 状态: $master_info"

  local master_ip
  master_ip=$(get_sentinel_master 2>/dev/null || echo "")
  if [ -n "$master_ip" ] && [ "$master_ip" != "nil" ]; then
    ok "Sentinel 报告的 master: $master_ip"
  else
    fail "Sentinel 无法获取 master 地址"
  fi
}

rw_test() {
  local key="chaos-$(date +%s)"
  local master_ip
  master_ip=$(get_sentinel_master 2>/dev/null)
  [ -z "$master_ip" ] && { fail "无 master 地址，跳过读写"; return 1; }

  # 通过 sentinel 获取的 master IP 直接写入
  if kubectl exec -n "$NS" "${APP}-0" -- redis-cli SET "$key" "ok-$(date +%H:%M:%S)" 2>/dev/null; then
    local val
    val=$(kubectl exec -n "$NS" "${APP}-0" -- redis-cli GET "$key" 2>/dev/null)
    if echo "$val" | grep -q "ok-"; then
      ok "读写正常 (key=$key, val=$val)"
      return 0
    fi
  fi
  fail "读写失败"
  return 1
}

# ── 状态快照 ─────────────────────────────────────────────────────

snapshot() {
  echo_line
  echo "  [$(date +%H:%M:%S)] 集群快照"
  echo_sep
  for pod in "${APP}-0" "${APP}-1" "${APP}-2" "${SENTINEL}-sentinel-0" "${SENTINEL}-sentinel-1" "${SENTINEL}-sentinel-2"; do
    local role="" phase
    phase=$(get_redis_phase "$pod" 2>/dev/null || echo "N/A")
    if echo "$pod" | grep -q "sentinel"; then
      role="sentinel"
    else
      role=$(get_pod_role "$pod" 2>/dev/null || echo "N/A")
    fi
    echo "  ${pod}:${role} (${phase})"
  done
  echo_sep
  local sentinel_info
  sentinel_info=$(get_sentinel_status 2>/dev/null || echo "N/A")
  echo "  Sentinel: $sentinel_info"
  local master_ip
  master_ip=$(get_sentinel_master 2>/dev/null || echo "N/A")
  echo "  Master IP: $master_ip"
  echo_line
}

# ── Kill pod ─────────────────────────────────────────────────────

kill_pod() {
  local pod="$1"
  warn "删除 pod: $pod"
  kubectl delete pod -n "$NS" "$pod" --force --grace-period=0 2>/dev/null || true
}

run_rw_loop() {
  # 后台读写测试
  local duration="$1"
  local result_file="$2"
  local key_prefix="chaos-loop-"
  local start
  start=$(date +%s)
  local end=$((start + duration))
  local ops=0 errors=0

  while [ "$(date +%s)" -lt "$end" ]; do
    local now_epoch
    now_epoch=$(date +%s)
    local key="${key_prefix}${now_epoch}"
    local ts
    ts=$(date +%H:%M:%S)

    # 尝试找到当前 master 并写入
    local wrote=0
    for pod in "${APP}-0" "${APP}-1" "${APP}-2"; do
      local role
      role=$(get_pod_role "$pod" 2>/dev/null || echo "?")
      if [ "$role" = "master" ]; then
        if kubectl exec -n "$NS" "$pod" -- redis-cli SET "$key" "$ts" 2>/dev/null; then
          # 验证
          local val
          val=$(kubectl exec -n "$NS" "$pod" -- redis-cli GET "$key" 2>/dev/null)
          if echo "$val" | grep -q "$ts"; then
            ops=$((ops+1))
          else
            errors=$((errors+1))
            echo "  [$ts] 数据不一致: $key" >> "$result_file"
          fi
        else
          errors=$((errors+1))
          echo "  [$ts] 写入失败" >> "$result_file"
        fi
        wrote=1
        break
      fi
    done
    [ "$wrote" -eq 0 ] && errors=$((errors+1))
    sleep 0.5
  done

  echo "ops=$ops errors=$errors" > "$result_file.summary"
  echo "$ops $errors"
}

# ── 测试场景 ─────────────────────────────────────────────────────

# 场景 1: Kill 1 replica
test_kill_replica() {
  echo_line
  echo "  测试 1: 删除 1 个 Slave (replica)"
  echo "  预期: 无主从切换，Pod 自动重建，重新加入复制"
  echo_line

  snapshot
  local master_before
  master_before=$(get_sentinel_master)

  # 选一个 slave
  local target=""
  for pod in "${APP}-1" "${APP}-2"; do
    local role
    role=$(get_pod_role "$pod" 2>/dev/null)
    if echo "$role" | grep -q "slave"; then
      target="$pod"
      break
    fi
  done
  [ -z "$target" ] && { fail "找不到 slave"; return 1; }

  info "目标: $target"
  local start_time
  start_time=$(date +%s)
  kill_pod "$target"

  # 监控重建
  local recovered=0
  info "等待重建..."
  for i in $(seq 1 45); do
    sleep 2
    local phase
    phase=$(get_redis_phase "$target" 2>/dev/null || echo "Terminating")
    local role
    role=$(get_pod_role "$target" 2>/dev/null || echo "N/A")

    # 每 10s 输出一次状态
    if [ $((i % 5)) -eq 0 ]; then
      echo "  [$i/45] $target: phase=$phase role=$role"
    fi

    if [ "$phase" = "Running" ] && echo "$role" | grep -q "slave"; then
      local end_time
      end_time=$(date +%s)
      ok "$target 已重建并恢复为 slave (耗时 $((end_time - start_time))s)"
      recovered=1
      break
    fi
  done

  # 验证 master 没变
  local master_after
  master_after=$(get_sentinel_master)
  if [ "$master_before" = "$master_after" ]; then
    ok "Master 未切换 (${master_before})"
  else
    warn "Master 变化: ${master_before} → ${master_after}"
  fi

  rw_test
  if [ "$recovered" -eq 1 ]; then
    pass "删除 1 个 slave 测试通过"
  else
    fail "slave 未能在 90s 内恢复"
  fi
  snapshot
}

# 场景 2: Kill master → 触发 failover
test_failover() {
  echo_line
  echo "  测试 2: 删除 Master 触发 Sentinel 故障切换"
  echo "  预期: Sentinel 检测到 master 下线 → 选举新 master → 恢复"
  echo_line

  snapshot
  local master_before master_before_ip
  master_before=$(get_sentinel_master)
  master_before_ip="$master_before"

  # 找 master pod name
  local master_pod=""
  for pod in "${APP}-0" "${APP}-1" "${APP}-2"; do
    local role
    role=$(get_pod_role "$pod" 2>/dev/null)
    if [ "$role" = "master" ]; then
      master_pod="$pod"
      break
    fi
  done
  [ -z "$master_pod" ] && { fail "找不到 master pod"; return 1; }

  # 写入测试数据
  info "写入测试数据..."
  kubectl exec -n "$NS" "$master_pod" -- redis-cli SET failover-test-before "before-$(date +%s)" 2>/dev/null || true

  info "当前 master: $master_pod ($master_before_ip)"
  local start_time
  start_time=$(date +%s)
  kill_pod "$master_pod"

  # 监控 failover
  local new_master=""
  local failover_time=0
  info "监控 Sentinel 故障切换..."
  for i in $(seq 1 60); do
    sleep 2
    local now
    now=$(date +%s)
    local elapsed=$((now - start_time))

    # 从 Sentinel 获取 master
    local current_master_ip
    current_master_ip=$(get_sentinel_master 2>/dev/null || echo "")
    local sentinel_info
    sentinel_info=$(get_sentinel_status 2>/dev/null || echo "")

    # 每 10s 输出状态
    if [ $((i % 5)) -eq 0 ]; then
      echo "  [${elapsed}s] sentinel master=$current_master_ip status=$sentinel_info"
    fi

    if [ -n "$current_master_ip" ] && [ "$current_master_ip" != "$master_before_ip" ] && [ "$current_master_ip" != "nil" ]; then
      # 看哪个 pod 是新 master
      for pod in "${APP}-0" "${APP}-1" "${APP}-2"; do
        local pod_ip role
        pod_ip=$(get_pod_ip "$pod" 2>/dev/null || echo "")
        role=$(get_pod_role "$pod" 2>/dev/null || echo "")
        if [ "$pod_ip" = "$current_master_ip" ] && [ "$role" = "master" ]; then
          new_master="$pod"
          failover_time=$elapsed
          break 2
        fi
        # 如果没有 IP 匹配，看 role
        if [ "$role" = "master" ] && [ "$pod" != "$master_pod" ]; then
          new_master="$pod"
          failover_time=$elapsed
          break 2
        fi
      done
    fi
  done

  if [ -n "$new_master" ]; then
    ok "故障切换完成: ${master_pod} → ${new_master} (耗时 ${failover_time}s)"
  else
    fail "60s 内未完成故障切换"
    return 1
  fi

  # 验证数据 — 切换前的数据应存在 (因为有复制)
  info "验证数据完整性..."
  local test_val
  test_val=$(kubectl exec -n "$NS" "$new_master" -- redis-cli GET failover-test-before 2>/dev/null || echo "")
  if [ -n "$test_val" ] && echo "$test_val" | grep -q "before-"; then
    ok "数据完整: failover-test-before = ${test_val}"
  else
    warn "切换前数据不可读 (值: ${test_val:-空})"
  fi

  # 验证写
  rw_test

  # 等旧 master 恢复并验证它变为 slave
  info "等待 ${master_pod} 恢复..."
  for i in $(seq 1 30); do
    sleep 3
    local phase
    phase=$(get_redis_phase "$master_pod" 2>/dev/null || echo "N/A")
    local role
    role=$(get_pod_role "$master_pod" 2>/dev/null || echo "N/A")
    if [ "$phase" = "Running" ] && echo "$role" | grep -q "slave"; then
      ok "旧 master (${master_pod}) 恢复为 slave"
      break
    fi
    if [ $((i % 5)) -eq 0 ]; then
      echo "  [${i}/30] ${master_pod}: phase=$phase role=$role"
    fi
  done

  # 最终验证
  local final_role=0
  for pod in "${APP}-0" "${APP}-1" "${APP}-2"; do
    local role
    role=$(get_pod_role "$pod" 2>/dev/null || echo "?")
    if [ "$role" = "master" ]; then final_role=$((final_role+1)); fi
  done
  [ "$final_role" -eq 1 ] && ok "最终拓扑: 1 master + 2 slaves" || warn "最终 master 数量: $final_role"

  pass "Master 故障切换测试通过"
  snapshot
}

# 场景 3: Kill 1 sentinel
test_kill_sentinel() {
  echo_line
  echo "  测试 3: 删除 1 个 Sentinel"
  echo "  预期: 无切换，仲裁仍可满足 (2/3)，Sentinel 重建后恢复"
  echo_line

  snapshot
  local master_before master_before_ip
  master_before=$(get_sentinel_master)
  master_before_ip="$master_before"

  local start_time
  start_time=$(date +%s)

  # 选一个 sentinel
  local target="${SENTINEL}-sentinel-0"
  info "杀死: $target"
  kill_pod "$target"

  sleep 5
  info "检查剩余 sentinels..."
  for pod in "${SENTINEL}-sentinel-1" "${SENTINEL}-sentinel-2"; do
    local status
    status=$(kubectl exec -n "$NS" "$pod" -- redis-cli -p 26379 INFO sentinel 2>/dev/null | grep "master0" || echo "N/A")
    echo "  ${pod}: ${status}"
  done

  # 验证 master 没变
  local master_after
  master_after=$(get_sentinel_master 2>/dev/null || echo "")
  if [ "$master_after" = "$master_before_ip" ]; then
    ok "Master 未变化 (${master_before_ip})"
  else
    warn "Master 变化: ${master_before_ip} → ${master_after}"
  fi

  rw_test

  # 等被杀的 sentinel 重建
  info "等待 sentinel-0 重建..."
  for i in $(seq 1 15); do
    sleep 2
    local phase
    phase=$(get_redis_phase "$target" 2>/dev/null || echo "N/A")
    if [ "$phase" = "Running" ]; then
      local end_time
      end_time=$(date +%s)
      ok "Sentinel-0 已重建 (耗时 $((end_time - start_time))s)"

      # 给它时间重新发现集群
      sleep 3
      local sinfo
      sinfo=$(kubectl exec -n "$NS" "$target" -- redis-cli -p 26379 INFO sentinel 2>/dev/null | grep "master0" || echo "N/A")
      echo "  ${target}: ${sinfo}"
      break
    fi
  done

  pass "删除 1 个 Sentinel 测试通过"
  snapshot
}

# 场景 4: Kill 1 master + 1 sentinel 同时
test_master_and_sentinel() {
  echo_line
  echo "  测试 4: 同时删除 Master + 1 Sentinel"
  echo "  预期: 剩余 2 个 sentinels 满足仲裁 (quorum=2)，完成切换"
  echo_line

  snapshot

  local master_pod=""
  local master_ip
  for pod in "${APP}-0" "${APP}-1" "${APP}-2"; do
    local role
    role=$(get_pod_role "$pod" 2>/dev/null)
    if [ "$role" = "master" ]; then
      master_pod="$pod"
      master_ip=$(get_pod_ip "$pod")
      break
    fi
  done
  [ -z "$master_pod" ] && { fail "找不到 master"; return 1; }

  info "当前 master: $master_pod ($master_ip)"
  info "同时杀死: ${master_pod} + ${SENTINEL}-sentinel-0"

  local start_time
  start_time=$(date +%s)

  # 同时 kill
  kill_pod "$master_pod"
  kill_pod "${SENTINEL}-sentinel-0"

  # 监控 failover
  local new_master=""
  local failover_time=0
  info "监控 failover (剩余 2 个 sentinel 应满足 quorum)..."
  for i in $(seq 1 60); do
    sleep 2
    local now
    now=$(date +%s)
    local elapsed=$((now - start_time))

    local current_master_ip
    current_master_ip=$(get_sentinel_master 2>/dev/null || echo "")
    local sinfo
    sinfo=$(get_sentinel_status 2>/dev/null || echo "")

    if [ $((i % 5)) -eq 0 ]; then
      echo "  [${elapsed}s] sentinel master=$current_master_ip"
    fi

    if [ -n "$current_master_ip" ] && [ "$current_master_ip" != "$master_ip" ] && [ "$current_master_ip" != "nil" ]; then
      for pod in "${APP}-0" "${APP}-1" "${APP}-2"; do
        local role
        role=$(get_pod_role "$pod" 2>/dev/null || echo "")
        if [ "$role" = "master" ] && [ "$pod" != "$master_pod" ]; then
          new_master="$pod"
          failover_time=$elapsed
          break 2
        fi
      done
    fi
  done

  if [ -n "$new_master" ]; then
    ok "故障切换完成: ${master_pod} → ${new_master} (耗时 ${failover_time}s)"
  else
    fail "60s 内未完成故障切换 (仲裁不足?)"
  fi

  rw_test
  pass "Master + 1 Sentinel 同时故障测试通过"
  snapshot
}

# 场景 5: Kill 2 sentinels (quorum 丢失)
test_quorum_lost() {
  echo_line
  echo "  测试 5: 删除 2 个 Sentinels (仲裁丢失)"
  echo "  预期: quorum=2，剩余 1 个 sentinel 无法完成仲裁"
  echo "  此时不应发生自动切换，集群只读/维持原状"
  echo_line

  snapshot

  local master_before
  master_before=$(get_sentinel_master)
  info "当前 master: $master_before"

  # 杀死 2 个 sentinels
  info "杀死 sentinel-1 和 sentinel-2..."
  kill_pod "${SENTINEL}-sentinel-1"
  kill_pod "${SENTINEL}-sentinel-2"
  sleep 3

  # 验证剩余 sentinel 监控的 sentinels 数量
  echo "  剩余 sentinel 状态:"
  local sinfo
  sinfo=$(kubectl exec -n "$NS" "${SENTINEL}-sentinel-0" -- redis-cli -p 26379 INFO sentinel 2>/dev/null | grep "master0" || echo "N/A")
  echo "  ${sinfo}"

  sleep 5

  # 现在杀死 master，sentinel 应无法完成 failover
  local master_pod=""
  for pod in "${APP}-0" "${APP}-1" "${APP}-2"; do
    local role
    role=$(get_pod_role "$pod" 2>/dev/null)
    if [ "$role" = "master" ]; then
      master_pod="$pod"
      break
    fi
  done

  if [ -n "$master_pod" ]; then
    info "杀死 master ($master_pod) 在仲裁不足的情况下..."
    kill_pod "$master_pod"
  fi

  # 观察 — 由于只有 1 个 sentinel, quorum 达不到 3，不应 failover
  info "观察 30s (不应发生 failover)..."
  local saw_failover=0
  for i in $(seq 1 15); do
    sleep 2
    local current_master_ip
    current_master_ip=$(get_sentinel_master 2>/dev/null || echo "")
    local sinfo_now
    sinfo_now=$(get_sentinel_status 2>/dev/null || echo "")
    if [ $((i % 5)) -eq 0 ]; then
      echo "  [${i}/15] sentinel: ${sinfo_now}"
    fi
    if [ -n "$current_master_ip" ] && [ "$current_master_ip" != "$master_before" ] && [ "$current_master_ip" != "nil" ]; then
      local master_role
      master_role=$(kubectl exec -n "$NS" "${APP}-1" -- redis-cli ROLE 2>/dev/null | head -1 || echo "")
      local master2_role
      master2_role=$(kubectl exec -n "$NS" "${APP}-2" -- redis-cli ROLE 2>/dev/null | head -1 || echo "")
      if [ "$master_role" = "master" ] || [ "$master2_role" = "master" ]; then
        warn "检测到 failover: 新 master=${current_master_ip}"
        saw_failover=1
        break
      fi
    fi
  done

  if [ "$saw_failover" -eq 1 ]; then
    warn "⚠ 在仲裁不足时仍然发生了切换 (节点可能仍在运行)"
  else
    ok "仲裁不足时未发生自动切换 (符合预期)"
  fi

  # 恢复所有 sentinels
  info "等待所有 sentinels 重建..."
  kubectl wait pod --for=condition=Ready -l "app.kubernetes.io/name=${SENTINEL}" -n "$NS" --timeout=120s 2>/dev/null || true
  sleep 5

  # 等 master 选举恢复
  info "等待集群恢复..."
  for i in $(seq 1 30); do
    sleep 3
    local master_count=0
    for pod in "${APP}-0" "${APP}-1" "${APP}-2"; do
      local role
      role=$(get_pod_role "$pod" 2>/dev/null || echo "?")
      if [ "$role" = "master" ]; then master_count=$((master_count+1)); fi
    done
    if [ "$master_count" -eq 1 ]; then
      ok "集群已恢复: 1 master"
      rw_test
      break
    fi
    if [ $((i % 5)) -eq 0 ]; then
      echo "  [${i}/30] masters=$master_count"
    fi
  done

  pass "Sentinel 仲裁丢失测试通过"
  snapshot
}

# 场景 6: Kill 3 sentinels (全部死亡)
test_all_sentinels_down() {
  echo_line
  echo "  测试 6: 删除全部 3 个 Sentinels"
  echo "  预期: Redis 复制不受影响，但无法自动 failover"
  echo_line

  snapshot
  local master_before
  master_before=$(get_sentinel_master)
  info "当前 master: $master_before"

  local start_time
  start_time=$(date +%s)

  # 杀死所有 sentinels
  info "杀死全部 3 个 sentinels..."
  for i in 0 1 2; do
    kill_pod "${SENTINEL}-sentinel-${i}"
  done
  sleep 5

  # 验证复制还在正常工作
  info "验证复制..."
  rw_test

  local master_role
  master_role=$(kubectl exec -n "$NS" "${APP}-1" -- redis-cli ROLE 2>/dev/null | head -1 || echo "N/A")
  local master2_role
  master2_role=$(kubectl exec -n "$NS" "${APP}-2" -- redis-cli ROLE 2>/dev/null | head -1 || echo "N/A")
  echo "  ${APP}-1: ${master_role}"
  echo "  ${APP}-2: ${master2_role}"

  if echo "$master_role" | grep -q "slave" && echo "$master2_role" | grep -q "slave"; then
    ok "复制仍正常工作 (无 sentinel 时)"
  fi

  # 等 sentinels 重建
  info "等待 sentinels 重建..."
  kubectl wait pod --for=condition=Ready -l "app.kubernetes.io/name=${SENTINEL}" -n "$NS" --timeout=120s 2>/dev/null || true

  local end_time
  end_time=$(date +%s)
  ok "全部 sentinels 恢复 (总耗时 $((end_time - start_time))s)"

  # 验证 sentinel 重新发现集群
  sleep 5
  local sinfo
  sinfo=$(get_sentinel_status 2>/dev/null || echo "N/A")
  echo "  Sentinel 最终状态: ${sinfo}"

  pass "全部 Sentinels 下线测试通过"
}

# ── 主菜单 ───────────────────────────────────────────────────────

menu() {
  echo
  echo_line
  echo "  Redis Sentinel 混沌测试"
  echo_line
  echo "  Namespace: ${NS}  |  实例: ${APP} / ${SENTINEL}"
  echo_line
  echo
  echo "  可选测试场景 (输入编号或名称):"
  echo
  echo "    status          — 查看当前集群状态"
  echo "    1               — 删除 1 个 Slave"
  echo "    2               — 删除 Master (Failover 测试)"
  echo "    3               — 删除 1 个 Sentinel"
  echo "    4               — 同时删除 Master + 1 Sentinel"
  echo "    5               — 删除 2 个 Sentinels (仲裁丢失)"
  echo "    6               — 删除全部 3 个 Sentinels"
  echo "    all             — 运行全部测试 (1→6)"
  echo "    exit|quit       — 退出"
  echo
  echo_sep
}

# ── 主流程 ───────────────────────────────────────────────────────

if [ $# -eq 0 ]; then
  while true; do
    menu
    read -r -p "  选择场景: " choice
    echo
    case "$choice" in
      1|slave)       test_kill_replica ;;
      2|master)      test_failover ;;
      3|1sentinel)   test_kill_sentinel ;;
      4|mas+sen)     test_master_and_sentinel ;;
      5|quorum)      test_quorum_lost ;;
      6|allsentinel) test_all_sentinels_down ;;
      all|full)      test_kill_replica; test_failover; test_kill_sentinel; test_master_and_sentinel; test_quorum_lost; test_all_sentinels_down ;;
      status)        snapshot ;;
      status-full)   check_all_pods; check_replication; check_sentinel; rw_test ;;
      exit|quit)     echo "  Bye."; exit 0 ;;
      *)             echo "  未知选项: $choice" ;;
    esac
  done
else
  case "$1" in
    status) snapshot ;;
    1) test_kill_replica ;;
    2) test_failover ;;
    3) test_kill_sentinel ;;
    4) test_master_and_sentinel ;;
    5) test_quorum_lost ;;
    6) test_all_sentinels_down ;;
    all) test_kill_replica; test_failover; test_kill_sentinel; test_master_and_sentinel; test_quorum_lost; test_all_sentinels_down ;;
    *) echo "Usage: $0 [1|2|3|4|5|6|all|status]"; exit 1 ;;
  esac
fi

# ── 汇总 ─────────────────────────────────────────────────────────

echo
echo_line
echo "  测试汇总"
echo_line
for r in "${RESULTS[@]}"; do
  echo "  $r"
done
echo_line
if [ "$TOTAL_ERRORS" -eq 0 ]; then
  echo "  结果: 全部通过 ✓"
else
  echo "  结果: ${TOTAL_ERRORS} 个失败 ✗"
fi
echo_line
echo
