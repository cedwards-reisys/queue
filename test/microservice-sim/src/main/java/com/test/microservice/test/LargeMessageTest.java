package com.test.microservice.test;

import jakarta.jms.BytesMessage;
import jakarta.jms.Connection;
import jakarta.jms.ConnectionFactory;
import jakarta.jms.MessageConsumer;
import jakarta.jms.MessageProducer;
import jakarta.jms.Queue;
import jakarta.jms.Session;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.List;
import java.util.Random;
import java.util.UUID;

@Component
public class LargeMessageTest {

    private static final Logger log = LoggerFactory.getLogger(LargeMessageTest.class);

    private final ConnectionFactory connectionFactory;

    @Value("${test.queue-prefix}")
    private String queuePrefix;

    public LargeMessageTest(ConnectionFactory connectionFactory) {
        this.connectionFactory = connectionFactory;
    }

    public List<TestResult> run(int sizeMb) {
        List<TestResult> results = new ArrayList<>();

        if (sizeMb <= 0) {
            // Default: test multiple sizes
            int[] sizesKb = {100, 1024, 5120, 10240};
            for (int kb : sizesKb) {
                results.add(runSingle(kb * 1024));
            }
        } else {
            results.add(runSingle(sizeMb * 1024 * 1024));
        }

        return results;
    }

    private TestResult runSingle(int sizeBytes) {
        String runId = UUID.randomUUID().toString().substring(0, 8);
        String queueName = queuePrefix + ".large." + runId;
        String sizeLabel = formatSize(sizeBytes);
        long start = System.currentTimeMillis();

        log.info("[LargeMessage] Starting test: size={}, queue={}", sizeLabel, queueName);

        try (Connection connection = connectionFactory.createConnection()) {
            connection.start();

            // Generate random bytes simulating a PDF
            byte[] payload = new byte[sizeBytes];
            new Random().nextBytes(payload);

            // Compute original SHA-256
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            String originalHash = HexFormat.of().formatHex(digest.digest(payload));
            log.info("[LargeMessage] Original hash: {} (size={})", originalHash, sizeLabel);

            try (Session session = connection.createSession(false, Session.AUTO_ACKNOWLEDGE)) {
                Queue queue = session.createQueue(queueName);

                // Send
                try (MessageProducer producer = session.createProducer(queue)) {
                    BytesMessage msg = session.createBytesMessage();
                    msg.writeBytes(payload);
                    msg.setStringProperty("originalHash", originalHash);
                    msg.setIntProperty("originalSize", sizeBytes);
                    producer.send(msg);
                    log.info("[LargeMessage] Sent {} message", sizeLabel);
                }

                // Receive
                try (MessageConsumer consumer = session.createConsumer(queue)) {
                    BytesMessage received = (BytesMessage) consumer.receive(30000);

                    if (received == null) {
                        long duration = System.currentTimeMillis() - start;
                        return TestResult.failure("LargeMessage-" + sizeLabel,
                                "No message received within 30s timeout", duration, "Receive timeout");
                    }

                    // Read bytes
                    long bodyLength = received.getBodyLength();
                    byte[] receivedBytes = new byte[(int) bodyLength];
                    received.readBytes(receivedBytes);

                    // Verify size
                    if (receivedBytes.length != sizeBytes) {
                        long duration = System.currentTimeMillis() - start;
                        return TestResult.failure("LargeMessage-" + sizeLabel,
                                "Size mismatch: expected " + sizeBytes + ", got " + receivedBytes.length,
                                duration, "Size mismatch");
                    }

                    // Verify hash
                    digest.reset();
                    String receivedHash = HexFormat.of().formatHex(digest.digest(receivedBytes));
                    String sentHash = received.getStringProperty("originalHash");

                    if (!originalHash.equals(receivedHash)) {
                        long duration = System.currentTimeMillis() - start;
                        return TestResult.failure("LargeMessage-" + sizeLabel,
                                "Hash mismatch: original=" + originalHash + ", received=" + receivedHash,
                                duration, "SHA-256 hash mismatch");
                    }

                    if (!originalHash.equals(sentHash)) {
                        long duration = System.currentTimeMillis() - start;
                        return TestResult.failure("LargeMessage-" + sizeLabel,
                                "Property hash mismatch", duration, "originalHash property corrupted");
                    }

                    long duration = System.currentTimeMillis() - start;
                    log.info("[LargeMessage] {} verified successfully in {}ms", sizeLabel, duration);
                    return TestResult.success("LargeMessage-" + sizeLabel,
                            "Sent/received " + sizeLabel + ", SHA-256 verified, size matched",
                            duration);
                }
            }
        } catch (Exception e) {
            long duration = System.currentTimeMillis() - start;
            log.error("[LargeMessage] {} test failed", sizeLabel, e);
            return TestResult.failure("LargeMessage-" + sizeLabel, "Exception during test", duration, e.getMessage());
        }
    }

    private String formatSize(int bytes) {
        if (bytes >= 1024 * 1024) {
            return (bytes / (1024 * 1024)) + "MB";
        } else if (bytes >= 1024) {
            return (bytes / 1024) + "KB";
        }
        return bytes + "B";
    }
}
