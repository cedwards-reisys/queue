#!/usr/bin/env bash
set -euo pipefail

# JMS Source Code Analyzer
# Scans a Java/Spring monolith for JMS configurations, connection factories,
# listeners, producers, queue references, and transport settings.
# Outputs a migration-ready report.

# --- Colors (disabled when piped or --no-color) ---
if [[ -t 1 && "${NO_COLOR:-}" == "" ]]; then
    BOLD="\033[1m"
    GREEN="\033[32m"
    YELLOW="\033[33m"
    CYAN="\033[36m"
    RED="\033[31m"
    DIM="\033[2m"
    RESET="\033[0m"
else
    BOLD="" GREEN="" YELLOW="" CYAN="" RED="" DIM="" RESET=""
fi

usage() {
    cat <<EOF
Usage: $(basename "$0") <source-root> [OPTIONS]

Scan a Java/Spring monolith for JMS configurations and implementations.

Arguments:
    source-root              Path to project root (where pom.xml or build.gradle lives)

Options:
    -o, --output FILE        Write report to file (default: stdout only)
    -v, --verbose            Show matching file contents (not just locations)
    --no-color               Disable colored output
    --help                   Show this help

Examples:
    $(basename "$0") /path/to/monolith
    $(basename "$0") /path/to/monolith -o jms-report.txt
    $(basename "$0") /path/to/monolith -v
EOF
    exit 0
}

SOURCE_ROOT=""
OUTPUT_FILE=""
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -o|--output) OUTPUT_FILE="$2"; shift 2 ;;
        -v|--verbose) VERBOSE=true; shift ;;
        --no-color) NO_COLOR=1; BOLD="" GREEN="" YELLOW="" CYAN="" RED="" DIM="" RESET=""; shift ;;
        --help) usage ;;
        -*) echo "Unknown option: $1"; usage ;;
        *) SOURCE_ROOT="$1"; shift ;;
    esac
done

if [[ -z "${SOURCE_ROOT}" ]]; then
    echo "Error: source-root is required."
    usage
fi

if [[ ! -d "${SOURCE_ROOT}" ]]; then
    echo "Error: ${SOURCE_ROOT} is not a directory."
    exit 1
fi

# Tee to file if requested
if [[ -n "${OUTPUT_FILE}" ]]; then
    exec > >(tee "${OUTPUT_FILE}") 2>&1
    echo -e "${DIM}Writing report to ${OUTPUT_FILE}${RESET}"
    echo ""
fi

# --- Helpers ---
section() {
    echo ""
    echo -e "${BOLD}${GREEN}=== $1 ===${RESET}"
    echo ""
}

subsection() {
    echo -e "  ${BOLD}${CYAN}--- $1 ---${RESET}"
}

found_count=0
warn_count=0

search_files() {
    local pattern="$1"
    local label="$2"
    local file_glob="${3:-*.java}"
    local extra_glob="${4:-}"

    local results
    results=$(grep -rl --include="${file_glob}" ${extra_glob:+--include="${extra_glob}"} -E "${pattern}" "${SOURCE_ROOT}" 2>/dev/null || true)

    if [[ -n "${results}" ]]; then
        local count
        count=$(echo "${results}" | wc -l | xargs)
        found_count=$((found_count + count))
        echo -e "  ${GREEN}✓${RESET} ${label}: ${BOLD}${count} file(s)${RESET}"
        echo "${results}" | while read -r f; do
            echo -e "    ${DIM}${f#${SOURCE_ROOT}/}${RESET}"
        done
        if [[ "${VERBOSE}" == "true" ]]; then
            echo ""
            grep -rn --include="${file_glob}" ${extra_glob:+--include="${extra_glob}"} -E "${pattern}" "${SOURCE_ROOT}" 2>/dev/null | while read -r line; do
                echo -e "      ${line#${SOURCE_ROOT}/}"
            done
        fi
        echo ""
    else
        echo -e "  ${DIM}○ ${label}: none found${RESET}"
    fi
}

