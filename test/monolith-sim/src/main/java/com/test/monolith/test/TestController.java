package com.test.monolith.test;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import javax.jms.Connection;
import javax.jms.ConnectionFactory;
import javax.jms.MessageConsumer;
import javax.jms.MessageProducer;
import javax.jms.Queue;
import javax.jms.Session;
import javax.jms.TextMessage;

import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;

@RestController
@RequestMapping("/test")
public class TestController {

    private static final Logger log = LoggerFactory.getLogger(TestController.class);
    private static final String PERF_QUEUE = "perf.throughput";

    private final TestRunner testRunner;
    private final SmallMessageTest smallMessageTest;
    private final LargeMessageTest largeMessageTest;
    private final TransactionTest transactionTest;
    private final PrefetchTest prefetchTest;
    private final RequestReplyTest requestReplyTest;
    private final ConnectionFactory connectionFactory;
    private final AtomicLong produceCount = new AtomicLong(0);
    private final AtomicLong consumeCount = new AtomicLong(0);

    public TestController(TestRunner testRunner,
                          SmallMessageTest smallMessageTest,
                          LargeMessageTest largeMessageTest,
                          TransactionTest transactionTest,
                          PrefetchTest prefetchTest,
                          RequestReplyTest requestReplyTest,
                          ConnectionFactory connectionFactory) {
        this.testRunner = testRunner;
        this.smallMessageTest = smallMessageTest;
        this.largeMessageTest = largeMessageTest;
        this.transactionTest = transactionTest;
        this.prefetchTest = prefetchTest;
        this.requestReplyTest = requestReplyTest;
        this.connectionFactory = connectionFactory;
    }

    @GetMapping("/health")
    public ResponseEntity<Map<String, String>> health() {
        Map<String, String> status = new HashMap<>();
        status.put("status", "UP");
        status.put("application", "monolith-sim");
        return ResponseEntity.ok(status);
    }

    @PostMapping("/run-all")
    public ResponseEntity<List<TestResult>> runAll() {
        log.info("POST /test/run-all - executing all compatibility tests");
        List<TestResult> results = testRunner.runAll();
        return ResponseEntity.ok(results);
    }

    @PostMapping("/small-message")
    public ResponseEntity<TestResult> smallMessage() {
        log.info("POST /test/small-message");
        return ResponseEntity.ok(smallMessageTest.run());
    }

    @PostMapping("/large-message")
    public ResponseEntity<List<TestResult>> largeMessage(
            @RequestParam(value = "sizeMb", required = false) Integer sizeMb) {
        if (sizeMb != null) {
            log.info("POST /test/large-message?sizeMb={}", sizeMb);
            return ResponseEntity.ok(Collections.singletonList(largeMessageTest.run(sizeMb)));
        }
        log.info("POST /test/large-message (all sizes: 100KB, 1MB, 5MB, 10MB)");
        return ResponseEntity.ok(largeMessageTest.runAllSizes());
    }

    @PostMapping("/transaction-commit")
    public ResponseEntity<TestResult> transactionCommit() {
        log.info("POST /test/transaction-commit");
        return ResponseEntity.ok(transactionTest.runCommit());
    }

    @PostMapping("/transaction-rollback")
    public ResponseEntity<TestResult> transactionRollback() {
        log.info("POST /test/transaction-rollback");
        return ResponseEntity.ok(transactionTest.runRollback());
    }

    @PostMapping("/prefetch")
    public ResponseEntity<TestResult> prefetch(
            @RequestParam(value = "count", defaultValue = "100") int count,
            @RequestParam(value = "sizeKb", defaultValue = "100") int sizeKb) {
        log.info("POST /test/prefetch?count={}&sizeKb={}", count, sizeKb);
        return ResponseEntity.ok(prefetchTest.run(count, sizeKb));
    }

    @PostMapping("/request-reply")
    public ResponseEntity<TestResult> requestReply() {
        log.info("POST /test/request-reply");
        return ResponseEntity.ok(requestReplyTest.run());
    }

    @PostMapping("/produce")
    public ResponseEntity<Map<String, Object>> produce() {
        long start = System.currentTimeMillis();
        try (Connection conn = connectionFactory.createConnection()) {
            Session session = conn.createSession(false, Session.AUTO_ACKNOWLEDGE);
            Queue queue = session.createQueue(PERF_QUEUE);
            MessageProducer producer = session.createProducer(queue);
            StringBuilder sb = new StringBuilder(1024);
            while (sb.length() < 1024) sb.append("ABCDEFGHIJKLMNOP");
            TextMessage msg = session.createTextMessage(sb.substring(0, 1024));
            producer.send(msg);
            producer.close();
            session.close();
        } catch (Exception e) {
            Map<String, Object> err = new HashMap<>();
            err.put("error", e.getMessage());
            err.put("durationMs", System.currentTimeMillis() - start);
            return ResponseEntity.status(500).body(err);
        }
        long seq = produceCount.incrementAndGet();
        Map<String, Object> result = new HashMap<>();
        result.put("produced", true);
        result.put("seq", seq);
        result.put("durationMs", System.currentTimeMillis() - start);
        return ResponseEntity.ok(result);
    }

    @PostMapping("/consume")
    public ResponseEntity<Map<String, Object>> consume() {
        long start = System.currentTimeMillis();
        int count = 0;
        try (Connection conn = connectionFactory.createConnection()) {
            conn.start();
            Session session = conn.createSession(false, Session.AUTO_ACKNOWLEDGE);
            Queue queue = session.createQueue(PERF_QUEUE);
            MessageConsumer consumer = session.createConsumer(queue);
            while (consumer.receive(100) != null) {
                count++;
            }
            consumer.close();
            session.close();
        } catch (Exception e) {
            Map<String, Object> err = new HashMap<>();
            err.put("error", e.getMessage());
            err.put("durationMs", System.currentTimeMillis() - start);
            return ResponseEntity.status(500).body(err);
        }
        consumeCount.addAndGet(count);
        Map<String, Object> result = new HashMap<>();
        result.put("consumed", count);
        result.put("totalConsumed", consumeCount.get());
        result.put("durationMs", System.currentTimeMillis() - start);
        return ResponseEntity.ok(result);
    }
}
