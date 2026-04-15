package com.test.monolith.test;

import org.apache.activemq.ActiveMQConnectionFactory;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import javax.jms.BytesMessage;
import javax.jms.Connection;
import javax.jms.DeliveryMode;
import javax.jms.Message;
import javax.jms.MessageConsumer;
import javax.jms.MessageProducer;
import javax.jms.Queue;
import javax.jms.Session;
import java.util.Random;
import java.util.UUID;

@Component
public class PrefetchTest {

    private static final Logger log = LoggerFactory.getLogger(PrefetchTest.class);

    private final ActiveMQConnectionFactory connectionFactory;

    @Value("${test.queue-prefix}")
    private String queuePrefix;

    @Value("${test.prefetch-size:1000}")
    private int prefetchSize;

    public PrefetchTest(@Qualifier("rawConnectionFactory") ActiveMQConnectionFactory connectionFactory) {
        this.connectionFactory = connectionFactory;
    }

    public TestResult run(int count, int sizeKb) {
        String runId = UUID.randomUUID().toString().substring(0, 8);
        String queueName = queuePrefix + ".prefetch." + runId;
        long start = System.currentTimeMillis();

        Connection sendConn = null;
        Connection recvConn = null;
        try {
            log.info("[Prefetch] Starting test: count={}, sizeKb={}, prefetchSize={}, queue={}",
                    count, sizeKb, prefetchSize, queueName);

            int sizeBytes = sizeKb * 1024;
            byte[] payload = new byte[sizeBytes];
            new Random().nextBytes(payload);

            // Send all messages
            sendConn = connectionFactory.createConnection();
            sendConn.start();
            Session sendSession = sendConn.createSession(false, Session.AUTO_ACKNOWLEDGE);
            Queue queue = sendSession.createQueue(queueName);
            MessageProducer producer = sendSession.createProducer(queue);
            producer.setDeliveryMode(DeliveryMode.NON_PERSISTENT);

            log.info("[Prefetch] Sending {} messages of {}KB each", count, sizeKb);
            for (int i = 0; i < count; i++) {
                BytesMessage msg = sendSession.createBytesMessage();
                msg.writeBytes(payload);
                msg.setIntProperty("index", i);
                producer.send(msg);
            }
            producer.close();
            sendSession.close();
            long sendDur = System.currentTimeMillis() - start;
            log.info("[Prefetch] All {} messages sent in {}ms", count, sendDur);

            // Record heap before consuming
            Runtime runtime = Runtime.getRuntime();
            runtime.gc();
            long heapBefore = runtime.totalMemory() - runtime.freeMemory();

            // Consume all messages
            long consumeStart = System.currentTimeMillis();
            recvConn = connectionFactory.createConnection();
            recvConn.start();
            Session recvSession = recvConn.createSession(false, Session.AUTO_ACKNOWLEDGE);
            Queue recvQueue = recvSession.createQueue(queueName);
            MessageConsumer consumer = recvSession.createConsumer(recvQueue);

            int received = 0;
            long peakHeap = heapBefore;

            log.info("[Prefetch] Consuming messages (5s timeout per message)");
            while (true) {
                Message msg = consumer.receive(5000);
                if (msg == null) break;
                received++;

                // Sample heap periodically
                if (received % 10 == 0) {
                    long currentHeap = runtime.totalMemory() - runtime.freeMemory();
                    if (currentHeap > peakHeap) {
                        peakHeap = currentHeap;
                    }
                }
            }

            // Final heap check
            long heapAfter = runtime.totalMemory() - runtime.freeMemory();
            if (heapAfter > peakHeap) {
                peakHeap = heapAfter;
            }

            consumer.close();
            recvSession.close();

            long consumeDur = System.currentTimeMillis() - consumeStart;
            long totalDur = System.currentTimeMillis() - start;

            long heapDelta = peakHeap - heapBefore;
            long estimatedMemPerMsg = received > 0 ? heapDelta / received : 0;

            String details = String.format(
                    "messages=%d/%d, prefetchSize=%d, sendMs=%d, consumeMs=%d, "
                            + "heapBeforeMB=%.1f, peakHeapMB=%.1f, heapDeltaMB=%.1f, estMemPerMsgKB=%.1f",
                    received, count, prefetchSize, sendDur, consumeDur,
                    heapBefore / (1024.0 * 1024.0),
                    peakHeap / (1024.0 * 1024.0),
                    heapDelta / (1024.0 * 1024.0),
                    estimatedMemPerMsg / 1024.0);

            if (received != count) {
                return TestResult.failure("prefetch", details, totalDur,
                        "Expected " + count + " messages, received " + received);
            }

            log.info("[Prefetch] Test passed: {}", details);
            return TestResult.success("prefetch", details, totalDur);

        } catch (Exception e) {
            long dur = System.currentTimeMillis() - start;
            log.error("[Prefetch] Test failed", e);
            return TestResult.failure("prefetch", "Exception during test", dur, e.getMessage());
        } finally {
            closeQuietly(sendConn);
            closeQuietly(recvConn);
        }
    }

    private void closeQuietly(Connection connection) {
        if (connection != null) {
            try {
                connection.close();
            } catch (Exception e) {
                log.warn("[Prefetch] Error closing connection", e);
            }
        }
    }
}