search_with_context() {
    local pattern="$1"
    local label="$2"
    local file_glob="${3:-*.java}"
    local context="${4:-3}"

    local results
    results=$(grep -rn --include="${file_glob}" -E "${pattern}" "${SOURCE_ROOT}" 2>/dev/null || true)

    if [[ -n "${results}" ]]; then
        local count
        count=$(echo "${results}" | wc -l | xargs)
        found_count=$((found_count + count))
        echo -e "  ${GREEN}✓${RESET} ${label}: ${BOLD}${count} match(es)${RESET}"
        if [[ "${VERBOSE}" == "true" ]]; then
            echo "${results}" | while read -r line; do
                echo -e "    ${line#${SOURCE_ROOT}/}"
            done
        fi
        echo ""
    else
        echo -e "  ${DIM}○ ${label}: none found${RESET}"
    fi
}

extract_values() {
    local pattern="$1"
    local file_glob="${2:-*.java}"
    local extra_glob="${3:-}"
    grep -roh --include="${file_glob}" ${extra_glob:+--include="${extra_glob}"} -E "${pattern}" "${SOURCE_ROOT}" 2>/dev/null | sort | uniq -c | sort -rn || true
}

# ===========================================================================
echo -e "${BOLD}JMS Source Code Analyzer${RESET}"
echo -e "Scanning: ${CYAN}${SOURCE_ROOT}${RESET}"
echo -e "Date: $(date '+%Y-%m-%d %H:%M:%S')"

# --- 0. Build file dependencies ---
section "1. Build Dependencies (JMS / ActiveMQ / Messaging)"

subsection "Maven (pom.xml)"
search_with_context "(activemq|artemis|jms|javax\.jms|jakarta\.jms|spring-jms|pooled-jms|messaginghub)" "JMS-related dependencies" "pom.xml"

subsection "Gradle (build.gradle*)"
search_with_context "(activemq|artemis|jms|javax\.jms|jakarta\.jms|spring-jms|pooled-jms|messaginghub)" "JMS-related dependencies" "build.gradle*"

# Check which JMS API — javax vs jakarta matters for Artemis migration
subsection "JMS API Version"
JAVAX_COUNT=$(grep -rl --include="*.java" "javax\.jms\." "${SOURCE_ROOT}" 2>/dev/null | wc -l | tr -d ' ' || true)
JAVAX_COUNT=${JAVAX_COUNT:-0}
JAKARTA_COUNT=$(grep -rl --include="*.java" "jakarta\.jms\." "${SOURCE_ROOT}" 2>/dev/null | wc -l | tr -d ' ' || true)
JAKARTA_COUNT=${JAKARTA_COUNT:-0}
echo -e "  javax.jms imports:  ${BOLD}${JAVAX_COUNT}${RESET} files"
echo -e "  jakarta.jms imports: ${BOLD}${JAKARTA_COUNT}${RESET} files"
if [[ ${JAVAX_COUNT} -gt 0 && ${JAKARTA_COUNT} -eq 0 ]]; then
    echo -e "  ${YELLOW}⚠ Uses javax.jms only — OpenWire compatibility mode on Artemis (no native client without migration to jakarta)${RESET}"
    warn_count=$((warn_count + 1))
elif [[ ${JAVAX_COUNT} -gt 0 && ${JAKARTA_COUNT} -gt 0 ]]; then
    echo -e "  ${YELLOW}⚠ Mixed javax/jakarta — transitional codebase${RESET}"
    warn_count=$((warn_count + 1))
fi
echo ""

# --- 1. Connection Factory Configurations ---
section "2. Connection Factory Configuration"

subsection "ActiveMQConnectionFactory (Classic)"
search_with_context "ActiveMQConnectionFactory" "ActiveMQConnectionFactory usage" "*.java" 3
search_with_context "ActiveMQConnectionFactory" "ActiveMQConnectionFactory in XML" "*.xml" 3

subsection "ArtemisConnectionFactory / ServerLocator"
search_with_context "(ActiveMQJMS|ServerLocator|TransportConfiguration).*artemis" "Artemis native client" "*.java"

subsection "Connection Pooling"
search_with_context "(PooledConnectionFactory|CachingConnectionFactory|JmsPoolConnectionFactory)" "Connection pooling" "*.java"
search_with_context "(PooledConnectionFactory|CachingConnectionFactory|JmsPoolConnectionFactory)" "Connection pooling in XML" "*.xml"

# Extract pool sizes
echo ""
subsection "Pool Size Settings"
POOL_SETTINGS=$(grep -rn --include="*.java" --include="*.xml" --include="*.properties" --include="*.yml" --include="*.yaml" \
    -E "(maxConnections|setMaxConnections|maximumActiveSessionPerConnection|setMaxSessionsPerConnection|max-connections|maxSessions|pool\.max|pool\.size|idleTimeout|setIdleTimeout|connectionIdleTimeout)" \
    "${SOURCE_ROOT}" 2>/dev/null || true)
