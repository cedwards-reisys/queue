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
import javax.jms.MessageConsumer;
import javax.jms.MessageProducer;
import javax.jms.Queue;
import javax.jms.Session;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.List;
import java.util.Random;
import java.util.UUID;

@Component
public class LargeMessageTest {

    private static final Logger log = LoggerFactory.getLogger(LargeMessageTest.class);

    private final ActiveMQConnectionFactory connectionFactory;

    @Value("${test.queue-prefix}")
    private String queuePrefix;

    public LargeMessageTest(@Qualifier("rawConnectionFactory") ActiveMQConnectionFactory connectionFactory) {
        this.connectionFactory = connectionFactory;
    }

    public TestResult run(int sizeMb) {
        String runId = UUID.randomUUID().toString().substring(0, 8);
        String queueName = queuePrefix + ".large." + runId;
        long start = System.currentTimeMillis();

        Connection connection = null;
        try {
            int sizeBytes = sizeMb * 1024 * 1024;
            log.info("[LargeMessage] Starting test: size={}MB, queue={}", sizeMb, queueName);

            // Generate random bytes (simulated PDF)
            byte[] payload = new byte[sizeBytes];
            new Random().nextBytes(payload);

            // Compute SHA-256
            String originalHash = sha256(payload);
            log.info("[LargeMessage] Generated {}MB payload, hash={}", sizeMb, originalHash);

            connection = connectionFactory.createConnection();
            connection.start();
            Session session = connection.createSession(false, Session.AUTO_ACKNOWLEDGE);
            Queue queue = session.createQueue(queueName);

            // Send
            log.info("[LargeMessage] Sending {}MB BytesMessage", sizeMb);
            MessageProducer producer = session.createProducer(queue);
            producer.setDeliveryMode(DeliveryMode.PERSISTENT);

            BytesMessage sendMsg = session.createBytesMessage();
            sendMsg.writeBytes(payload);
            sendMsg.setStringProperty("originalHash", originalHash);
            sendMsg.setIntProperty("originalSize", sizeBytes);
            producer.send(sendMsg);
            producer.close();
            log.info("[LargeMessage] Message sent");

            // Receive (30s timeout for large messages)
            log.info("[LargeMessage] Consuming message (30s timeout)");
            MessageConsumer consumer = session.createConsumer(queue);
            BytesMessage recvMsg = (BytesMessage) consumer.receive(30000);

            if (recvMsg == null) {
                long dur = System.currentTimeMillis() - start;
                return TestResult.failure("large-message-" + sizeMb + "MB",
                        "No message received within 30s", dur, "Receive timeout");
            }

            // Read received bytes
            long bodyLength = recvMsg.getBodyLength();
            byte[] received = new byte[(int) bodyLength];
            recvMsg.readBytes(received);

            // Verify size
            if (received.length != sizeBytes) {
                long dur = System.currentTimeMillis() - start;
                return TestResult.failure("large-message-" + sizeMb + "MB",
                        "Size mismatch: expected=" + sizeBytes + ", got=" + received.length,
                        dur, "Size mismatch");
            }

            // Verify hash
            String receivedHash = sha256(received);
            String sentHash = recvMsg.getStringProperty("originalHash");

            consumer.close();
            session.close();

            long dur = System.currentTimeMillis() - start;

            if (!originalHash.equals(receivedHash)) {
                return TestResult.failure("large-message-" + sizeMb + "MB",
                        "Hash mismatch: expected=" + originalHash + ", got=" + receivedHash,
                        dur, "SHA-256 hash mismatch");
            }

            if (!originalHash.equals(sentHash)) {
                return TestResult.failure("large-message-" + sizeMb + "MB",
                        "Property hash mismatch", dur, "originalHash property corrupted");
            }

            log.info("[LargeMessage] {}MB test passed in {}ms", sizeMb, dur);
            return TestResult.success("large-message-" + sizeMb + "MB",
                    sizeMb + "MB message sent/received, SHA-256 verified, size=" + sizeBytes + " bytes", dur);

        } catch (Exception e) {
            long dur = System.currentTimeMillis() - start;
            log.error("[LargeMessage] {}MB test failed", sizeMb, e);
            return TestResult.failure("large-message-" + sizeMb + "MB",
                    "Exception during test", dur, e.getMessage());
        } finally {
            closeQuietly(connection);
        }
    }

