package com.test.monolith.test;

import org.apache.activemq.ActiveMQConnectionFactory;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import javax.jms.Connection;
import javax.jms.DeliveryMode;
import javax.jms.Message;
import javax.jms.MessageConsumer;
import javax.jms.MessageProducer;
import javax.jms.Queue;
import javax.jms.Session;
import javax.jms.TextMessage;
import java.util.UUID;

@Component
public class TransactionTest {

    private static final Logger log = LoggerFactory.getLogger(TransactionTest.class);

    private final ActiveMQConnectionFactory connectionFactory;

    @Value("${test.queue-prefix}")
    private String queuePrefix;

    public TransactionTest(@Qualifier("rawConnectionFactory") ActiveMQConnectionFactory connectionFactory) {
        this.connectionFactory = connectionFactory;
    }

    public TestResult runCommit() {
        String runId = UUID.randomUUID().toString().substring(0, 8);
        String queueName = queuePrefix + ".tx." + runId;
        long start = System.currentTimeMillis();
        int messageCount = 10;

        Connection sendConn = null;
        Connection recvConn = null;
        try {
            log.info("[Transaction-Commit] Starting test on queue: {}", queueName);

            // Send phase: transacted session
            sendConn = connectionFactory.createConnection();
            sendConn.start();
            Session txSession = sendConn.createSession(true, Session.SESSION_TRANSACTED);
            Queue queue = txSession.createQueue(queueName);

            MessageProducer producer = txSession.createProducer(queue);
            producer.setDeliveryMode(DeliveryMode.PERSISTENT);

            log.info("[Transaction-Commit] Sending {} messages in transaction", messageCount);
            for (int i = 0; i < messageCount; i++) {
                TextMessage msg = txSession.createTextMessage("tx-commit-msg-" + i);
                msg.setIntProperty("index", i);
                producer.send(msg);
            }

            log.info("[Transaction-Commit] Committing transaction");
            txSession.commit();
            producer.close();
            txSession.close();

            // Receive phase: non-transacted session
            recvConn = connectionFactory.createConnection();
            recvConn.start();
            Session recvSession = recvConn.createSession(false, Session.AUTO_ACKNOWLEDGE);
            Queue recvQueue = recvSession.createQueue(queueName);
            MessageConsumer consumer = recvSession.createConsumer(recvQueue);

            int received = 0;
            log.info("[Transaction-Commit] Consuming messages (5s timeout per message)");
            while (true) {
                Message msg = consumer.receive(5000);
                if (msg == null) break;
                received++;
            }

            consumer.close();
            recvSession.close();

            long dur = System.currentTimeMillis() - start;

            if (received != messageCount) {
                return TestResult.failure("transaction-commit",
                        "Expected " + messageCount + " messages, received " + received,
                        dur, "Message count mismatch after commit");
            }

            log.info("[Transaction-Commit] Test passed: {} messages committed and received in {}ms",
                    messageCount, dur);
            return TestResult.success("transaction-commit",
                    messageCount + " messages sent in transaction, committed, all received", dur);

        } catch (Exception e) {
            long dur = System.currentTimeMillis() - start;
            log.error("[Transaction-Commit] Test failed", e);
            return TestResult.failure("transaction-commit", "Exception during test", dur, e.getMessage());
        } finally {
            closeQuietly(sendConn);
            closeQuietly(recvConn);
        }
    }

    public TestResult runRollback() {
        String runId = UUID.randomUUID().toString().substring(0, 8);
        String queueName = queuePrefix + ".tx-rollback." + runId;
        long start = System.currentTimeMillis();
        int messageCount = 10;

        Connection sendConn = null;
        Connection recvConn = null;
        try {
            log.info("[Transaction-Rollback] Starting test on queue: {}", queueName);

            // Send phase: transacted session, then rollback
            sendConn = connectionFactory.createConnection();
            sendConn.start();
            Session txSession = sendConn.createSession(true, Session.SESSION_TRANSACTED);
            Queue queue = txSession.createQueue(queueName);

            MessageProducer producer = txSession.createProducer(queue);
            producer.setDeliveryMode(DeliveryMode.PERSISTENT);

            log.info("[Transaction-Rollback] Sending {} messages in transaction", messageCount);
            for (int i = 0; i < messageCount; i++) {
                TextMessage msg = txSession.createTextMessage("tx-rollback-msg-" + i);
                msg.setIntProperty("index", i);
                producer.send(msg);
            }

            log.info("[Transaction-Rollback] Rolling back transaction");
            txSession.rollback();
            producer.close();
            txSession.close();

            // Receive phase: try to consume (should get nothing)
            recvConn = connectionFactory.createConnection();
            recvConn.start();
            Session recvSession = recvConn.createSession(false, Session.AUTO_ACKNOWLEDGE);
            Queue recvQueue = recvSession.createQueue(queueName);
            MessageConsumer consumer = recvSession.createConsumer(recvQueue);

            int received = 0;
            log.info("[Transaction-Rollback] Attempting to consume (1s timeout)");
            Message msg = consumer.receive(1000);
            if (msg != null) {
                received++;
                // Drain any additional messages
                while ((msg = consumer.receive(500)) != null) {
                    received++;
                }
            }

            consumer.close();
            recvSession.close();

            long dur = System.currentTimeMillis() - start;

            if (received != 0) {
                return TestResult.failure("transaction-rollback",
                        "Expected 0 messages after rollback, received " + received,
                        dur, "Messages were delivered despite rollback");
            }

            log.info("[Transaction-Rollback] Test passed: 0 messages received after rollback in {}ms", dur);
            return TestResult.success("transaction-rollback",
                    messageCount + " messages sent in transaction, rolled back, 0 received", dur);

        } catch (Exception e) {
            long dur = System.currentTimeMillis() - start;
            log.error("[Transaction-Rollback] Test failed", e);
            return TestResult.failure("transaction-rollback", "Exception during test", dur, e.getMessage());
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
                log.warn("[Transaction] Error closing connection", e);
            }
        }
    }
}