if [[ -n "${POOL_SETTINGS}" ]]; then
    local_count=$(echo "${POOL_SETTINGS}" | wc -l | xargs)
    echo -e "  ${GREEN}✓${RESET} Pool configuration found: ${BOLD}${local_count} match(es)${RESET}"
    if [[ "${VERBOSE}" == "true" ]]; then
        echo "${POOL_SETTINGS}" | while read -r line; do
            echo -e "    ${line#${SOURCE_ROOT}/}"
        done
    fi
else
    echo -e "  ${RED}✗ No connection pool configuration found${RESET}"
    echo -e "  ${YELLOW}⚠ This likely means each JMS operation opens a raw TCP connection — major connection leak source${RESET}"
    warn_count=$((warn_count + 1))
fi
echo ""

# --- 2. Broker URLs ---
section "3. Broker URLs & Transport Settings"

subsection "Broker URL patterns"
BROKER_URLS=$(grep -roh --include="*.java" --include="*.xml" --include="*.properties" --include="*.yml" --include="*.yaml" \
    -E "(tcp|ssl|failover|nio|auto)://[^\"' ,}]+" "${SOURCE_ROOT}" 2>/dev/null | sort -u || true)
if [[ -n "${BROKER_URLS}" ]]; then
    local_count=$(echo "${BROKER_URLS}" | wc -l | xargs)
    echo -e "  ${GREEN}✓${RESET} Broker URLs found: ${BOLD}${local_count}${RESET}"
    echo "${BROKER_URLS}" | while read -r url; do
        echo -e "    ${BOLD}${url}${RESET}"
        if [[ "${VERBOSE}" == "true" ]]; then
            # Flag important transport params
            if echo "${url}" | grep -q "wireFormat.maxFrameSize"; then
                SIZE=$(echo "${url}" | sed -n 's/.*maxFrameSize=\([0-9]*\).*/\1/p' || true)
                [[ -n "${SIZE}" ]] && echo -e "      maxFrameSize: ${SIZE} bytes ($(( SIZE / 1048576 ))MB)"
            fi
            if echo "${url}" | grep -q "jms.prefetchPolicy"; then
                echo -e "      ${YELLOW}⚠ Prefetch set in URL — note for Artemis migration${RESET}"
            fi
            if echo "${url}" | grep -q "wireFormat.maxInactivityDuration"; then
                DUR=$(echo "${url}" | sed -n 's/.*maxInactivityDuration=\([0-9]*\).*/\1/p' || true)
                [[ -n "${DUR}" ]] && echo -e "      maxInactivityDuration: ${DUR}ms ($(( DUR / 1000 ))s)"
            fi
        fi
    done
else
    echo -e "  ${DIM}○ No hardcoded broker URLs (may be externalized to config)${RESET}"
fi
echo ""

subsection "Externalized broker config (application.properties / application.yml)"
search_with_context "(broker-url|broker\.url|brokerUrl|brokerURL|spring\.activemq|spring\.jms|spring\.artemis)" \
    "Broker config in properties/yml" "*.properties" 3
search_with_context "(broker-url|broker_url|brokerUrl|brokerURL|activemq|spring\.jms|artemis)" \
    "Broker config in YAML" "*.yml" 3
search_with_context "(broker-url|broker_url|brokerUrl|brokerURL|activemq|spring\.jms|artemis)" \
    "Broker config in YAML" "*.yaml" 3

# --- 3. JNDI ---
section "4. JNDI Usage (must be removed for Artemis)"

search_with_context "(InitialContext|jndi|JndiTemplate|JndiObjectFactoryBean|JndiDestinationResolver|java:comp/env)" \
    "JNDI lookups" "*.java"
search_with_context "(jndi-name|jndi-lookup|JndiObjectFactoryBean|JndiDestinationResolver)" \
    "JNDI in XML config" "*.xml"

JNDI_CHECK=$(grep -rl --include="*.java" --include="*.xml" -E "(InitialContext|jndi|JndiTemplate)" "${SOURCE_ROOT}" 2>/dev/null | wc -l | tr -d ' ' || true)
if [[ ${JNDI_CHECK:-0} -gt 0 ]]; then
    echo -e "  ${YELLOW}⚠ JNDI detected — Artemis does not use JNDI by default. These lookups must be replaced with direct bean injection.${RESET}"
    warn_count=$((warn_count + 1))