    public List<TestResult> runAllSizes() {
        int[] sizes = {0, 1, 5, 10}; // 0 = 100KB
        List<TestResult> results = new ArrayList<>();
        for (int size : sizes) {
            if (size == 0) {
                results.add(runKb(100));
            } else {
                results.add(run(size));
            }
        }
        return results;
    }

    public TestResult runKb(int sizeKb) {
        String runId = UUID.randomUUID().toString().substring(0, 8);
        String queueName = queuePrefix + ".large." + runId;
        long start = System.currentTimeMillis();

        Connection connection = null;
        try {
            int sizeBytes = sizeKb * 1024;
            log.info("[LargeMessage] Starting test: size={}KB, queue={}", sizeKb, queueName);

            byte[] payload = new byte[sizeBytes];
            new Random().nextBytes(payload);
            String originalHash = sha256(payload);

            connection = connectionFactory.createConnection();
            connection.start();
            Session session = connection.createSession(false, Session.AUTO_ACKNOWLEDGE);
            Queue queue = session.createQueue(queueName);

            MessageProducer producer = session.createProducer(queue);
            producer.setDeliveryMode(DeliveryMode.PERSISTENT);
            BytesMessage sendMsg = session.createBytesMessage();
            sendMsg.writeBytes(payload);
            sendMsg.setStringProperty("originalHash", originalHash);
            sendMsg.setIntProperty("originalSize", sizeBytes);
            producer.send(sendMsg);
            producer.close();

            MessageConsumer consumer = session.createConsumer(queue);
            BytesMessage recvMsg = (BytesMessage) consumer.receive(15000);

            if (recvMsg == null) {
                long dur = System.currentTimeMillis() - start;
                return TestResult.failure("large-message-" + sizeKb + "KB",
                        "No message received within 15s", dur, "Receive timeout");
            }

            byte[] received = new byte[(int) recvMsg.getBodyLength()];
            recvMsg.readBytes(received);
            String receivedHash = sha256(received);

            consumer.close();
            session.close();

            long dur = System.currentTimeMillis() - start;

            if (received.length != sizeBytes || !originalHash.equals(receivedHash)) {
                return TestResult.failure("large-message-" + sizeKb + "KB",
                        "Verification failed: sizeMatch=" + (received.length == sizeBytes)
                                + ", hashMatch=" + originalHash.equals(receivedHash),
                        dur, "Content verification failed");
            }

            log.info("[LargeMessage] {}KB test passed in {}ms", sizeKb, dur);
            return TestResult.success("large-message-" + sizeKb + "KB",
                    sizeKb + "KB message sent/received, SHA-256 verified", dur);

        } catch (Exception e) {
            long dur = System.currentTimeMillis() - start;
            log.error("[LargeMessage] {}KB test failed", sizeKb, e);
            return TestResult.failure("large-message-" + sizeKb + "KB",
                    "Exception during test", dur, e.getMessage());
        } finally {
            closeQuietly(connection);
        }
    }

    private String sha256(byte[] data) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        byte[] hash = digest.digest(data);
        StringBuilder hex = new StringBuilder();
        for (byte b : hash) {
            hex.append(String.format("%02x", b));
        }
        return hex.toString();
    }

    private void closeQuietly(Connection connection) {
        if (connection != null) {
            try {
                connection.close();
            } catch (Exception e) {
                log.warn("[LargeMessage] Error closing connection", e);
            }
        }
    }
}
