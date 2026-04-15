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
public class TransactionTest {

    private static final Logger log = LoggerFactory.getLogger(TransactionTest.class);

    private final ConnectionFactory connectionFactory;

    @Value("${test.queue-prefix}")
    private String queuePrefix;

    public TransactionTest(ConnectionFactory connectionFactory) {
        this.connectionFactory = connectionFactory;
    }

    public TestResult runCommit() {
        String runId = UUID.randomUUID().toString().substring(0, 8);
        String queueName = queuePrefix + ".tx." + runId;
        long start = System.currentTimeMillis();

        log.info("[Transaction-Commit] Starting test on queue: {}", queueName);

        try (Connection connection = connectionFactory.createConnection()) {
            connection.start();

            // Send 10 messages in a transacted session, then commit
            try (Session txSession = connection.createSession(true, Session.SESSION_TRANSACTED)) {
                Queue queue = txSession.createQueue(queueName);

                try (MessageProducer producer = txSession.createProducer(queue)) {
                    for (int i = 0; i < 10; i++) {
                        TextMessage msg = txSession.createTextMessage("tx-commit-message-" + i);
                        msg.setIntProperty("index", i);
                        producer.send(msg);
                    }
                    log.info("[Transaction-Commit] Sent 10 messages, committing...");
                    txSession.commit();
                    log.info("[Transaction-Commit] Transaction committed");
                }
            }

            // Consume with non-transacted session
            try (Session session = connection.createSession(false, Session.AUTO_ACKNOWLEDGE)) {
                Queue queue = session.createQueue(queueName);

                int count = 0;
                try (MessageConsumer consumer = session.createConsumer(queue)) {
                    while (true) {
                        TextMessage received = (TextMessage) consumer.receive(2000);
                        if (received == null) {
                            break;
                        }
                        count++;
                    }
                }

                long duration = System.currentTimeMillis() - start;

                if (count != 10) {
                    return TestResult.failure("Transaction-Commit",
                            "Expected 10 messages after commit, received " + count,
                            duration, "Message count mismatch: " + count + " != 10");
                }

                log.info("[Transaction-Commit] Verified all 10 messages received in {}ms", duration);
                return TestResult.success("Transaction-Commit",
                        "Sent 10 messages in transaction, committed, consumed all 10",
                        duration);
            }
        } catch (Exception e) {
            long duration = System.currentTimeMillis() - start;
            log.error("[Transaction-Commit] Test failed", e);
            return TestResult.failure("Transaction-Commit", "Exception during test", duration, e.getMessage());
        }
    }

    public TestResult runRollback() {
        String runId = UUID.randomUUID().toString().substring(0, 8);
        String queueName = queuePrefix + ".tx-rollback." + runId;
        long start = System.currentTimeMillis();

        log.info("[Transaction-Rollback] Starting test on queue: {}", queueName);

        try (Connection connection = connectionFactory.createConnection()) {
            connection.start();

            // Send 10 messages in a transacted session, then rollback
            try (Session txSession = connection.createSession(true, Session.SESSION_TRANSACTED)) {
                Queue queue = txSession.createQueue(queueName);

                try (MessageProducer producer = txSession.createProducer(queue)) {
                    for (int i = 0; i < 10; i++) {
                        TextMessage msg = txSession.createTextMessage("tx-rollback-message-" + i);
                        msg.setIntProperty("index", i);
                        producer.send(msg);
                    }
                    log.info("[Transaction-Rollback] Sent 10 messages, rolling back...");
                    txSession.rollback();
                    log.info("[Transaction-Rollback] Transaction rolled back");
                }
            }

            // Try to consume — should get nothing
            try (Session session = connection.createSession(false, Session.AUTO_ACKNOWLEDGE)) {
                Queue queue = session.createQueue(queueName);

                int count = 0;
                try (MessageConsumer consumer = session.createConsumer(queue)) {
                    while (true) {
                        TextMessage received = (TextMessage) consumer.receive(1000);
                        if (received == null) {
                            break;
                        }
                        count++;
                    }
                }

                long duration = System.currentTimeMillis() - start;

                if (count != 0) {
                    return TestResult.failure("Transaction-Rollback",
                            "Expected 0 messages after rollback, received " + count,
                            duration, "Messages survived rollback: " + count);
                }

                log.info("[Transaction-Rollback] Verified 0 messages after rollback in {}ms", duration);
                return TestResult.success("Transaction-Rollback",
                        "Sent 10 messages in transaction, rolled back, confirmed 0 deliverable",
                        duration);
            }
        } catch (Exception e) {
            long duration = System.currentTimeMillis() - start;
            log.error("[Transaction-Rollback] Test failed", e);
            return TestResult.failure("Transaction-Rollback", "Exception during test", duration, e.getMessage());
        }
    }
}