fi

# --- 4. Queue / Topic Declarations ---
section "5. Queue & Topic Declarations"

subsection "Queue names (string literals and constants)"
QUEUE_NAMES=$(grep -roh --include="*.java" --include="*.xml" --include="*.properties" --include="*.yml" --include="*.yaml" \
    -E '(queue://|"queue://)[^"]*"?|destination(-name)?[= :]+"?[A-Za-z0-9._-]+"?' "${SOURCE_ROOT}" 2>/dev/null | sort -u || true)
if [[ -n "${QUEUE_NAMES}" ]]; then
    local_count=$(echo "${QUEUE_NAMES}" | wc -l | xargs)
    echo -e "  ${GREEN}✓${RESET} Queue references found: ${BOLD}${local_count}${RESET}"
    if [[ "${VERBOSE}" == "true" ]]; then
        echo "${QUEUE_NAMES}" | while read -r q; do
            echo -e "    ${q}"
        done
    fi
else
    echo -e "  ${DIM}○ No explicit queue:// references (may use constants or @Value)${RESET}"
fi
echo ""

subsection "ActiveMQQueue / ActiveMQTopic constructors"
search_with_context "(new ActiveMQQueue|new ActiveMQTopic|ActiveMQQueue\(|ActiveMQTopic\()" \
    "Classic queue/topic objects" "*.java"

subsection "@JmsListener destination values"
JMS_LISTENERS=$(grep -rn --include="*.java" -E '@JmsListener' "${SOURCE_ROOT}" 2>/dev/null || true)
if [[ -n "${JMS_LISTENERS}" ]]; then
    COUNT=$(echo "${JMS_LISTENERS}" | wc -l | xargs)
    echo -e "  ${GREEN}✓${RESET} @JmsListener annotations: ${BOLD}${COUNT}${RESET}"

    # Extract destination names — always show these (they're the key info)
    DESTINATIONS=$(echo "${JMS_LISTENERS}" | sed -n 's/.*destination[[:space:]]*=[[:space:]]*"\{0,1\}\([^",)]*\).*/\1/p' || true)
    if [[ -n "${DESTINATIONS}" ]]; then
        echo -e "  Listener destinations:"
        echo "${DESTINATIONS}" | sort -u | while read -r dest; do
            echo -e "    ${BOLD}${dest}${RESET}"
        done
    fi

    if [[ "${VERBOSE}" == "true" ]]; then
        echo ""
        echo "${JMS_LISTENERS}" | while read -r line; do
            echo -e "    ${line#${SOURCE_ROOT}/}"
        done
    fi
else
    echo -e "  ${DIM}○ No @JmsListener annotations${RESET}"
fi
echo ""

subsection "@SendTo annotations"
search_with_context "@SendTo" "Reply-to destinations" "*.java"

subsection "Destination constants / enums"
search_with_context "(QUEUE_NAME|TOPIC_NAME|DESTINATION|JMS_QUEUE|JMS_TOPIC|queueName|topicName)" \
    "Queue/topic constants" "*.java"

# --- 5. JMS Listener Containers ---
section "6. JMS Listener Configuration"

subsection "DefaultMessageListenerContainer (XML)"
search_with_context "(DefaultMessageListenerContainer|SimpleMessageListenerContainer|JmsListenerContainerFactory)" \
    "Listener containers" "*.xml"

subsection "JmsListenerContainerFactory (Java config)"
search_with_context "(JmsListenerContainerFactory|DefaultJmsListenerContainerFactory|SimpleJmsListenerContainerFactory)" \
    "Listener container factories" "*.java"

subsection "Concurrency settings"
CONCURRENCY=$(grep -rn --include="*.java" --include="*.xml" --include="*.properties" --include="*.yml" --include="*.yaml" \
    -E "(setConcurrency|concurrency|concurrent-consumers|maxConcurrentConsumers|jms\.listener\.concurrency)" \
    "${SOURCE_ROOT}" 2>/dev/null || true)
