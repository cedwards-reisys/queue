package com.test.microservice.test;

import jakarta.jms.Connection;
import jakarta.jms.ConnectionFactory;
import jakarta.jms.MessageConsumer;
import jakarta.jms.MessageProducer;
import jakarta.jms.Queue;
import jakarta.jms.Session;
import jakarta.jms.BytesMessage;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.util.Random;
import java.util.UUID;

@Component
public class PrefetchTest {

    private static final Logger log = LoggerFactory.getLogger(PrefetchTest.class);

    private final ConnectionFactory connectionFactory;

    @Value("${test.queue-prefix}")
    private String queuePrefix;

    @Value("${test.consumer-window-size:1048576}")
    private int consumerWindowSize;

    public PrefetchTest(ConnectionFactory connectionFactory) {
        this.connectionFactory = connectionFactory;
    }

    public TestResult run(int count, int sizeKb) {
        String runId = UUID.randomUUID().toString().substring(0, 8);
        String queueName = queuePrefix + ".prefetch." + runId;
        long start = System.currentTimeMillis();

        log.info("[Prefetch] Starting test: count={}, sizeKb={}, consumerWindowSize={}, queue={}",
                count, sizeKb, consumerWindowSize, queueName);

        try (Connection connection = connectionFactory.createConnection()) {
            connection.start();

            byte[] payload = new byte[sizeKb * 1024];
            new Random().nextBytes(payload);

            // Send messages
            try (Session session = connection.createSession(false, Session.AUTO_ACKNOWLEDGE)) {
                Queue queue = session.createQueue(queueName);

                try (MessageProducer producer = session.createProducer(queue)) {
                    for (int i = 0; i < count; i++) {
                        BytesMessage msg = session.createBytesMessage();
                        msg.writeBytes(payload);
                        msg.setIntProperty("index", i);
                        producer.send(msg);
                    }
                }
                log.info("[Prefetch] Sent {} messages of {}KB each", count, sizeKb);
            }

            // Force GC and record baseline
            System.gc();
            Thread.sleep(100);
            Runtime runtime = Runtime.getRuntime();
            long heapBefore = runtime.totalMemory() - runtime.freeMemory();
            log.info("[Prefetch] Heap before consuming: {} MB", heapBefore / (1024 * 1024));

            // Consume all messages
            long consumeStart = System.currentTimeMillis();
            long peakHeap = heapBefore;
            int consumed = 0;

            try (Session session = connection.createSession(false, Session.AUTO_ACKNOWLEDGE)) {
                Queue queue = session.createQueue(queueName);

                try (MessageConsumer consumer = session.createConsumer(queue)) {
                    while (consumed < count) {
                        BytesMessage received = (BytesMessage) consumer.receive(5000);
                        if (received == null) {
                            log.warn("[Prefetch] Receive timeout after consuming {}/{} messages", consumed, count);
                            break;
                        }
                        consumed++;

                        // Sample heap periodically
                        if (consumed % 10 == 0 || consumed == count) {
                            long currentHeap = runtime.totalMemory() - runtime.freeMemory();
                            peakHeap = Math.max(peakHeap, currentHeap);
                        }
                    }
                }
            }

            long consumeDuration = System.currentTimeMillis() - consumeStart;
            long duration = System.currentTimeMillis() - start;
            long heapDelta = peakHeap - heapBefore;
            long estimatedMemPerMsg = consumed > 0 ? heapDelta / consumed : 0;

            String details = String.format(
                    "consumed=%d/%d, consumeDurationMs=%d, heapBeforeMB=%d, peakHeapMB=%d, " +
                    "heapDeltaMB=%d, estMemPerMsgKB=%d, consumerWindowSize=%d",
                    consumed, count, consumeDuration,
                    heapBefore / (1024 * 1024), peakHeap / (1024 * 1024),
                    heapDelta / (1024 * 1024), estimatedMemPerMsg / 1024,
                    consumerWindowSize);

            log.info("[Prefetch] {}", details);

            if (consumed != count) {
                return TestResult.failure("Prefetch", details, duration,
                        "Only consumed " + consumed + " of " + count + " messages");
            }

            return TestResult.success("Prefetch", details, duration);

        } catch (Exception e) {
            long duration = System.currentTimeMillis() - start;
            log.error("[Prefetch] Test failed", e);
            return TestResult.failure("Prefetch", "Exception during test", duration, e.getMessage());
        }
    }
}
