package com.test.monolith.test;

import org.apache.activemq.ActiveMQConnectionFactory;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import javax.jms.Connection;
import javax.jms.DeliveryMode;
import javax.jms.MessageConsumer;
import javax.jms.MessageProducer;
import javax.jms.Queue;
import javax.jms.Session;
import javax.jms.TextMessage;
import java.util.UUID;

@Component
public class SmallMessageTest {

    private static final Logger log = LoggerFactory.getLogger(SmallMessageTest.class);

    private final ActiveMQConnectionFactory connectionFactory;

    @Value("${test.queue-prefix}")
    private String queuePrefix;

    public SmallMessageTest(@Qualifier("rawConnectionFactory") ActiveMQConnectionFactory connectionFactory) {
        this.connectionFactory = connectionFactory;
    }

    public TestResult run() {
        String runId = UUID.randomUUID().toString().substring(0, 8);
        String queueName = queuePrefix + ".small." + runId;
        long start = System.currentTimeMillis();

        Connection connection = null;
        try {
            log.info("[SmallMessage] Starting test on queue: {}", queueName);

            // Build 1KB body
            StringBuilder sb = new StringBuilder();
            while (sb.length() < 1024) {
                sb.append("ABCDEFGHIJ");
            }
            String body = sb.substring(0, 1024);

            connection = connectionFactory.createConnection();
            connection.start();
            Session session = connection.createSession(false, Session.AUTO_ACKNOWLEDGE);
            Queue queue = session.createQueue(queueName);

            // Send
            log.info("[SmallMessage] Sending 1KB message with custom properties");
            MessageProducer producer = session.createProducer(queue);
            producer.setDeliveryMode(DeliveryMode.PERSISTENT);

            TextMessage sendMsg = session.createTextMessage(body);
            sendMsg.setStringProperty("testString", "hello-world");
            sendMsg.setIntProperty("testInt", 42);
            sendMsg.setLongProperty("testLong", 9876543210L);
            sendMsg.setBooleanProperty("testBoolean", true);
            producer.send(sendMsg);
            producer.close();
            log.info("[SmallMessage] Message sent, JMSMessageID={}", sendMsg.getJMSMessageID());

            // Receive
            log.info("[SmallMessage] Consuming message (5s timeout)");
            MessageConsumer consumer = session.createConsumer(queue);
            TextMessage recvMsg = (TextMessage) consumer.receive(5000);

            if (recvMsg == null) {
                long dur = System.currentTimeMillis() - start;
                return TestResult.failure("small-message", "No message received within 5s", dur, "Receive timeout");
            }

            // Verify body
            String receivedBody = recvMsg.getText();
            if (!body.equals(receivedBody)) {
                long dur = System.currentTimeMillis() - start;
                return TestResult.failure("small-message",
                        "Body mismatch: expected length=" + body.length() + ", got length=" + receivedBody.length(),
                        dur, "Body content mismatch");
            }

            // Verify properties
            StringBuilder propErrors = new StringBuilder();
            if (!"hello-world".equals(recvMsg.getStringProperty("testString"))) {
                propErrors.append("String property mismatch. ");
            }
            if (recvMsg.getIntProperty("testInt") != 42) {
                propErrors.append("Int property mismatch. ");
            }
            if (recvMsg.getLongProperty("testLong") != 9876543210L) {
                propErrors.append("Long property mismatch. ");
            }
            if (!recvMsg.getBooleanProperty("testBoolean")) {
                propErrors.append("Boolean property mismatch. ");
            }

            consumer.close();
            session.close();

            long dur = System.currentTimeMillis() - start;

            if (propErrors.length() > 0) {
                return TestResult.failure("small-message",
                        "Body OK but properties failed: " + propErrors.toString().trim(), dur,
                        propErrors.toString().trim());
            }

            log.info("[SmallMessage] Test passed in {}ms", dur);
            return TestResult.success("small-message",
                    "1KB message sent/received, body and all 4 properties verified", dur);

        } catch (Exception e) {
            long dur = System.currentTimeMillis() - start;
            log.error("[SmallMessage] Test failed", e);
            return TestResult.failure("small-message", "Exception during test", dur, e.getMessage());
        } finally {
            closeQuietly(connection);
        }
    }

    private void closeQuietly(Connection connection) {
        if (connection != null) {
            try {
                connection.close();
            } catch (Exception e) {
                log.warn("[SmallMessage] Error closing connection", e);
            }
        }
    }
}