if [[ -n "${CONCURRENCY}" ]]; then
    local_count=$(echo "${CONCURRENCY}" | wc -l | xargs)
    echo -e "  ${GREEN}✓${RESET} Concurrency configuration: ${BOLD}${local_count} match(es)${RESET}"
    if [[ "${VERBOSE}" == "true" ]]; then
        echo "${CONCURRENCY}" | while read -r line; do
            echo -e "    ${line#${SOURCE_ROOT}/}"
        done
    fi
else
    echo -e "  ${DIM}○ No explicit concurrency settings (defaults apply: usually 1 thread per listener)${RESET}"
fi
echo ""

# --- 6. JMS Producers ---
section "7. JMS Producers"

subsection "JmsTemplate usage"
search_with_context "(JmsTemplate|jmsTemplate\.|JmsMessagingTemplate)" "JmsTemplate producers" "*.java"

subsection "Direct MessageProducer usage"
search_with_context "(MessageProducer|session\.createProducer|\.send\()" "Raw JMS producers" "*.java"

subsection "convertAndSend / send patterns"
SEND_PATTERNS=$(grep -rn --include="*.java" \
    -E "\.(convertAndSend|send|sendAndReceive)\(" "${SOURCE_ROOT}" 2>/dev/null \
    | grep -i -E "(jms|template|producer|message)" || true)
if [[ -n "${SEND_PATTERNS}" ]]; then
    COUNT=$(echo "${SEND_PATTERNS}" | wc -l | xargs)
    echo -e "  ${GREEN}✓${RESET} Send operations: ${BOLD}${COUNT}${RESET}"
    if [[ "${VERBOSE}" == "true" ]]; then
        echo "${SEND_PATTERNS}" | head -30 | while read -r line; do
            echo -e "    ${line#${SOURCE_ROOT}/}"
        done
        [[ ${COUNT} -gt 30 ]] && echo -e "    ${DIM}... and $((COUNT - 30)) more${RESET}"
    fi
fi
echo ""

# --- 7. JMS Consumers ---
section "8. JMS Consumers"

subsection "MessageListener implementations"
search_with_context "(implements MessageListener|onMessage\(Message)" "MessageListener classes" "*.java"

subsection "MessageConsumer usage"
search_with_context "(MessageConsumer|session\.createConsumer|\.receive\(|\.receiveNoWait\()" "Raw JMS consumers" "*.java"

# --- 8. Transactions ---
section "9. Transaction Configuration"

subsection "JMS Transaction Manager"
search_with_context "(JmsTransactionManager|JtaTransactionManager|PlatformTransactionManager.*jms)" \
    "JMS transaction managers" "*.java"
search_with_context "(transaction-manager|transactionManager.*jms|JmsTransactionManager)" \
    "JMS transactions in XML" "*.xml"

subsection "Session transacted mode"
search_with_context "(SESSION_TRANSACTED|setSessionTransacted|sessionTransacted|session-transacted|isSessionTransacted)" \
    "Transacted sessions" "*.java"
search_with_context "(SESSION_TRANSACTED|session-transacted)" "Transacted sessions in XML" "*.xml"

subsection "Acknowledge modes"
ACK_MODES=$(grep -roh --include="*.java" --include="*.xml" --include="*.properties" --include="*.yml" \
    -E "(AUTO_ACKNOWLEDGE|CLIENT_ACKNOWLEDGE|DUPS_OK_ACKNOWLEDGE|SESSION_TRANSACTED|acknowledge-mode|setSessionAcknowledgeMode|acknowledgment-mode)" \
    "${SOURCE_ROOT}" 2>/dev/null | sort | uniq -c | sort -rn || true)
if [[ -n "${ACK_MODES}" ]]; then
    echo -e "  ${GREEN}✓${RESET} Acknowledge modes:"
    echo "${ACK_MODES}" | while read -r line; do
        echo -e "    ${line}"
    done
else
    echo -e "  ${DIM}○ No explicit ack modes (defaults to AUTO_ACKNOWLEDGE)${RESET}"
fi
echo ""

# --- 9. Request-Reply (temp queues) ---
section "10. Request-Reply & Temporary Queues"

search_with_context "(createTemporaryQueue|createTemporaryTopic|TemporaryQueue|TemporaryTopic)" \
    "Temporary queue usage" "*.java"
search_with_context "(sendAndReceive|JmsTemplate.*receive|correlationId|JMSCorrelationID|JMSReplyTo)" \
    "Request-reply patterns" "*.java"

