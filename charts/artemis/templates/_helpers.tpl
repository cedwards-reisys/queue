{{/*
Chart name
*/}}
{{- define "artemis.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fullname — release + chart name
*/}}
{{- define "artemis.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "artemis.labels" -}}
helm.sh/chart: {{ include "artemis.name" . }}-{{ .Chart.Version | replace "+" "_" }}
{{ include "artemis.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.broker.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
environment: {{ .Values.environment }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "artemis.selectorLabels" -}}
app.kubernetes.io/name: {{ include "artemis.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app: artemis
{{- end }}

{{/*
Service account name
*/}}
{{- define "artemis.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "artemis.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Broker image
*/}}
{{- define "artemis.image" -}}
{{ .Values.broker.image.repository }}:{{ .Values.broker.image.tag }}
{{- end }}

{{/*
JVM args
*/}}
{{- define "artemis.jvmArgs" -}}
-Xms{{ .Values.broker.jvm.xms }} -Xmx{{ .Values.broker.jvm.xmx }} {{ .Values.broker.jvm.gc }}{{ if .Values.broker.jvm.extraOpts }} {{ .Values.broker.jvm.extraOpts }}{{ end }}
{{- end }}

{{/*
Static cluster connector list — generates comma-separated list of live broker DNS names
Used for cluster-connection static-connectors in broker.xml
*/}}
{{- define "artemis.clusterConnectors" -}}
{{- $fullname := include "artemis.fullname" . -}}
{{- $ns := .Release.Namespace -}}
{{- $replicas := int .Values.broker.replicas.live -}}
{{- $port := int .Values.ports.cluster -}}
{{- $connectors := list -}}
{{- range $i := until $replicas -}}
{{- $connectors = append $connectors (printf "tcp://%s-live-%d.%s-live-headless.%s.svc.cluster.local:%d" $fullname $i $fullname $ns $port) -}}
{{- end -}}
{{ join "," $connectors }}
{{- end }}

{{/*
Render broker.xml
*/}}
{{- define "artemis.brokerXml" -}}
<?xml version="1.0" encoding="UTF-8"?>
<configuration xmlns="urn:activemq" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
               xsi:schemaLocation="urn:activemq /schema/artemis-configuration.xsd">
  <core xmlns="urn:activemq:core">

    <name>__HOSTNAME__</name>
    <persistence-enabled>true</persistence-enabled>

    <!-- Journal -->
    <journal-type>{{ .Values.broker.journal.type }}</journal-type>
    <journal-buffer-size>{{ int64 .Values.broker.journal.bufferSize }}</journal-buffer-size>
    <journal-min-files>{{ int .Values.broker.journal.minFiles }}</journal-min-files>
    <journal-pool-files>{{ int .Values.broker.journal.poolFiles }}</journal-pool-files>
    <journal-file-size>{{ int64 .Values.broker.journal.fileSize }}</journal-file-size>
    <journal-compact-min-files>{{ int .Values.broker.journal.compactMinFiles }}</journal-compact-min-files>
    <journal-compact-percentage>{{ int .Values.broker.journal.compactPercentage }}</journal-compact-percentage>
    <journal-max-io>{{ int .Values.broker.journal.maxIo }}</journal-max-io>
    <journal-sync-transactional>{{ .Values.broker.journal.syncTransactional }}</journal-sync-transactional>
    <journal-sync-non-transactional>{{ .Values.broker.journal.syncNonTransactional }}</journal-sync-non-transactional>

    <!-- Directories -->
    <paging-directory>./data/paging</paging-directory>
    <bindings-directory>./data/bindings</bindings-directory>
    <journal-directory>./data/journal</journal-directory>
    <large-messages-directory>./data/large-messages</large-messages-directory>

    <!-- Memory / Paging -->
    <global-max-size>{{ int64 .Values.broker.paging.globalMaxSize }}</global-max-size>
    <max-disk-usage>{{ int .Values.broker.paging.maxDiskUsage }}</max-disk-usage>
    <page-sync-timeout>{{ int64 .Values.broker.paging.pageSyncTimeout }}</page-sync-timeout>

    <!-- Thread Pools -->
    <thread-pool-max-size>{{ int .Values.broker.threads.threadPoolMaxSize }}</thread-pool-max-size>
    <scheduled-thread-pool-max-size>{{ int .Values.broker.threads.scheduledThreadPoolMaxSize }}</scheduled-thread-pool-max-size>

    <!-- Connection Management -->
    <connection-ttl-override>{{ int64 .Values.broker.connections.ttlOverride }}</connection-ttl-override>
    <connection-ttl-check-interval>{{ int64 .Values.broker.connections.ttlCheckInterval }}</connection-ttl-check-interval>

    <!-- Graceful Shutdown -->
    <graceful-shutdown-enabled>{{ .Values.broker.gracefulShutdown.enabled }}</graceful-shutdown-enabled>
    <graceful-shutdown-timeout>{{ int64 .Values.broker.gracefulShutdown.timeout }}</graceful-shutdown-timeout>

    <!-- Background Tasks -->
    <message-expiry-scan-period>{{ int64 .Values.broker.backgroundTasks.messageExpiryScanPeriod }}</message-expiry-scan-period>
    <address-queue-scan-period>{{ int64 .Values.broker.backgroundTasks.addressQueueScanPeriod }}</address-queue-scan-period>

    <!-- Acceptors -->
    <acceptors>
      {{- if .Values.broker.tls.enabled }}
      <acceptor name="openwire">tcp://0.0.0.0:{{ .Values.ports.openwire }}?protocols={{ .Values.broker.connections.enabledProtocols }};connectionsAllowed={{ int .Values.broker.connections.maxConnections }};tcpSendBufferSize={{ int64 .Values.broker.connections.tcpSendBufferSize }};tcpReceiveBufferSize={{ int64 .Values.broker.connections.tcpReceiveBufferSize }};sslEnabled=true;keyStorePath=/var/lib/artemis/tls/keystore.p12;keyStorePassword={{ "{{TLS_KEYSTORE_PASSWORD}}" }};trustStorePath=/var/lib/artemis/tls/truststore.p12;trustStorePassword={{ "{{TLS_TRUSTSTORE_PASSWORD}}" }};needClientAuth={{ if .Values.broker.tls.requireClientAuth }}true{{ else }}false{{ end }}</acceptor>
      {{- else }}
      <acceptor name="openwire">tcp://0.0.0.0:{{ .Values.ports.openwire }}?protocols={{ .Values.broker.connections.enabledProtocols }};connectionsAllowed={{ int .Values.broker.connections.maxConnections }};tcpSendBufferSize={{ int64 .Values.broker.connections.tcpSendBufferSize }};tcpReceiveBufferSize={{ int64 .Values.broker.connections.tcpReceiveBufferSize }}</acceptor>
      {{- end }}
      {{- if .Values.broker.clustered }}
      {{- if .Values.broker.tls.enabled }}
      <acceptor name="cluster">tcp://0.0.0.0:{{ .Values.ports.cluster }}?protocols=CORE;sslEnabled=true;keyStorePath=/var/lib/artemis/tls/keystore.p12;keyStorePassword={{ "{{TLS_KEYSTORE_PASSWORD}}" }};trustStorePath=/var/lib/artemis/tls/truststore.p12;trustStorePassword={{ "{{TLS_TRUSTSTORE_PASSWORD}}" }};needClientAuth=true</acceptor>
      {{- else }}
      <acceptor name="cluster">tcp://0.0.0.0:{{ .Values.ports.cluster }}?protocols=CORE</acceptor>
      {{- end }}
      {{- end }}
      {{- if .Values.broker.ha.enabled }}
      {{- if .Values.broker.tls.enabled }}
      <acceptor name="replication">tcp://0.0.0.0:{{ .Values.ports.replication }}?protocols=CORE;sslEnabled=true;keyStorePath=/var/lib/artemis/tls/keystore.p12;keyStorePassword={{ "{{TLS_KEYSTORE_PASSWORD}}" }};trustStorePath=/var/lib/artemis/tls/truststore.p12;trustStorePassword={{ "{{TLS_TRUSTSTORE_PASSWORD}}" }};needClientAuth=true</acceptor>
      {{- else }}
      <acceptor name="replication">tcp://0.0.0.0:{{ .Values.ports.replication }}?protocols=CORE</acceptor>
      {{- end }}
      {{- end }}
    </acceptors>

    <!-- Security -->
    <security-enabled>true</security-enabled>

    {{- if .Values.broker.ha.enabled }}
    <!-- HA Policy -->
    <ha-policy>
      <replication>
        <{{ .haRole | default "primary" }}>
          <check-for-active-server>{{ .Values.broker.ha.checkForLiveServer }}</check-for-active-server>
          <group-name>__HA_GROUP__</group-name>
          <vote-on-replication-failure>{{ .Values.broker.ha.voteOnReplicationFailure }}</vote-on-replication-failure>
          <quorum-size>{{ .Values.broker.ha.quorumSize }}</quorum-size>
        </{{ .haRole | default "primary" }}>
      </replication>
    </ha-policy>
    {{- end }}

    {{- if .Values.broker.clustered }}
    <!-- Cluster -->
    {{- $maxLive := int .Values.broker.replicas.live -}}
    <connectors>
      {{- $fullname := include "artemis.fullname" . -}}
      {{- $ns := .Release.Namespace -}}
      {{- range $i := until $maxLive }}
      {{- if $.Values.broker.tls.enabled }}
      <connector name="live-{{ $i }}">tcp://{{ $fullname }}-live-{{ $i }}.{{ $fullname }}-live-headless.{{ $ns }}.svc.cluster.local:{{ $.Values.ports.cluster }}?sslEnabled=true;keyStorePath=/var/lib/artemis/tls/keystore.p12;keyStorePassword={{`{{TLS_KEYSTORE_PASSWORD}}`}};trustStorePath=/var/lib/artemis/tls/truststore.p12;trustStorePassword={{`{{TLS_TRUSTSTORE_PASSWORD}}`}}</connector>
      {{- else }}
      <connector name="live-{{ $i }}">tcp://{{ $fullname }}-live-{{ $i }}.{{ $fullname }}-live-headless.{{ $ns }}.svc.cluster.local:{{ $.Values.ports.cluster }}</connector>
      {{- end }}
      {{- end }}
    </connectors>

    <cluster-connections>
      <cluster-connection name="artemis-cluster">
        <connector-ref>live-__ORDINAL__</connector-ref>
        <message-load-balancing>{{ .Values.broker.cluster.messageLoadBalancing }}</message-load-balancing>
        <max-hops>{{ .Values.broker.cluster.maxHops }}</max-hops>
        <call-timeout>{{ .Values.broker.cluster.callTimeout }}</call-timeout>
        <retry-interval>{{ .Values.broker.cluster.retryInterval }}</retry-interval>
        <redistribution-delay>{{ .Values.broker.cluster.redistributionDelay }}</redistribution-delay>
        <forward-when-no-consumers>{{ .Values.broker.cluster.forwardWhenNoConsumers }}</forward-when-no-consumers>
        <static-connectors>
          {{- range $i := until $maxLive }}
          <connector-ref>live-{{ $i }}</connector-ref>
          {{- end }}
        </static-connectors>
      </cluster-connection>
    </cluster-connections>
    {{- end }}

    <!-- Address Settings -->
    <address-settings>
      <!-- Global defaults -->
      <address-setting match="#">
        <dead-letter-address>DLQ</dead-letter-address>
        <expiry-address>{{ .Values.broker.addressing.expiryAddress }}</expiry-address>
        <expiry-delay>{{ int64 .Values.broker.addressing.expiryDelay }}</expiry-delay>
        <max-size-bytes>{{ int64 .Values.broker.addressing.maxSizeBytes }}</max-size-bytes>
        <page-max-cache-size>{{ int .Values.broker.paging.pageMaxCacheSize }}</page-max-cache-size>
        <address-full-policy>{{ .Values.broker.addressing.addressFullPolicy }}</address-full-policy>
        <max-delivery-attempts>{{ int .Values.broker.addressing.maxDeliveryAttempts }}</max-delivery-attempts>
        <redelivery-delay>{{ int64 .Values.broker.addressing.redeliveryDelay }}</redelivery-delay>
        <max-redelivery-delay>{{ int64 .Values.broker.addressing.maxRedeliveryDelay }}</max-redelivery-delay>
        <redelivery-delay-multiplier>{{ printf "%.1f" (.Values.broker.addressing.redeliveryMultiplier | float64) }}</redelivery-delay-multiplier>
        <auto-create-queues>{{ .Values.broker.addressing.autoCreateQueues }}</auto-create-queues>
        <auto-create-addresses>{{ .Values.broker.addressing.autoCreateAddresses }}</auto-create-addresses>
        <default-queue-routing-type>{{ .Values.broker.addressing.defaultQueueRoutingType }}</default-queue-routing-type>
        {{- if .Values.broker.addressing.autoCreateDlq }}
        <auto-create-dead-letter-resources>true</auto-create-dead-letter-resources>
        <dead-letter-queue-prefix>{{ .Values.broker.addressing.dlqPrefix }}</dead-letter-queue-prefix>
        <dead-letter-queue-suffix>{{ .Values.broker.addressing.dlqSuffix }}</dead-letter-queue-suffix>
        {{- end }}
        {{- if gt (int .Values.broker.addressing.slowConsumerThreshold) 0 }}
        <slow-consumer-threshold>{{ .Values.broker.addressing.slowConsumerThreshold }}</slow-consumer-threshold>
        <slow-consumer-policy>{{ .Values.broker.addressing.slowConsumerPolicy }}</slow-consumer-policy>
        <slow-consumer-check-period>{{ .Values.broker.addressing.slowConsumerCheckPeriod }}</slow-consumer-check-period>
        {{- end }}
      </address-setting>
      {{- range .Values.broker.addressSettingOverrides }}
      <!-- Override: {{ .match }} -->
      <address-setting match="{{ .match }}">
        {{- if .maxDeliveryAttempts }}
        <max-delivery-attempts>{{ .maxDeliveryAttempts }}</max-delivery-attempts>
        {{- end }}
        {{- if .maxSizeBytes }}
        <max-size-bytes>{{ .maxSizeBytes }}</max-size-bytes>
        {{- end }}
        {{- if .redeliveryDelay }}
        <redelivery-delay>{{ .redeliveryDelay }}</redelivery-delay>
        {{- end }}
        {{- if .maxRedeliveryDelay }}
        <max-redelivery-delay>{{ .maxRedeliveryDelay }}</max-redelivery-delay>
        {{- end }}
        {{- if .redeliveryMultiplier }}
        <redelivery-delay-multiplier>{{ printf "%.1f" (.redeliveryMultiplier | float64) }}</redelivery-delay-multiplier>
        {{- end }}
        {{- if .addressFullPolicy }}
        <address-full-policy>{{ .addressFullPolicy }}</address-full-policy>
        {{- end }}
        {{- if .expiryDelay }}
        <expiry-delay>{{ .expiryDelay }}</expiry-delay>
        {{- end }}
        {{- if .slowConsumerThreshold }}
        <slow-consumer-threshold>{{ .slowConsumerThreshold }}</slow-consumer-threshold>
        <slow-consumer-policy>{{ default "NOTIFY" .slowConsumerPolicy }}</slow-consumer-policy>
        <slow-consumer-check-period>{{ default 30 .slowConsumerCheckPeriod }}</slow-consumer-check-period>
        {{- end }}
      </address-setting>
      {{- end }}
    </address-settings>

    <!-- Default addresses -->
    <addresses>
      <address name="DLQ">
        <anycast>
          <queue name="DLQ" />
        </anycast>
      </address>
      <address name="{{ .Values.broker.addressing.expiryAddress }}">
        <anycast>
          <queue name="{{ .Values.broker.addressing.expiryAddress }}" />
        </anycast>
      </address>
    </addresses>

  </core>
</configuration>
{{- end }}
