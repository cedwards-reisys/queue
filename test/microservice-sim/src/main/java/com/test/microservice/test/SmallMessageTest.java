package com.test.microservice.test;

import jakarta.jms.Connection;
import jakarta.jms.ConnectionFactory;
import jakarta.jms.MessageConsumer;
import jakarta.jms.MessageProducer;
import jakarta.jms.Queue;
import jakarta.jms.Session;
import jakarta.jms.TextMessage;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.util.UUID;

@Component
public class SmallMessageTest {

    private static final Logger log = LoggerFactory.getLogger(SmallMessageTest.class);

    private final ConnectionFactory connectionFactory;

    @Value("${test.queue-prefix}")
    private String queuePrefix;

    public SmallMessageTest(ConnectionFactory connectionFactory) {
        this.connectionFactory = connectionFactory;
    }

    public TestResult run() {
        String runId = UUID.randomUUID().toString().substring(0, 8);
        String queueName = queuePrefix + ".small." + runId;
        long start = System.currentTimeMillis();

        log.info("[SmallMessage] Starting test on queue: {}", queueName);

        try (Connection connection = connectionFactory.createConnection()) {
            connection.start();

            // Build a 1KB body
            StringBuilder sb = new StringBuilder();
            while (sb.length() < 1024) {
                sb.append("ABCDEFGHIJKLMNOP");
            }
            String body = sb.substring(0, 1024);

            // Send
            try (Session session = connection.createSession(false, Session.AUTO_ACKNOWLEDGE)) {
                Queue queue = session.createQueue(queueName);

                try (MessageProducer producer = session.createProducer(queue)) {
                    TextMessage msg = session.createTextMessage(body);
                    msg.setStringProperty("testStringProp", "hello-artemis");
                    msg.setIntProperty("testIntProp", 42);
                    msg.setLongProperty("testLongProp", 123456789L);
                    msg.setBooleanProperty("testBoolProp", true);
                    producer.send(msg);
                    log.info("[SmallMessage] Sent 1KB message with custom properties");
                }

                // Receive
                try (MessageConsumer consumer = session.createConsumer(queue)) {
                    TextMessage received = (TextMessage) consumer.receive(5000);

                    if (received == null) {
                        long duration = System.currentTimeMillis() - start;
                        return TestResult.failure("SmallMessage", "No message received within 5s timeout", duration, "Receive timeout");
                    }

                    // Verify body
                    if (!body.equals(received.getText())) {
                        long duration = System.currentTimeMillis() - start;
                        return TestResult.failure("SmallMessage",
                                "Body mismatch: expected length " + body.length() + ", got " + received.getText().length(),
                                duration, "Body content mismatch");
                    }

                    // Verify properties
                    StringBuilder errors = new StringBuilder();
                    if (!"hello-artemis".equals(received.getStringProperty("testStringProp"))) {
                        errors.append("String property mismatch. ");
                    }
                    if (received.getIntProperty("testIntProp") != 42) {
                        errors.append("Int property mismatch. ");
                    }
                    if (received.getLongProperty("testLongProp") != 123456789L) {
                        errors.append("Long property mismatch. ");
                    }
                    if (!received.getBooleanProperty("testBoolProp")) {
                        errors.append("Boolean property mismatch. ");
                    }

                    long duration = System.currentTimeMillis() - start;

                    if (!errors.isEmpty()) {
                        return TestResult.failure("SmallMessage", errors.toString(), duration, "Property verification failed");
                    }

                    log.info("[SmallMessage] All verifications passed in {}ms", duration);
                    return TestResult.success("SmallMessage",
                            "1KB message sent/received, body verified, all 4 properties (string, int, long, boolean) preserved",
                            duration);
                }
            }
        } catch (Exception e) {
            long duration = System.currentTimeMillis() - start;
            log.error("[SmallMessage] Test failed with exception", e);
            return TestResult.failure("SmallMessage", "Exception during test", duration, e.getMessage());
        }
    }
}