TEMP_Q_COUNT=$(grep -rl --include="*.java" -E "(createTemporaryQueue|TemporaryQueue)" "${SOURCE_ROOT}" 2>/dev/null | wc -l | tr -d ' ' || true)
TEMP_Q_COUNT=${TEMP_Q_COUNT:-0}
if [[ ${TEMP_Q_COUNT} -gt 0 ]]; then
    echo -e "  ${RED}⚠ Temporary queues detected in ${TEMP_Q_COUNT} file(s)${RESET}"
    echo -e "  ${YELLOW}  Known issue: OpenWire temp queue request-reply fails on Artemis.${RESET}"
    echo -e "  ${YELLOW}  Workaround: switch to named reply queues or native Artemis client.${RESET}"
    warn_count=$((warn_count + 1))
fi
echo ""

# --- 10. Prefetch / Consumer Window ---
section "11. Prefetch & Consumer Window Settings"

search_with_context "(prefetchPolicy|prefetchSize|jms\.prefetch|consumerWindowSize|setConsumerWindowSize|consumer-window-size)" \
    "Prefetch/window configuration" "*.java"
search_with_context "(prefetchPolicy|prefetchSize|prefetch|consumerWindowSize)" \
    "Prefetch in properties/yml" "*.properties"

# Also check broker URL params for prefetch
PREFETCH_IN_URL=$(grep -roh --include="*.java" --include="*.properties" --include="*.yml" --include="*.yaml" \
    -E "prefetchPolicy\.[a-zA-Z]+=[0-9]+" "${SOURCE_ROOT}" 2>/dev/null | sort -u || true)
if [[ -n "${PREFETCH_IN_URL}" ]]; then
    echo -e "  ${GREEN}✓${RESET} Prefetch in broker URLs:"
    echo "${PREFETCH_IN_URL}" | while read -r p; do
        echo -e "    ${BOLD}${p}${RESET}"
    done
    echo -e "  ${YELLOW}⚠ OpenWire on Artemis uses ~2x memory per prefetched message vs Classic. Consider halving these values.${RESET}"
    warn_count=$((warn_count + 1))
fi
echo ""

# --- 11. Message Selectors ---
section "12. Message Selectors"

search_with_context "(selector|setMessageSelector|messageSelector|message-selector)" \
    "Message selectors" "*.java"
search_with_context "(selector|message-selector)" "Selectors in XML" "*.xml"

# --- 12. Message Types & Serialization ---
section "13. Message Types & Serialization"

subsection "Message creation patterns"
MSG_TYPES=$(grep -roh --include="*.java" \
    -E "(createTextMessage|createObjectMessage|createBytesMessage|createMapMessage|createStreamMessage)" \
    "${SOURCE_ROOT}" 2>/dev/null | sort | uniq -c | sort -rn || true)
if [[ -n "${MSG_TYPES}" ]]; then
    echo -e "  ${GREEN}✓${RESET} Message types used:"
    echo "${MSG_TYPES}" | while read -r line; do
        echo -e "    ${line}"
    done
    if echo "${MSG_TYPES}" | grep -q "createObjectMessage"; then
        echo -e "  ${YELLOW}⚠ ObjectMessage uses Java serialization — Artemis requires explicit class allowlisting.${RESET}"
        echo -e "  ${YELLOW}  Set: org.apache.activemq.artemis.jms.client.compatible.deserialization.allowList=${RESET}"
        warn_count=$((warn_count + 1))
    fi
else
    echo -e "  ${DIM}○ No direct message creation (probably using JmsTemplate.convertAndSend with MessageConverter)${RESET}"
fi
echo ""

subsection "MessageConverter implementations"
search_with_context "(MessageConverter|MappingJackson2MessageConverter|SimpleMessageConverter|MarshallingMessageConverter)" \
    "Message converters" "*.java"

# --- 13. Spring XML JMS Config ---
section "14. Spring XML Configuration"

search_files "(jms:|activemq|broker-url|listener-container|jms-template)" \
    "Spring JMS XML namespaces" "*.xml"

# --- 14. Advisory / Special Topics ---
section "15. Advisory Topics & ActiveMQ-Specific Features"

search_with_context "(ActiveMQ\.Advisory|ActiveMQ\.DLQ|ActiveMQ\.Scheduler|scheduledJobId|AMQ_SCHEDULED)" \
    "ActiveMQ-specific features" "*.java"
