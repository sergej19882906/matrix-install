#!/usr/bin/env bash
# shellcheck shell=bash
# ---------------------------------------------------------------------------
# Мониторинг: Prometheus + Grafana + node-exporter + postgres-exporter + cAdvisor
# ---------------------------------------------------------------------------

render_monitoring_stack() {
	[[ "${ENABLE_MONITORING:-1}" == "1" ]] || { log "Мониторинг отключён"; return 0; }

	step "Рендеринг мониторинга"
	render "$TPL_DIR/docker-compose.monitoring.yml" "$STACK_DIR/docker-compose.monitoring.yml"
	render "$TPL_DIR/monitoring/prometheus/prometheus.yml" "$STACK_DIR/monitoring/prometheus/prometheus.yml"
	# Метрики MAS добавляются только в legacy-режиме
	if [[ "${ENABLE_MAS:-0}" == "1" ]]; then
		render "$TPL_DIR/monitoring/prometheus/mas-job.yml" "$STACK_DIR/monitoring/prometheus/mas-job.yml"
		cat "$STACK_DIR/monitoring/prometheus/mas-job.yml" >>"$STACK_DIR/monitoring/prometheus/prometheus.yml"
		rm -f "$STACK_DIR/monitoring/prometheus/mas-job.yml"
	else
		rm -f "$STACK_DIR/monitoring/prometheus/mas-job.yml"
	fi
	render "$TPL_DIR/monitoring/grafana/provisioning/datasources/datasources.yml" \
		"$STACK_DIR/monitoring/grafana/provisioning/datasources/datasources.yml"
	render "$TPL_DIR/monitoring/grafana/provisioning/dashboards/dashboards.yml" \
		"$STACK_DIR/monitoring/grafana/provisioning/dashboards/dashboards.yml"
	render "$TPL_DIR/monitoring/grafana/dashboards/matrix-overview.json" \
		"$STACK_DIR/monitoring/grafana/dashboards/matrix-overview.json"
	mkdir -p "$STACK_DIR/monitoring/prometheus/rules"
	ok "Конфигурация мониторинга готова"
}

start_monitoring_stack() {
	[[ "${ENABLE_MONITORING:-1}" == "1" ]] || return 0
	step "Запуск мониторинга"
	dc up -d prometheus grafana node-exporter postgres-exporter cadvisor
	# Перечитываем конфигурацию Prometheus (важно при повторной установке)
	dc exec -T prometheus wget -qO- --post-data='' http://127.0.0.1:9090/-/reload >/dev/null 2>&1 \
		|| dc up -d --force-recreate prometheus >/dev/null 2>&1 || true
	ok "Grafana: https://${GRAFANA_DOMAIN}/ (admin / $(grep -m1 '^GRAFANA_ADMIN_PASSWORD=' "$STACK_DIR/.env" | cut -d= -f2-))"
}