search_with_context "(BlobMessage|blob|streamMessage)" "Blob/stream messages" "*.java"
search_with_context "(compositeDestination|VirtualTopic|virtualTopic)" "Virtual/composite destinations" "*.java"
search_with_context "(VirtualTopic|composite|mirror)" "Virtual topics in XML" "*.xml"

# --- 15. Error Handling ---
section "16. Error Handling & DLQ Configuration"

search_with_context "(ErrorHandler|JmsListenerEndpointRegistry|BackOff|FixedBackOff|ExponentialBackOff)" \
    "Error handling config" "*.java"
search_with_context "(dead-letter|dlq|deadLetter|DeadLetter|error-handler)" \
    "DLQ references" "*.java"

# ===========================================================================
section "SUMMARY"

echo -e "  Files with JMS matches: ${BOLD}${found_count}${RESET}"
echo -e "  Migration warnings:     ${BOLD}${YELLOW}${warn_count}${RESET}"
echo ""

echo -e "${BOLD}Migration Checklist (based on scan):${RESET}"
echo ""

# Dynamic checklist based on what we found
if [[ ${JAVAX_COUNT} -gt 0 ]]; then
    echo -e "  [ ] javax.jms → remains on OpenWire protocol (no code change needed for Phase 1)"
    echo -e "      Future: migrate to jakarta.jms + Artemis native client for 2x memory efficiency"
fi

POOL_FOUND=$(grep -rl --include="*.java" --include="*.xml" -E "(PooledConnectionFactory|CachingConnectionFactory|JmsPoolConnectionFactory)" "${SOURCE_ROOT}" 2>/dev/null | wc -l | tr -d ' ' || true)
POOL_FOUND=${POOL_FOUND:-0}
if [[ ${POOL_FOUND} -eq 0 ]]; then
    echo -e "  ${RED}[!]${RESET} Add connection pooling (CachingConnectionFactory or pooled-jms)"
    echo -e "      Without pooling, every JMS op opens a new TCP connection — this is likely your 4-6K connection source"
else
    echo -e "  [✓] Connection pooling present — verify pool sizes are appropriate"
fi

if [[ ${TEMP_Q_COUNT} -gt 0 ]]; then
    echo -e "  ${RED}[!]${RESET} Replace temporary queue request-reply with named reply queues"
    echo -e "      OpenWire temp queues fail on Artemis (known compatibility issue)"
fi

JNDI_FOUND=$(grep -rl --include="*.java" --include="*.xml" -E "(InitialContext|jndi|JndiTemplate)" "${SOURCE_ROOT}" 2>/dev/null | wc -l | tr -d ' ' || true)
JNDI_FOUND=${JNDI_FOUND:-0}
if [[ ${JNDI_FOUND} -gt 0 ]]; then
    echo -e "  [ ] Remove JNDI lookups — replace with direct Spring bean injection"
fi

OBJ_MSG=$(grep -rl --include="*.java" "createObjectMessage" "${SOURCE_ROOT}" 2>/dev/null | wc -l | tr -d ' ' || true)
OBJ_MSG=${OBJ_MSG:-0}
if [[ ${OBJ_MSG} -gt 0 ]]; then
    echo -e "  [ ] Configure Artemis deserialization allowlist for ObjectMessage classes"
fi

ADVISORY=$(grep -rl --include="*.java" "ActiveMQ\.Advisory" "${SOURCE_ROOT}" 2>/dev/null | wc -l | tr -d ' ' || true)
ADVISORY=${ADVISORY:-0}
if [[ ${ADVISORY} -gt 0 ]]; then
    echo -e "  [ ] Replace ActiveMQ Advisory topic usage (not available in Artemis)"
fi

VTOPIC=$(grep -rl --include="*.java" --include="*.xml" -iE "VirtualTopic" "${SOURCE_ROOT}" 2>/dev/null | wc -l | tr -d ' ' || true)
VTOPIC=${VTOPIC:-0}
if [[ ${VTOPIC} -gt 0 ]]; then
    echo -e "  [ ] Migrate VirtualTopic pattern to Artemis native multicast addresses"
fi

echo ""
echo -e "  [ ] Update broker URLs (failover:// format may differ)"
echo -e "  [ ] Verify prefetch settings (OpenWire on Artemis uses ~2x memory per message)"
echo -e "  [ ] Test with monolith-sim / microservice-sim before cutover"
echo ""

echo -e "${BOLD}${GREEN}=== Done ===${RESET}"
